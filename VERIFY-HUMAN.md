# Verifying SEQS — human walkthrough

Companion to [TRUST.md](TRUST.md). This document walks you through verifying — *before* you trust the resulting qubes with anything valuable — that what SEQS installs matches what TRUST.md claims. Steps are ordered for a typical first-time setup; do them once when you first install, plus the maintenance section whenever upstreams rotate keys.

> **Do not trust this verification guide merely because it is in the repository.**
> A malicious or mistaken repository can alter `VERIFY-HUMAN.md` at the same
> time as the code, omit the dangerous files, misdescribe behavior, or provide
> checks designed to approve its own changes. This document is only a
> convenience checklist for navigating the review. Verify every claim against
> the actual runner, Salt states, pillar, component scripts, upstream primary
> sources, and an independently obtained expectation of what the revision
> should contain. Treat contradictions or unexplained omissions as a stop.

## 1. Trust assumptions you cannot verify from here

Four things must be true *before* SEQS does anything useful — none of them provable from inside this repo:

- **The published commit hash.** The hash a user compares against must come from a source they trust, through a channel independent of this repository and its hosting — the repo cannot designate its own trusted source, since a hostile revision would name a hostile one. Establishing that source is out of scope of this repository. If you are working through this document, you are becoming that source: review the revision, then publish the hash you reviewed through a channel your users can authenticate.
- **The QubesOS installation.** The whole TCB rests on this. Download from <https://www.qubes-os.org/downloads/>, then verify the ISO's signature as [Install Qubes OS](docs/install-qubes.md) describes. If you skipped this step, every line below provides false comfort.
- **Your dom0.** A fresh install you booted yourself.
- **`REPO_VM`.** This qube serves the Salt tree into dom0, where it eventually runs as root. For first installation, use a fresh networked DisposableVM as described in `docs/first-install.md`, keep it alive only until the fetch is done, then destroy it. Independently verify and check out the intended revision before bootstrap, and review `/var/lib/seqs/fetched` before staging and building. Fetch automatically resolves and records the source qube's `HEAD`; commit-object export excludes working-tree drift but dom0 does not independently compare that answer to the reviewed ID and cannot make a malicious source qube honest.

## 2. Read what you'll run

Read top-to-bottom, in this order:

1. **`setup-qubes.sh`** — the thin dom0 runner: source selection, terminal sanitization, validated fetch, staging and completion markers, Salt failure detection, policy takeover, air-gap verification, and the dom0 panel launchers it adds.
   **`delete-vms.sh`**, the deletion helper, also runs in dom0; read it before you use it.
