{#-
SEQS master configuration (Qubes Salt pillar).

This file replaces the config arrays that used to sit at the top of the old
imperative setup-qubes.sh (SINGLE_QUBES / DEV_QUBES / WALLET_QUBES /
BRAVE_EXTENSIONS / CLEANUP_DIRS / OS_TEMPLATE_VM / PREFIX_* / BROWSER_VM).
Edit the jinja sets below, then re-run setup-qubes.sh in dom0 (or
`sudo qubesctl state.apply seqs.dom0` followed by per-qube applies).

Pillar is compiled in dom0 and is per-minion: each qube only ever receives
its OWN slice (role, its component list, the extension IDs it references,
and the shared browser/cleanup knobs). dom0 receives the full map. This is
deliberate -- a compromised app qube must not learn the full qube topology
or the wallet-extension inventory from its pillar.

COLOR / label semantics (unchanged from the old script):
  red    -- arbitrary network input from strangers (brave, element, telegram)
  orange -- heavy tooling / agent code execution (dev qubes)
  yellow -- local docs with import risk (openoffice, xournalpp)
  green  -- clean utility, known-only input (signal)
  gray   -- exposed AND holds value (wallets)
  black  -- offline vault, no network at all (keepass)
  blue/purple -- reserved for user-added qubes.

Per-qube flags:
  offline: True    -- app qube gets its netvm cleared (air-gapped). Implies
                      no_handoff. setup-qubes.sh re-verifies the air gap
                      after the dom0 apply before provisioning anything.
  no_handoff: True -- no xdg link-handoff to the browser qube, AND a dom0
                      qrexec deny rule blocks qubes.OpenURL from this qube
                      (see seqs/dom0.sls, 28-browser-suppress.policy).
  firewall: [...]  -- optional outbound allowlist for the app qube. When the
                      key is PRESENT the qube gets default-deny egress with
                      one accept rule per entry (applied via qvm-firewall);
                      when ABSENT the Qubes default (allow all) is kept, and
                      a previously applied SEQS allowlist is reverted.
                      Entries:
                        'host.example.com'   accept to that host (any port)
                        '10.137.0.51'        accept to that IPv4
                        'host:443'           accept tcp to that host:port
                        'dns'                accept DNS resolution
                        'icmp'               accept ICMP (ping / path MTU)
                      'dns' is needed if the qube must resolve hostnames
                      itself, but DNS is also an exfiltration channel
                      (tunneling) -- prefer IP entries without 'dns' where
                      practical. Contradicts 'offline' (validated). Note
                      qvm-firewall does NOT gate qrexec; the OpenURL
                      back-channel is closed separately by no_handoff.
                      Recommended for the wallet qubes once you know your
                      RPC endpoints, e.g.:
                        'firewall': ['dns', 'rpc.example.com:443']

Qube specs are a LIST (not a dict) so that a duplicate name cannot silently
shadow an earlier entry: duplicates are collected into config_errors below
and abort the seqs.dom0 pre-flight -- same strictness as the old
validateAllQubes.
-#}

{%- set prefix_template = 'Z-' %}
{%- set prefix_app = 'A-' %}
{#- Base template every new template VM clones from. #}
{%- set base_template = 'debian-13-xfce' %}
{#- App qube every non-browser qube opens web links in. Must match a qube
    that gets built below (prefix_app + name) or an existing one; seqs.dom0
    validates this. #}
{%- set browser_vm = prefix_app ~ 'brave' %}
{%- set browser_desktop = 'open-links-in-browser-qube.desktop' %}
{#- Per-component install timeout (seconds) inside each qube; replaces the
    old per-qube BUILD_TIMEOUT_SECONDS watchdog. #}
{%- set component_timeout = 900 %}

{#- Secure QR transfer. The display and scanner entries below are offline
    DisposableVM templates. Set webcam_usb_controller to the dedicated USB
    controller BDF identified in dom0 (qvm-pci), e.g. '03_00.0', to have SEQS
    create sys-usb-webcam and move that controller to it. Empty is deliberately
    safe-by-default: software cannot determine which ports/controllers are safe.
    Do not confuse this physical dom0 BDF with a qvm-usb device path (e.g.
    sys-usb:4-3) or the virtual PCI address visible inside sys-usb. Follow the
    identification and stop-condition guide in docs/secure-qr-transfer.md.
    no_strict_reset weakens reset isolation and must only be enabled if the
    controller cannot otherwise be attached. #}
{%- set webcam_usb_controller = '' %}
{%- set webcam_usb_no_strict_reset = False %}
{%- set webcam_usb_qube = 'sys-usb-webcam' %}
{%- set webcam_scanner_dvm = prefix_app ~ 'qr-camera' %}

{%- set qube_list = [
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
  {'name': 'dev-full',          'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code']},
  {'name': 'wallet-ledger',     'label': 'gray',   'components': ['ledger', 'brave-extension-rabby'], 'no_handoff': True},
  {'name': 'wallet-trezor',     'label': 'gray',   'components': ['trezor', 'brave-extension-rabby'], 'no_handoff': True},
] %}

{#- Brave wallet extension name -> Chrome Web Store ID. Reference as
    'brave-extension-<name>' in a qube's component list. #}
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

{#- Transient-directory cleanup at app-qube boot and shutdown.
    mode 'folder'   -- delete the directory itself, contents and all
    mode 'contents' -- empty the directory but keep it
    Paths must be absolute, strictly under /home/user/, contain no '..' and
    only [A-Za-z0-9._/-] characters (validated in seqs/dom0.sls and again in
    seqs/qube.sls -- the generated cleanup script runs rm -rf as root). #}
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
{%- for q in qube_list %}
{%-   set qname = q.get('name', '') %}
{%-   if not qname %}
{%-     do config_errors.append('qube entry without a name in qube_list') %}
{%-   elif qname in qubes %}
{%-     do config_errors.append("duplicate qube name '" ~ qname ~ "' in qube_list") %}
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
  component_timeout: {{ component_timeout }}
  config_errors: {{ config_errors | tojson }}
  qubes: {{ qubes | tojson }}
  brave_extensions: {{ brave_extensions | tojson }}
  cleanup_dirs: {{ cleanup_dirs | tojson }}
  webcam_usb_controller: '{{ webcam_usb_controller }}'
  webcam_usb_no_strict_reset: {{ webcam_usb_no_strict_reset | tojson }}
  webcam_usb_qube: '{{ webcam_usb_qube }}'
  webcam_scanner_dvm: '{{ webcam_scanner_dvm }}'
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
