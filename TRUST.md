# SEQS Trust Model

Companion to the [README](README.md). This document records, **per component**,
what you are implicitly trusting when you use the scripts in this repository,
how (or whether) that trust is verified, and the residual risk that remains.

QubesOS isolates qubes from one another. These scripts deliberately *cross* those
boundaries — copying code into dom0, installing software into templates, wiring
qubes together — so every crossing is a place where trust is extended. The point
of this file is to make each assumption explicit and reviewable.

State as of **2026-05-18**.

## Trust levels

| Level | Meaning |
|-------|---------|
| ✅ Verified | Integrity checked against a cryptographic pin or an independent reference. |
| 📝 Reviewed | No automated check; trust rests on you having read the committed file. |
| ⚠️ TOFU | Fetched over HTTPS; trust on first use — you trust TLS/CA + whoever answered, with no pin. Package-manager signatures apply *afterwards*. |
| ❌ Unverified | HTTPS transport only; no signature or checksum. Compromise of the host, CDN, mirror, or DNS means code execution. |

---

## 1. Trusted Computing Base

Trusted unconditionally — nothing in this repo can compensate if these are compromised.

### QubesOS + dom0
- **Trust assumption:** The hypervisor, dom0, and the qrexec/policy system enforce isolation correctly.
- **Established by:** The QubesOS project. Out of scope for this repo.
- **Residual risk:** A dom0 compromise is total. Note that `setup-qubes.sh` runs *in* dom0 — see §2.

### The QubesOS installation ISO
- **Trust assumption:** The ISO you installed from is genuine.
- **Established by:** ⚠️ Qubes publishes a detached signature and checksums, but the README only links the download page — it does **not** instruct you to verify the ISO. Verification is on you.
- **Residual risk:** A tampered ISO compromises everything from first boot.

### Qubes update proxy (`127.0.0.1:8082`)
- **Trust assumption:** The updates proxy and the sys-net/sys-firewall chain relay template downloads honestly.
- **Established by:** Qubes default configuration.
- **Residual risk:** It sees and routes all template `curl`/`apt` traffic. TLS still protects content end-to-end; a hostile proxy can block or attempt downgrades but not forge signed packages.

---

## 2. Bootstrap & installation

### The SEQS repository contents
- **Trust assumption:** Every script here does what it claims and nothing else.
- **Established by:** 📝 You. The README explicitly tells you to read every file first. The repo is not signed.
- **Residual risk:** Whoever can write to the repo (or the branch you pull) controls dom0 and every template. **Treat repo write-access as dom0-equivalent.**

### `REPO_VM` — the qube hosting the repo (default `personal`)
- **Trust assumption:** The qube the repo is fetched from is not compromised.
- **Established by:** 📝 Your choice of qube; configurable at the top of `setup-qubes.sh`.
- **Residual risk:** dom0 runs whatever this qube serves (see the cat hack below). A compromised `REPO_VM` = compromised dom0. A dedicated, minimal qube is preferable to a daily-driver.

### The dom0 "cat hack" copy
- **Trust assumption:** `qvm-run -p REPO_VM cat <file>` returns the genuine file.
- **Established by:** ❌ Nothing — a raw byte copy with no integrity check. This is the documented Qubes way to move files into dom0, and is exactly why review must happen *before* running anything.
- **Residual risk:** No tamper detection between `REPO_VM` and dom0; mitigated only by manual review and by `REPO_VM` being trusted.

### `setup-qubes.sh` (runs in dom0)
- **Trust assumption:** Orchestrates qube creation/templating correctly and runs only the intended install scripts.
- **Established by:** 📝 Reviewed.
- **Residual risk:** Runs with the dom0 user's privileges — `qvm-*` management of every qube, plus `sudo` to write the qrexec browser policy. It also fetches and moves install scripts and `lib/*.sh` into VMs.

### `install-scripts/*.sh` (run inside templates / app qubes)
- **Trust assumption:** Each install script is safe to run as root in its VM.
- **Established by:** 📝 Reviewed. They run via `qvm-run` and use **passwordless `sudo`** (full-template default) — i.e. root in that VM.
- **Residual risk:** A malicious or compromised install script owns that template and every app qube based on it.

### `lib/brave.sh` sourcing mechanism
- **Trust assumption:** The shared library moved next to each install script is the genuine one.
- **Established by:** 📝 Reviewed; fetched via the same cat hack as the scripts.
- **Residual risk:** Same as any install script — runs as root in the template.

---

## 3. Software sources