2. **`salt/pillar/seqs/config.sls`** — the reviewed catalogue: prefixes, base template, `browser_vm`, `qube_catalog` (names, labels, components, `offline`/`no_handoff`/`network_provider`/`audio_provider` flags), `brave_extensions`, `cleanup_dirs`, and per-minion slicing. Ordinary selection must not require editing this file; verify that `setup-qubes.sh --qubes` supplies names separately and that each qube receives only its own pillar slice.
3. **`salt/seqs/dom0.sls`** — the pre-flight validation block (everything is checked before anything is changed), all generated qrexec policy states (including QR containment when enabled), the no-clobber guard (`seqs-managed` feature + intent markers), qube creation, and the targets file. It installs the two scripts in **`salt/seqs/files/`** into dom0: `seqs-vpn-monitor`, installed while the catalogue has a GnosisVPN entry and run by the dom0 panel every two seconds for each built GnosisVPN qube, and `qr-sequential.sh`, the QR ceremony of sequential webcam mode, installed only in that mode. With `nuc11_headset_fix`, it also writes two static files, no code: `/lib/firmware/seqs-nuc11-headset.fw` and `/etc/modprobe.d/seqs-nuc11-headset.conf`.
4. **`salt/seqs/qube.sls`** — per-qube provisioning: component staging on tmpfs with the libs overlaid *after* component files, completion markers under `/rw/config/seqs/`, the browser handler, the cleanup service, the xdg default-browser step.
5. **`install-scripts/lib/brave.sh`** — Brave install + keyring verification logic + `install_brave_extension`. Also adds the apt-`preferences.d` pin that locks the Brave repo to the brave-browser packages and `brave-keyring`, which is then held at its installed version.
6. **`install-scripts/lib/verify-gpg.sh`** — shared `verify_detached_sig` helper, which `fetch_signed` runs after it checks the pinned SHA-256, for keepass / bitbox / openoffice / gnosisvpn. Requires both `GOODSIG` and `VALIDSIG <pinned_fpr>` and explicitly rejects `BADSIG / ERRSIG / EXP*SIG / REV*SIG / KEYEXPIRED / KEYREVOKED / NO_PUBKEY`. If this helper is wrong, all four signed installers are wrong.
7. **`install-scripts/components/*/template-vm.sh`** and `*/app-vm.sh` — every component you'll actually use. For Brave / Docker / VS Code / Signal / Element / GnosisVPN / Proton VPN specifically, verify the script also installs an `/etc/apt/preferences.d/<repo>.pref` default-denying the origin and re-allowing only the named package set — without this, a compromise of the upstream signing key could ship higher-version `bash` / `libc6` / `systemd` etc. via that repo.
8. **`TRUST.md`** — the trust model you are signing up for. Note especially §3 "Brave wallet extensions ⚠️", §4 "Wallet qube egress is unrestricted ⚠️", §4 "USB-keyboard policy override" and the Trezor-specific note under §4 "Hardware-wallet udev rules ⚠️" — these are deferred-acceptance items, not closed gaps.
9. **`README.md` and `docs/first-install.md`** — sanity-check the documented
   command path matches the code.

The README's first install is one invocation, `--repo-vm <VM> --qubes ...`, which fetches, stages, and builds after one confirmation. To review in dom0 what was fetched before anything is staged, split it: run `--repo-vm <VM> --fetch-only`, review `/var/lib/seqs/fetched`, confirm `source-commit` contains the ID previously verified in the repository qube, run `--stage-only`, and finally run `--build-only --qubes ...` or explicit `--all`. Repository edits are needed only for intentional advanced definition or hardware changes.

The README warning is in earnest: you are running these scripts in dom0.

### Using an LLM to assist the review

If you use an LLM, task it with the same job this document gives you: read the
entire tree adversarially and report what the code actually does, especially
where that differs from what TRUST.md claims. Two rules keep the result
meaningful:

- **The instructions driving the LLM must originate outside the tree under
  audit.** Never have it execute a checklist, script, or verification protocol
  shipped inside the repository it is auditing — a hostile revision can rewrite
  the code and its own verification instructions in the same commit. (That is
  why this repository ships no machine-runnable verification protocol, and the
  warning at the top of this document applies to this file too.)
- **Treat its output as pointers for your own reading, not as a verdict.** An
  all-clear from an LLM is not evidence you can publish a hash on; a finding it
  raises is a place to start reading.

## 3. Cross-check the verified components' keys

For each ✅ component below, SEQS embeds a signing key + a pinned fingerprint (Brave: pins only the fingerprints and checks the downloaded keyring against them), and at install time refuses to proceed unless the embedded key matches the pin AND, for a signed download, the file verifies against that key; for an apt repository, apt then checks each package against it. Re-do the cross-check yourself, ideally from a Linux machine separate from dom0, with `curl` + `gpg` available. The fingerprints you compute must match the pinned values:

| Component | Pinned fingerprint(s) | Quick check |
|---|---|---|
| Brave | `DBF1A116C220B8C7164F98230686B78420038257`<br>`47D32A74E9A9E013A4B4926C68D513D36A73CD96`<br>`B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0` | `curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \| gpg --show-keys --with-colons \| awk -F: '$1=="fpr"{print $10}'` then compare against <https://brave.com/signing-keys/> (Linux Package Repositories — Release Channel) |
| KeePassXC | `BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2` | `curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2 \| gpg --show-keys` then confirm against <https://keepassxc.org/verifying-signatures/> |
| Signal | `DBA36B5181D0C816F630E889D980A17457F6FB06` | `curl -fsSL https://updates.signal.org/desktop/apt/keys.asc \| gpg --show-keys`; also check `https://keys.openpgp.org/vks/v1/by-fingerprint/DBA36B5181D0C816F630E889D980A17457F6FB06` matches |
| Docker | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` | `curl -fsSL https://download.docker.com/linux/debian/gpg \| gpg --show-keys` then check `keyserver.ubuntu.com` and `keys.openpgp.org` by-fingerprint |
| Microsoft (VS Code) | `BC528686B50D79E339D3721CEB3E94ADBE1229CF` | `curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \| gpg --show-keys` |
| BitBoxApp (ShiftCrypto) | `DD09E41309750EBFAE0DEF63509249B068D215AE` | `curl -fsSL https://bitbox.swiss/download/shiftcryptosec-509249B068D215AE.gpg.asc \| gpg --show-keys`; BitBox's own docs publish the fingerprint at <https://support.bitbox.swiss/en_US/verify-app-signature/verify-bitboxapp-signature-linux> |
| Apache OpenOffice (Jim Jagielski) | `A93D62ECC3C8EA12DB220EC934EA76E6791485A8` | `curl -fsSL https://downloads.apache.org/openoffice/KEYS \| gpg --show-keys --with-colons \| grep A93D62EC`; also check `https://people.apache.org/keys/committer/jim.asc` |
| Element | `12D4CD600C2240A9F4A82071D7B0B66941D01538` | `curl -fsSL https://packages.element.io/debian/element-io-archive-keyring.gpg \| gpg --show-keys` then check both keyservers by-fingerprint |
| Proton VPN | `84B0D3492C76C9C6F5873C18EDA3E22630349F1C` | `curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/84B0D3492C76C9C6F5873C18EDA3E22630349F1C \| gpg --show-keys`; also download `protonvpn-stable-release_1.0.8_all.deb` as <https://protonvpn.com/support/official-linux-vpn-debian> describes, compare its `sha256sum` with the hash published there, and run `gpg --show-keys` on `usr/share/keyrings/protonvpn-stable-archive-keyring.gpg` inside it (`dpkg-deb -x`) |
| GnosisVPN | `9A308031FD3BFE8EDBF5076D84F73FEA46D10972`, and SHA-256 `87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb` for `gnosisvpn_0.95.2_amd64.deb` | `gpg --show-keys install-scripts/components/gnosisvpn/gnosisvpn-public-key.asc`, and `curl -fsSL https://download.vpn.gnosis.eth.limo/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.95.2_amd64.deb \| sha256sum`; the key comes only from the GnosisVPN project, so confirm the fingerprint through a channel of your own |
| Ledger Live (ECDSA, not OpenPGP) | the `LEDGER_PUBKEY` block and `LEDGER_SHA512` in `install-scripts/components/ledger/template-vm.sh` | compare the key with `apps/ledger-live-desktop/src/main/updater/ledger-pubkey.ts` in <https://github.com/LedgerHQ/ledger-live>; then, with the key saved as `ledger.pem` and `F=ledger-live-desktop-4.24.1.sha512sum`, `curl -fsSL --remote-name-all https://resources.live.ledger.app/public_resources/signatures/$F{,.sig}` and `openssl dgst -sha256 -verify ledger.pem -signature $F.sig $F` must print `Verified OK`, and `$F` must list `LEDGER_SHA512` for the AppImage |

KeePassXC, BitBox, and OpenOffice also pin the SHA-256 of their release file (`*_SHA256` in the script); after you have checked a download's signature yourself, compare its `sha256sum` with the pin.

