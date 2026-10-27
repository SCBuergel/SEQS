{#-
SEQS master configuration. Edit the values below; see docs/configuration.md
for all options and docs/secure-qr-transfer.md before enabling webcam USB.
-#}

{%- set prefix_template = 'Z-' %}
{%- set prefix_app = 'A-' %}
{#- Prefix for named DisposableVMs created from a 'named_disposable' entry's
    dispvm template, so the disposable is launchable from the Qubes menu
    instead of only appearing under "Templates". #}
{%- set prefix_disposable = 'D-' %}
{#- Base template every new template VM clones from. #}
{%- set base_template = 'debian-13-xfce' %}
{#- Browser-link target; see docs/configuration.md. #}
{%- set browser_vm = prefix_app ~ 'brave' %}
{%- set browser_desktop = 'open-links-in-browser-qube.desktop' %}
{#- Per-component installation timeout in seconds. #}
{%- set component_timeout = 900 %}
{#- Minimum memory of sys-usb in MiB (0 leaves it alone); see docs/configuration.md. #}
{%- set sys_usb_memory = 600 %}
{#- Intel NUC 11 headset jack fix (True/False), applied only on a NUC 11; see
    docs/configuration.md. #}
{%- set nuc11_headset_fix = True %}
{#- Ask in dom0 before a USB keyboard from sys-usb works where Qubes 4.3 would
    refuse it (True/False); see docs/configuration.md. #}
{%- set usb_keyboard_prompt = True %}
{#- Dom0 desktop: panel launchers for dom0 programs, placed right after the
    Qubes menu button, and window-tiling shortcuts; see docs/configuration.md. #}
{%- set dom0_launchers = ['qubes-qube-manager.desktop', 'qubes-update-gui.desktop',
                          'xfce4-screenshooter.desktop', 'xfce4-terminal.desktop'] %}
{%- set window_tiling_keys = {
  '<Super>Up': 'tile_up_key', '<Super>Down': 'tile_down_key',
  '<Super>Left': 'tile_left_key', '<Super>Right': 'tile_right_key',
  '<Super>Page_Up': 'tile_up_left_key', '<Super>Page_Down': 'tile_up_right_key',
  '<Alt>Left': 'tile_down_left_key', '<Alt>Right': 'tile_down_right_key'} %}

{#- Keep disabled until completing docs/secure-qr-transfer.md. #}
{%- set webcam_usb_mode = 'disabled' %}
{%- set webcam_usb_controller = '' %}
{#- True: Qubes resets the controller whenever it moves to the webcam qube.
    False only for a sequential-mode controller without a reset method; the
    build checks which applies. #}
{%- set webcam_usb_strict_reset = True %}
{%- set webcam_usb_qube = 'sys-usb-webcam' %}
{%- set webcam_normal_usb_qube = 'sys-usb' %}
{#- Named disposable of qr-camera that scans on both paths; qrexec rules name it. #}
{%- set webcam_scanner_qube = 'seqs-qr-scanner' %}

{#- Catalogue of everything this reviewed tree is able to build. The runner's
    mandatory --qubes/--all argument selects entries for each invocation. #}
{%- set qube_catalog = [
  {'name': 'brave',             'label': 'red',    'components': ['brave'], 'main_app': 'brave-browser.desktop'},
  {'name': 'element',           'label': 'red',    'components': ['element'], 'main_app': 'element-desktop.desktop'},
  {'name': 'telegram',          'label': 'red',    'components': ['telegram'], 'main_app': 'telegram-desktop_telegram-desktop.desktop'},
  {'name': 'signal',            'label': 'green',  'components': ['signal'], 'main_app': 'signal-desktop.desktop'},
  {'name': 'wireguard',         'label': 'purple', 'components': ['wireguard'], 'network_provider': True, 'no_handoff': True},
  {'name': 'gnosisvpn',         'label': 'purple', 'components': ['gnosisvpn'], 'network_provider': True, 'no_handoff': True, 'vcpus': 4},
  {'name': 'protonvpn',         'label': 'purple', 'components': ['protonvpn'], 'network_provider': True, 'no_handoff': True, 'main_app': 'proton.vpn.app.gtk.desktop'},
  {'name': 'anon',              'label': 'red',    'components': ['brave'], 'netvm': 'gnosisvpn', 'dispvm_template': True, 'named_disposable': True, 'no_handoff': True, 'main_app': 'brave-browser.desktop'},
  {'name': 'openoffice',        'label': 'yellow', 'components': ['openoffice'], 'main_app': 'openoffice4-startcenter.desktop'},
  {'name': 'xournalpp',         'label': 'yellow', 'components': ['xournalpp'], 'main_app': 'com.github.xournalpp.xournalpp.desktop'},
  {'name': 'usb-data-transfer', 'label': 'red',    'components': ['adb']},
  {'name': 'keepass',           'label': 'black',  'components': ['keepass'], 'offline': True, 'main_app': 'keepass.desktop'},
  {'name': 'bluetooth',         'label': 'blue',   'components': ['bluetooth'], 'offline': True, 'audio_provider': True, 'main_app': 'blueman-manager.desktop'},
  {'name': 'qr-display',        'label': 'black',  'components': ['qr-display'], 'offline': True, 'dispvm_template': True, 'named_disposable': True, 'main_app': 'qr-display.desktop'},
  {'name': 'qr-camera',         'label': 'red',    'components': ['qr-camera'], 'offline': True, 'dispvm_template': True},
  {'name': 'qr-staging',        'label': 'red',    'components': [], 'offline': True, 'preserve_incoming': True},
  {'name': 'claude-code',       'label': 'orange', 'components': ['claude-code']},
  {'name': 'dev-full',          'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code'], 'main_app': 'com.microsoft.VSCode.desktop'},
  {'name': 'wallet-ledger',     'label': 'gray',   'components': ['ledger', 'brave-extension-rabby'], 'no_handoff': True, 'main_app': 'ledger.desktop'},
  {'name': 'wallet-trezor',     'label': 'gray',   'components': ['trezor', 'brave-extension-rabby'], 'no_handoff': True, 'main_app': 'brave-browser.desktop'},
] %}

{#- Wallet extension IDs; see docs/configuration.md. #}
{%- set brave_extensions = {
  'ready':        'dlcobpjiigpikoobohmabehhmhfoodbb',
  'cosmostation': 'fpkhgmpbidmiogeglndfbkegfdlnajnf',
  'enkrypt':      'kkpllkodjeloidieedojogacfhpaihoh',
  'metamask':     'nkbihfbeogaeaoehlefnkodbefgpgknn',
  'nabox':        'nknhiehlklippafakaeklbeglecifhad',
  'okx':          'mcohilncbfahbmgdjkbpemcciiolgcge',
  'rabby':        'acmacodkjbdgmoleebolmdjonilkdbch',
  'rainbow':      'opfgelmcmbiajamepnmloijbpoleiama',
  'tahoe':        'eajafomhmkipbjmfmhebemolkcicgfmd',
  'trustwallet':  'egjidjbpglichdcondbcbdnbeeppgdph',
  'zeal':         'heamnjbnflcikcggoiplibfommfbkjpj',
  'zerion':       'klghhnkeealcohjjanjjdaeeggmfmlpl',
} %}

{#- App-qube boot/shutdown cleanup; see docs/configuration.md. #}
{%- set cleanup_dirs = [
  {'mode': 'folder',   'path': '/home/user/QubesIncoming'},
  {'mode': 'contents', 'path': '/home/user/Downloads'},
] %}

{#- ────────────────────────────────────────────────────────────────────────
    Derived data below -- no configuration past this point.
    ──────────────────────────────────────────────────────────────────────── #}

{#- Build the by-name map and catch duplicates. Errors are shipped to dom0
    as config_errors and abort the seqs.dom0 pre-flight before anything
    is changed. #}
{%- set config_errors = [] %}
{%- set qubes = {} %}
{%- for q in qube_catalog %}
{%-   set qname = q.get('name', '') %}
{%-   if not qname %}
{%-     do config_errors.append('qube entry without a name in qube_catalog') %}
{%-   elif qname in qubes %}
{%-     do config_errors.append("duplicate qube name '" ~ qname ~ "' in qube_catalog") %}
{%-   else %}
{%-     do qubes.update({qname: q}) %}
{%-   endif %}
{%- endfor %}

{#- ── Per-minion slicing ─────────────────────────────────────────────── #}
{%- set id = grains['id'] %}
{%- if id == 'dom0' %}
seqs:
  prefix_template: '{{ prefix_template }}'
  prefix_app: '{{ prefix_app }}'
  prefix_disposable: '{{ prefix_disposable }}'
  base_template: '{{ base_template }}'
  browser_vm: '{{ browser_vm }}'
  browser_desktop: '{{ browser_desktop }}'
  config_errors: {{ config_errors | tojson }}
  catalogue: {{ qubes | tojson }}
  brave_extensions: {{ brave_extensions | tojson }}
  cleanup_dirs: {{ cleanup_dirs | tojson }}
  sys_usb_memory: {{ sys_usb_memory | tojson }}
  nuc11_headset_fix: {{ nuc11_headset_fix | tojson }}
  usb_keyboard_prompt: {{ usb_keyboard_prompt | tojson }}
  dom0_launchers: {{ dom0_launchers | tojson }}
  window_tiling_keys: {{ window_tiling_keys | tojson }}
  webcam_usb_controller: '{{ webcam_usb_controller }}'
  webcam_usb_mode: '{{ webcam_usb_mode }}'
  webcam_usb_strict_reset: {{ webcam_usb_strict_reset | tojson }}
  webcam_usb_qube: '{{ webcam_usb_qube }}'
  webcam_normal_usb_qube: '{{ webcam_normal_usb_qube }}'
  webcam_scanner_qube: '{{ webcam_scanner_qube }}'
{%- else %}
{%-   set ns = namespace(role='', base='') %}
{%-   if id.startswith(prefix_template) %}
{%-     set ns.role = 'template' %}
{%-     set ns.base = id[(prefix_template | length):] %}
{%-   elif id.startswith(prefix_app) %}
{%-     set ns.role = 'app' %}
{%-     set ns.base = id[(prefix_app | length):] %}
{%-   endif %}
{#-   Instance names are <recipe> or <recipe>-<postfix>. Prefer an exact
       catalogue match, otherwise choose the longest matching recipe prefix.
       Dom0 rejects generated names that collide with a different exact recipe. #}
{%-   set resolved = namespace(recipe='') %}
{%-   if ns.base in qubes %}
{%-     set resolved.recipe = ns.base %}
{%-   else %}
{%-     for candidate in qubes if ns.base.startswith(candidate ~ '-') %}
{%-       if candidate | length > resolved.recipe | length %}
{%-         set resolved.recipe = candidate %}
{%-       endif %}
{%-     endfor %}
{%-   endif %}
{%-   if ns.base and resolved.recipe %}
{%-     set recipe = resolved.recipe %}
{%-     set spec = qubes[recipe] %}
{#-     Only ship the extension IDs this qube actually references. #}
{%-     set exts = {} %}
{%-     for c in spec.get('components', []) if c.startswith('brave-extension-') %}
{%-       set en = c[16:] %}
{%-       if en in brave_extensions %}
{%-         do exts.update({en: brave_extensions[en]}) %}
{%-       endif %}
{%-     endfor %}
seqs:
  role: '{{ ns.role }}'
  browser_vm: '{{ browser_vm }}'
  browser_desktop: '{{ browser_desktop }}'
  component_timeout: {{ component_timeout }}
  spec: {{ spec | tojson }}
  brave_extensions: {{ exts | tojson }}
{%-     if ns.role == 'template' %}
  cleanup_dirs: {{ cleanup_dirs | tojson }}
{%-     endif %}
{%-   else %}
{#-     A qube that matches the Z-*/A-* glob but is neither an exact catalogue
        name nor <catalogue-name>-<postfix> gets an empty marker, so seqs.qube
        renders to a no-op for it. The runner targets postfixed names only
        after dom0 has created/validated their seqs-managed ownership. #}
seqs: {}
{%-   endif %}
{%- endif %}
