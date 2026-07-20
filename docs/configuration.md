# Selecting what SEQS builds

The reviewed catalogue lives in `salt/pillar/seqs/config.sls` and is installed
unchanged under `/srv/pillar/seqs/config.sls`. Ordinary installation does not
require editing it. Select existing catalogue entries with a mandatory dom0
runner argument:

```bash
~/s.sh --build-only --qubes brave,signal,keepass
~/s.sh --build-only --all
```

Do not edit the staged `/srv` copy to select qubes. Editing the repository file
is an advanced operation for changing catalogue definitions or machine-wide
settings; those changes must go through fetch, review, and stage again.

For an already installed machine, follow [the upgrade procedure](upgrading.md).
In particular, repository changes must be fetched into
`/var/lib/seqs/fetched`, staged under `/srv`, and then built.

The first-install guide covers the common selection-only case. This document
also describes advanced fields for an intentionally maintained custom fork or
machine-specific hardware configuration.

## Components

Each qube in `qube_catalog` is built from a list of components. The catalogue
describes what the reviewed tree can build; it does not select every entry for
every run.

Staging always copies the complete reviewed tree. Consequently, changing only
the runtime selection does not change the staged-tree hash. The runner prints a
separate build-plan hash and records the canonical selection in
`/var/lib/seqs/last-run`.

The shipped catalogue currently exposes these base names:

```text
brave  element  telegram  signal  openoffice  xournalpp
usb-data-transfer  keepass  qr-display  qr-camera  qr-staging
dev-full  wallet-ledger  wallet-trezor
```

Names are case-sensitive and must be passed without the generated `A-` or `Z-`
prefix. On a new machine, include `brave` in the first selection because the
default browser-handoff policy targets `A-brave`. Later partial builds may omit
it once `A-brave` already exists.

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
| `qr-camera`    | `zbarcam` QR scanner + Qubes USB proxy for the offline camera DisposableVM template |
| `qr-display`   | `qrencode` for the offline QR-display DisposableVM template |
| `signal`       | Signal Desktop (apt repo, embedded verified key) |
| `telegram`     | Telegram via snap (`telegram-desktop`) |
| `trezor`       | Trezor udev rules |
| `vscode`       | Visual Studio Code |
| `xournalpp`    | Xournal++ (Debian package) |

## `qube_catalog` flags

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
- `'named_disposable': True` — also creates a named DisposableVM (`D-<name>`,
  the `prefix_disposable`) from the `A-<name>` dispvm template, so the
  disposable is launchable from the Qubes menu rather than only appearing under
  "Templates". Requires `dispvm_template`; the shipped `qr-display` entry uses
  it. The named disposable inherits the offline air gap and is reset on every
  shutdown, so nothing is provisioned inside it.

Duplicate names abort the pre-flight.

Browser-suppression denies are additive across partial upgrades. When a run
configures only new qubes, SEQS preserves exact `qubes.OpenURL` deny rules for
existing qubes carrying the `seqs-managed` feature; it never imports arbitrary
policy text or allow rules. To deliberately forget a preserved entry, add its
base name to `browser_suppress_prune`, for example:

```jinja
{%- set browser_suppress_prune = ['old-wallet'] %}
```

A qube that is still configured with `offline` or `no_handoff` remains denied
even if named in the prune list. Remove that flag as well when intentionally
re-enabling browser handoff.

`delete-vms.sh <name>` removes the exact `A-<name>` browser deny immediately
after the app qube is gone, without running a full build. It updates only a
policy carrying the `Managed by SEQS` marker; an unmarked policy is left
unchanged with a warning for manual review.

## Secure QR USB modes

`webcam_usb_mode` is `disabled` by default. After completing the qualification
test in [secure QR transfer](secure-qr-transfer.md#start-here-determine-which-path-the-machine-qualifies-for),
select `dedicated` for a webcam-only physical controller or `sequential` for
the reduced-assurance shared-controller ceremony. Both require a verified
physical `webcam_usb_controller` BDF. Sequential mode requires strict PCI reset
and intentionally powers off rather than restoring normal USB input in place.

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
`qubes.OpenURL * @anyvm A-brave allow`. If you remove `brave` from `qube_catalog`,
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