Each component's `template-vm.sh` header (Brave: `install-scripts/lib/brave.sh`) also documents the three sources it was cross-checked against and the verification date — read it. GnosisVPN's names only the project itself, so its key needs your own cross-check (see its row).

## 4. Watch the install

When you run `setup-qubes.sh`:

1. **Fetch and stage.** The integrity anchor is the **git commit hash** you verified in the disposable (`git rev-parse HEAD` against the value you publish/trust) — it covers the whole repository, including `setup-qubes.sh`. Copy the runner with `git show HEAD:setup-qubes.sh`. Fetch resolves that same checkout's `HEAD`, validates the returned full object-ID shape, and archives that exact object rather than the live working tree. It records the source-reported ID in `/var/lib/seqs/fetched/source-commit`, saves a validated tree there, and prints a `Transfer SHA256` of the tar stream. Dom0 does not independently compare the ID to the value you reviewed, and neither the transfer hash nor Git makes a compromised source qube honest. Review the tree before `--stage-only`; staging shows the diff that will be placed under `/srv`, and re-running `--stage-only` reports whether the staged tree is identical to the fetched one.

   At build time, confirm `Staged tree SHA256`, `Build-plan SHA256`, and
   `Requested qubes` match your intent. Reordering the same names must produce
   the same canonical selection and plan hash; changing the selection must not
   change the staged-tree hash.

2. **The pre-flight validation** runs inside `qubesctl state.apply seqs.dom0` and checks everything before anything is changed: base template exists, `browser_vm` resolves, every component directory exists, extension IDs are well-formed, no duplicate qube names, cleanup paths are in-bounds, prefixes match the `.top` globs, and no same-named qube exists that SEQS didn't create. A failure shows as `seqs-validation-failed` with the reasons in its comment — *no* qubes are built before this passes.

3. **Policy-takeover prompt.** If any SEQS-owned qrexec policy file under `/etc/qubes/policy.d/` (`00-seqs-qr-input-deny`, `01-seqs-qr-filecopy`, `28-browser-suppress`, `29-browser`, `50-seqs-audiovm`, or, on Qubes 4.3 with `sys-usb` whose `50-config-input.policy` neither allows nor asks for the USB keyboard and `usb_keyboard_prompt` left at `True`, `30-user-input`) exists without `# Managed by SEQS` as its first line — e.g. hand-edited or from another tool — the runner prints its full contents and **blocks** on:

   `Overwrite the file(s) above? [y/N]`

   Read the dump. Type `y` (or `Y`) only when replacement is intended; Enter
   and every other response abort. If a hand-tightened rule (e.g.
   `qubes.InputKeyboard` pinned to a specific keyboard qube, or `qubes.OpenURL`
   using `ask` instead of `allow`) is about to be clobbered, accept the default
   no. No state is applied before this gate; SEQS-written policies re-converge
   silently on re-runs, which is expected.

4. **Air-gap verification.** After the dom0 state you should see `Air gap verified: no netvm and no default disposable on <every selected offline app qube and named disposable>.` — the runner refuses to provision anything if an `offline` qube still has a netvm or a default disposable (`default_dispvm`), which a qube can start without a prompt through `qubes.OpenInVM` and similar services; unsetting it is the primary control. For `no_handoff` and `firewall` qubes, `No default disposable verified on <qubes>.` reports the same check of `default_dispvm` alone. `/etc/qubes/policy.d/28-browser-suppress.policy` must contain, for the source `@tag:seqs-no-handoff`, denies to `@anyvm` for `qubes.OpenURL`, `qubes.OpenInVM`, `qubes.StartApp`, `qubes.GetImageRGBA`, `qubes.VMShell`, `qubes.VMExec`, `qubes.VMExecGUI`, and `qubes.PdfConvert`.