### Brave — apt repository & signing keys ✅
- **Trust assumption:** Brave's apt signing keys are genuine; thereafter apt trusts whatever Brave signs.
- **Established by:** ✅ `lib/brave.sh` downloads the keyring and **aborts unless it contains exactly the three pinned key fingerprints**:
  - `DBF1A116C220B8C7164F98230686B78420038257`
  - `47D32A74E9A9E013A4B4926C68D513D36A73CD96`
  - `B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0`

  The fingerprints were verified on **2026-05-18** by cross-checking three independent sources — forging the set would require compromising all three at once:

  1. The keyring served from the actual install source (the S3 apt bucket):
     <https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg>
  2. The same keys published as ASCII-armored PGP blocks on Brave's signing-keys page (a different host), under the heading "Linux Package Repositories — Release Channel":
     <https://brave.com/signing-keys/>
  3. Key `DBF1A116C220B8C7164F98230686B78420038257` independently hard-coded in an unrelated third-party project:
     <https://github.com/fphammerle/docker-brave-browser/blob/master/Dockerfile>

  See the `lib/brave.sh` header comment for the exact commands used.
- **Residual risk:** The pin only proves you got Brave's real keys; it does not vouch for what Brave builds and signs. The fingerprints were captured on **2026-05-18** — if Brave rotates keys the install fails by design and the pins must be re-verified against the links above.

### KeePassXC — AppImage with verified signature ✅
- **Trust assumption:** The KeePassXC AppImage really was built and released by the KeePassXC team.
- **Established by:** ✅ `install-scripts/components/keepass/template-vm.sh` embeds the KeePassXC release signing key, downloads the release's detached `.sig`, and **aborts unless `gpg --verify` confirms the AppImage is signed by that key** (primary fingerprint `BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2`). The fingerprint was verified on **2026-05-18** against `keepassxc.org/verifying-signatures/`, a keys.openpgp.org by-fingerprint lookup, and the Arch Linux `keepassxc` PKGBUILD — see the script header.
- **Residual risk:** The version (currently 2.7.12) is pinned in the script; an AppImage does not auto-update, so security fixes arrive only when the pin is bumped and the script re-run. The signing key is embedded in the repo, so it also inherits §2 repo trust.

### Signal — apt repository with an embedded, verified key ✅
- **Trust assumption:** Signal's apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/signal/template-vm.sh` embeds the Signal signing key and **aborts unless its fingerprint matches the pinned value** `DBA36B5181D0C816F630E889D980A17457F6FB06`. Signal publishes no fingerprint, so it was cross-checked on **2026-05-18** against the key served at `updates.signal.org`, a keys.openpgp.org by-fingerprint lookup, and Wayback Machine snapshots from 2018/2020/2022 (the same key for 8+ years) — see the script header.
- **Residual risk:** The pin proves you have Signal's real key; it does not vouch for what Signal builds and signs. The embedded key inherits §2 repo trust.

### Docker — apt repository with an embedded, verified key ✅
- **Trust assumption:** Docker's apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/docker/template-vm.sh` embeds the Docker signing key and **aborts unless its fingerprint matches the pinned value** `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. Verified on **2026-05-19** against `download.docker.com`, `keyserver.ubuntu.com` and `keys.openpgp.org` (and Wayback Machine snapshots from 2020/2023) — see the script header.
- **Residual risk:** docker-group membership granted to `user` is **equivalent to root inside the qube** — significant because dev qubes run untrusted build code. Images pulled at runtime are arbitrary code.

### Element — apt repository with an embedded, verified key ✅
- **Trust assumption:** The Element apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/element/template-vm.sh` embeds the Element signing key and **aborts unless its fingerprint matches the pinned value** `12D4CD600C2240A9F4A82071D7B0B66941D01538`. Verified on **2026-05-20** against the key served at `packages.element.io/debian/element-io-archive-keyring.gpg`, a `keyserver.ubuntu.com` by-fingerprint lookup, and a `keys.openpgp.org` by-fingerprint lookup; a Wayback Machine snapshot from 2023 carries the same fingerprint. uid is the historical "riot.im packages <packages@riot.im>" (Element's prior name). Element Desktop is not in the Debian repositories (verified 2026-05-20), so the upstream apt repo is the only mainstream channel; the install procedure matches the Brave/Signal/KeePass pattern.
- **Residual risk:** The pin proves you have Element's real key; it does not vouch for what Element builds and signs. The embedded key inherits §2 repo trust.

### VS Code — apt repository with an embedded, verified key ✅
- **Trust assumption:** The Microsoft signing key is genuine.
- **Established by:** ✅ `install-scripts/components/vscode/template-vm.sh` embeds the Microsoft signing key and **aborts unless its fingerprint matches the pinned value** `BC528686B50D79E339D3721CEB3E94ADBE1229CF`. Verified on **2026-05-19** against `packages.microsoft.com/keys/microsoft.asc`, `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header.
- **Residual risk:** VS Code extensions (the Marketplace) run with full user privileges — the real VS Code attack surface, beyond the package install.

