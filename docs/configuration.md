# Configuring what SEQS builds

All configuration lives in **one file**: `salt/pillar/seqs/config.sls`
(installed to `/srv/pillar/seqs/config.sls`). Edit it in the repo qube and
re-run `./setup-qubes.sh`, or edit the installed copy in dom0 and re-run with
`--skip-fetch`.

The README covers the common case — [editing `qube_list`](../README.md#22-choose-your-qubes-saltpillarseqsconfigsls).
This document covers the component catalogue and everything else.

## Components

Each qube in `qube_list` is built from a list of components:

| Component | What it installs |
|---|---|
| `adb`          | Android Debug Bridge + `pv` (Debian apt) + chunked, resumable `/usr/bin/adb-pull` helper |
| `brave`        | Brave browser (apt repo, embedded verified key) |
| `bitbox`       | BitBoxApp `.deb` (GPG-verified) |
| `claude-code`  | Claude Code (native installer) |
| `docker`       | Docker engine + persistent `/var/lib/docker` bind-dir |
| `element`      | Element chat (apt repo) |
| `keepass`      | KeePassXC AppImage (GPG-verified) |
| `ledger`       | Ledger udev rules + Ledger Live |
| `node`         | Node.js via nvm |
| `openoffice`   | Apache OpenOffice tarball (GPG-verified) |
| `python`       | pyenv + Python |
| `signal`       | Signal Desktop (apt repo, embedded verified key) |
| `telegram`     | Telegram via snap (`telegram-desktop`) |
| `trezor`       | Trezor udev rules |
| `vscode`       | Visual Studio Code |
| `xournalpp`    | Xournal++ (Debian package) |

## `qube_list` flags

Each entry is `{'name': ..., 'label': ..., 'components': [...]}` plus optional
flags:

- `'offline': True` — detaches the app qube from netvm (air gap). Implies
  `no_handoff`, and the runner re-verifies the air gap after the dom0 apply.
  Use for wallet/vault qubes.
- `'no_handoff': True` — disables the browser-link handoff for that qube, both
  at the qube's xdg config and via a dom0 qrexec deny rule.
- `'dispvm_template': True` — makes the app qube a DisposableVM template. The
  shipped offline `qr-display` and `qr-camera` entries use this flag; see
  [secure QR transfer](secure-qr-transfer.md). Sensitive disposable templates
  must also set `offline: True` (enforced by pre-flight validation).

Duplicate names abort the pre-flight.

## `brave_extensions`

Maps name → Chrome Web Store ID for each Brave wallet extension. Reference them
in qube specs as `brave-extension-<name>`; Brave is auto-installed on the first
such reference in a qube.

- **Enable** an extension in a qube: add `brave-extension-<name>` to that qube's
  component list.
- **Add** a new extension (e.g. Ambire): add a `brave_extensions` line, then
  reference it as `brave-extension-ambire` in any wallet qube.
- **Retire** an extension entirely: remove its line from `brave_extensions`.

## Browser-link handoff requires `A-brave`

The `seqs.dom0` state configures every non-browser qube to open web links in
`browser_vm` (default `A-brave`) via the dom0 qrexec policy
`qubes.OpenURL * @anyvm A-brave allow`. If you remove `brave` from `qube_list`,
also change `browser_vm` in `config.sls` to a browser qube you do have — the
pre-flight refuses a `browser_vm` that is neither configured nor already
existing.

## Adding a new component

Create `install-scripts/components/<name>/` containing:

- an optional `template-vm.sh` — system-wide install in the template,
- an optional `app-vm.sh` — per-app-VM setup in `$HOME` / `/rw`,
- an optional `menu.desktop` — installed as
  `/usr/share/applications/<name>.desktop`.

Then reference `<name>` in any qube spec. If the component needs Brave, it can
`source "$(dirname "$0")/brave.sh"` and call `install_brave` (or `ensure_brave`
for idempotent installation).

After adding a component, also add it to the **Components** table above so the
`VERIFY-LLM.md` §10 coherence check stays green.
