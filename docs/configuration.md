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
reuses and reconciles them. SEQS prints an existing-qube message for each template and app qube,
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

## Machine-wide settings

The top of `config.sls` sets values that apply to every qube:

| Setting | Default | Meaning |
| --- | --- | --- |
| `prefix_template`, `prefix_app`, `prefix_disposable` | `Z-`, `A-`, `D-` | Name prefixes of the templates, app qubes, and named disposables SEQS builds. The minion globs in `config.top` must match the first two; the pre-flight checks this. |
| `base_template` | `debian-13-xfce` | The template every SEQS template is cloned from. A change affects only templates cloned afterwards. |
| `browser_vm`, `browser_desktop` | `A-brave`, `open-links-in-browser-qube.desktop` | The qube that opens links handed off by other SEQS qubes, and the desktop entry in those qubes that hands them off; see [below](#browser-link-handoff-requires-a-brave). |
| `component_timeout` | `900` | Seconds one component may run before Salt stops it. |
| `webcam_*` | QR transfer disabled | See [Secure QR USB modes](#secure-qr-usb-modes). |

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
brave  element  telegram  signal  wireguard  gnosisvpn  protonvpn  anon
openoffice  xournalpp  usb-data-transfer  keepass  qr-display  qr-camera  qr-staging
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
| `brave`        | Brave browser (apt repo; the downloaded keyring must hold exactly the pinned fingerprints); asks once per qube for a keyring password, which may be empty |
| `bitbox`       | BitBoxApp `.deb` (GPG-verified) |
| `claude-code`  | Claude Code (native installer) |
| `docker`       | Docker engine + persistent `/var/lib/docker` bind-dir |
| `element`      | Element chat (apt repo) |
| `gnosisvpn`    | Pinned, signed GnosisVPN stable release for `jura-prod`, persistent `/var/lib/gnosisvpn`, and dynamic Qubes DNS/fail-closed hooks |
| `keepass`      | KeePassXC AppImage (GPG-verified) |
| `ledger`       | Ledger udev rules + Ledger Live |
| `node`         | Node.js via nvm |
| `openoffice`   | Apache OpenOffice tarball (GPG-verified) |
| `protonvpn`    | Proton VPN app (Proton's apt repository, embedded verified key) and a fail-closed NetVM hook |
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
flags; a duplicate name aborts the pre-flight. The label (window colour) is one
of red, orange, yellow, green, gray, blue, purple, or black. The flags:

- `'offline': True` — detaches the app qube from netvm (air gap) and unsets its
  default disposable, which would otherwise have network access. Implies
  `no_handoff`, and the runner re-verifies both after the dom0 apply. Use for
  wallet/vault qubes.
- `'no_handoff': True` — the qube can neither hand links to the browser qube
  nor open files in another qube or start a disposable, which would be
  networked and so another way out; copy files with `qvm-copy` instead. SEQS
  leaves the qube's link handler unset, and dom0 tags the qube
  `seqs-no-handoff` and denies by that tag, to every qube and disposable,
  `qubes.OpenURL`, `qubes.OpenInVM`, and the services that start a program in
  another qube or a disposable. Every build updates the tag on all SEQS app qubes and named
  disposables, selected or not, and disposables started from a tagged qube
  inherit it. A build that selects the qube also sets its default disposable
  to none, so a lost tag does not reopen that networked route.
- `'dispvm_template': True` — makes the app qube a DisposableVM template. The
  shipped offline `qr-display` and `qr-camera` entries use this flag; see
  [secure QR transfer](secure-qr-transfer.md). Every disposable template
  must also set `offline: True` or a `netvm` (enforced by pre-flight
  validation).
- `'named_disposable': True` — also creates a named DisposableVM (`D-<name>`,
  the `prefix_disposable`) from the `A-<name>` dispvm template, so the
  disposable is launchable from the Qubes menu rather than only appearing under
  "Templates". Requires `dispvm_template`; the shipped `qr-display` and `anon`
  entries use it. The named disposable gets the same NetVM as its template
  (none, or the `netvm` provider) and is reset on every shutdown, so nothing
  is provisioned inside it.
- `'network_provider': True` — enables `provides_network` and the
  `qubes-firewall` service on the app qube, allowing other qubes to select it
  as their NetVM. It cannot be combined with `offline` or `dispvm_template`.
- `'netvm': 'gnosisvpn'` — the app qube and its named disposable use the app
  qube of that catalogue entry (here `A-gnosisvpn`), which must set
  `network_provider`, as their NetVM. The provider must be selected in the
  same build or already built; a postfixed provider cannot be named. The
  shipped `anon` entry, a Brave disposable (`D-anon`), uses it. The runner
  re-verifies the NetVM after the dom0 apply. It cannot be combined with
  `offline` or `network_provider`.
- `'firewall': [...]` — an outbound allowlist for the app qube: each entry is a
  hostname or IPv4 address, `host:port` for one TCP port (1-65535), `'dns'`, or
  `'icmp'`, and all other traffic is dropped; the pre-flight refuses other
  ports and IPv4 octets above 255. Hostname entries also need `'dns'`, which
  allows lookups of any name, so DNS remains a channel out. Qubes enforces the
  rules in the qube's NetVM, which must run the `qubes-firewall` service
  (`sys-firewall` does); SEQS neither sets nor checks that NetVM. A build
  that selects the qube restores the list if its rules were changed by hand;
  removing the key and rebuilding restores the Qubes default (allow all). It
  cannot be combined with `offline`. Because the allowlist does not restrict
  qrexec, it implies `no_handoff`, which closes link handoff and disposables
  and clears the qube's default disposable.
- `'preserve_incoming': True` — skips the boot and shutdown cleanup of
  [`cleanup_dirs`](#cleanup_dirs). The shipped
  `qr-staging` entry uses it to hold a received file while the computer is off.
- `'main_app': 'signal-desktop.desktop'` — the desktop file of the app the
  qube is for, as the qube's template installs it under
  `/usr/share/applications`. It is added to the qube's Qubes menu, and starts
  first in the qube's [panel launcher](#panel-launchers).
- `'vcpus': 4` — the app qube's number of virtual CPUs (the Qubes default is
  2); the shipped `gnosisvpn` entry uses 4. A running qube changes at its next
  start, and removing the key keeps the count. It cannot be combined with
  `cpu_pinning`, which sets the count itself.
- `'cpu_pinning': {'cpus': [0, 2], 'weight': 512}` — gives the app qube one
  vCPU per listed CPU, pins them to those CPUs, and optionally
  raises its Xen scheduler weight (1-65535; the default is 256). dom0 writes
  `/etc/qubes/templates/libvirt/xen/by-name/A-<name>.xml`, a per-qube addition
  to the Xen configuration that Qubes applies at every start, so a running
  qube changes at its next start. CPU numbers are Xen's, 0 to `nr_cpus` - 1
  as `xl info` in dom0 shows; for a selected qube the pre-flight refuses
  others, and refuses to overwrite such a file that SEQS did not write. Removing the key deletes the
  file; the vCPU count stays.

Removing `offline`, `no_handoff`, `firewall`, `dispvm_template`, or
`network_provider` from a built qube does not revert the qube preferences
(`qvm-prefs`) these flags set: a NetVM or default disposable set to none stays none, and
`template_for_dispvms` or `provides_network` stays on (see
[convergence](architecture.md#convergence)).

## Panel launchers

A build adds one launcher to the dom0 XFCE panel for each app qube and named
disposable it builds, before the panel's first expanding separator. The
launcher's button starts the qube's `main_app` (without one, its terminal);
its arrow opens the qube's terminal and file manager. A disposable template gets none, because its
entries would run in the template instead of in a disposable. The build
needs to find a running XFCE panel of the user who runs it; otherwise it adds
no launchers and says so.

A rebuild refreshes the launcher's entries. A launcher removed from the panel
(right-click, **Remove**) stays removed; deleting the qube with
[`delete-vms.sh`](deleting-vms.md) removes its launcher too.

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

## Proton VPN NetVM

The optional `protonvpn` entry builds `A-protonvpn`, a fail-closed
network-provider AppVM running the official Proton VPN app. See
[Using the Proton VPN NetVM](protonvpn.md).

## Secure QR USB modes

`webcam_usb_mode` is `disabled` by default. After completing the qualification
test in [secure QR transfer](secure-qr-transfer.md#choose-the-hardware-isolation-path),
select `dedicated` for a webcam-only physical controller or `sequential` for
the reduced-assurance shared-controller ceremony. Both require a verified
physical `webcam_usb_controller` BDF. Set `webcam_usb_no_strict_reset` to
`True` only for a sequential-mode controller without a PCI reset method;
dedicated mode refuses it. Sequential mode intentionally powers off rather than
restoring normal USB input in place, so the controller returns to `sys-usb`
only after a cold boot. The other `webcam_*` settings name the qubes the
transfer creates or uses (`webcam_usb_qube`, `webcam_scanner_dvm`,
`webcam_scanner_qube`, `webcam_staging_qube`, `webcam_normal_usb_qube`);
change them only to avoid a clash with an existing qube.

## `brave_extensions`

Maps name → Chrome Web Store ID for each Brave wallet extension. Reference them
in qube specs as `brave-extension-<name>`; each such component installs or
updates Brave first.

- **Enable** an extension in a qube: add `brave-extension-<name>` to that qube's
  component list.
- **Add** a new extension (e.g. Ambire): add a `brave_extensions` line, then
  reference it as `brave-extension-ambire` in any wallet qube.
- **Retire** an extension entirely: remove every `brave-extension-<name>`
  reference, then its `brave_extensions` line. Templates already built keep it
  installed until you rebuild them.

## `cleanup_dirs`

Directories that app qubes and disposables delete at every boot and shutdown,
so downloads and received files do not accumulate; templates are never
cleaned. By default `~/QubesIncoming` is deleted (mode `folder`) and
`~/Downloads` is emptied (mode `contents`). A path must lie strictly under
`/home/user/`, use only `A-Z a-z 0-9 . _ / -`, and contain no `..`, `.`, or
empty segment; the pre-flight refuses others, because the cleanup runs
`rm -rf` as root.

## Browser-link handoff requires `A-brave`

The `seqs.dom0` state tags each SEQS qube without `offline`, `no_handoff`, or
`firewall` as `seqs-handoff`; the dom0 policy
`qubes.OpenURL * @tag:seqs-handoff A-brave allow` lets those open web links in
`browser_vm` (default `A-brave`) without a prompt. Other qubes keep the Qubes
default, which asks. Qubes with those flags never hand links off, so a run
that selects only such qubes (for example `keepass` or the wallets) does not
need the browser qube. For any other selected qube,
the pre-flight refuses a `browser_vm` that is neither selected in the same run
nor already existing. With `--postfix`, selecting `brave` builds
`A-brave-<postfix>`, which is not the browser qube, so the plain `A-brave` must
already exist. If you remove `brave` from `qube_catalog`, also change
`browser_vm` in `config.sls` to a browser qube you do have.

## Adding a new component

Create `install-scripts/components/<name>/` containing:

- an optional `template-vm.sh` — system-wide install in the template,
- an optional `app-vm.sh` — per-app-VM setup in `$HOME` / `/rw`,
- an optional `menu.desktop` — installed as
  `/usr/share/applications/<name>.desktop`.

The scripts run as `user` with `sudo` available, and each one is stopped after
`component_timeout` (900 seconds). A component runs again whenever its files or
the shared libraries in `install-scripts/lib/` change, so its scripts must be
safe to run twice.

Then reference `<name>` in any qube spec. If the component needs Brave, it can
`source "$(dirname "$0")/brave.sh"` and call `install_brave`.

After adding a component, also add it to the **Components** table above so the
documentation stays coherent with the on-disk components.
