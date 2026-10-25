# SEQS dom0 state: validation, policies, and qube creation; see docs/architecture.md.

{% set seqs = salt['pillar.get']('seqs', {}) %}
{% set ptpl = seqs.get('prefix_template', '') %}
{% set papp = seqs.get('prefix_app', '') %}
{% set pdvm = seqs.get('prefix_disposable', '') %}
{% set base_template = seqs.get('base_template', '') %}
{% set browser_vm = seqs.get('browser_vm', '') %}
{% set qcatalog = seqs.get('catalogue', {}) %}
{% set selection_file = '/var/lib/seqs/selection' %}
{% set selection_raw = salt['cmd.shell']('cat ' ~ selection_file ~ ' 2>/dev/null') %}
{% set selection = selection_raw.splitlines() %}
{% set exts = seqs.get('brave_extensions', {}) %}
{% set cleanup_dirs = seqs.get('cleanup_dirs', []) %}
{% set sys_usb_memory = seqs.get('sys_usb_memory', 0) %}
{% set nuc11_headset_fix = seqs.get('nuc11_headset_fix', false) %}
{% set usb_keyboard_prompt = seqs.get('usb_keyboard_prompt', true) %}
{% set dom0_launchers = seqs.get('dom0_launchers', []) %}
{% set tiling_keys = seqs.get('window_tiling_keys', {}) %}
{% set webcam_mode = seqs.get('webcam_usb_mode', 'disabled') %}
{% set webcam_controller = seqs.get('webcam_usb_controller', '') %}
{% set webcam_no_strict_reset = seqs.get('webcam_usb_no_strict_reset', false) %}
{% set webcam_usb_qube = seqs.get('webcam_usb_qube', 'sys-usb-webcam') %}
{% set webcam_scanner_dvm = seqs.get('webcam_scanner_dvm', '') %}
{% set webcam_normal_usb_qube = seqs.get('webcam_normal_usb_qube', 'sys-usb') %}
{% set webcam_scanner_qube = seqs.get('webcam_scanner_qube', 'seqs-qr-scanner') %}
{% set webcam_staging_qube = seqs.get('webcam_staging_qube', papp ~ 'qr-staging') %}