5. To see each qube's own output, add `--verbose` to the setup command; then watch for the verification lines:
    - `Brave keyring verified -- <the three pinned fingerprints>`
    - `key verified: <pinned fingerprint>` for each imported repository or signing key (KeePassXC, Signal, Docker, VS Code, Element, BitBox, OpenOffice, GnosisVPN, Proton VPN, and Brave next to its keyring line); compare it with the table above
    - `sha256 OK -- <file>`, then `signature OK -- <file> signed by <pinned fingerprint>`, for each signed download, such as `KeePassXC-2.7.12-x86_64.AppImage`, `bitbox_4.51.0_amd64.deb`, the OpenOffice archive, and the GnosisVPN package; for Ledger Live, `Verified OK` and then `sha512 and Ledger signature OK -- <AppImage>`
    - `installing extension <id>` for each `brave-extension-*`

6. Watch for verifier-rejection diagnostics. If `verify_detached_sig` ever fails, `--verbose` output shows **one** of the following root-cause lines before that component's state fails (when gpg names several problems, the line names the last one it reported), followed by `ERROR: <file> signature verification FAILED (gpg exit N, pin: ...)`; that ERROR line alone means gpg failed without naming a cause:
    - `rejected: gpg emitted BADSIG`         — the signature math failed; the artifact does not match the signature.
    - `rejected: gpg emitted ERRSIG` / `NO_PUBKEY` — gpg could not verify, for example because the file is signed by a key other than the pinned one: most likely upstream rotated keys, or a substitution.
    - `rejected: gpg emitted EXPSIG`         — the signature itself has expired (signature expiration time in the past).
    - `rejected: gpg emitted EXPKEYSIG`      — the key used to sign has expired.
    - `rejected: gpg emitted REVKEYSIG`      — the signing key has been **revoked** by its owner. **Treat this as alarm-level.**
    - `rejected: gpg emitted KEYEXPIRED` / `KEYREVOKED` — corresponding key-state issues.
    - `rejected: no GOODSIG in gpg output (expired/revoked key, or no signature)` — the positive marker is absent.
    - `rejected: no VALIDSIG with primary-key fingerprint <pin>` — signed by a key other than the pin that gpg could verify; not expected, as the verifying keyring holds only the pinned key.

   A file with a valid signature but another SHA-256 than the pinned one fails with `ERROR: <file> does not have the pinned SHA-256` instead: a different release than the one reviewed.

   None of these are "rerun and hope." Each requires either a re-verify-from-three-sources of the new upstream key (§6) before bumping the pin, or treating the artifact as untrusted.

7. Any `Result: False` in the salt output, any non-zero `Failed:` summary, or any `<qube>: ERROR` line is a hard stop — the runner reports these as failures even when `qubesctl`'s exit code doesn't, prints the last error lines from that qube's log, and skips the app qubes of a failed template. Don't keep going assuming the qube will work — read the failed state's comment and fix it, then re-run (re-runs converge; a finished component is skipped while its `/rw/config/seqs` marker matches the hash of its staged files).

## 5. Spot-check the result

After install:

