# SEQS dom0 state: validation, policies, and qube creation; see docs/architecture.md.

{% set seqs = salt['pillar.get']('seqs', {}) %}
{% set ptpl = seqs.get('prefix_template', '') %}
{% set papp = seqs.get('prefix_app', '') %}
{% set base_template = seqs.get('base_template', '') %}
{% set browser_vm = seqs.get('browser_vm', '') %}
{% set qmap = seqs.get('qubes', {}) %}
{% set exts = seqs.get('brave_extensions', {}) %}
{% set cleanup_dirs = seqs.get('cleanup_dirs', []) %}
{% set webcam_mode = seqs.get('webcam_usb_mode', 'disabled') %}
{% set webcam_controller = seqs.get('webcam_usb_controller', '') %}
{% set webcam_no_strict_reset = seqs.get('webcam_usb_no_strict_reset', false) %}
{% set webcam_usb_qube = seqs.get('webcam_usb_qube', 'sys-usb-webcam') %}
{% set webcam_scanner_dvm = seqs.get('webcam_scanner_dvm', '') %}
{% set webcam_normal_usb_qube = seqs.get('webcam_normal_usb_qube', 'sys-usb') %}
{% set webcam_sequential_scanner = seqs.get('webcam_sequential_scanner', 'seqs-qr-scanner') %}
{% set webcam_staging_qube = seqs.get('webcam_staging_qube', papp ~ 'qr-staging') %}

{% set name_re = '^[A-Za-z0-9_][A-Za-z0-9._-]*$' %}
{% set labels = ['red', 'orange', 'yellow', 'green', 'gray', 'blue', 'purple', 'black'] %}
{% set intents_dir = '/var/lib/seqs/intents' %}
{% set errors = [] %}

{% if webcam_mode not in ['disabled', 'dedicated', 'sequential'] %}
{%   do errors.append("webcam_usb_mode '" ~ webcam_mode ~ "' is invalid (expected disabled, dedicated, or sequential)") %}
{% endif %}
{% if webcam_mode == 'disabled' and webcam_controller %}
{%   do errors.append("webcam_usb_controller is set while webcam_usb_mode is disabled -- select a mode or clear the controller") %}
{% endif %}
{% if webcam_mode in ['dedicated', 'sequential'] and not webcam_controller %}
{%   do errors.append("webcam_usb_mode '" ~ webcam_mode ~ "' requires webcam_usb_controller") %}
{% endif %}
{% if webcam_controller and webcam_controller | regex_match('^[0-9A-Fa-f]{2}_[0-9A-Fa-f]{2}\.[0-7]$') is none %}
{%   do errors.append("webcam_usb_controller '" ~ webcam_controller ~ "' is invalid (expected a qvm-pci BDF such as 03_00.0)") %}
{% endif %}
{% for field, value in [('webcam_usb_qube', webcam_usb_qube), ('webcam_normal_usb_qube', webcam_normal_usb_qube), ('webcam_sequential_scanner', webcam_sequential_scanner), ('webcam_staging_qube', webcam_staging_qube)] %}
{%   if value | regex_match(name_re) is none %}
{%     do errors.append(field ~ " '" ~ value ~ "' has an unsafe name") %}
{%   endif %}
{% endfor %}
{% if webcam_controller and (not webcam_scanner_dvm or webcam_scanner_dvm | regex_match(name_re) is none) %}
{%   do errors.append("webcam_scanner_dvm is missing or unsafe") %}
{% endif %}
{% if webcam_controller and 'qr-camera' not in qmap %}
{%   do errors.append("webcam_usb_controller is configured but the required qr-camera qube is absent") %}
{% endif %}
{% if webcam_mode == 'sequential' and 'qr-staging' not in qmap %}
{%   do errors.append("sequential webcam mode requires the qr-staging qube") %}
{% endif %}
{% if webcam_mode == 'sequential' and (not qmap.get('qr-staging', {}).get('offline') or not qmap.get('qr-staging', {}).get('preserve_incoming')) %}
{%   do errors.append("sequential webcam mode requires qr-staging to be offline with preserve_incoming enabled") %}
{% endif %}
{% if webcam_mode == 'sequential' and webcam_no_strict_reset %}
{%   do errors.append("sequential webcam mode forbids webcam_usb_no_strict_reset -- safe controller reuse requires strict reset") %}
{% endif %}
{% if webcam_mode == 'sequential' and salt['cmd.retcode']('qvm-check -q -- ' ~ webcam_normal_usb_qube) != 0 %}
{%   do errors.append("sequential webcam mode requires existing normal USB qube '" ~ webcam_normal_usb_qube ~ "'") %}
{% endif %}
{% for special in [webcam_usb_qube] + ([webcam_sequential_scanner] if webcam_mode == 'sequential' else []) %}
{%   if webcam_mode in ['dedicated', 'sequential'] and salt['cmd.retcode']('qvm-check -q -- ' ~ special) == 0 and salt['cmd.shell']('qvm-features -- ' ~ special ~ ' seqs-managed 2>/dev/null') | trim != '1' %}
{%     do errors.append("special qube '" ~ special ~ "' already exists but is not marked seqs-managed -- refusing to adopt it") %}
{%   endif %}
{% endfor %}

