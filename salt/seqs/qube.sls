# SEQS per-qube provisioning state; see docs/architecture.md and docs/configuration.md.

{% set seqs = salt['pillar.get']('seqs', {}) %}
{% set role = seqs.get('role', '') %}
{% set spec = seqs.get('spec', {}) %}
{% set comps = spec.get('components', []) %}
{% set exts = seqs.get('brave_extensions', {}) %}
{% set browser_vm = seqs.get('browser_vm', '') %}
{% set browser_desktop = seqs.get('browser_desktop', '') %}
{% set cleanup_dirs = seqs.get('cleanup_dirs', []) %}
{% set timeout = seqs.get('component_timeout', 900) %}
{% set no_handoff = spec.get('no_handoff', False) or spec.get('offline', False) %}
{% set name_re = '^[A-Za-z0-9_][A-Za-z0-9._-]*$' %}

{% if role not in ['template', 'app'] %}
# Not a SEQS-configured qube (matched the Z-*/A-* glob but has no spec in the
# pillar map) -- deliberately a no-op so a stray prefix match is harmless.
seqs-noop:
  test.nop:
    - name: {{ grains['id'] }} has no SEQS pillar spec -- nothing to do
{% else %}

{# ── Defense-in-depth validation. Pillar is dom0-authored, but nothing is
     interpolated into a command or path without a charset check. ─────── #}
{% set errors = [] %}
{% for comp in comps %}
{%   if comp | regex_match(name_re) is none %}
{%     do errors.append("unsafe component name '" ~ comp ~ "'") %}
{%   elif comp.startswith('brave-extension-') %}
{%     if exts.get(comp[16:], '') | regex_match('^[a-p]{32}$') is none %}
{%       do errors.append("missing or invalid extension ID for '" ~ comp ~ "'") %}
{%     endif %}
{%   endif %}
{% endfor %}
{% if browser_vm | regex_match(name_re) is none %}
{%   do errors.append("unsafe browser_vm '" ~ browser_vm ~ "'") %}
{% endif %}
{% if browser_desktop | regex_match('^[A-Za-z0-9._-]+\\.desktop$') is none %}
{%   do errors.append("unsafe browser_desktop '" ~ browser_desktop ~ "'") %}
{% endif %}
{# timeout is interpolated into the cmd.run states below as a bare YAML
   value -- anything but a number could smuggle extra YAML keys in. #}
{% if timeout is not number %}
{%   do errors.append("component_timeout must be a number, got '" ~ timeout ~ "'") %}
{% endif %}
{% if role == 'template' %}
{%   for e in cleanup_dirs %}
{%     if e.get('mode') not in ['folder', 'contents']
          or e.get('path', '') | regex_match('^/home/user/[A-Za-z0-9._/-]+$') is none
          or '..' in e.get('path', '') %}
{%       do errors.append("unsafe cleanup_dirs entry '" ~ e ~ "'") %}
{%     endif %}
{%   endfor %}
{% endif %}

{% if errors %}
seqs-qube-validation-failed:
  test.fail_without_changes:
    - name: SEQS pillar validation failed in {{ grains['id'] }}
    - comment: {{ errors | join(' | ') | tojson }}
    - failhard: True
{% else %}

seqs-marker-dir:
  file.directory:
    - name: /rw/config/seqs
    - user: root
    - group: root
    - mode: '0755'

# Shared helper libs, staged once for brave-extension installs.
seqs-stage-lib:
  file.recurse:
    - name: /run/seqs/stage/lib
    - source: salt://seqs/files/lib
    - dir_mode: '0755'
    - file_mode: '0755'

{% for comp in comps %}
{%   if comp.startswith('brave-extension-') %}
{%     if role == 'template' %}
{%       set eid = exts[comp[16:]] %}
# Extension IDs were validated against ^[a-p]{32}$ above, so the
# interpolation below cannot break out of the quoted command.
# brave.sh documents that its caller must run under `set -Eeuo pipefail`,
# so the inner shell sets it too -- a failure inside a lib function must
# not fall through to install_brave_extension.
seqs-install-{{ comp }}:
  cmd.run:
    - name: |
        set -e
        runuser -l user -c 'set -Eeuo pipefail; . /run/seqs/stage/lib/brave.sh; ensure_brave; install_brave_extension {{ eid }}'
        touch /rw/config/seqs/{{ comp }}.template.done
    - creates: /rw/config/seqs/{{ comp }}.template.done
    - timeout: {{ timeout }}
    - require:
      - file: seqs-stage-lib
      - file: seqs-marker-dir
{%     endif %}
{%   else %}
{%     set script = 'template-vm.sh' if role == 'template' else 'app-vm.sh' %}
# Stage the component directory (scripts + assets) ...
seqs-stage-{{ comp }}:
  file.recurse:
    - name: /run/seqs/stage/{{ comp }}
    - source: salt://seqs/files/components/{{ comp }}
    - dir_mode: '0755'
    - file_mode: '0755'

# ... then overlay shared libraries so component assets cannot shadow them.
seqs-stage-{{ comp }}-libs:
  file.recurse:
    - name: /run/seqs/stage/{{ comp }}
    - source: salt://seqs/files/lib
    - file_mode: '0755'
    - require:
      - file: seqs-stage-{{ comp }}

# template-vm.sh / app-vm.sh are both optional per component; a missing
# script is a no-op (marker is still written so the state converges).
seqs-install-{{ comp }}:
  cmd.run:
    - name: |
        set -e
        script=/run/seqs/stage/{{ comp }}/{{ script }}
        if [ -e "$script" ]; then
          runuser -l user -c "$script"
        fi
{%     if role == 'template' %}
        if [ -e /run/seqs/stage/{{ comp }}/menu.desktop ]; then
          install -m 0644 -o root -g root /run/seqs/stage/{{ comp }}/menu.desktop /usr/share/applications/{{ comp }}.desktop
        fi
{%     endif %}
        touch /rw/config/seqs/{{ comp }}.{{ role }}.done
    - creates: /rw/config/seqs/{{ comp }}.{{ role }}.done
    - timeout: {{ timeout }}
    - require:
      - file: seqs-stage-{{ comp }}-libs
      - file: seqs-marker-dir
{%   endif %}
{% endfor %}

{% if role == 'template' %}
# ── Link-handoff .desktop handler (root volume, inherited by app qubes).
# Installed into EVERY template; whether a given app qube actually hands
# links off is gated per-qube by the xdg default below and at the dom0
# boundary by the qubes.OpenURL policy. Root-owned 0644 so nothing running
# as 'user' can rewrite the Exec= line.
seqs-browser-handler:
  file.managed:
    - name: /usr/share/applications/{{ browser_desktop }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Desktop Entry]
        Encoding=UTF-8
        Name=Open links in {{ browser_vm }}
        Exec=qvm-open-in-vm {{ browser_vm }} %u
        Terminal=false
        X-MultipleArgs=false
        Type=Application
        Categories=Network;WebBrowser;
        MimeType=x-scheme-handler/http;x-scheme-handler/https;

{% if cleanup_dirs and not spec.get('preserve_incoming') %}
# ── Boot/shutdown cleanup of transient directories.
# Fails CLOSED: only deletes when the VM is explicitly an AppVM/DispVM, so a
# qubesdb-read failure inside the template never wipes template state.
# Paths were validated above (absolute, under /home/user/, no '..', safe
# charset), so quoting them below is sufficient.
seqs-cleanup-script:
  file.managed:
    - name: /usr/sbin/seqs-cleanup
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # SEQS: delete transient directories on app-qube boot and shutdown.
        # Managed by salt state seqs.qube -- edit the SEQS repo, not this copy.
        vmtype="$(qubesdb-read /qubes-vm-type 2>/dev/null)" || exit 0
        case "$vmtype" in
          AppVM|DispVM) ;;
          *) exit 0 ;;
        esac
        {%- for e in cleanup_dirs if e.get('mode') == 'folder' %}
        rm -rf -- "{{ e.get('path') }}"
        {%- endfor %}
        {%- for e in cleanup_dirs if e.get('mode') == 'contents' %}
        if [ -d "{{ e.get('path') }}" ]; then find "{{ e.get('path') }}" -mindepth 1 -delete; fi
        {%- endfor %}
        exit 0

seqs-cleanup-unit:
  file.managed:
    - name: /etc/systemd/system/seqs-cleanup.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=SEQS delete transient directories on boot and shutdown
        RequiresMountsFor=/home

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/seqs-cleanup
        ExecStop=/usr/sbin/seqs-cleanup

        [Install]
        WantedBy=multi-user.target

seqs-cleanup-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: seqs-cleanup-unit

seqs-cleanup-enabled:
  service.enabled:
    - name: seqs-cleanup.service
    - require:
      - file: seqs-cleanup-script
      - file: seqs-cleanup-unit
      - cmd: seqs-cleanup-reload
{% endif %}
{% endif %}

{% if role == 'app' %}
{% if not no_handoff and grains['id'] != browser_vm %}
# ── Open web links in the browser qube. Writes ~/.config/mimeapps.list on
# the private volume, so it must run per app qube, not in the template.
seqs-default-browser:
  cmd.run:
    - name: runuser -l user -c 'xdg-settings set default-web-browser {{ browser_desktop }}'
    - unless: runuser -l user -c 'test "$(xdg-settings get default-web-browser 2>/dev/null)" = "{{ browser_desktop }}"'
{% endif %}
{% endif %}

{% endif %}
{% endif %}