- `qvm-ls` shows the expected templates (`Z-*`) and app qubes (`A-*`). Pay attention to labels (they encode the trust taxonomy in `config.sls`): `A-keepass` should be `black`, `A-wallet-ledger`/`A-wallet-trezor` `gray`, `A-dev-full` `orange`, browsers/chat `red`/`green`, etc.
- `qvm-prefs A-keepass | grep -E '^(netvm|default_dispvm) '` should show `-` and then `None` on both lines (the offline qube; a `D` instead of `-` means the none is only inherited from a global default) — the runner already verified this before provisioning, but check it yourself.
- `qvm-prefs sys-usb memory` should print at least the configured `sys_usb_memory` (600 by default) unless that is `0`.
- `ls /lib/firmware/seqs-nuc11-headset.fw /etc/modprobe.d/seqs-nuc11-headset.conf` in dom0 should list both files if `nuc11_headset_fix` is `True` and report both missing otherwise.
- If using WireGuard, `qvm-prefs A-wireguard provides_network` should print
  `True`; `/usr/bin/seqs-wireguard-import` and `~/WireGuard` should exist in
  `A-wireguard`; importing a copy of the configuration with an added
  `PostUp = true` line must fail with `only the keys ... are accepted`; after
  importing the configuration, `sudo wg show` inside
  `A-wireguard` should report a recent handshake. Attach a test qube, confirm
  its public IP is the VPN's, then run
  `sudo wg-quick down /run/seqs-wireguard/wg0.conf` and confirm the test qube
  loses both IP and DNS connectivity (fail closed) before bringing the tunnel
  back with `sudo /rw/config/seqs-wireguard/boot.sh`.
  The test qube's `/etc/resolv.conf` should remain Qubes-managed with
  `10.139.1.1` and `10.139.1.2`; inside `A-wireguard`,
  `sudo nft list chain ip qubes dnat-dns` should translate those addresses to
  the DNS selected by the WireGuard configuration. Import and boot output
  should contain no `resolvconf` warning. Inside `A-wireguard`,
  `sudo nft list chain ip qubes seqs-wireguard-dns-output` should show the
  equivalent output-hook translations, and both `getent hosts example.com`
  there and in the test client should succeed.
- If using GnosisVPN, `qvm-prefs A-gnosisvpn provides_network` should print
  `True`; `openresolv`, `wireguard-tools`, and the pinned GnosisVPN package
  should be installed in `Z-gnosisvpn`. Confirm
  `/etc/qubes/policy.d/20-seqs-gnosisvpn-updates.policy` and
  `seqs-gnosisvpn-update-proxy` no longer exist after provisioning. After a
  GnosisVPN connection, `/etc/resolv.conf` should remain Qubes-managed and
  `sudo nft list table ip seqs_gnosisvpn_dns` should show provider-DNS
  translations with increasing counters. If
  `/run/resolvconf/interfaces/wg0_gnosisvpn` is absent, confirm the table uses
  the documented `1.1.1.1`/`8.8.8.8` fallback. Confirm DNS crosses
  `wg0_gnosisvpn`, not `eth0`, and confirm an attached disposable test client
  loses both DNS and IP connectivity no later than five seconds after the VPN
  disconnects.
