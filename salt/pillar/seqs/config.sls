{#-
SEQS master configuration. Edit the values below; see docs/configuration.md
for all options and docs/secure-qr-transfer.md before enabling webcam USB.
-#}

{%- set prefix_template = 'Z-' %}
{%- set prefix_app = 'A-' %}
{#- Base template every new template VM clones from. #}
{%- set base_template = 'debian-13-xfce' %}
{#- Browser-link target; see docs/configuration.md. #}
{%- set browser_vm = prefix_app ~ 'brave' %}
{%- set browser_desktop = 'open-links-in-browser-qube.desktop' %}
{#- Explicitly forget preserved browser-suppression denies by base name. #}
{%- set browser_suppress_prune = [] %}
{#- Per-component installation timeout in seconds. #}
{%- set component_timeout = 900 %}

{#- Keep disabled until completing docs/secure-qr-transfer.md. #}
{%- set webcam_usb_mode = 'disabled' %}
{%- set webcam_usb_controller = '' %}
{%- set webcam_usb_no_strict_reset = False %}
{%- set webcam_usb_qube = 'sys-usb-webcam' %}
{%- set webcam_scanner_dvm = prefix_app ~ 'qr-camera' %}
{%- set webcam_normal_usb_qube = 'sys-usb' %}
{%- set webcam_sequential_scanner = 'seqs-qr-scanner' %}
{%- set webcam_staging_qube = prefix_app ~ 'qr-staging' %}

{#- Catalogue of everything this reviewed tree is able to build. The runner's
    mandatory --qubes/--all argument selects entries for each invocation. #}
{%- set qube_catalog = [
  {'name': 'brave',             'label': 'red',    'components': ['brave']},
  {'name': 'element',           'label': 'red',    'components': ['element']},
  {'name': 'telegram',          'label': 'red',    'components': ['telegram']},
  {'name': 'signal',            'label': 'green',  'components': ['signal']},
  {'name': 'openoffice',        'label': 'yellow', 'components': ['openoffice']},
  {'name': 'xournalpp',         'label': 'yellow', 'components': ['xournalpp']},
  {'name': 'usb-data-transfer', 'label': 'red',    'components': ['adb']},
  {'name': 'keepass',           'label': 'black',  'components': ['keepass'], 'offline': True},
  {'name': 'qr-display',        'label': 'black',  'components': ['qr-display'], 'offline': True, 'dispvm_template': True},
  {'name': 'qr-camera',         'label': 'red',    'components': ['qr-camera'], 'offline': True, 'dispvm_template': True},
  {'name': 'qr-staging',        'label': 'red',    'components': [], 'offline': True, 'preserve_incoming': True},
  {'name': 'dev-full',          'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code']},
  {'name': 'wallet-ledger',     'label': 'gray',   'components': ['ledger', 'brave-extension-rabby'], 'no_handoff': True},
  {'name': 'wallet-trezor',     'label': 'gray',   'components': ['trezor', 'brave-extension-rabby'], 'no_handoff': True},
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
  base_template: '{{ base_template }}'
  browser_vm: '{{ browser_vm }}'
  browser_desktop: '{{ browser_desktop }}'
  browser_suppress_prune: {{ browser_suppress_prune | tojson }}
  component_timeout: {{ component_timeout }}
  config_errors: {{ config_errors | tojson }}
  catalogue: {{ qubes | tojson }}
  brave_extensions: {{ brave_extensions | tojson }}
  cleanup_dirs: {{ cleanup_dirs | tojson }}
  webcam_usb_controller: '{{ webcam_usb_controller }}'
  webcam_usb_mode: '{{ webcam_usb_mode }}'
  webcam_usb_no_strict_reset: {{ webcam_usb_no_strict_reset | tojson }}
  webcam_usb_qube: '{{ webcam_usb_qube }}'
  webcam_scanner_dvm: '{{ webcam_scanner_dvm }}'
  webcam_normal_usb_qube: '{{ webcam_normal_usb_qube }}'
  webcam_sequential_scanner: '{{ webcam_sequential_scanner }}'
  webcam_staging_qube: '{{ webcam_staging_qube }}'
{%- else %}
{%-   set ns = namespace(role='', base='') %}
{%-   if id.startswith(prefix_template) %}
{%-     set ns.role = 'template' %}
{%-     set ns.base = id[(prefix_template | length):] %}
{%-   elif id.startswith(prefix_app) %}
{%-     set ns.role = 'app' %}
{%-     set ns.base = id[(prefix_app | length):] %}
{%-   endif %}
{%-   if ns.base and ns.base in qubes %}
{%-     set spec = qubes[ns.base] %}
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
  base_name: '{{ ns.base }}'
  browser_vm: '{{ browser_vm }}'
  browser_desktop: '{{ browser_desktop }}'
  component_timeout: {{ component_timeout }}
  spec: {{ spec | tojson }}
  brave_extensions: {{ exts | tojson }}
{%-     if ns.role == 'template' %}
  cleanup_dirs: {{ cleanup_dirs | tojson }}
{%-     endif %}
{%-   else %}
{#-     A qube that merely matches the Z-*/A-* glob but is not in the map
        (user-added qube with the same prefix) gets an empty marker so
        seqs.qube renders to a no-op for it. #}
seqs: {}
{%-   endif %}
{%- endif %}