{# ── Errors detected while the pillar itself was compiled (duplicate qube
     names etc. -- see qube_list handling in pillar config.sls). ────────── #}
{% for e in seqs.get('config_errors', []) %}
{%   do errors.append(e) %}
{% endfor %}

{# ── Pillar present at all? ─────────────────────────────────────────────── #}
{% if not qmap or not base_template or not browser_vm or not ptpl or not papp %}
{%   do errors.append("pillar 'seqs' is missing or incomplete -- was 'sudo qubesctl top.enable seqs.config pillar=true' run, and does /srv/pillar/seqs/config.sls exist?") %}
{% endif %}

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
{%   elif salt['cmd.retcode']('qvm-check -q -- ' ~ base_template) != 0 %}
{%     do errors.append("base template '" ~ base_template ~ "' does not exist -- install it first, e.g.: sudo qubes-dom0-update qubes-template-" ~ base_template) %}
{%   endif %}
{% endif %}

{# ── browser_vm must be a qube this run builds or one that already exists
     (the qubes.OpenURL allow rule below points every qube at it). ──────── #}
{% if browser_vm %}
{%   if browser_vm | regex_match(name_re) is none %}
{%     do errors.append("browser_vm '" ~ browser_vm ~ "' has an unsafe name") %}
{%   else %}
{%     set bbase = browser_vm[(papp | length):] if papp and browser_vm.startswith(papp) else '' %}
{%     if not (bbase and bbase in qmap) and salt['cmd.retcode']('qvm-check -q -- ' ~ browser_vm) != 0 %}
{%       do errors.append("browser_vm '" ~ browser_vm ~ "' is neither in the configured qubes map nor an existing qube -- links would hand off into a void") %}
{%     endif %}
{%   endif %}
{% endif %}

{# ── Per-qube validation (replaces the old validateAllQubes) ───────────── #}
{% for name, q in qmap.items() %}
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
{#     No-clobber guard: the old script refused to touch a pre-existing
       Z-NAME / A-NAME. Salt converges instead of refusing, so we only adopt
       qubes that carry the 'seqs-managed' feature this state sets right
       after creation. A same-named qube WITHOUT the feature is someone
       else's qube -- refuse before any state runs. Exception: an intent
       marker under /var/lib/seqs/intents/ proves a previous SEQS run
       created this qube and was interrupted before tagging it (the marker
       is written before creation and removed after tagging) -- adopt it,
       otherwise an interrupted first run would lock the operator out of
       every re-run. #}
{%     for vmname in [ptpl ~ name, papp ~ name] %}
{%       if salt['cmd.retcode']('qvm-check -q -- ' ~ vmname) == 0 %}
{%         if salt['cmd.shell']('qvm-features -- ' ~ vmname ~ ' seqs-managed 2>/dev/null') | trim != '1'
              and not salt['file.file_exists'](intents_dir ~ '/' ~ vmname) %}
{%           do errors.append("qube '" ~ vmname ~ "' already exists but is not marked seqs-managed -- refusing to adopt it (remove or rename it, or set: qvm-features " ~ vmname ~ " seqs-managed 1)") %}
{%         endif %}
{%       endif %}
{%     endfor %}
{%   endif %}
{% endfor %}

{# ── Cleanup-dir validation (the generated script runs rm -rf as root) ── #}
{% for e in cleanup_dirs %}
{%   if e.get('mode') not in ['folder', 'contents'] %}
{%     do errors.append("cleanup_dirs entry '" ~ e ~ "' has unknown mode (expected folder or contents)") %}
{%   endif %}
{%   if (e.get('path', '') | regex_match('^/home/user/[A-Za-z0-9._/-]+$') is none) or ('..' in e.get('path', '')) %}
{%     do errors.append("cleanup_dirs path '" ~ e.get('path', '') ~ "' must be strictly under /home/user/, contain no '..' and use only [A-Za-z0-9._/-]") %}
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
# The old script's interactive confirmPolicyOverwrite gate is replaced by a
# marker-based takeover prompt in setup-qubes.sh: a policy file that exists
# WITHOUT the "Managed by SEQS" header is never silently overwritten -- the
# runner refuses to invoke this state until the operator confirms. After
# that, salt owns these files and re-applies converge them.

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
{% if webcam_mode == 'sequential' %}
        qubes.InputKeyboard  *  {{ webcam_sequential_scanner }}  @adminvm  deny
        qubes.InputMouse     *  {{ webcam_sequential_scanner }}  @adminvm  deny
        qubes.InputTablet    *  {{ webcam_sequential_scanner }}  @adminvm  deny
{% endif %}
{% else %}
seqs-policy-qr-input-deny:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
    - onlyif: grep -q 'Managed by SEQS' /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
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
        qubes.Filecopy  *  {{ webcam_sequential_scanner }}  {{ webcam_staging_qube }}  allow
        qubes.Filecopy  *  {{ webcam_sequential_scanner }}  @anyvm  deny
{% else %}
seqs-policy-qr-filecopy:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
    - onlyif: grep -q 'Managed by SEQS' /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
{% endif %}

seqs-policy-browser:
  file.managed:
    - name: /etc/qubes/policy.d/29-browser.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Link-handoff: any qube may open http/https links in {{ browser_vm }}.
        # Denies for offline/no-handoff qubes live in 28-browser-suppress.policy,
        # which is evaluated first.
        qubes.OpenURL  *  @anyvm  {{ browser_vm }}  allow

{% set suppressed = [] %}
{% for name, q in qmap.items() if q.get('offline') or q.get('no_handoff') %}
{%   do suppressed.append(papp ~ name) %}
{% endfor %}
{% if suppressed %}
seqs-policy-browser-suppress:
  file.managed:
    - name: /etc/qubes/policy.d/28-browser-suppress.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.
        # Deny qubes.OpenURL from every 'offline' / 'no_handoff' qube to ANY
        # target. Evaluated before 29-browser.policy, so the deny fires before
        # the @anyvm allow rule -- the opt-out is enforced at the dom0
        # boundary, not just at each qube's xdg config.
        {%- for vm in suppressed %}
        qubes.OpenURL  *  {{ vm }}  @anyvm  deny
        {%- endfor %}
{% else %}
# No offline/no_handoff qubes configured: remove a stale suppress policy from
# a previous run, but ONLY if it is ours (carries the managed marker).
seqs-policy-browser-suppress:
  cmd.run:
    - name: rm -f /etc/qubes/policy.d/28-browser-suppress.policy
    - onlyif: grep -q 'Managed by SEQS' /etc/qubes/policy.d/28-browser-suppress.policy
{% endif %}

{# USB keyboard override -- only relevant on Qubes 4.3 with sys-usb present
   (the shipped 50-config-input.policy silently denies qubes.InputKeyboard
   there). Same semantics as the old setupUsbKeyboardPolicy: skip -- never
   delete -- on other releases. #}
{% set release = salt['cmd.shell']("grep -oE '[0-9]+\\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1") | trim %}
{% if release == '4.3' and salt['cmd.retcode']('qvm-check -q -- sys-usb') == 0 %}
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
{%   set tpl = ptpl ~ name %}
{%   set app = papp ~ name %}
{%   set tpl_exists = salt['cmd.retcode']('qvm-check -q -- ' ~ tpl) == 0 %}
{%   set app_exists = salt['cmd.retcode']('qvm-check -q -- ' ~ app) == 0 %}
{%   set tpl_tagged = tpl_exists and salt['cmd.shell']('qvm-features -- ' ~ tpl ~ ' seqs-managed 2>/dev/null') | trim == '1' %}
{%   set app_tagged = app_exists and salt['cmd.shell']('qvm-features -- ' ~ app ~ ' seqs-managed 2>/dev/null') | trim == '1' %}

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
# Air gap (e.g. keepass): same CLI invocation the old installer used in
# production ('qvm-prefs <vm> netvm none') -- the declarative qvm.prefs
# netvm-clearing syntax differs across releases and stays out until verified
# on real hardware. setup-qubes.sh independently re-checks this pref after
# the dom0 apply and refuses to provision anything if the air gap is not in
# effect.
seqs-offline-{{ name }}:
  cmd.run:
    - name: qvm-prefs -- {{ app }} netvm none
    - unless: n="$(qvm-prefs -- {{ app }} netvm 2>/dev/null)"; [ -z "$n" ] || [ "$n" = "None" ] || [ "$n" = "none" ]
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
# dom0. qvm-firewall does NOT gate qrexec -- the OpenURL back-channel is
# closed separately via no_handoff. The marker file makes an unchanged
# ruleset a no-op on re-runs; editing the config rewrites it.
seqs-firewall-{{ name }}:
  cmd.run:
    - name: |
        set -e
        qvm-firewall -- {{ app }} reset
        qvm-firewall -- {{ app }} del --rule-no 0
{%     for r in fwrules %}
        qvm-firewall -- {{ app }} add {{ r }}
{%     endfor %}
        qvm-firewall -- {{ app }} add drop
        mkdir -p /var/lib/seqs/firewall
        printf '%s' '{{ fwmarker }}' > /var/lib/seqs/firewall/{{ app }}
    - unless: test "$(cat /var/lib/seqs/firewall/{{ app }} 2>/dev/null)" = '{{ fwmarker }}'
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

{%   if not app_tagged %}
seqs-tag-app-{{ name }}:
  cmd.run:
    - name: qvm-features -- {{ app }} seqs-managed 1 && rm -f {{ intents_dir }}/{{ app }}
    - require:
      - qvm: seqs-app-{{ name }}
      - file: seqs-intent-app-{{ name }}
{%   endif %}
{% endfor %}

{% if webcam_mode in ['dedicated', 'sequential'] %}
# A named disposable USB backend is created only after the operator explicitly
# configures a controller BDF and mode. Dedicated mode removes the controller
# from its old backend. Sequential mode leaves the normal sys-usb assignment in
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
        qvm-prefs -- {{ webcam_usb_qube }} autostart false
        qvm-features -- {{ webcam_usb_qube }} appmenus-dispvm ''
        qvm-features -- {{ webcam_usb_qube }} seqs-managed 1
{% if webcam_mode == 'dedicated' %}
        # Remove persistent assignments from other qubes. qvm-pci's display
        # begins with dom0:BDF and has a free-form description, so it is not a
        # reliable owner parser; query each qube's pcidevs preference instead.
        for current in $(qvm-ls --raw-list); do
          printf '%s\n' "$current" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._-]*$' || continue
          [ "$current" = "{{ webcam_usb_qube }}" ] && continue
          if qvm-prefs -- "$current" pcidevs 2>/dev/null | grep -Fq '{{ webcam_controller }}'; then
            qvm-shutdown --wait "$current" || true
            qvm-pci detach --persistent "$current" dom0:{{ webcam_controller }}
          fi
        done
{% else %}
        # Sequential mode is valid only when this is already the physical
        # controller used by the configured normal USB backend.
        qvm-prefs -- {{ webcam_normal_usb_qube }} pcidevs 2>/dev/null | grep -Fq '{{ webcam_controller }}' || {
          echo 'Configured controller is not assigned to {{ webcam_normal_usb_qube }}' >&2
          exit 1
        }
{% endif %}
        qvm-shutdown --wait {{ webcam_usb_qube }} || true
{% if webcam_mode == 'sequential' %}
        # Remove any prior weak attachment options, then recreate the webcam
        # assignment with Qubes' strict-reset default. The normal sys-usb
        # assignment remains; only one owner may run at a time.
        qvm-pci detach --persistent {{ webcam_usb_qube }} dom0:{{ webcam_controller }} 2>/dev/null || true
{% endif %}
        qvm-pci attach --persistent{% if webcam_no_strict_reset %} --option no-strict-reset=true{% endif %} {{ webcam_usb_qube }} dom0:{{ webcam_controller }}
{% if webcam_mode == 'dedicated' %}
    - unless: n="$(qvm-prefs -- {{ webcam_usb_qube }} netvm 2>/dev/null)"; qvm-check -q -- {{ webcam_usb_qube }} && { [ -z "$n" ] || [ "$n" = None ] || [ "$n" = none ]; } && qvm-prefs -- {{ webcam_usb_qube }} pcidevs 2>/dev/null | grep -Fq '{{ webcam_controller }}'
{% endif %}
    - require:
      - qvm: seqs-app-qr-camera
{% endif %}

{% if webcam_mode == 'sequential' %}
seqs-qr-sequential-scanner:
  cmd.run:
    - name: |
        set -e
        if ! qvm-check -q -- {{ webcam_sequential_scanner }}; then
          qvm-create -C DispVM -t {{ webcam_scanner_dvm }} -l red {{ webcam_sequential_scanner }}
        fi
        qvm-prefs -- {{ webcam_sequential_scanner }} netvm none
        qvm-prefs -- {{ webcam_sequential_scanner }} autostart false
        qvm-features -- {{ webcam_sequential_scanner }} appmenus-dispvm ''
        qvm-features -- {{ webcam_sequential_scanner }} seqs-managed 1
    - unless: n="$(qvm-prefs -- {{ webcam_sequential_scanner }} netvm 2>/dev/null)"; qvm-check -q -- {{ webcam_sequential_scanner }} && { [ -z "$n" ] || [ "$n" = None ] || [ "$n" = none ]; }
    - require:
      - qvm: seqs-app-qr-camera

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
        SCANNER_QUBE='{{ webcam_sequential_scanner }}'
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
        # Format: <template|app> <qube-name> [offline]
        {%- for name in qmap %}
        template {{ ptpl }}{{ name }}
        {%- endfor %}
        {%- for name, q in qmap.items() %}
        app {{ papp }}{{ name }}{{ ' offline' if q.get('offline') else '' }}
        {%- endfor %}

{% endif %}