- If using GnosisVPN, `/rw/config/seqs-gnosisvpn-exit` in `A-gnosisvpn` should hold the exit you chose (`Netherlands` by default), and after a start `journalctl -b -u seqs-gnosisvpn-autoconnect` there should show the worker start and the connect to it.
- If using `anon`, `qvm-prefs A-anon netvm` should print `A-gnosisvpn`, and `qvm-prefs D-anon | grep -E '^(netvm|default_dispvm) '` should show the flag `-` on both lines, then `A-gnosisvpn` and `None`. With GnosisVPN disconnected (`gnosis_vpn-ctl disconnect` in `A-gnosisvpn`), `curl https://ifconfig.co` in a terminal of `D-anon` should fail.
- If using Proton VPN, `qvm-prefs A-protonvpn provides_network` should print `True` and `qvm-service A-protonvpn network-manager` `on`; `/rw/config/qubes-firewall-user-script` in `A-protonvpn` should start with `#!` and list `/rw/config/seqs-protonvpn-firewall.sh`. With Proton VPN disconnected, a client qube using `A-protonvpn` should reach nothing.
- If using the Bluetooth audio qube, `qvm-service A-bluetooth audiovm` should print `on` and `qvm-prefs A-bluetooth audiovm` nothing (no audio qube of its own). Every rule in `/etc/qubes/policy.d/50-seqs-audiovm.policy` should name `A-bluetooth` as its source and allow only `admin.Events`, `admin.vm.CurrentState`, and `admin.vm.List` (targets: itself, `@adminvm`, `@tag:audiovm-A-bluetooth`) and reading the properties `audiovm`, `xid`, `stubdom_xid`, `virt_mode`, `is_preload` and the features `audio`, `audio-model` (target: `@tag:audiovm-A-bluetooth`).
- For each wallet qube: `qvm-prefs A-wallet-ledger label` shows `gray`, `qvm-prefs A-wallet-ledger template` shows `Z-wallet-ledger`.
- `qvm-tags A-keepass list` includes `seqs-no-handoff`, as for every `offline`, `no_handoff`, or `firewall` app qube; `qvm-tags A-signal list` shows `seqs-handoff` instead, and `/etc/qubes/policy.d/29-browser.policy` allows `qubes.OpenURL` only from `@tag:seqs-handoff`.
- `qvm-features A-keepass seqs-managed` prints `1` for every SEQS-built qube (the no-clobber marker), and `/var/lib/seqs/intents/` in dom0 is empty after a clean run.
- If QR webcam mode is enabled, `qvm-pci list --assignments` must show the reviewed controller assigned only to `sys-usb-webcam` in dedicated mode, or to both `sys-usb` and `sys-usb-webcam` in sequential mode. `qvm-pci list sys-usb` must show the selected controller before a sequential build. Do not use `qvm-prefs ... pcidevs`; PCI ownership is exposed through `qvm-pci`, not a VM preference.
- If QR webcam mode is enabled, `/etc/qubes/policy.d/00-seqs-qr-input-deny.policy` must deny, from `sys-usb-webcam` and `seqs-qr-scanner`, `qubes.InputKeyboard`, `qubes.InputMouse`, and `qubes.InputTablet` to `@adminvm`, and `qubes.OpenURL`, `qubes.OpenInVM`, and the disposable services listed under air-gap verification to `@anyvm`; and `qubes.Filecopy` from `sys-usb-webcam` to `@anyvm`, in either mode; and `seqs-qr-scanner` must exist with no netvm and no default disposable.
- If QR webcam mode is `dedicated`, confirm from the recorded lookups in `docs/secure-qr-transfer.md` that the webcam socket is not split (a USB 2 and a verified USB 3 test device reach the same controller), and that `qvm-usb` lists the webcam under `sys-usb-webcam` as a single device, with nothing else there except internal devices recorded for that controller, none of them a radio such as Bluetooth. If QR webcam mode is `sequential`, confirm that, with every external USB device unplugged and the selected controller's internal devices switched off in firmware, the `sleep 20; qvm-usb` check lists no device on that controller, and that `webcam_usb_no_strict_reset` is `True` only if that document's `reset_method` check found no reset method for the controller; this rule is documented, not enforced. SEQS refuses `True` in dedicated mode. Before each sequential scan, the script lists the devices in `sys-usb`; only the USB keyboard and mouse, and internal devices recorded on another controller, may appear.
- Before using QR transfer with a real secret, rehearse with disposable test data and confirm the trusted source and target independently display the same four groups of five ciphertext-fingerprint characters before GnuPG runs. The passphrase must be the only value written on paper; the expected fingerprint must not travel through the QR channel.
- Open each app and confirm it actually launches. Versions in About dialogs match what's pinned in TRUST.md / the scripts.
- In a terminal of any non-browser qube that is neither offline nor `no_handoff` (such as `A-signal`), run `qvm-open-in-vm A-brave https://example.com`, or click an http(s) link inside the qube; it should open in `A-brave`.
- Reboot any app qube other than `A-qr-staging`, which keeps its incoming files; afterwards `~/QubesIncoming` should be gone entirely and `~/Downloads` should still exist but be empty (the boot/shutdown cleanup service — `folder:` removes the directory, `contents:` empties it but keeps it). Confirm `/usr/sbin/seqs-cleanup` exists in the app qube (not just the template) and `systemctl status seqs-cleanup` is not failed.

