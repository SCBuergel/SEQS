# SEQS dom0 state: validation, policies, and qube creation; see docs/architecture.md.

{% set seqs = salt['pillar.get']('seqs', {}) %}
{% set ptpl = seqs.get('prefix_template', '') %}
{% set papp = seqs.get('prefix_app', '') %}
{% set pdvm = seqs.get('prefix_disposable', '') %}
{% set base_template = seqs.get('base_template', '') %}
{% set browser_vm = seqs.get('browser_vm', '') %}
{% set qcatalog = seqs.get('catalogue', seqs.get('qubes', {})) %}
{% set selection_file = '/var/lib/seqs/selection' %}
{% set selection_raw = salt['cmd.shell']('cat ' ~ selection_file ~ ' 2>/dev/null') %}
{% set selection = selection_raw.splitlines() %}
{% set qmap = {} %}
{% set recipes = {} %}
{% if selection %}
{%   set first = selection[0].split() %}
{%   if first and first[0] == '@all' %}
{%     set postfix = first[1] if first | length == 2 else '' %}
{%     for recipe, spec in qcatalog.items() %}
{%       set instance = recipe ~ (('-' ~ postfix) if postfix else '') %}
{%       do qmap.update({instance: spec}) %}
{%       do recipes.update({instance: recipe}) %}
{%     endfor %}
{%   else %}
{%     for line in selection %}
{%       set fields = line.split() %}
{%       if fields | length == 1 and fields[0] in qcatalog %}
{%         do qmap.update({fields[0]: qcatalog[fields[0]]}) %}
{%         do recipes.update({fields[0]: fields[0]}) %}
{%       elif fields | length == 2 and fields[0] in qcatalog %}
{%         do qmap.update({fields[1]: qcatalog[fields[0]]}) %}
{%         do recipes.update({fields[1]: fields[0]}) %}
{%       endif %}
{%     endfor %}
{%   endif %}
{% endif %}
{% set exts = seqs.get('brave_extensions', {}) %}
{% set cleanup_dirs = seqs.get('cleanup_dirs', []) %}
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
    empty or unreadable list must never read as "no qube exists": that would
    let the no-clobber guard below pass, so the run stops unless dom0 is in
    it. #}
{% set inventory_cmd %}python3 -c 'import qubesadmin
for vm in qubesadmin.Qubes().domains:
    f = vm.features
    print(vm.name, "1" if f.get("seqs-managed") == "1" else "0", "".join((f.get("seqs-recipe") or "-").split()))'{% endset %}
{% set inventory = {} %}
{% for line in salt['cmd.shell'](inventory_cmd | trim).splitlines() %}
{%   set f = line.split() %}
{%   if f | length == 3 %}
{%     do inventory.update({f[0]: {'managed': f[1] == '1', 'recipe': '' if f[2] == '-' else f[2]}}) %}
{%   endif %}
{% endfor %}
{% if 'dom0' not in inventory %}
{%   do errors.append("could not list the existing qubes through qubesadmin -- refusing to continue without knowing which qubes exist") %}
{% endif %}

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
{%     endif %}
{%   elif fields | length not in [1, 2] %}
{%     do errors.append("runtime selection entry '" ~ line ~ "' is malformed") %}
{%   elif fields[0] | regex_match(name_re) is none or (fields | length == 2 and fields[1] | regex_match(name_re) is none) %}
{%     do errors.append("runtime selection contains unsafe recipe or instance name '" ~ line ~ "'") %}
{%   elif fields[0] not in qcatalog %}
{%     do errors.append("runtime selection names unknown catalogue entry '" ~ fields[0] ~ "'") %}
{%   elif fields | length == 2 and fields[1] != fields[0] and not fields[1].startswith(fields[0] ~ '-') %}
{%     do errors.append("runtime instance '" ~ fields[1] ~ "' is not derived from recipe '" ~ fields[0] ~ "'") %}
{%   endif %}
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
{% if webcam_controller and webcam_controller | regex_match('^[0-9a-f]{2}_[0-9a-f]{2}\.[0-7]$') is none %}
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
     but only when a selected qube hands links to it: offline and no_handoff
     qubes never do (qube.sls), so selecting only those needs no browser. ── #}
{% if browser_vm %}
{%   if browser_vm | regex_match(name_re) is none %}
{%     do errors.append("browser_vm '" ~ browser_vm ~ "' has an unsafe name") %}
{%   else %}
{%     set bbase = browser_vm[(papp | length):] if papp and browser_vm.startswith(papp) else '' %}
{%     set handoff = [] %}
{%     for name, q in qmap.items() if not q.get('offline') and not q.get('no_handoff') and papp ~ name != browser_vm %}
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
{%         elif exts[en] | regex_match('^[a-p]{32}$') is none %}
{%           do errors.append("Brave extension '" ~ en ~ "' has invalid Chrome Web Store ID '" ~ exts[en] ~ "' (expected 32 chars a-p)") %}
{%         endif %}
{%       elif not salt['file.directory_exists']('/srv/salt/seqs/files/components/' ~ comp) %}
{%         do errors.append("qube '" ~ name ~ "' references unknown component '" ~ comp ~ "' (no /srv/salt/seqs/files/components/" ~ comp ~ "/)") %}
{%       endif %}
{%     endfor %}
{#     Optional outbound allowlist ('firewall' key): validate before any
       entry is interpolated into a qvm-firewall command below. #}
{%     set fw = q.get('firewall') %}
{%     if q.get('dispvm_template') and not q.get('offline') %}
{%       do errors.append("qube '" ~ name ~ "' is a DisposableVM template for sensitive data but is not offline") %}
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
{%         for e in fw %}
{%           if e not in ['dns', 'icmp'] and (e | string | regex_match('^[A-Za-z0-9._-]+(:[0-9]{1,5})?$')) is none %}
{%             do errors.append("qube '" ~ name ~ "' has invalid firewall entry '" ~ e ~ "' (expected hostname/IPv4 with optional :port, or the tokens 'dns' / 'icmp')") %}
{%           endif %}
{%         endfor %}
{%       endif %}
{%     endif %}
{%   endif %}
{% endfor %}

{# ── No-clobber: adopt a selected instance's qubes only if they carry
     seqs-managed or an interrupted-run intent marker, and only for the
     recipe they were built for. Iterates instances, not catalogue names,
     so --postfix instances are covered too. ─────────────────────────── #}
{% for name, q in qmap.items() %}
{%   set recipe = recipes.get(name, '') %}
{%   for vmname in [ptpl ~ name, papp ~ name] + ([pdvm ~ name] if q.get('named_disposable') and pdvm else []) if vmname in inventory %}
{%     if not inventory[vmname].managed and not salt['file.file_exists'](intents_dir ~ '/' ~ vmname) %}
{%       do errors.append("qube '" ~ vmname ~ "' already exists but is not marked seqs-managed -- refusing to adopt it (remove or rename it, or set: qvm-features " ~ vmname ~ " seqs-managed 1)") %}
{%     elif inventory[vmname].managed and inventory[vmname].recipe and inventory[vmname].recipe != recipe %}
{%       do errors.append("qube '" ~ vmname ~ "' is managed for recipe '" ~ inventory[vmname].recipe ~ "', not requested recipe '" ~ recipe ~ "' -- refusing to repurpose it") %}
{%     endif %}
{%   endfor %}
{% endfor %}

{# ── CPU pinning ('cpu_pinning' key): a per-qube libvirt file that Qubes
     applies at every start. Values are interpolated into that file, so they
     must be plain integers, and the cores must exist on this machine. ── #}
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
{%     if salt['file.file_exists'](pin_file) and not salt['file.read'](pin_file).startswith(pin_marker) %}
{%       do errors.append("'" ~ pin_file ~ "' exists and was not written by SEQS -- remove it, or remove cpu_pinning from '" ~ name ~ "'") %}
{%     endif %}
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
{%   if (p | regex_match('^/home/user(/[A-Za-z0-9._-]+)+$') is none) or ('..' in p) or ('/./' in p ~ '/') %}
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
        # netvm=none does not block qrexec: close the browser handoff too, or
        # 29-browser.policy would let a compromised camera-side qube push the
        # ciphertext to the browser qube without a prompt.
        qubes.OpenURL        *  {{ webcam_usb_qube }}  @anyvm    deny
        qubes.OpenURL        *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.OpenInVM       *  {{ webcam_usb_qube }}  @anyvm    deny
        qubes.OpenInVM       *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.StartApp       *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.GetImageRGBA   *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.VMShell        *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.VMExec         *  {{ webcam_usb_qube }}  @dispvm   deny
        qubes.VMExecGUI      *  {{ webcam_usb_qube }}  @dispvm   deny
        # qubes.PdfConvert comes from the PDF converter, a default dom0 package,
        # whose own policy allows it into a disposable without asking.
        qubes.PdfConvert     *  {{ webcam_usb_qube }}  @dispvm   deny
        # The transfer scans only in the named scanner below: Qubes 4.3 matches
        # a @dispvm:<template> source against no running qube. A disposable
        # started from the camera template by hand inherits seqs-no-handoff.
        qubes.InputKeyboard  *  {{ webcam_scanner_qube }}  @adminvm  deny
        qubes.InputMouse     *  {{ webcam_scanner_qube }}  @adminvm  deny
        qubes.InputTablet    *  {{ webcam_scanner_qube }}  @adminvm  deny
        qubes.OpenURL        *  {{ webcam_scanner_qube }}  @anyvm    deny
        qubes.OpenURL        *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.OpenInVM       *  {{ webcam_scanner_qube }}  @anyvm    deny
        qubes.OpenInVM       *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.StartApp       *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.GetImageRGBA   *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.VMShell        *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.VMExec         *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.VMExecGUI      *  {{ webcam_scanner_qube }}  @dispvm   deny
        qubes.PdfConvert     *  {{ webcam_scanner_qube }}  @dispvm   deny
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
{%   set r = qcatalog.get(info.recipe or base) if base else none %}
{%   if r %}
{%     do handoff_tags.update({vm: {'want': r.get('offline') or r.get('no_handoff') or r.get('firewall') is not none, 'require': ''}}) %}
{%   endif %}
{% endfor %}
{% for name, q in qmap.items() %}
{%   set want = q.get('offline') or q.get('no_handoff') or q.get('firewall') is not none %}
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
        # any qube, open nothing in another qube, and start no disposable
        # through the services the Qubes default policy allows without asking
        # (qubes.PdfConvert through the PDF converter's own policy): the browser
        # qube or a networked disposable would be a way out past no_handoff and
        # any firewall allowlist. Evaluated before 29-browser.policy.
        qubes.OpenURL  *  @tag:seqs-no-handoff  @anyvm  deny
        qubes.OpenURL  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.OpenInVM  *  @tag:seqs-no-handoff  @anyvm  deny
        qubes.OpenInVM  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.StartApp  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.GetImageRGBA  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.VMShell  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.VMExec  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.VMExecGUI  *  @tag:seqs-no-handoff  @dispvm  deny
        qubes.PdfConvert  *  @tag:seqs-no-handoff  @dispvm  deny
{# A failed tag keeps the previous policy instead of a deny nobody matches. #}
{% set wanted = handoff_tags | dictsort | selectattr('1.want') | map('first') | list %}
{% if wanted %}
    - require:
{%   for vm in wanted %}
      - cmd: seqs-handoff-tag-{{ vm }}
{%   endfor %}
{% endif %}

{# Qubes 4.3 USB-keyboard override; skip without deleting on other releases. #}
{% set release = salt['cmd.shell']("grep -oE '[0-9]+\\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1") | trim %}
{% if release == '4.3' and ('sys-usb' in inventory) %}
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
# stay churn-free.

{% for name, q in qmap.items() %}
{%   set recipe = recipes.get(name, '') %}
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
seqs-intent-template-{{ name }}:
  file.managed:
    - name: {{ intents_dir }}/{{ tpl }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: SEQS is creating this qube; removed once it is tagged seqs-managed.
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
seqs-intent-app-{{ name }}:
  file.managed:
    - name: {{ intents_dir }}/{{ app }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: SEQS is creating this qube; removed once it is tagged seqs-managed.
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
{%   if q.get('cpu_pinning') %}
      - vcpus: {{ q.cpu_pinning.cpus | length }}
{%   endif %}
{%   if (not app_tagged) or (not tpl_exists) %}
    - require:
{%     if not app_tagged %}
      - file: seqs-intent-app-{{ name }}
{%     endif %}
{%     if not tpl_exists %}
      - qvm: seqs-clone-{{ name }}
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
{%   endif %}

{%   if q.get('network_provider') %}
# Network providers must run Qubes' firewall service so downstream firewall
# policy is enforced and /rw/config/qubes-firewall-user-script is applied.
seqs-network-provider-{{ name }}:
  cmd.run:
    - name: qvm-service --enable {{ app }} qubes-firewall
    - unless: test "$(qvm-service -- {{ app }} qubes-firewall 2>/dev/null)" = "1"
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
# whose denies close link handoff and the routes into networked disposables. The marker records the configured rules
# and the rules Qubes reported after applying them, so a rerun is a no-op
# only while both are unchanged: a config edit or a hand edit of the qube's
# rules reapplies the allowlist.
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
seqs-intent-disposable-{{ name }}:
  file.managed:
    - name: {{ intents_dir }}/{{ dvm }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: SEQS is creating this qube; removed once it is tagged seqs-managed.
{%     endif %}

{%     if not dvm_exists %}
seqs-create-disposable-{{ name }}:
  cmd.run:
    - name: qvm-create -C DispVM -t {{ app }} -l {{ q.get('label') }} {{ dvm }}
    - require:
      - qvm: seqs-app-{{ name }}
      - file: seqs-intent-disposable-{{ name }}
{%     endif %}

# Clear the NetVM (every named_disposable derives from an offline dispvm
# template) and suppress the dispvm-launcher menu entries so this disposable
# shows normal app launchers, not "start a disposable from me".
seqs-disposable-prefs-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-prefs -- {{ dvm }} netvm none
        qvm-prefs -- {{ dvm }} default_dispvm none
        qvm-features -- {{ dvm }} appmenus-dispvm ''
    - unless: qvm-prefs -- {{ dvm }} | {{ explicitly_offline }} && [ -z "$(qvm-features -- {{ dvm }} appmenus-dispvm 2>/dev/null)" ]
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

{#   A component's own menu entry ships as menu.desktop and is installed in
     the template as <component>.desktop; list it in the menus of the qubes
     that run it. A disposable template gets none: its entry would run the
     component in the template itself, whose files persist, instead of in the
     named disposable. The state only adds entries, so it also re-adds one the
     operator removed and leaves one behind when a component leaves the
     recipe. qvm-appmenus regenerates menus in the dom0 user's home, so the
     runner, not this root state, refreshes them. #}
{%   set menu_entries = [] %}
{%   for comp in q.get('components', []) if salt['file.file_exists']('/srv/salt/seqs/files/components/' ~ comp ~ '/menu.desktop') %}
{%     do menu_entries.append(comp ~ '.desktop') %}
{%   endfor %}
{%   for vm in (([] if q.get('dispvm_template') else [app]) + ([dvm] if q.get('named_disposable') else [])) if menu_entries %}
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
        for current in $(qvm-ls --raw-list); do
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

# ── Target list for the runner ─────────────────────────────────────────────
# setup-qubes.sh reads this to know which qubes to provision (templates
# first, then app qubes), instead of guessing from qvm-ls prefixes. The
# 'offline' flag lets the runner independently verify the air gap before
# provisioning starts.
seqs-targets:
  file.managed:
    - name: /var/lib/seqs/targets
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        # Managed by SEQS (salt state seqs.dom0). Read by setup-qubes.sh.
        # Format: <template|app|disposable> <qube-name> <catalogue-recipe> [offline]
        {%- for name in qmap %}
        template {{ ptpl }}{{ name }} {{ recipes.get(name, '') }}
        {%- endfor %}
        {%- for name, q in qmap.items() %}
        app {{ papp }}{{ name }} {{ recipes.get(name, '') }}{{ ' offline' if q.get('offline') else '' }}
        {%- endfor %}
        {%- for name, q in qmap.items() if q.get('named_disposable') %}
        disposable {{ pdvm }}{{ name }} {{ recipes.get(name, '') }}{{ ' offline' if q.get('offline') else '' }}
        {%- endfor %}

{% endif %}