### Telegram — snap
- **Trust assumption:** Canonical's snap store and the `telegram-desktop` publisher.
- **Established by:** ⚠️ snapd verifies Canonical-signed assertions; the snap content is the publisher's.
- **Residual risk:** Publisher or store compromise; the snap auto-updates.

### BitBoxApp — .deb with a verified signature ✅
- **Component:** `install-scripts/components/bitbox/template-vm.sh` — downloads the BitBoxApp `.deb` and its detached `.asc`.
- **Established by:** ✅ The script embeds the ShiftCrypto Security signing key and **aborts unless `gpg --verify` confirms the `.deb` is signed by it** (fingerprint `DD09E41309750EBFAE0DEF63509249B068D215AE`). Verified on **2026-05-19** against BitBox's own docs (which publish the fingerprint), `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header. Installed via `apt-get` so dependencies resolve. (Not in the default `WALLET_QUBES`; add `bitbox` to a wallet qube's component list to include it.)
- **Residual risk:** The pinned version (currently 4.51.0) is bumped manually. A crypto wallet — keep its qube isolated.

### Apache OpenOffice — tarball with a verified signature ✅
- **Component:** `install-scripts/components/openoffice/template-vm.sh` — downloads the Apache OpenOffice tarball and its detached `.asc` from `downloads.apache.org`.
- **Established by:** ✅ The script embeds Jim Jagielski's Apache OpenOffice release signing key and **aborts unless `gpg --verify` confirms the tarball is signed by it** (fingerprint `A93D62ECC3C8EA12DB220EC934EA76E6791485A8`). Verified on **2026-05-19** against the Apache OpenOffice `KEYS` file, the Apache committer keyring (`people.apache.org`) and `keyserver.ubuntu.com` — see the script header.
- **Residual risk:** The pinned version (currently 4.1.16) is bumped manually; Apache OpenOffice releases infrequently.

### Ledger Live ❌ — unverifiable
- **Component:** `install-scripts/components/ledger/app-vm.sh` — `curl -fsSL https://download.live.ledger.com/latest/linux`.
- **Trust assumption:** The AppImage served by Ledger at that URL is genuine.
- **Established by:** ❌ Nothing. Ledger does **not** publish a GPG signature for the Linux AppImage (only a SHA-512 on a JS-rendered download page), and the download URL is unversioned ("latest"), so the AppImage can be neither signature-verified nor version-pinned. `-f` is set so an HTTP error page is not saved as the AppImage, but the AppImage content itself is trusted on download.
- **Residual risk:** Whoever controls Ledger's download infrastructure or DNS can serve arbitrary code into the wallet qube. The Ledger udev rules in `install-scripts/components/ledger/template-vm.sh` are independent — the hardware device works regardless.