## 6. Ongoing maintenance

- **Key rotations**: when an upstream rotates its signing key, the install fails by design (fingerprint mismatch, or one of the `verify_detached_sig` "rejected: gpg emitted ERRSIG" / "NO_PUBKEY" lines from §4 step 6). Re-verify the new key against three independent sources (see TRUST.md for the pattern), then update the pin and the embedded key block in the component script. Don't bypass the check.
- **`brave_extensions`** (in `salt/pillar/seqs/config.sls`): periodically prune. Remove abandoned/discontinued wallet extensions; review the maintained status of those that remain.
- **Re-running `setup-qubes.sh`**: every build again requires `--qubes ...` or explicit `--all`; the previous selection is audit history, never an implicit default. Re-runs generally **converge** — selected SEQS-built qubes are reported and reconfigured in place, a finished component is skipped while its `/rw/config/seqs` marker matches the SHA-256 of its staged files and runs again after any change to them, unselected managed qubes are untouched, and qubes SEQS did not build are refused. GnosisVPN converges like every other qube; check that a pin change actually installed the new release. `--postfix NAME` applies one validated postfix to every selected recipe and creates a separate managed instance. For every GnosisVPN build, confirm every temporary `qubes.UpdatesProxy` allow/deny pair names its exact selected template instance and that the policy and proxy are removed afterward. Use `delete-vms.sh <instance-name>` ([Deleting SEQS qubes](docs/deleting-vms.md)) only when you intentionally want to rebuild an instance from scratch. The policy-takeover `[y/N]` prompt only fires for policy files SEQS does not own — if it fires on a re-run, read the dump.
- **`base_template`** (in `config.sls`): when you upgrade to a newer Qubes / Debian template, change the value and re-run; note a changed base only affects templates cloned from then on — existing `Z-*` stay on the old base until deleted and rebuilt.
- **Wallet-qube egress hardening (operator follow-up)**: by default `A-wallet-*` reach any internet host. If you know your RPC endpoints (and the block-explorer / `clients2.google.com` / etc. you actually depend on), set the `firewall` catalogue key ([configuration](docs/configuration.md)) or apply a `qvm-firewall` default-deny + explicit allow-list to each wallet qube — see TRUST.md §4 "Wallet qube egress is unrestricted ⚠️". This is the single hardening with the biggest blast-radius reduction on a wallet-extension supply-chain compromise.

## 7. Honest residual risk

What this whole pipeline does **not** verify:

- That Brave / Signal / KeePassXC / Element / BitBox / etc. (the upstreams) build clean binaries from clean source. The pin proves you got *their* key; it does not vouch for what they sign. The apt-`preferences.d` pins narrow this to "they can sign the *named* package set" but a hostile build of *those* packages still gets through.
- That `REPO_VM` hasn't been tampered with between repo checkout and install.
- That dom0 hasn't been tampered with.
- That **pyenv**, **nvm**, **Claude Code**, the snap-installed **Telegram**, or the Brave **wallet extensions** match anything beyond what their upstream (and, for Telegram, Canonical's snap assertion chain) chose to publish. See `TRUST.md` §3 for the per-component trust level.
- That a hostile **wallet extension** update, once on the wallet qube, is contained by network rules. By default the wallet qubes have no `qvm-firewall` allow-list — see §6 above and TRUST.md §4 "Wallet qube egress is unrestricted ⚠️".
- That a `trezor` qube can independently cross-check a transaction outside the browser-extension UX — SEQS does **not** install Trezor Suite. The hardware-wallet on-device confirmation screen is the *only* non-extension source of truth in that qube.

The `❌` and `⚠️` items in TRUST.md are not bugs — they are honest descriptions of trust gaps inherent to those upstreams (or to operator-specific tradeoffs SEQS does not unilaterally make). Treat the qubes that hold them as accordingly lower-trust domains.
