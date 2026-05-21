# Verifying SEQS — human walkthrough

Companion to [TRUST.md](TRUST.md). This document walks you through verifying — *before* you trust the resulting qubes with anything valuable — that what SEQS installs matches what TRUST.md claims. Steps are ordered for a typical first-time setup; do them once when you first install, plus the maintenance section whenever upstreams rotate keys.

## 1. Trust assumptions you cannot verify from here

Three things must be true *before* SEQS does anything useful — none of them provable from inside this repo:

- **The QubesOS installation.** The whole TCB rests on this. Download from <https://www.qubes-os.org/downloads/>, then verify the ISO's PGP signature and SHA-256 checksum against Qubes' published values (see <https://www.qubes-os.org/security/verifying-signatures/>). If you skipped this step, every line below provides false comfort.
- **Your dom0.** A fresh install you booted yourself.
- **`REPO_VM`** (default: `personal`). This qube serves every install script into dom0; a compromise here is a compromise of everything. Use a freshly-created, lightly-used qube (not your daily-driver). Clone the SEQS repo into it from a known-good upstream URL on the day of install.

## 2. Read what you'll run

Read top-to-bottom, in this order:

1. **`setup-qubes.sh`** — every config block (REPO_VM, OS_TEMPLATE_VM, prefixes, BROWSER_VM, LIB_*, CLEANUP_*, SINGLE_QUBES, BRAVE_EXTENSIONS, WALLET_QUBES, DEV_QUBES), every function. Understand each `installQube` call. Pay extra attention to `vmRun` (the dom0 terminal sanitizer — two stages, C0 via `tr` and UTF-8-encoded C1 via `sed`) and `confirmPolicyOverwrite` (the single helper that both `setupBrowserPolicy` and `setupUsbKeyboardPolicy` route through before clobbering a qrexec policy file).
2. **`install-scripts/lib/brave.sh`** — Brave install + keyring verification logic + `ensure_brave`. Also adds the apt-`preferences.d` pin that locks the Brave repo to brave-browser packages only.
3. **`install-scripts/lib/verify-gpg.sh`** — shared `verify_detached_sig` helper used by keepass / bitbox / openoffice. Requires both `GOODSIG` and `VALIDSIG <pinned_fpr>` and explicitly rejects `BADSIG / ERRSIG / EXP*SIG / REV*SIG / KEYEXPIRED / KEYREVOKED / NO_PUBKEY`. If this helper is wrong, all three signed installers are wrong.
4. **`install-scripts/components/*/template-vm.sh`** and `*/app-vm.sh` — every component you'll actually use. For Brave / Docker / VS Code / Signal / Element specifically, verify the script also installs an `/etc/apt/preferences.d/<repo>.pref` default-denying the origin and re-allowing only the named package set — without this, a compromise of the upstream signing key could ship higher-version `bash` / `libc6` / `systemd` etc. via that repo.
5. **`TRUST.md`** — the trust model you are signing up for. Note especially §3 "Brave wallet extensions ⚠️", §4 "Wallet qube egress is unrestricted ⚠️", §4 "USB-keyboard policy override" and the Trezor-specific note under §4 "Hardware-wallet udev rules ⚠️" — these are deferred-acceptance items, not closed gaps.
6. **`README.md`** — sanity-check it matches the code.

The README's WARNING section is in earnest: you are running these scripts in dom0.

## 3. Cross-check the verified components' keys

For each ✅ component below, SEQS embeds a signing key + a pinned fingerprint, and at install time refuses to proceed unless the embedded key matches the pin AND the downloaded artifact verifies against that key. Re-do the cross-check yourself, ideally from a Linux machine separate from dom0, with `curl` + `gpg` available. The fingerprints you compute must match the pinned values:

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

Each component's `template-vm.sh` header also documents the three sources it was cross-checked against and the verification date — read it.

## 4. Watch the install

When you run `setup-qubes.sh`:

1. The pre-flight check runs first. You should see:
    - `Base template '…' found.`
    - `Source qube '…' found.`
    - `validating all qube specs...` → ends with `All qube specs valid.`

   Any `ERROR:` and an abort here means your config has typos, duplicates, or qubes that already exist. Fix and retry — *no* qubes are built before this passes.

2. **Policy-overwrite prompts.** If you have re-run `setup-qubes.sh` against a dom0 that already has `/etc/qubes/policy.d/29-browser.policy` or `/etc/qubes/policy.d/30-user-input.policy` from a previous run (or hand-edited), the script will print a banner showing the current contents and the new rule, then **block** on:

   `Overwrite /etc/qubes/policy.d/…? type OVERWRITE to confirm (anything else aborts):`

   Read the diff. If a hand-tightened rule (e.g. `qubes.InputKeyboard` pinned to a specific keyboard qube, or `qubes.OpenURL` using `ask` instead of `allow`) is about to be clobbered, type anything other than `OVERWRITE` to abort. Re-confirm the loss is acceptable before re-running. (No qube is built before this gate.)

3. Then for each qube it builds, watch for the verification lines. The signed-artifact lines all come from the shared `verify_detached_sig` helper and share a uniform `signature OK -- <file> signed by <fingerprint>` shape:
    - `Brave keyring verified -- DBF1A116… 47D32A74… B2A3DCA3…`
    - `KeePassXC signing key verified: BF5A669F…` followed by `signature OK -- KeePassXC-2.7.12-x86_64.AppImage signed by BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2`
    - `Signal signing key verified: DBA36B…`
    - `Docker signing key verified: 9DC858…`
    - `Microsoft signing key verified: BC528686…`
    - `Element signing key verified: 12D4CD…`
    - `signature OK -- bitbox_4.51.0_amd64.deb signed by DD09E41309750EBFAE0DEF63509249B068D215AE`
    - `signature OK -- Apache_OpenOffice_4.1.16_Linux_x86-64_install-deb_en-US.tar.gz signed by A93D62ECC3C8EA12DB220EC934EA76E6791485A8`
    - For each `brave-extension-*`: `installing Brave extension '<name>' (<id>) into Z-…`

4. Watch for verifier-rejection diagnostics. If `verify_detached_sig` ever fails, you will see exactly **one** of the following root-cause lines printed before the script aborts — each maps to a concrete upstream condition:
    - `rejected: gpg emitted BADSIG`         — the signature math failed; the artifact does not match the signature.
    - `rejected: gpg emitted ERRSIG`         — gpg could not complete verification (e.g. missing pubkey, broken sig packet).
    - `rejected: gpg emitted EXPSIG`         — the signature itself has expired (signature expiration time in the past).
    - `rejected: gpg emitted EXPKEYSIG`      — the key used to sign has expired.
    - `rejected: gpg emitted REVKEYSIG`      — the signing key has been **revoked** by its owner. **Treat this as alarm-level.**
    - `rejected: gpg emitted KEYEXPIRED` / `KEYREVOKED` / `NO_PUBKEY` — corresponding key-state issues.
    - `rejected: no GOODSIG in gpg output (expired/revoked key, or no signature)` — the positive marker is absent.
    - `rejected: no VALIDSIG with primary-key fingerprint <pin>` — the artifact is signed, but **not by the pinned key** — most likely upstream rotated keys, or a substitution.

   None of these are "rerun and hope." Each requires either a re-verify-from-three-sources of the new upstream key (§6) before bumping the pin, or treating the artifact as untrusted.

5. Any line beginning with `ERROR:` is a hard stop. Don't keep going assuming the qube will work — read the error and fix it.

## 5. Spot-check the result

After install:

- `qvm-ls` shows the expected templates (`Z-*`) and app qubes (`A-*`). Pay attention to labels: `A-keepass` should be `black`, `A-wallet-ledger`/`A-wallet-trezor` `orange`, dev qubes `gray`, etc.
- `qvm-prefs A-keepass netvm` should print `(default) None` (the offline qube).
- For each wallet qube: `qvm-prefs A-wallet-ledger label` shows `orange`, `qvm-prefs A-wallet-ledger template` shows `Z-wallet-ledger`.
- Open each app and confirm it actually launches. Versions in About dialogs match what's pinned in TRUST.md / the scripts.
- From any non-browser qube, run `qvm-open-in-vm A-brave https://example.com` (or click an http(s) link inside the qube) — it should open in `A-brave`.
- Reboot any app qube; afterwards `~/QubesIncoming` and `~/Downloads` should be empty (the boot/shutdown cleanup service).

## 6. Ongoing maintenance

- **Key rotations**: when an upstream rotates its signing key, the install fails by design (fingerprint mismatch, or one of the `verify_detached_sig` "rejected: no VALIDSIG with primary-key fingerprint" / "rejected: no GOODSIG" lines from §4 step 4). Re-verify the new key against three independent sources (see TRUST.md for the pattern), then update the pin and the embedded key block in the component script. Don't bypass the check.
- **`BRAVE_EXTENSIONS`**: periodically prune. Remove abandoned/discontinued wallet extensions; review the maintained status of those that remain.
- **Re-running `setup-qubes.sh`**: `validateAllQubes` aborts if a target qube already exists. Use `./delete-vms.sh <name>` to clean specific qubes first (it matches `[A-Z]-<name>`, so it removes both `A-<name>` and `Z-<name>` in one go). Re-runs against a dom0 that already has `/etc/qubes/policy.d/29-browser.policy` or `…/30-user-input.policy` will prompt you with `Overwrite … type OVERWRITE to confirm` — read the dumped diff each time; the prompt is exactly the chance to notice that a hand-tightened rule is about to be lost.
- **`OS_TEMPLATE_VM`**: when you upgrade to a newer Qubes / Debian template, change the value at the top of `setup-qubes.sh` and re-test that the component installs still work.
- **Wallet-qube egress hardening (operator follow-up)**: by default `A-wallet-*` reach any internet host. If you know your RPC endpoints (and the block-explorer / `clients2.google.com` / etc. you actually depend on), apply a `qvm-firewall` default-deny + explicit allow-list to each wallet qube — see TRUST.md §4 "Wallet qube egress is unrestricted ⚠️". This is the single hardening with the biggest blast-radius reduction on a wallet-extension supply-chain compromise.

## 7. Honest residual risk

What this whole pipeline does **not** verify:

- That Brave / Signal / KeePassXC / Element / BitBox / etc. (the upstreams) build clean binaries from clean source. The pin proves you got *their* key; it does not vouch for what they sign. The apt-`preferences.d` pins narrow this to "they can sign the *named* package set" but a hostile build of *those* packages still gets through.
- That `REPO_VM` hasn't been tampered with between repo checkout and install.
- That dom0 hasn't been tampered with.
- That **Ledger Live**, **pyenv**, **nvm**, **Claude Code**, the snap-installed **Telegram**, or the Brave **wallet extensions** match anything beyond what their upstream (and, for Telegram, Canonical's snap assertion chain) chose to publish. See `TRUST.md` §3 for the per-component trust level.
- That a hostile **wallet extension** update, once on the wallet qube, is contained by network rules. By default the wallet qubes have no `qvm-firewall` allow-list — see §6 above and TRUST.md §4 "Wallet qube egress is unrestricted ⚠️".
- That a `trezor` qube can independently cross-check a transaction outside the browser-extension UX — SEQS does **not** install Trezor Suite. The hardware-wallet on-device confirmation screen is the *only* non-extension source of truth in that qube.

The `❌` and `⚠️` items in TRUST.md are not bugs — they are honest descriptions of trust gaps inherent to those upstreams (or to operator-specific tradeoffs SEQS does not unilaterally make). Treat the qubes that hold them as accordingly lower-trust domains.