### pyenv (python component) ❌ — accepted tradeoff
- **Component:** `install-scripts/components/python/app-vm.sh` — `curl -fsSL https://pyenv.run | bash`.
- **Trust assumption:** Whatever `pyenv.run` serves at run time is benign.
- **Established by:** ❌ Unverified remote code piped to a shell. **This is a deliberate choice:** pyenv is kept, in preference to the apt `python3` package, for the flexibility of installing and switching Python versions — accepting the weaker trust. (`app-vm.sh` also lacks `set -euo pipefail`, kept off so pyenv's profile sourcing does not abort it.)
- **Residual risk:** Full control of the dev qube for whoever controls `pyenv.run` or its redirect target. `pip install` then pulls from PyPI (hash-checked, not signature-verified).

### Claude Code — native installer (claude-code component) ❌
- **Component:** `install-scripts/components/claude-code/app-vm.sh` — `curl -fsSL https://claude.ai/install.sh | bash`.
- **Trust assumption:** The installer script served by `claude.ai`, and the binary it fetches, are genuine.
- **Established by:** ❌ Unverified — remote code piped to a shell over HTTPS, no signature or checksum; Anthropic publishes no pinnable artifact for this path. `-f` only ensures an HTTP error page is not executed.
- **Residual risk:** Whoever controls `claude.ai/install.sh` or DNS runs code in the dev qube. Claude Code then self-updates, so the trust is ongoing — not just at install time.

### nvm + Node.js (node component) ❌ — accepted tradeoff
- **Component:** `install-scripts/components/node/app-vm.sh` — `curl -fsSL …/nvm/<pinned-tag>/install.sh | bash`.
- **Trust assumption:** The pinned nvm `install.sh` served by GitHub is benign.
- **Established by:** ❌ Unverified remote code piped to a shell, pinned to a specific nvm release. **This is a deliberate choice:** nvm is kept, in preference to the apt `nodejs` package, for the flexibility of installing and switching Node versions — accepting the weaker trust.
- **Residual risk:** Whoever controls that script (or the pinned tag) runs code in the dev qube. `npm install` then runs package lifecycle scripts — a large supply-chain surface.

### Brave wallet extensions ⚠️
- **Mechanism:** Each wallet qube's `WALLET_QUBES` spec lists extensions as `brave-extension-<name>` components; the composer looks `<name>` up in the `BRAVE_EXTENSIONS` array (name → Chrome Web Store ID) in `setup-qubes.sh`, ensures Brave is installed (idempotent `ensure_brave` in `lib/brave.sh`), and force-installs the extension via an `external_update_url` manifest. No per-extension component directory exists.
- **Trust assumption:** Google's Web Store distribution and each extension's publisher.
- **Established by:** ⚠️ Web Store hosting + publisher; extensions auto-update silently.
- **Residual risk:** A large surface — every installed wallet extension can read pages and prompt to sign in the browser. Abandoned extensions (Liquality, BlockWallet, Frame) have been removed; the `BRAVE_EXTENSIONS` list should be periodically pruned to maintained projects only. The default `WALLET_QUBES` builds two minimal wallet qubes (Ledger + Rabby, Trezor + Rabby) — much smaller blast radius than a single qube with every extension.

---

## 4. Runtime & inter-qube wiring

### Browser-link policy (`qubes.OpenURL` → `A-brave`)
- **Component:** `setup-qubes.sh` writes `/etc/qubes/policy.d/29-browser.policy` and a `.desktop` handler so every app qube opens web links in `A-brave`.
- **Trust assumption:** `A-brave` can safely handle arbitrary, possibly hostile URLs handed to it by any qube.
- **Established by:** A deliberate design choice — concentrating link handling in one browser qube *is* the isolation benefit.
- **Residual risk:** `A-brave` becomes a funnel for hostile links from every qube; its compromise is in scope. The policy allows `@anyvm → A-brave`.

### ADB file transfer
- **Components:** `utils/switch-to-new-sys-usb.sh` (adds `adb` to a `sys-usb` template), `utils/adb-pull.sh` (chunked pull over wireless ADB).
- **Trust assumptions:** (a) `platform-tools` downloaded from `dl.google.com` is genuine; (b) the Android device / ADB peer on the network is the real one.
- **Established by:** ❌ The platform-tools download has no checksum. `adb-pull.sh`'s SHA-256 step compares remote vs local, but both pass through the same ADB endpoint — so it catches transport corruption, **not** a malicious peer.
- **Residual risk:** Wireless ADB exposes a shell-capable channel on the LAN; a hostile peer can feed arbitrary file content. Prefer USB-attached ADB on an untrusted network.

### Hardware-wallet udev rules
- **Components:** `install-scripts/components/ledger/template-vm.sh` and `install-scripts/components/trezor/template-vm.sh` install the Ledger and Trezor udev rules respectively.
- **Trust assumption:** The rule contents (USB vendor/product IDs, permissions) are correct.
- **Established by:** 📝 Reviewed; mirrors vendor-published rules.
- **Residual risk:** Low — grants local device access to the user; no network trust involved.

---

## Weakest links, ranked

1. **Ledger Live** (§3) — Ledger publishes no verifiable artifact for the Linux AppImage and the URL is unversioned, so it can be neither signature-verified nor version-pinned. The one remaining unverifiable software download.
2. **curl-pipe-bash installers** (§3) — the `python` (pyenv), `node` (nvm) and `claude-code` components execute unreviewed remote code on install. For pyenv and nvm this is a deliberate tradeoff for dev-version flexibility; see their entries.
3. **`REPO_VM` + cat hack** (§2) — the repo and its host qube are dom0-equivalent in effect; protected only by manual review.

Brave, KeePassXC, Signal, Docker, VS Code, BitBoxApp, Apache OpenOffice and Element (§3) verify their signing keys/signatures against pinned, cross-checked fingerprints; only Ledger Live remains unverifiable.