{# \Z, not $: Python's $ also matches before a trailing newline. #}
{% set name_re = '^[A-Za-z0-9_][A-Za-z0-9._-]*\\Z' %}
{# Reads `qvm-prefs VM` and succeeds only if netvm and default_dispvm are both
   explicitly None: a value inherited from a global default (flag D) could
   become networked when that default changes. #}
{% set explicitly_offline = "awk '($1 == \"netvm\" || $1 == \"default_dispvm\") && $2 == \"-\" && $3 == \"None\" { n++ } END { exit n != 2 }'" %}
{% set labels = ['red', 'orange', 'yellow', 'green', 'gray', 'blue', 'purple', 'black'] %}
{% set intents_dir = '/var/lib/seqs/intents' %}
{% set errors = [] %}

{#- One qubesd query lists every qube with its seqs-managed and seqs-recipe
    features, instead of one qvm-check/qvm-features process per name. An
    empty, unreadable, or partial list must never read as "no such qube
    exists": that would let the no-clobber guard below pass, so the run stops
    unless dom0 is in it and the query printed its final END line. #}
{% set inventory_cmd %}python3 -c 'import qubesadmin
for vm in qubesadmin.Qubes().domains:
    f = vm.features
    print(vm.name, "1" if f.get("seqs-managed") == "1" else "0", "".join((f.get("seqs-recipe") or "-").split()))
print("END")'{% endset %}
{% set inventory = {} %}
{% set inventory_lines = salt['cmd.shell'](inventory_cmd | trim).splitlines() %}
{% if inventory_lines[-1:] != ['END'] %}
{%   do errors.append("the list of existing qubes ended early -- refusing to continue without knowing which qubes exist") %}
{% endif %}
{% for line in inventory_lines %}
{%   set f = line.split() %}
{%   if f | length == 3 %}
{%     do inventory.update({f[0]: {'managed': f[1] == '1', 'recipe': '' if f[2] == '-' else f[2]}}) %}
{%   endif %}
{% endfor %}
{% if 'dom0' not in inventory %}
{%   do errors.append("could not list the existing qubes through qubesadmin -- refusing to continue without knowing which qubes exist") %}
{% endif %}

{# The selection: '@all [POSTFIX]', or one 'RECIPE [INSTANCE]' per line. qmap
   maps each instance to its catalogue entry, recipes to its recipe name. #}
{% set qmap = {} %}
{% set recipes = {} %}
{% if not selection %}
{%   do errors.append("runtime selection is missing -- invoke setup-qubes.sh with --qubes or --all") %}
{% endif %}
{% for line in selection %}
{%   set fields = line.split() %}
{%   if fields and fields[0] == '@all' %}
{%     if selection | length != 1 or fields | length > 2 %}
{%       do errors.append("runtime @all selection is malformed or mixed with named entries") %}
{%     elif fields | length == 2 and fields[1] | regex_match(name_re) is none %}
{%       do errors.append("runtime selection contains unsafe postfix '" ~ fields[1] ~ "'") %}
{%     else %}
{%       for recipe, spec in qcatalog.items() %}
{%         set instance = recipe ~ (('-' ~ fields[1]) if fields | length == 2 else '') %}
{%         do qmap.update({instance: spec}) %}
{%         do recipes.update({instance: recipe}) %}
{%       endfor %}
{%     endif %}
{%   elif fields | length not in [1, 2] %}
{%     do errors.append("runtime selection entry '" ~ line ~ "' is malformed") %}
{%   elif fields[0] | regex_match(name_re) is none or (fields | length == 2 and fields[1] | regex_match(name_re) is none) %}
{%     do errors.append("runtime selection contains unsafe recipe or instance name '" ~ line ~ "'") %}
{%   elif fields[0] not in qcatalog %}
{%     do errors.append("runtime selection names unknown catalogue entry '" ~ fields[0] ~ "'") %}
{%   elif fields | length == 2 and fields[1] != fields[0] and not fields[1].startswith(fields[0] ~ '-') %}
{%     do errors.append("runtime instance '" ~ fields[1] ~ "' is not derived from recipe '" ~ fields[0] ~ "'") %}
{%   else %}
{%     do qmap.update({fields[-1]: qcatalog[fields[0]]}) %}
{%     do recipes.update({fields[-1]: fields[0]}) %}
{%   endif %}
{% endfor %}
{# Recipes whose qubes may hand no link, open-in-VM request or disposable call
   to another qube: offline, no_handoff, and firewalled ones. They are tagged
   seqs-no-handoff below, and qube.sls sets no browser handoff in them. #}
{% set no_handoff = [] %}
{% for recipe, q in qcatalog.items() if q.get('offline') or q.get('no_handoff') or q.get('firewall') is not none %}
{%   do no_handoff.append(recipe) %}
{% endfor %}
{# The pillar gives a qube the recipe its name resolves to: an exact catalogue
   name, else the longest recipe followed by '-'. Refuse an instance that would
   resolve to another recipe, such as dev-full-x of dev beside dev-full. #}
{% for instance, recipe in recipes.items() %}
{%   set longest = namespace(name='') %}
{%   for c in qcatalog if (instance == c or instance.startswith(c ~ '-')) and c | length > longest.name | length %}
{%     set longest.name = c %}
{%   endfor %}
{%   if longest.name != recipe %}
{%     do errors.append("generated instance name '" ~ instance ~ "' collides with catalogue recipe '" ~ longest.name ~ "'") %}
{%   endif %}
{% endfor %}
{% if selection and not qmap %}
{%   do errors.append("runtime selection resolved to no qube instances") %}
{% endif %}

{# Interpolated into a shell command; the integer test rejects booleans. #}
{# The runner puts these into file paths and xfconf properties in dom0. #}
{% for d in dom0_launchers %}
{%   if d is not string or d | regex_match('^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop\\Z') is none %}
{%     do errors.append("dom0_launchers entry '" ~ d ~ "' must be a desktop file name such as qubes-qube-manager.desktop") %}
{%   endif %}
{% endfor %}
{% for shortcut, action in tiling_keys.items() %}
{%   if shortcut | regex_match('^(<(Super|Alt|Control|Shift|Primary|Meta|Hyper)>)+[A-Za-z0-9_]+\\Z') is none
      or action is not string or action | regex_match('^[a-z][a-z_]*_key\\Z') is none %}
{%     do errors.append("window_tiling_keys entry '" ~ shortcut ~ "': '" ~ action ~ "' must map a modifier shortcut such as <Super>Up to an xfwm4 action ending in _key") %}
{%   endif %}
{% endfor %}
{% if sys_usb_memory is not integer or sys_usb_memory < 0 %}
{%   do errors.append("sys_usb_memory '" ~ sys_usb_memory ~ "' must be a whole number of MiB (0 leaves sys-usb unchanged)") %}
{% endif %}
{# The kernel reads a patch file's subsystem ID as a signed number, so it
   cannot match Intel's 0x8086.... IDs and would apply the fix to any ALC256
   codec: only a computer that has the NUC 11's codec may enable it. #}
{% if nuc11_headset_fix is not sameas true and nuc11_headset_fix is not sameas false %}
{%   do errors.append("nuc11_headset_fix '" ~ nuc11_headset_fix ~ "' must be True or False") %}
{% elif nuc11_headset_fix %}
{%   set codecs = salt['cmd.shell']('for d in /sys/class/sound/hwC*D*; do echo "$(cat $d/vendor_id) $(cat $d/subsystem_id)"; done 2>/dev/null') %}
{%   if '0x10ec0256 0x80863004' not in codecs.splitlines() %}
{%     do errors.append("nuc11_headset_fix is True, but this computer has no Intel NUC 11 audio codec (Realtek ALC256, subsystem 0x80863004)") %}
{%   endif %}
{% endif %}
{% if usb_keyboard_prompt is not sameas true and usb_keyboard_prompt is not sameas false %}
{%   do errors.append("usb_keyboard_prompt '" ~ usb_keyboard_prompt ~ "' must be True or False") %}
{% endif %}
{% if webcam_mode not in ['disabled', 'dedicated', 'sequential'] %}
{%   do errors.append("webcam_usb_mode '" ~ webcam_mode ~ "' is invalid (expected disabled, dedicated, or sequential)") %}
{% endif %}
{% if webcam_mode == 'disabled' and webcam_controller %}
{%   do errors.append("webcam_usb_controller is set while webcam_usb_mode is disabled -- select a mode or clear the controller") %}
{% endif %}
{% if webcam_mode in ['dedicated', 'sequential'] and not webcam_controller %}
{%   do errors.append("webcam_usb_mode '" ~ webcam_mode ~ "' requires webcam_usb_controller") %}
{% endif %}
{# Lowercase only: qvm-pci lists and matches BDFs in lowercase, and the
   ownership checks below compare them as strings. #}
{% if webcam_controller and webcam_controller | regex_match('^[0-9a-f]{2}_[0-9a-f]{2}\.[0-7]\\Z') is none %}
{%   do errors.append("webcam_usb_controller '" ~ webcam_controller ~ "' is invalid (expected a lowercase BDF as listed by qvm-pci, such as 03_00.0)") %}
{% endif %}
{% for field, value in [('webcam_usb_qube', webcam_usb_qube), ('webcam_normal_usb_qube', webcam_normal_usb_qube), ('webcam_scanner_qube', webcam_scanner_qube), ('webcam_staging_qube', webcam_staging_qube)] %}
{%   if value | regex_match(name_re) is none %}
{%     do errors.append(field ~ " '" ~ value ~ "' has an unsafe name") %}
{%   endif %}
{% endfor %}
{% if webcam_controller and (not webcam_scanner_dvm or webcam_scanner_dvm | regex_match(name_re) is none) %}
{%   do errors.append("webcam_scanner_dvm is missing or unsafe") %}
{% endif %}
{% if webcam_controller and 'qr-camera' not in qmap and (webcam_scanner_dvm not in inventory) %}
{%   do errors.append("webcam_usb_controller requires qube 'qr-camera': select it in this run or build it first") %}
{% endif %}
{% if webcam_mode == 'sequential' and 'qr-staging' not in qmap and (webcam_staging_qube not in inventory) %}
{%   do errors.append("sequential webcam mode requires qube 'qr-staging': select it in this run or build it first") %}
{% endif %}
{% if webcam_mode == 'sequential' and (not qcatalog.get('qr-staging', {}).get('offline') or not qcatalog.get('qr-staging', {}).get('preserve_incoming')) %}
{%   do errors.append("sequential webcam mode requires qr-staging to be offline with preserve_incoming enabled") %}
{% endif %}
{% if webcam_mode == 'dedicated' and webcam_no_strict_reset %}
{%   do errors.append("dedicated webcam mode forbids webcam_usb_no_strict_reset -- without a power-off between transfers, only a strict reset clears the controller") %}
{% endif %}
{% if webcam_mode == 'sequential' and (webcam_normal_usb_qube not in inventory) %}
{%   do errors.append("sequential webcam mode requires existing normal USB qube '" ~ webcam_normal_usb_qube ~ "'") %}
{% endif %}
{% for special in [webcam_usb_qube, webcam_scanner_qube] %}
{%   if webcam_mode in ['dedicated', 'sequential'] and (special in inventory) and not inventory.get(special, {}).get('managed') %}
{%     do errors.append("special qube '" ~ special ~ "' already exists but is not marked seqs-managed -- refusing to adopt it") %}
{%   endif %}
{% endfor %}

{# ── Errors detected while the pillar itself was compiled (duplicate qube
     names etc. -- see qube_catalog handling in pillar config.sls). ─────── #}
{% for e in seqs.get('config_errors', []) %}
{%   do errors.append(e) %}
{% endfor %}

{# ── Pillar present at all? ─────────────────────────────────────────────── #}
{% if not qcatalog or not base_template or not browser_vm or not ptpl or not papp %}
{%   do errors.append("pillar 'seqs' is missing or incomplete -- was 'sudo qubesctl top.enable seqs.config pillar=true' run, and does /srv/pillar/seqs/config.sls exist?") %}
{% endif %}

{# ── Prefixes go into qube names and shell commands. ────────────────────── #}
{% for field, value in [('prefix_template', ptpl), ('prefix_app', papp), ('prefix_disposable', pdvm)] if value and value | regex_match(name_re) is none %}
{%   do errors.append(field ~ " '" ~ value ~ "' must match " ~ name_re) %}
{% endfor %}

{# ── Prefixes must match the globs in the .top files. Top files cannot read
     pillar, so the Z-*/A-* globs are duplicated there; a prefix change with
     stale top files would silently stop delivering pillar to every minion
     (each --targets apply would no-op). Fail loudly instead. ───────────── #}
{% if ptpl and papp %}
{%   set top_content = salt['cmd.shell']('cat /srv/pillar/seqs/config.top 2>/dev/null') %}
{%   if ("'" ~ ptpl ~ "*'") not in top_content or ("'" ~ papp ~ "*'") not in top_content %}
{%     do errors.append("prefix_template '" ~ ptpl ~ "' / prefix_app '" ~ papp ~ "' do not match the minion globs in /srv/pillar/seqs/config.top -- update the globs there (and in salt/seqs/qube.top if you use highstate), then re-run") %}
{%   endif %}
{% endif %}

{# ── Base template exists? ──────────────────────────────────────────────── #}
{% if base_template %}
{%   if base_template | regex_match(name_re) is none %}
{%     do errors.append("base_template '" ~ base_template ~ "' has an unsafe name") %}
{%   elif (base_template not in inventory) %}
{%     do errors.append("base template '" ~ base_template ~ "' does not exist -- install it first, e.g.: sudo qubes-dom0-update qubes-template-" ~ base_template) %}
{%   endif %}
{% endif %}

{# ── browser_vm must be a qube this run builds or one that already exists,
     but only when a selected qube hands links to it: offline, no_handoff and
     firewalled qubes never do (qube.sls), so selecting only those needs no
     browser. ── #}
{% if browser_vm %}
{%   if browser_vm | regex_match(name_re) is none %}
{%     do errors.append("browser_vm '" ~ browser_vm ~ "' has an unsafe name") %}
{%   else %}
{%     set bbase = browser_vm[(papp | length):] if papp and browser_vm.startswith(papp) else '' %}
{%     set handoff = [] %}
{%     for name in qmap if recipes[name] not in no_handoff and papp ~ name != browser_vm %}
{%       do handoff.append(name) %}
{%     endfor %}
{%     if handoff and not (bbase and bbase in qmap) and (browser_vm not in inventory) %}
{%       do errors.append("browser_vm '" ~ browser_vm ~ "' is neither selected nor an existing qube, but " ~ handoff | join(', ') ~ " would hand links to it -- select it in this run or build it first") %}
{%     endif %}
{%   endif %}
{% endif %}

{# ── Per-qube validation ───────────────────────────────────────────────── #}
{% for name, q in qcatalog.items() %}
{%   if name | regex_match(name_re) is none %}
{%     do errors.append("qube name '" ~ name ~ "' is unsafe") %}
{%   else %}
{%     if q.get('label') not in labels %}
{%       do errors.append("qube '" ~ name ~ "' has unknown label '" ~ q.get('label') ~ "'") %}
{%     endif %}
{%     for comp in q.get('components', []) %}
{%       if comp | regex_match(name_re) is none %}
{%         do errors.append("qube '" ~ name ~ "' references component with unsafe name '" ~ comp ~ "'") %}
{%       elif comp.startswith('brave-extension-') %}
{%         set en = comp[16:] %}
{%         if en not in exts %}
{%           do errors.append("qube '" ~ name ~ "' references unknown Brave extension '" ~ en ~ "' (not in brave_extensions)") %}
{%         elif exts[en] | regex_match('^[a-p]{32}\\Z') is none %}
{%           do errors.append("Brave extension '" ~ en ~ "' has invalid Chrome Web Store ID '" ~ exts[en] ~ "' (expected 32 chars a-p)") %}
{%         endif %}
{%       elif not salt['file.directory_exists']('/srv/salt/seqs/files/components/' ~ comp) %}
{%         do errors.append("qube '" ~ name ~ "' references unknown component '" ~ comp ~ "' (no /srv/salt/seqs/files/components/" ~ comp ~ "/)") %}
{%       endif %}
{%     endfor %}
{%     if q.get('main_app') is not none and (q.main_app is not string
          or q.main_app | regex_match('^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop\\Z') is none) %}
{%       do errors.append("qube '" ~ name ~ "': 'main_app' must be a desktop file name such as 'signal-desktop.desktop'") %}
{%     endif %}
{#     Optional outbound allowlist ('firewall' key): validate before any
       entry is interpolated into a qvm-firewall command below. #}
{%     set fw = q.get('firewall') %}
{%     if q.get('dispvm_template') and not q.get('offline') and q.get('netvm') is none %}
{%       do errors.append("qube '" ~ name ~ "' is a DisposableVM template but neither offline nor routed through a 'netvm' network provider") %}
{%     endif %}
{#     'netvm' names the catalogue entry of a network provider; the qube and
       its named disposable use that entry's app qube as NetVM. #}
{%     set nv = q.get('netvm') %}
{%     if nv is not none %}
{%       if nv is not string or nv | regex_match(name_re) is none or not qcatalog.get(nv, {}).get('network_provider') %}
{%         do errors.append("qube '" ~ name ~ "': 'netvm' must name a catalogue entry with 'network_provider'") %}
{%       elif q.get('offline') or q.get('network_provider') %}
{%         do errors.append("qube '" ~ name ~ "' sets 'netvm' together with 'offline' or 'network_provider'") %}
{%       endif %}
{%     endif %}
{%     if q.get('named_disposable') and not q.get('dispvm_template') %}
{%       do errors.append("qube '" ~ name ~ "' sets 'named_disposable' but not 'dispvm_template' -- a named disposable can only derive from a dispvm template") %}
{%     endif %}
{%     if q.get('network_provider') and q.get('offline') %}
{%       do errors.append("qube '" ~ name ~ "' sets both 'network_provider' and 'offline' -- a network provider requires an upstream NetVM") %}
{%     endif %}
{%     if q.get('network_provider') and q.get('dispvm_template') %}
{%       do errors.append("qube '" ~ name ~ "' sets both 'network_provider' and 'dispvm_template' -- persistent network-provider configuration requires an AppVM") %}
{%     endif %}
{#     An audio qube hears and records every qube that uses it, so it must
       have no network; its policy names its app qube, which a disposable
       template's disposables are not. #}
{%     if q.get('audio_provider') and (not q.get('offline') or q.get('dispvm_template')) %}
{%       do errors.append("qube '" ~ name ~ "' sets 'audio_provider' without 'offline' or with 'dispvm_template' -- an audio qube must be an offline app qube") %}
{%     endif %}
{%     if q.get('named_disposable') and (not pdvm or pdvm | regex_match(name_re) is none) %}
{%       do errors.append("qube '" ~ name ~ "' requests a named disposable but prefix_disposable is missing or unsafe") %}
{%     endif %}
{%     if fw is not none %}
{%       if fw is string or fw is not sequence %}
{%         do errors.append("qube '" ~ name ~ "': 'firewall' must be a list of allowlist entries") %}
{%       else %}
{%         if q.get('offline') %}
{%           do errors.append("qube '" ~ name ~ "' sets both 'offline' and 'firewall' -- contradictory: offline removes the netvm entirely, there is no egress to filter") %}
{%         endif %}
{#         The firewall state keeps the list on the app qube only. #}
{%         if q.get('named_disposable') %}
{%           do errors.append("qube '" ~ name ~ "' sets both 'named_disposable' and 'firewall' -- SEQS keeps the allowlist on the app qube only, not on its named disposable") %}
{%         endif %}
{%         for e in fw %}
{%           set es = e | string %}
{%           set port = es.split(':')[1] if ':' in es else '1' %}
{%           set host = es.split(':')[0] %}
{%           set octet = '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])' %}
{#           Qubes rejects a port outside 1-65535 or a malformed dotted-quad
             host only after egress is already closed. #}
{%           if e not in ['dns', 'icmp'] and ((es | regex_match('^[A-Za-z0-9._-]+(:[0-9]{1,5})?\\Z')) is none
                or (port | int) < 1 or (port | int) > 65535
                or ((host | regex_match('^[0-9.]+$')) is not none
                    and (host | regex_match('^' ~ octet ~ '([.]' ~ octet ~ '){3}$')) is none)) %}
{%             do errors.append("qube '" ~ name ~ "' has invalid firewall entry '" ~ e ~ "' (expected hostname/IPv4 with optional :port 1-65535, or the tokens 'dns' / 'icmp')") %}
{%           endif %}
{%         endfor %}
{%       endif %}
{%     endif %}
{%   endif %}
{% endfor %}

{# ── A selected qube's 'netvm' provider must be selected in this run or be
     an existing qube SEQS built for that recipe. ── #}
{% for name, q in qmap.items() if q.get('netvm') is string and q.netvm in qcatalog %}
{%   set provider = papp ~ q.netvm %}
{%   if q.netvm not in qmap and inventory.get(provider, {}).get('recipe') != q.netvm %}
{%     do errors.append("qube '" ~ name ~ "' needs its netvm '" ~ provider ~ "': select '" ~ q.netvm ~ "' in this run or build it first") %}
{%   endif %}
{% endfor %}

{# ── No-clobber: adopt a selected instance's qubes only if they carry
     seqs-managed or an interrupted-run intent marker, and only for the
     recipe they were built for. Iterates instances, not catalogue names,
     so --postfix instances are covered too. ─────────────────────────── #}
{% for name, q in qmap.items() %}
{%   set recipe = recipes[name] %}
{%   for vmname in [ptpl ~ name, papp ~ name] + ([pdvm ~ name] if q.get('named_disposable') and pdvm else []) if vmname in inventory %}
{%     if not inventory[vmname].managed and not salt['file.file_exists'](intents_dir ~ '/' ~ vmname) %}
{%       do errors.append("qube '" ~ vmname ~ "' already exists but is not marked seqs-managed -- refusing to adopt it (remove or rename it, or set: qvm-features " ~ vmname ~ " seqs-managed 1)") %}
{%     elif inventory[vmname].managed and inventory[vmname].recipe and inventory[vmname].recipe != recipe %}
{%       do errors.append("qube '" ~ vmname ~ "' is managed for recipe '" ~ inventory[vmname].recipe ~ "', not requested recipe '" ~ recipe ~ "' -- refusing to repurpose it") %}
{%     endif %}
{%   endfor %}
{% endfor %}

{# ── vCPU count ('vcpus' key) and CPU pinning ('cpu_pinning' key, a
     per-qube libvirt file that Qubes applies at every start). Values are
     interpolated into states and that file, so they must be plain integers,
     and pinned cores must exist on this machine. ── #}
{% set libvirt_dir = '/etc/qubes/templates/libvirt/xen/by-name' %}
{% set pin_marker = '{# Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten. #}' %}
{% set host_cpus = salt['cmd.shell']("xl info 2>/dev/null | awk '$1 == \"nr_cpus\" { print $3 }'") %}
{% for name, q in qmap.items() %}
{%   set pin = q.get('cpu_pinning') %}
{%   set pin_file = libvirt_dir ~ '/' ~ papp ~ name ~ '.xml' %}
{%   if pin is not none %}
{%     set cpus = pin.get('cpus') if pin is mapping else none %}
{%     if pin is not mapping or cpus is string or cpus is not sequence or not cpus
          or (pin.keys() | reject('in', ['cpus', 'weight']) | list) %}
{%       do errors.append("qube '" ~ name ~ "': 'cpu_pinning' must be {'cpus': [core, ...]} with an optional 'weight'") %}
{%     elif host_cpus | regex_match('^[0-9]+$') is none %}
{%       do errors.append("qube '" ~ name ~ "': could not read the number of CPUs from 'xl info' to check 'cpu_pinning'") %}
{%     else %}
{%       for c in cpus if c is not integer or c < 0 or c >= host_cpus | int %}
{%         do errors.append("qube '" ~ name ~ "': cpu_pinning core '" ~ c ~ "' is not one of this machine's cores 0-" ~ (host_cpus | int - 1)) %}
{%       endfor %}
{%       if cpus | unique | list | length != cpus | length %}
{%         do errors.append("qube '" ~ name ~ "': cpu_pinning lists a core twice") %}
{%       endif %}
{%       if pin.get('weight') is not none and (pin.weight is not integer or pin.weight < 1 or pin.weight > 65535) %}
{%         do errors.append("qube '" ~ name ~ "': cpu_pinning weight must be an integer from 1 to 65535") %}
{%       endif %}
{%     endif %}
{%     if q.get('vcpus') is not none %}
{%       do errors.append("qube '" ~ name ~ "': set either 'vcpus' or 'cpu_pinning', which gives one vCPU per listed core") %}
{%     endif %}
{%     if salt['file.file_exists'](pin_file) and not salt['file.read'](pin_file).startswith(pin_marker) %}
{%       do errors.append("'" ~ pin_file ~ "' exists and was not written by SEQS -- remove it, or remove cpu_pinning from '" ~ name ~ "'") %}
{%     endif %}
{%   endif %}
{%   if q.get('vcpus') is not none and (q.vcpus is not integer or q.vcpus < 1) %}
{%     do errors.append("qube '" ~ name ~ "': 'vcpus' must be a positive integer") %}
{%   endif %}
{% endfor %}

{# ── Cleanup-dir validation (the generated script runs rm -rf as root) ── #}
{% for e in cleanup_dirs %}
{%   if e.get('mode') not in ['folder', 'contents'] %}
{%     do errors.append("cleanup_dirs entry '" ~ e ~ "' has unknown mode (expected folder or contents)") %}
{%   endif %}
{#   Each segment non-empty and neither '.' nor '..': '/home/user//' or
     '/home/user/.' would name the home directory itself. #}
{%   set p = e.get('path', '') %}
{%   if (p | regex_match('^/home/user(/[A-Za-z0-9._-]+)+\\Z') is none) or ('..' in p) or ('/./' in p ~ '/') %}
{%     do errors.append("cleanup_dirs path '" ~ p ~ "' must be strictly under /home/user/, contain no '..', '.' or empty segment, and use only [A-Za-z0-9._/-]") %}
{%   endif %}
{% endfor %}

{% if errors %}
seqs-validation-failed:
  test.fail_without_changes:
    - name: SEQS pre-flight validation failed -- nothing was changed
    - comment: {{ errors | join(' | ') | tojson }}
    - failhard: True
{% else %}

# ── qrexec policies ────────────────────────────────────────────────────────
# setup-qubes.sh requires confirmation before taking over any policy without
# the "Managed by SEQS" header. Salt then owns and converges the files.

{# Ways out of a qube: handing a link or file to another qube, and starting a
   program in another qube or a disposable (qubes.PdfConvert through the PDF
   converter's own policy, a default dom0 package). The Qubes default policy
   allows some of these without asking and asks for the rest. deny_escapes
   denies all of them to @anyvm, which also matches @dispvm and a disposable
   requested by its template, @dispvm:<template>. #}
{% set escape_services = ['qubes.OpenURL', 'qubes.OpenInVM', 'qubes.StartApp', 'qubes.GetImageRGBA',
                          'qubes.VMShell', 'qubes.VMExec', 'qubes.VMExecGUI', 'qubes.PdfConvert'] %}
{% macro deny_escapes(source) -%}
{%- set lines = [] -%}
{%- for service in escape_services -%}
{%-   do lines.append('%-20s *  %s  @anyvm  deny' | format(service, source)) -%}
{%- endfor -%}
{{ lines | join('\n') | indent(8) }}
{%- endmacro %}

{% if webcam_mode in ['dedicated', 'sequential'] %}
# The camera-exposed backend must never become an input source for dom0, even
# if a keyboard or mouse is accidentally left on the selected controller.
seqs-policy-qr-input-deny:
  file.managed:
    - name: /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        qubes.InputKeyboard  *  {{ webcam_usb_qube }}  @adminvm  deny
        qubes.InputMouse     *  {{ webcam_usb_qube }}  @adminvm  deny
        qubes.InputTablet    *  {{ webcam_usb_qube }}  @adminvm  deny
        qubes.Filecopy       *  {{ webcam_usb_qube }}  @anyvm    deny
        # netvm=none does not block qrexec: close the browser handoff and
        # every disposable too, or a compromised camera-side qube could push
        # the ciphertext out through them.
        {{ deny_escapes(webcam_usb_qube) }}
        # The transfer scans only in the named scanner below: Qubes 4.3 matches
        # a @dispvm:<template> source against no running qube. A disposable
        # started from the camera template by hand inherits seqs-no-handoff.
        qubes.InputKeyboard  *  {{ webcam_scanner_qube }}  @adminvm  deny
        qubes.InputMouse     *  {{ webcam_scanner_qube }}  @adminvm  deny
        qubes.InputTablet    *  {{ webcam_scanner_qube }}  @adminvm  deny
        {{ deny_escapes(webcam_scanner_qube) }}
{% else %}
seqs-policy-qr-input-deny:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
    - onlyif: head -n 1 /etc/qubes/policy.d/00-seqs-qr-input-deny.policy | grep -q '^# Managed by SEQS'
{% endif %}

{% if webcam_mode == 'sequential' %}
# The untrusted named scanner gets exactly one outbound operation: file copy to
# the offline staging qube. It has no general file-copy permission elsewhere.
seqs-policy-qr-filecopy:
  file.managed:
    - name: /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        qubes.Filecopy  *  {{ webcam_scanner_qube }}  {{ webcam_staging_qube }}  allow
        qubes.Filecopy  *  {{ webcam_scanner_qube }}  @anyvm  deny
{% else %}
seqs-policy-qr-filecopy:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
    - onlyif: head -n 1 /etc/qubes/policy.d/01-seqs-qr-filecopy.policy | grep -q '^# Managed by SEQS'
{% endif %}

seqs-policy-browser:
  file.managed:
    - name: /etc/qubes/policy.d/29-browser.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Link-handoff: SEQS qubes tagged seqs-handoff may open http/https
        # links in {{ browser_vm }}. Other qubes keep the Qubes default, which
        # asks. Denies for qubes tagged seqs-no-handoff live in
        # 28-browser-suppress.policy, which is evaluated first.
        qubes.OpenURL  *  @tag:seqs-handoff  {{ browser_vm }}  allow

{# ── Handoff tags. Offline, no_handoff, and firewalled qubes carry the tag
     seqs-no-handoff, and 28-browser-suppress.policy denies by that tag; the
     other SEQS qubes carry seqs-handoff, which 29-browser.policy allows. A
     disposable inherits its template's tags when it is created, so the denies
     also cover every disposable started from such a qube, named or not. Every
     SEQS-managed app qube and named disposable is tagged from its catalogue
     recipe, selected or not, so a partial run never leaves one unprotected;
     a qube built before SEQS recorded recipes falls back to its base name.
     A qube never carries seqs-handoff without its flags allowing it; while a
     state swaps the tags, the deny in 28- wins. #}
{% set handoff_tags = {} %}
{% for vm, info in inventory.items() if info.managed and vm | regex_match(name_re) is not none %}
{%   set base = vm[papp | length:] if papp and vm.startswith(papp) else (vm[pdvm | length:] if pdvm and vm.startswith(pdvm) else '') %}
{%   set recipe = (info.recipe or base) if base else '' %}
{%   if recipe in qcatalog %}
{%     do handoff_tags.update({vm: {'want': recipe in no_handoff, 'require': ''}}) %}
{%   endif %}
{% endfor %}
{% for name, q in qmap.items() %}
{%   set want = recipes[name] in no_handoff %}
{%   do handoff_tags.update({papp ~ name: {'want': want, 'require': 'qvm: seqs-app-' ~ name}}) %}
{%   if q.get('named_disposable') and pdvm %}
{%     do handoff_tags.update({pdvm ~ name: {'want': want, 'require': 'cmd: seqs-disposable-prefs-' ~ name}}) %}
{%   endif %}
{% endfor %}
{% if webcam_mode in ['dedicated', 'sequential'] %}
{%   do handoff_tags.update({webcam_usb_qube: {'want': true, 'require': 'cmd: seqs-webcam-usb-backend'},
                             webcam_scanner_qube: {'want': true, 'require': 'cmd: seqs-qr-scanner'}}) %}
{% endif %}
{% for vm, t in handoff_tags.items() %}
{%   set keep, drop = ('seqs-no-handoff', 'seqs-handoff') if t.want else ('seqs-handoff', 'seqs-no-handoff') %}
seqs-handoff-tag-{{ vm }}:
  cmd.run:
    - name: qvm-tags -- {{ vm }} add {{ keep }} && qvm-tags -- {{ vm }} del {{ drop }}
    - unless: t="$(qvm-tags -- {{ vm }} list)" && printf '%s\n' "$t" | grep -qx {{ keep }} && ! printf '%s\n' "$t" | grep -qx {{ drop }}
{%   if t.require %}
    - require:
      - {{ t.require }}
{%   endif %}
{% endfor %}

seqs-policy-browser-suppress:
  file.managed:
    - name: /etc/qubes/policy.d/28-browser-suppress.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Qubes tagged seqs-no-handoff (offline, no_handoff, and firewalled SEQS
        # qubes, and every disposable started from them) may hand no link to
        # any qube, open nothing in another qube, and start no program in
        # another qube or a disposable, named by its template or not: the
        # browser qube or a networked disposable would be a way out past
        # no_handoff and any firewall allowlist. Evaluated before
        # 29-browser.policy.
        {{ deny_escapes('@tag:seqs-no-handoff') }}
{# A failed tag keeps the previous policy instead of a deny nobody matches. #}
{% set wanted = handoff_tags | dictsort | selectattr('1.want') | map('first') | list %}
{% if wanted %}
    - require:
{%   for vm in wanted %}
      - cmd: seqs-handoff-tag-{{ vm }}
{%   endfor %}
{% endif %}

{# Qubes 4.3 USB-keyboard override; skip without deleting on other releases.
   Qubes answers an 'ask' rule only inside a logged-in session, so on a
   computer whose only keyboard is USB the override would lock the login
   screen. The installer and Qubes Global Config write their keyboard rule
   to 50-config-input.policy: when that file already allows or asks, or
   usb_keyboard_prompt is False to keep Qubes' refusal, SEQS writes no
   override and removes one it wrote earlier. #}
{% set release = salt['cmd.shell']("grep -oE '[0-9]+\\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1") | trim %}
{% set input_policy = '/etc/qubes/policy.d/50-config-input.policy' %}
{% set keyboard_rule_re = '\\s*qubes\\.InputKeyboard\\s+\\*\\s+sys-usb\\s+(@adminvm|dom0)\\s+(allow|ask)(\\s|$)' %}
{% set keyboard_handled = namespace(value=false) %}
{% if salt['file.file_exists'](input_policy) %}
{%   for line in salt['file.read'](input_policy).splitlines() %}
{%     if line | regex_match(keyboard_rule_re) is not none %}
{%       set keyboard_handled.value = true %}
{%     endif %}
{%   endfor %}
{% endif %}
{% if release == '4.3' and ('sys-usb' in inventory) and (keyboard_handled.value or not usb_keyboard_prompt) %}
seqs-policy-usb-keyboard-unneeded:
  file.absent:
    - name: /etc/qubes/policy.d/30-user-input.policy
    - onlyif: head -n 1 /etc/qubes/policy.d/30-user-input.policy 2>/dev/null | grep -q '^# Managed by SEQS'
{% elif release == '4.3' and ('sys-usb' in inventory) %}
seqs-policy-usb-keyboard:
  file.managed:
    - name: /etc/qubes/policy.d/30-user-input.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Prompt before attaching a USB keyboard from sys-usb to dom0. Lower
        # numeric prefix (30-) wins over the shipped 50-config-input.policy,
        # which silently denies qubes.InputKeyboard on Qubes 4.3.
        qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm
{% endif %}

{# ── Audio qubes (catalogue flag 'audio_provider'). A qube whose 'audiovm'
     names one plays and records through it, and Qubes tags that qube
     audiovm-<audio qube>. The audio qube's daemon then needs to read, through
     the Qubes admin API, which qubes use it and when they start; these are the
     rules Qubes' own sys-audio gets. Every SEQS-built audio qube is listed,
     selected or not. #}
{% set audio_qubes = [] %}
{% for vm, info in inventory.items() if info.managed and papp and vm.startswith(papp)
     and vm | regex_match(name_re) is not none and qcatalog.get(info.recipe, {}).get('audio_provider') %}
{%   do audio_qubes.append(vm) %}
{% endfor %}
{% for name, q in qmap.items() if q.get('audio_provider') and papp ~ name not in audio_qubes %}
{%   do audio_qubes.append(papp ~ name) %}
{% endfor %}
{% if audio_qubes %}
seqs-policy-audiovm:
  file.managed:
    - name: /etc/qubes/policy.d/50-seqs-audiovm.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Each audio qube may watch itself, dom0, and the qubes that use it
        # as their audiovm, and read their audio settings.
{%-  for a in audio_qubes | sort %}
{%-    for service in ['admin.Events', 'admin.vm.CurrentState', 'admin.vm.List'] %}
{%-      for target in [a, '@adminvm', '@tag:audiovm-' ~ a] %}
        {{ '%-40s *  %s  %s  allow target=dom0' | format(service, a, target) }}
{%-      endfor %}
{%-    endfor %}
{%-    for arg in ['admin.vm.property.Get +audiovm', 'admin.vm.property.Get +xid', 'admin.vm.property.Get +stubdom_xid',
                   'admin.vm.property.Get +virt_mode', 'admin.vm.property.Get +is_preload',
                   'admin.vm.feature.CheckWithTemplate +audio', 'admin.vm.feature.CheckWithTemplate +audio-model'] %}
        {{ '%-40s %s  @tag:audiovm-%s  allow target=dom0' | format(arg, a, a) }}
{%-    endfor %}
{%-  endfor %}
{% else %}
seqs-policy-audiovm:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/50-seqs-audiovm.policy
    - onlyif: head -n 1 /etc/qubes/policy.d/50-seqs-audiovm.policy | grep -q '^# Managed by SEQS'
{% endif %}

{# With too little memory, the USB/IP export in sys-usb fails to allocate a
   128 KiB buffer and drops the device it forwards, such as a webcam during
   a call. Only raises; takes effect when sys-usb next starts. #}
{% if sys_usb_memory and ('sys-usb' in inventory) %}
seqs-sys-usb-memory:
  cmd.run:
    - name: qvm-prefs -- sys-usb memory {{ sys_usb_memory }} && echo 'sys-usb gets {{ sys_usb_memory }} MiB from its next start'
    - unless: test "$(qvm-prefs -- sys-usb memory)" -ge {{ sys_usb_memory }}
{% endif %}

{# Intel NUC 11 Pro (NUC11PA*): the firmware leaves the front jack's mic pin
   unconfigured, so Linux sees neither the headset mic nor a plugged-in jack.
   This applies the kernel's NUC 10 fix (pin 0x19 as headset mic, headset
   mode) when snd-hda-intel next loads, normally at the next boot. #}
{% if nuc11_headset_fix %}
seqs-nuc11-headset-patch:
  file.managed:
    - name: /lib/firmware/seqs-nuc11-headset.fw
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # See nuc11_headset_fix in docs/configuration.md.
        [codec]
        0x10ec0256 0x80863004 0
        [pincfg]
        0x19 0x01a1913c
        [model]
        headset-mode

seqs-nuc11-headset-option:
  file.managed:
    - name: /etc/modprobe.d/seqs-nuc11-headset.conf
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # See nuc11_headset_fix in docs/configuration.md.
        options snd-hda-intel patch=seqs-nuc11-headset.fw
    - require:
      - file: seqs-nuc11-headset-patch
{% else %}
seqs-nuc11-headset-option:
  file.absent:
    - name: /etc/modprobe.d/seqs-nuc11-headset.conf

seqs-nuc11-headset-patch:
  file.absent:
    - name: /lib/firmware/seqs-nuc11-headset.fw
    - require:
      - file: seqs-nuc11-headset-option
{% endif %}

# ── Qube creation ──────────────────────────────────────────────────────────
# Templates are cloned from {{ base_template }}; app qubes are created on
# their template. Provisioning of the *contents* happens later via
# `qubesctl --skip-dom0 --targets=... state.apply seqs.qube`.
#
# Intent markers ({{ intents_dir }}/<vmname>) close the create->tag window:
# they are written BEFORE a qube is created and removed only after the
# 'seqs-managed' feature is set. If a run dies in between, the next run's
# no-clobber guard sees the marker and adopts the untagged qube instead of
# refusing it. For an already-tagged qube neither state runs, so re-runs
# stay churn-free. A marker whose qube does not exist and is not built in
# this run resumes nothing; it is removed, so that a same-named qube created
# later by someone else is refused rather than adopted.
{% macro intent(id, vm) -%}
seqs-intent-{{ id }}:
  file.managed:
    - name: {{ intents_dir }}/{{ vm }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: SEQS is creating this qube; removed once it is tagged seqs-managed.
{%- endmacro %}
{% set planned = [] %}
{% for name in qmap %}{% do planned.extend([ptpl ~ name, papp ~ name, pdvm ~ name]) %}{% endfor %}
{% for m in salt['cmd.shell']('ls -A ' ~ intents_dir ~ ' 2>/dev/null || true').split()
     if m not in inventory and m not in planned and m | regex_match(name_re) is not none %}
seqs-stale-intent-{{ m }}:
  file.absent:
    - name: {{ intents_dir }}/{{ m }}
{% endfor %}

{% for name, q in qmap.items() %}
{%   set recipe = recipes[name] %}
{%   set tpl = ptpl ~ name %}
{%   set app = papp ~ name %}
{%   set dvm = pdvm ~ name %}
{%   set tpl_exists = (tpl in inventory) %}
{%   set app_exists = (app in inventory) %}
{%   set dvm_exists = q.get('named_disposable') and (dvm in inventory) %}
{%   set tpl_tagged = tpl_exists and inventory.get(tpl, {}).get('managed') %}
{%   set app_tagged = app_exists and inventory.get(app, {}).get('managed') %}
{%   set dvm_tagged = dvm_exists and inventory.get(dvm, {}).get('managed') %}

{%   if tpl_tagged %}
seqs-existing-template-{{ name }}:
  test.nop:
    - name: Existing managed qube {{ tpl }} found; reusing and reconciling it
{%   endif %}
{%   if app_tagged %}
seqs-existing-app-{{ name }}:
  test.nop:
    - name: Existing managed qube {{ app }} found; reusing and reconciling it
{%   endif %}

{%   if not tpl_tagged %}
{{ intent('template-' ~ name, tpl) }}
{%   endif %}

{%   if not tpl_exists %}
seqs-clone-{{ name }}:
  qvm.clone:
    - name: {{ tpl }}
    - source: {{ base_template }}
    - require:
      - file: seqs-intent-template-{{ name }}
{%   endif %}

# The 'seqs-managed' feature is the adopt/no-clobber marker checked at
# render time above and by future re-runs.
{%   if not tpl_tagged %}
seqs-tag-template-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ tpl }} seqs-managed 1 && rm -f {{ intents_dir }}/{{ tpl }}
    - require:
      - file: seqs-intent-template-{{ name }}
{%     if not tpl_exists %}
      - qvm: seqs-clone-{{ name }}
{%     endif %}
{%   endif %}

seqs-recipe-template-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ tpl }} seqs-recipe {{ recipe }}
    - unless: test "$(qvm-features -- {{ tpl }} seqs-recipe 2>/dev/null)" = "{{ recipe }}"
{%   if not tpl_tagged %}
    - require:
      - cmd: seqs-tag-template-{{ name }}
{%   endif %}

{%   if not app_tagged %}
{{ intent('app-' ~ name, app) }}
{%   endif %}

seqs-app-{{ name }}:
  qvm.vm:
    - name: {{ app }}
{%   if not app_exists %}
    - present:
      - template: {{ tpl }}
      - label: {{ q.get('label') }}
{%   endif %}
    - prefs:
      - label: {{ q.get('label') }}
{%   if q.get('dispvm_template') %}
      - template_for_dispvms: True
{%   endif %}
{%   if q.get('network_provider') %}
      - provides_network: True
{%   endif %}
{%   if q.get('netvm') %}
      - netvm: {{ papp ~ q.netvm }}
{%   endif %}
{%   if q.get('cpu_pinning') %}
      - vcpus: {{ q.cpu_pinning.cpus | length }}
{%   elif q.get('vcpus') %}
      - vcpus: {{ q.vcpus }}
{%   endif %}
{%   set provider_selected = q.get('netvm') and q.netvm in qmap %}
{%   if (not app_tagged) or (not tpl_exists) or provider_selected %}
    - require:
{%     if not app_tagged %}
      - file: seqs-intent-app-{{ name }}
{%     endif %}
{%     if not tpl_exists %}
      - qvm: seqs-clone-{{ name }}
{%     endif %}
{%     if provider_selected %}
      - cmd: seqs-network-provider-{{ q.netvm }}
{%     endif %}
{%   endif %}

{%   if q.get('offline') %}
# Clear the NetVM and the default disposable (which normally has network
# access), then let setup-qubes.sh independently verify both.
seqs-offline-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-prefs -- {{ app }} netvm none
        qvm-prefs -- {{ app }} default_dispvm none
    - unless: qvm-prefs -- {{ app }} | {{ explicitly_offline }}
    - require:
      - qvm: seqs-app-{{ name }}
{%   elif q.get('no_handoff') or q.get('firewall') is not none %}
# The policy denies this qube every disposable by its seqs-no-handoff tag.
# The default disposable, which has network access, is cleared as well, so
# that a lost tag does not reopen that route.
seqs-no-dispvm-{{ name }}:
  cmd.run:
    - name: qvm-prefs -- {{ app }} default_dispvm none
    - unless: qvm-prefs -- {{ app }} | awk '$1 == "default_dispvm" && $2 == "-" && $3 == "None" { f = 1 } END { exit !f }'
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}

{%   if q.get('network_provider') %}
# Network providers must run Qubes' firewall service so downstream firewall
# policy is enforced and /rw/config/qubes-firewall-user-script is applied.
seqs-network-provider-{{ name }}:
  cmd.run:
    - name: qvm-service --enable {{ app }} qubes-firewall
    - unless: test "$(qvm-features -- {{ app }} service.qubes-firewall 2>/dev/null)" = "1"
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}
{%   if q.get('audio_provider') %}
# The audiovm service starts the Qubes audio daemon for the qubes that use this
# one as their audiovm. With no audiovm of its own, their audio cannot pass on
# to dom0's speakers, and this qube cannot reach dom0's microphone.
seqs-audio-provider-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-service --enable {{ app }} audiovm
        qvm-prefs -- {{ app }} audiovm ''
    - unless: >-
        test "$(qvm-features -- {{ app }} service.audiovm 2>/dev/null)" = "1"
        && qvm-prefs -- {{ app }} | awk '$1 == "audiovm" && $2 == "-" && $3 == "None" { f = 1 } END { exit !f }'
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}
{%   if 'bluetooth' in q.get('components', []) %}
# Qubes starts Blueman's panel icon, which connects and disconnects devices,
# only in a qube with this service.
seqs-blueman-{{ name }}:
  cmd.run:
    - name: qvm-service --enable {{ app }} blueman
    - unless: test "$(qvm-features -- {{ app }} service.blueman 2>/dev/null)" = "1"
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}
{%   if 'protonvpn' in q.get('components', []) %}
# The Proton VPN app connects through NetworkManager, which Qubes runs in a
# qube only with this service.
seqs-network-manager-{{ name }}:
  cmd.run:
    - name: qvm-service --enable {{ app }} network-manager
    - unless: test "$(qvm-features -- {{ app }} service.network-manager 2>/dev/null)" = "1"
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}

{%   set fw = q.get('firewall') %}
{%   if fw is not none %}
{%     set fwrules = [] %}
{%     for e in fw %}
{%       if e == 'dns' %}{% do fwrules.append('accept specialtarget=dns') %}
{%       elif e == 'icmp' %}{% do fwrules.append('accept proto=icmp') %}
{%       elif ':' in e %}{% set fwh = e.split(':', 1) %}{% do fwrules.append('accept dsthost=' ~ fwh[0] ~ ' proto=tcp dstports=' ~ fwh[1]) %}
{%       else %}{% do fwrules.append('accept dsthost=' ~ e) %}
{%       endif %}
{%     endfor %}
{%     set fwmarker = 'rules=' ~ (fwrules | join('; ')) %}
# Outbound allowlist (config 'firewall'): default-deny egress with one
# accept per entry. Entries were charset-validated in the pre-flight, so
# the interpolations below cannot break out of the command line. Hostname
# rules are resolved by the qubes-firewall service in the netvm, not in
# dom0. qvm-firewall does NOT gate qrexec: a firewall key implies no_handoff,
# whose denies close link handoff and the routes into networked disposables.
# The marker records the configured rules and the rules Qubes reported after
# applying them, so a rerun is a no-op only while both are unchanged: a
# config edit or a hand edit of the qube's rules reapplies the allowlist.
seqs-firewall-{{ name }}:
  cmd.run:
    - name: |
        set -e
        # Close egress first, then replace the rules in front of the drop, so
        # the qube is never more open than before or after.
        qvm-firewall -- {{ app }} add --before 0 drop
        n="$(qvm-firewall --raw -- {{ app }} list | wc -l)"
        for _ in $(seq 2 "$n"); do qvm-firewall -- {{ app }} del --rule-no 1; done
{%     for r in fwrules %}
        qvm-firewall -- {{ app }} add --before {{ loop.index0 }} {{ r }}
{%     endfor %}
        mkdir -p /var/lib/seqs/firewall
        { printf '%s\n' '{{ fwmarker }}'; qvm-firewall --raw -- {{ app }} list; } > /var/lib/seqs/firewall/{{ app }}
    - unless: test "$(cat /var/lib/seqs/firewall/{{ app }} 2>/dev/null)" = "$(printf '%s\n' '{{ fwmarker }}'; qvm-firewall --raw -- {{ app }} list)"
    - require:
      - qvm: seqs-app-{{ name }}
{%   elif salt['file.file_exists']('/var/lib/seqs/firewall/' ~ app) %}
# The 'firewall' key was removed from this qube's config: revert to the
# Qubes default (allow-all) and drop the marker, so config and reality
# converge. Only fires while a SEQS marker exists -- a ruleset the operator
# set by hand (no marker) is never touched.
seqs-firewall-clear-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-firewall -- {{ app }} reset
        rm -f /var/lib/seqs/firewall/{{ app }}
    - require:
      - qvm: seqs-app-{{ name }}
{%   endif %}

{%   set pin = q.get('cpu_pinning') %}
{%   set pin_file = libvirt_dir ~ '/' ~ app ~ '.xml' %}
{%   if pin %}
# The qube's vCPUs are pinned to the configured cores, and its Xen scheduler
# weight set, by a per-qube libvirt file that Qubes applies at every start;
# no daemon is involved. A running qube picks it up at its next start.
seqs-cpu-pinning-{{ name }}:
  file.managed:
    - name: {{ pin_file }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        {{ pin_marker }}
        {{ "{% extends 'libvirt/xen.xml' %}" }}
        {{ "{% block cpu %}" }}
            {{ "{{ super() }}" }}
            <cputune>
{%-    if pin.get('weight') %}
                <shares>{{ pin.weight }}</shares>
{%-    endif %}
{%-    for c in pin.cpus %}
                <vcpupin vcpu='{{ loop.index0 }}' cpuset='{{ c }}'/>
{%-    endfor %}
            </cputune>
        {{ "{% endblock %}" }}
    - require:
      - qvm: seqs-app-{{ name }}
{%   elif salt['file.file_exists'](pin_file) %}
# 'cpu_pinning' was removed: delete the file SEQS wrote, never another one.
seqs-cpu-pinning-clear-{{ name }}:
  cmd.run:
    - name: rm -f -- {{ pin_file }}
    - onlyif: head -n 1 {{ pin_file }} | grep -qF 'Managed by SEQS'
{%   endif %}

{%   if not app_tagged %}
seqs-tag-app-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ app }} seqs-managed 1 && rm -f {{ intents_dir }}/{{ app }}
    - require:
      - qvm: seqs-app-{{ name }}
      - file: seqs-intent-app-{{ name }}
{%     if q.get('offline') %}
      - cmd: seqs-offline-{{ name }}
{%     endif %}
{%   endif %}

seqs-recipe-app-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ app }} seqs-recipe {{ recipe }}
    - unless: test "$(qvm-features -- {{ app }} seqs-recipe 2>/dev/null)" = "{{ recipe }}"
    - require:
{%   if not app_tagged %}
      - cmd: seqs-tag-app-{{ name }}
{%   else %}
      - qvm: seqs-app-{{ name }}
{%   endif %}

{%   if q.get('named_disposable') %}
# ── Named DisposableVM ({{ dvm }}) so the offline dispvm template {{ app }} is
# launchable from the Qubes menu; a bare dispvm template only appears under
# "Templates". The disposable inherits its root and app-menu entries from
# {{ app }} -> {{ tpl }} and is reset on every shutdown, so nothing is
# provisioned inside it. Intent marker closes the same create->tag window as
# the template/app qubes above.
{%     if not dvm_tagged %}
{{ intent('disposable-' ~ name, dvm) }}
{%     endif %}

{%     if not dvm_exists %}
seqs-create-disposable-{{ name }}:
  cmd.run:
    - name: qvm-create -C DispVM -t {{ app }} -l {{ q.get('label') }} {{ dvm }}
    - require:
      - qvm: seqs-app-{{ name }}
      - file: seqs-intent-disposable-{{ name }}
{%     endif %}

# Set the NetVM of every named disposable explicitly: the 'netvm' provider
# if its entry names one, otherwise none. Clear its default disposable, and
# suppress the dispvm-launcher menu entries so this disposable shows normal
# app launchers, not "start a disposable from me".
{%     set dvm_netvm = (papp ~ q.netvm) if q.get('netvm') else 'none' %}
seqs-disposable-prefs-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-prefs -- {{ dvm }} netvm {{ dvm_netvm }}
        qvm-prefs -- {{ dvm }} default_dispvm none
        qvm-features -- {{ dvm }} appmenus-dispvm ''
    - unless: qvm-prefs -- {{ dvm }} | awk '$2 == "-" && (($1 == "netvm" && $3 == "{{ 'None' if dvm_netvm == 'none' else dvm_netvm }}") || ($1 == "default_dispvm" && $3 == "None")) { n++ } END { exit n != 2 }' && [ -z "$(qvm-features -- {{ dvm }} appmenus-dispvm 2>/dev/null)" ]
    - require:
      - qvm: seqs-app-{{ name }}
{%     if not dvm_exists %}
      - cmd: seqs-create-disposable-{{ name }}
{%     endif %}

{%     if not dvm_tagged %}
seqs-tag-disposable-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ dvm }} seqs-managed 1 && rm -f {{ intents_dir }}/{{ dvm }}
    - require:
      - cmd: seqs-disposable-prefs-{{ name }}
      - file: seqs-intent-disposable-{{ name }}
{%     endif %}

seqs-recipe-disposable-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ dvm }} seqs-recipe {{ recipe }}
    - unless: test "$(qvm-features -- {{ dvm }} seqs-recipe 2>/dev/null)" = "{{ recipe }}"
{%     if not dvm_tagged %}
    - require:
      - cmd: seqs-tag-disposable-{{ name }}
{%     endif %}
{%   endif %}

{#   List in the menus of the qubes that run them: the main app, a terminal,
     a file manager, and each component's own entry (shipped as menu.desktop
     and installed in the template as <component>.desktop). A disposable
     template gets none: its entry would run the app in the template itself,
     whose files persist, instead of in the named disposable. The state only
     adds entries, so it also re-adds one the operator removed and leaves one
     behind when it leaves the recipe. qvm-appmenus regenerates menus in the
     dom0 user's home, so the runner, not this root state, refreshes them.
     The runner also builds a panel launcher from the seqs-launcher-items
     feature: the main app first, as the launcher's button. #}
{%   set launcher_items = ([q.main_app] if q.get('main_app') else []) + ['xfce4-terminal.desktop', 'thunar.desktop'] %}
{%   set menu_entries = launcher_items[:] %}
{%   for comp in q.get('components', []) if salt['file.file_exists']('/srv/salt/seqs/files/components/' ~ comp ~ '/menu.desktop') and (comp ~ '.desktop') not in menu_entries %}
{%     do menu_entries.append(comp ~ '.desktop') %}
{%   endfor %}
{%   if 'gnosisvpn' in q.get('components', []) and not q.get('dispvm_template') %}
# The runner adds a panel monitor of the VPN's traffic for this qube.
seqs-vpn-monitor-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ app }} seqs-vpn-monitor 1
    - unless: test "$(qvm-features -- {{ app }} seqs-vpn-monitor 2>/dev/null)" = 1
    - require:
      - cmd: seqs-recipe-app-{{ name }}
{%   endif %}
{%   for vm in (([] if q.get('dispvm_template') else [app]) + ([dvm] if q.get('named_disposable') else [])) %}
seqs-launcher-items-{{ vm }}:
  cmd.run:
    - name: qvm-features -- {{ vm }} seqs-launcher-items '{{ launcher_items | join(' ') }}'
    - unless: test "$(qvm-features -- {{ vm }} seqs-launcher-items 2>/dev/null)" = '{{ launcher_items | join(' ') }}'
    - require:
{%     if vm == app %}
      - cmd: seqs-recipe-app-{{ name }}
{%     else %}
      - cmd: seqs-recipe-disposable-{{ name }}
{%     endif %}

seqs-menu-{{ vm }}:
  cmd.run:
    - name: |
        items="$(qvm-features -- {{ vm }} menu-items 2>/dev/null)"
        for e in {{ menu_entries | join(' ') }}; do
          case " $items " in *" $e "*) ;; *) items="${items:+$items }$e" ;; esac
        done
        qvm-features -- {{ vm }} menu-items "$items"
    - unless: items=" $(qvm-features -- {{ vm }} menu-items 2>/dev/null) "; for e in {{ menu_entries | join(' ') }}; do case "$items" in *" $e "*) ;; *) exit 1 ;; esac; done
    - require:
{%     if vm == app %}
      - cmd: seqs-recipe-app-{{ name }}
{%     else %}
      - cmd: seqs-recipe-disposable-{{ name }}
{%     endif %}
{%   endfor %}
{% endfor %}

{% if webcam_mode in ['dedicated', 'sequential'] %}
# A named disposable USB backend is created only after the operator explicitly
# configures a controller BDF and mode. Dedicated mode removes the controller
# from its current backend. Sequential mode leaves the normal sys-usb assignment in
# place and assigns the same PCI device to an autostart-disabled webcam backend;
# the ceremony enforces that only one owner runs at a time.
seqs-webcam-usb-backend:
  cmd.run:
    - name: |
        set -e
        if ! qvm-check -q -- {{ webcam_usb_qube }}; then
          qvm-create -C DispVM -t {{ webcam_scanner_dvm }} -l red {{ webcam_usb_qube }}
        fi
        qvm-prefs -- {{ webcam_usb_qube }} virt_mode hvm
        qvm-prefs -- {{ webcam_usb_qube }} maxmem 0
        qvm-prefs -- {{ webcam_usb_qube }} netvm none
        qvm-prefs -- {{ webcam_usb_qube }} default_dispvm none
        qvm-prefs -- {{ webcam_usb_qube }} autostart false
        qvm-features -- {{ webcam_usb_qube }} appmenus-dispvm ''
        qvm-features -- {{ webcam_usb_qube }} seqs-managed 1
{% if webcam_mode == 'dedicated' %}
        # Remove live attachments and persistent assignments from other qubes.
        # PCI devices are managed by qvm-pci/qvm-device, not qvm-prefs. dom0
        # is skipped: qvm-pci list dom0 shows every device dom0 exposes.
        stopped=''
        # A failed listing must stop the state, not skip every other owner.
        vms="$(qvm-ls --raw-list)"
        [ -n "$vms" ]
        for current in $vms; do
          printf '%s\n' "$current" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._-]*$' || continue
          [ "$current" = dom0 ] && continue
          [ "$current" = "{{ webcam_usb_qube }}" ] && continue
          if qvm-pci list "$current" 2>/dev/null | awk '$1 == "dom0:{{ webcam_controller }}" { found=1 } END { exit !found }'; then
            if qvm-check --running -q -- "$current"; then
              stopped="$stopped $current"
            fi
            # A former owner that keeps running keeps the camera controller.
            qvm-shutdown --wait "$current" || {
              echo "ERROR: could not stop $current, which holds dom0:{{ webcam_controller }}" >&2
              for s in $stopped; do qvm-start -- "$s" || true; done
              exit 1
            }
            qvm-pci detach "$current" dom0:{{ webcam_controller }} 2>/dev/null || true
          fi
          # An assignment made on Qubes 4.2 and carried into 4.3 records no
          # device identity; only the --port form matches it there.
          qvm-pci unassign "$current" dom0:{{ webcam_controller }} 2>/dev/null || true
          qvm-pci unassign --port "$current" dom0:{{ webcam_controller }} 2>/dev/null || true
        done
        # Restart only the former owners that were running (normally sys-usb),
        # now without the controller, so USB input on its other controllers
        # returns; qubes the user had stopped stay stopped.
        for current in $stopped; do
          qvm-start -- "$current" || echo "WARNING: could not restart $current" >&2
        done
{% else %}
        # Sequential mode is valid only when this is already the physical
        # controller used by the configured normal USB backend. Qubes 4.3
        # lists a qube's PCI devices only while it runs.
        qvm-pci list {{ webcam_normal_usb_qube }} 2>/dev/null | awk '$1 == "dom0:{{ webcam_controller }}" { found=1 } END { exit !found }' || {
          echo 'Configured controller is not attached to {{ webcam_normal_usb_qube }}; check the BDF and that {{ webcam_normal_usb_qube }} is running' >&2
          exit 1
        }
{% endif %}
        qvm-shutdown --wait {{ webcam_usb_qube }} || true
        # Drop an earlier webcam assignment so that a rerun can recreate it
        # with the configured reset option; Qubes refuses a duplicate. Qubes
        # 4.3 removes it with unassign (--port for one made on 4.2), 4.2 with
        # detach of the halted qube.
        qvm-pci unassign {{ webcam_usb_qube }} dom0:{{ webcam_controller }} 2>/dev/null || true
        qvm-pci unassign --port {{ webcam_usb_qube }} dom0:{{ webcam_controller }} 2>/dev/null || true
        qvm-pci detach {{ webcam_usb_qube }} dom0:{{ webcam_controller }} 2>/dev/null || true
{% if webcam_mode == 'sequential' %}
        # Strict reset by default, or no-strict-reset only when
        # webcam_usb_no_strict_reset is set for a controller without a reset
        # method. Either way the ceremony ends in a power-off, so sys-usb
        # receives the controller back only after a cold boot. The normal
        # sys-usb assignment remains; only one owner may run at a time.
{% endif %}
        qvm-pci attach --persistent{% if webcam_no_strict_reset %} --option no-strict-reset=true{% endif %} {{ webcam_usb_qube }} dom0:{{ webcam_controller }}
{% if webcam_mode == 'dedicated' %}
    # Skipped only while the webcam backend is the controller's sole owner,
    # assigned or attached: a qube listed before "(attached" or "(required".
    - unless: qvm-check -q -- {{ webcam_usb_qube }} && qvm-prefs -- {{ webcam_usb_qube }} | {{ explicitly_offline }} && qvm-pci list --assignments 2>/dev/null | awk -v vm="{{ webcam_usb_qube }}" '$1 == "dom0:{{ webcam_controller }}" { for (i = 2; i < NF; i++) if ($(i + 1) ~ /^\((attached|required)/) { o = $i; sub(/^\*/, "", o); if (o == vm) mine = 1; else other = 1 } } END { exit !(mine && !other) }'
{% endif %}
{# qr-camera is built in this run or was verified to exist in the pre-flight;
   a requisite on a state that this run does not render would fail. #}
{% if 'qr-camera' in qmap %}
    - require:
      - qvm: seqs-app-qr-camera
{% endif %}

# The named camera disposable scans on both paths. Policy rules name it,
# because Qubes 4.3 matches a @dispvm:<template> source against no qube.
seqs-qr-scanner:
  cmd.run:
    - name: |
        set -e
        if ! qvm-check -q -- {{ webcam_scanner_qube }}; then
          qvm-create -C DispVM -t {{ webcam_scanner_dvm }} -l red {{ webcam_scanner_qube }}
        fi
        qvm-prefs -- {{ webcam_scanner_qube }} netvm none
        qvm-prefs -- {{ webcam_scanner_qube }} default_dispvm none
        qvm-prefs -- {{ webcam_scanner_qube }} autostart false
        qvm-features -- {{ webcam_scanner_qube }} appmenus-dispvm ''
        qvm-features -- {{ webcam_scanner_qube }} seqs-managed 1
    - unless: qvm-check -q -- {{ webcam_scanner_qube }} && qvm-prefs -- {{ webcam_scanner_qube }} | {{ explicitly_offline }}
{% if 'qr-camera' in qmap %}
    - require:
      - qvm: seqs-app-qr-camera
{% endif %}
{% endif %}

{# The panel monitor of GnosisVPN qubes (setup-qubes.sh adds it to the panel)
   runs this every two seconds. It stays while the catalogue has such qubes,
   built or not. #}
{% set vpn = namespace(any=false) %}
{% for recipe, spec in qcatalog.items() if 'gnosisvpn' in spec.get('components', []) %}
{%   set vpn.any = true %}
{% endfor %}
{% if vpn.any %}
seqs-vpn-monitor:
  file.managed:
    - name: /usr/local/bin/seqs-vpn-monitor
    - source: salt://seqs/files/seqs-vpn-monitor
    - user: root
    - group: root
    - mode: '0755'
{% else %}
seqs-vpn-monitor:
  cmd.run:
    - name: rm -f /usr/local/bin/seqs-vpn-monitor
    - onlyif: head -n 2 /usr/local/bin/seqs-vpn-monitor | grep -q 'Managed by SEQS'
{% endif %}

{% if webcam_mode == 'sequential' %}
seqs-qr-sequential-config-dir:
  file.directory:
    - name: /etc/seqs
    - user: root
    - group: root
    - mode: '0700'

seqs-qr-sequential-config:
  file.managed:
    - name: /etc/seqs/qr-sequential.conf
    - user: root
    - group: root
    - mode: '0600'
    - require:
      - file: seqs-qr-sequential-config-dir
    - contents: |
        # Managed by SEQS. Shell-safe values were regex-validated at render time.
        CONTROLLER='{{ webcam_controller }}'
        NORMAL_USB_QUBE='{{ webcam_normal_usb_qube }}'
        WEBCAM_USB_QUBE='{{ webcam_usb_qube }}'
        SCANNER_QUBE='{{ webcam_scanner_qube }}'
        STAGING_QUBE='{{ webcam_staging_qube }}'

seqs-qr-sequential-script:
  file.managed:
    - name: /usr/local/sbin/seqs-qr-sequential
    - source: salt://seqs/files/qr-sequential.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: seqs-qr-sequential-config
{% else %}
seqs-qr-sequential-config:
  cmd.run:
    - name: rm -f /etc/seqs/qr-sequential.conf /usr/local/sbin/seqs-qr-sequential
    - onlyif: test -e /etc/seqs/qr-sequential.conf -o -e /usr/local/sbin/seqs-qr-sequential
{% endif %}

# ── Dom0 desktop settings for the runner ───────────────────────────────────
# Panel launchers and keyboard shortcuts live in the dom0 user's session, which
# this root state cannot reach; setup-qubes.sh applies them from this file.
seqs-desktop:
  file.managed:
    - name: /var/lib/seqs/desktop
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        # Managed by SEQS (salt state seqs.dom0). Read by setup-qubes.sh.
        # Format: launcher <file in /usr/share/applications> | key <shortcut> <xfwm4 action>
        {%- for d in dom0_launchers %}
        launcher {{ d }}
        {%- endfor %}
        {%- for shortcut, action in tiling_keys.items() %}
        key {{ shortcut }} {{ action }}
        {%- endfor %}

# ── Target list for the runner ─────────────────────────────────────────────
# setup-qubes.sh reads this to know which qubes to provision (templates
# first, then app qubes), instead of guessing from qvm-ls prefixes. The
# 'offline', 'netvm=' and 'nodispvm' flags let the runner independently verify
# the air gap, the NetVM, and the cleared default disposable before
# provisioning starts.
{% macro target_flag(q) %}{{ ' offline' if q.get('offline') else (' netvm=' ~ papp ~ q.netvm if q.get('netvm') else '') }}{{ ' nodispvm' if not q.get('offline') and (q.get('no_handoff') or q.get('firewall') is not none) else '' }}{% endmacro %}
seqs-targets:
  file.managed:
    - name: /var/lib/seqs/targets
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        # Managed by SEQS (salt state seqs.dom0). Read by setup-qubes.sh.
        # Format: <template|app|disposable> <qube-name> <catalogue-recipe> [offline | netvm=<qube>] [nodispvm]
        {%- for name in qmap %}
        template {{ ptpl }}{{ name }} {{ recipes[name] }}
        {%- endfor %}
        {%- for name, q in qmap.items() %}
        app {{ papp }}{{ name }} {{ recipes[name] }}{{ target_flag(q) }}
        {%- endfor %}
        {%- for name, q in qmap.items() if q.get('named_disposable') %}
        disposable {{ pdvm }}{{ name }} {{ recipes[name] }}{{ target_flag(q) }}
        {%- endfor %}

{% endif %}
