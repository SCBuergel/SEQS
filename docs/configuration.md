# Selecting what SEQS builds

The reviewed catalogue lives in `salt/pillar/seqs/config.sls` and is installed
unchanged under `/srv/pillar/seqs/config.sls`. Ordinary installation does not
require editing it. Select existing catalogue entries with a mandatory dom0
runner argument:

```bash
~/s.sh --build-only --qubes brave,signal,keepass
~/s.sh --build-only --all
```

To create an additional, independently named instance of every selected
catalogue recipe, add one postfix:

```bash
~/s.sh --build-only --qubes gnosisvpn,signal --postfix alpha
```

This creates `Z-gnosisvpn-alpha` / `A-gnosisvpn-alpha` and
`Z-signal-alpha` / `A-signal-alpha`. With `--all`, the postfix applies to the
entire catalogue. The postfix is part of the persistent instance name; use the
same command to converge that instance later.

Without `--postfix`, selecting an entry whose managed qubes already exist
reuses and reconciles them. SEQS prints an explicit existing-qube message,
never clones over them, and refuses a same-named qube it does not own. A
postfixed instance that already exists is handled identically.

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
brave  element  telegram  signal  wireguard  gnosisvpn  openoffice  xournalpp
usb-data-transfer  keepass  qr-display  qr-camera  qr-staging
claude-code  dev-full  wallet-ledger  wallet-trezor
```

Names are case-sensitive and must be passed without the generated `A-` or `Z-`
prefix. A postfix must also be a safe qube-name fragment; SEQS inserts the
separating `-`. A selection with a qube that hands links to the browser qube
needs `A-brave` too; see
[Browser-link handoff requires `A-brave`](#browser-link-handoff-requires-a-brave).

| Component | What it installs |
|---|---|
| `adb`          | Android Debug Bridge + `pv` (Debian apt) + chunked, resumable `/usr/bin/adb-pull` helper |
| `brave`        | Brave browser (apt repo, embedded verified key); asks once per qube for a keyring password, which may be empty |
| `bitbox`       | BitBoxApp `.deb` (GPG-verified) |
| `claude-code`  | Claude Code (native installer) |
| `docker`       | Docker engine + persistent `/var/lib/docker` bind-dir |
| `element`      | Element chat (apt repo) |
| `gnosisvpn`    | Pinned, signed GnosisVPN stable release for `jura-prod`, persistent `/var/lib/gnosisvpn`, and dynamic Qubes DNS/fail-closed hooks |
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
| `wireguard`    | WireGuard tools and persistent, fail-closed NetVM hooks (Debian apt) |
| `xournalpp`    | Xournal++ (Debian package) |

## `qube_catalog` flags

Each entry is `{'name': ..., 'label': ..., 'components': [...]}` plus optional
flags:

- `'offline': True` — detaches the app qube from netvm (air gap) and unsets its
  default disposable, which would otherwise have network access. Implies
  `no_handoff`, and the runner re-verifies both after the dom0 apply. Use for
  wallet/vault qubes.
- `'no_handoff': True` — the qube can neither hand links to the browser qube
  nor open files in another qube or start a disposable, which would be
  networked and so another way out; copy files with `qvm-copy` instead. SEQS
  leaves the qube's link handler unset, and dom0 tags the qube
  `seqs-no-handoff` and denies by that tag `qubes.OpenURL`, `qubes.OpenInVM`,
  and every other service that the Qubes default policy lets into a disposable
  without asking. Every build updates the tag on all SEQS qubes, selected or
  not, and disposables started from a tagged qube inherit it.
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
- `'network_provider': True` — enables `provides_network` and the
  `qubes-firewall` service on the app qube, allowing other qubes to select it
  as their NetVM. It cannot be combined with `offline` or `dispvm_template`.
- `'firewall': [...]` — an outbound allowlist for the app qube: each entry is a
  hostname or IPv4 address, `host:port` for one TCP port, `'dns'`, or `'icmp'`,
  and all other traffic is dropped. Hostname entries also need `'dns'`. A build
  that selects the qube restores the list if its rules were changed by hand;
  removing the key and rebuilding restores the Qubes default (allow all). It
  cannot be combined with `offline`. Because the allowlist does not restrict
  qrexec, it implies `no_handoff`, which closes link handoff and disposables.
- `'preserve_incoming': True` — skips the boot and shutdown cleanup of
  `cleanup_dirs` (by default `~/QubesIncoming` and `~/Downloads`). The shipped
  `qr-staging` entry uses it to hold a received file while the computer is off.

## WireGuard NetVM

The optional `wireguard` entry builds `A-wireguard`, a fail-closed
network-provider AppVM configured from a user-supplied WireGuard file. See
[Using the WireGuard NetVM](wireguard.md) for setup, verification,
troubleshooting, and a high-level explanation of its routing, DNS, persistence,
and firewall behavior.

## GnosisVPN NetVM preparation

The optional `gnosisvpn` entry builds `A-gnosisvpn`, installs Debian's
`wireguard-tools` and `openresolv`, installs the pinned GnosisVPN stable release for
the `jura-prod` network, and configures reconciled Qubes-aware DNS with
tunnel-routed fallback resolvers and fail-closed forwarding hooks. See
[Using the GnosisVPN NetVM](gnosisvpn.md) for the scoped download path,
verification, and runtime checks.

Duplicate names abort the pre-flight.

## Secure QR USB modes

`webcam_usb_mode` is `disabled` by default. After completing the qualification
test in [secure QR transfer](secure-qr-transfer.md#choose-the-hardware-isolation-path),
select `dedicated` for a webcam-only physical controller or `sequential` for
the reduced-assurance shared-controller ceremony. Both require a verified
physical `webcam_usb_controller` BDF. Set `webcam_usb_no_strict_reset` to
`True` only for a sequential-mode controller without a PCI reset method;
dedicated mode refuses it. Sequential mode intentionally powers off rather than
restoring normal USB input in place, so the controller returns to `sys-usb`
only after a cold boot.

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

The `seqs.dom0` state tags each SEQS qube without `offline`, `no_handoff`, or
`firewall` as `seqs-handoff`; the dom0 policy
`qubes.OpenURL * @tag:seqs-handoff A-brave allow` lets those open web links in
`browser_vm` (default `A-brave`) without a prompt. Other qubes keep the Qubes
default, which asks. Qubes with those flags never hand links off, so a run
that selects only such qubes (for example `keepass` or the wallets) does not
need the browser qube. For any other selected qube,
the pre-flight refuses a `browser_vm` that is neither selected in the same run
nor already existing. If you remove `brave` from `qube_catalog`, also change
`browser_vm` in `config.sls` to a browser qube you do have.

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
documentation stays coherent with the on-disk components.
