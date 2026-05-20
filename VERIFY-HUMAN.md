# Verifying SEQS — human walkthrough

Companion to [TRUST.md](TRUST.md). This document walks you through verifying — *before* you trust the resulting qubes with anything valuable — that what SEQS installs matches what TRUST.md claims. Steps are ordered for a typical first-time setup; do them once when you first install, plus the maintenance section whenever upstreams rotate keys.

## 1. Trust assumptions you cannot verify from here

Three things must be true *before* SEQS does anything useful — none of them provable from inside this repo:

- **The QubesOS installation.** The whole TCB rests on this. Download from <https://www.qubes-os.org/downloads/>, then verify the ISO's PGP signature and SHA-256 checksum against Qubes' published values (see <https://www.qubes-os.org/security/verifying-signatures/>). If you skipped this step, every line below provides false comfort.
- **Your dom0.** A fresh install you booted yourself.
- **`REPO_VM`** (default: `personal`). This qube serves every install script into dom0; a compromise here is a compromise of everything. Use a freshly-created, lightly-used qube (not your daily-driver). Clone the SEQS repo into it from a known-good upstream URL on the day of install.

## 2. Read what you'll run

Read top-to-bottom, in this order:

1. **`setup-qubes.sh`** — every config block (REPO_VM, OS_TEMPLATE_VM, prefixes, BROWSER_VM, LIB_*, CLEANUP_*, SINGLE_QUBES, BRAVE_EXTENSIONS, WALLET_QUBES, DEV_QUBES), every function. Understand each `installQube` call.
2. **`install-scripts/lib/brave.sh`** — Brave install + keyring verification logic + `ensure_brave`.
3. **`install-scripts/components/*/template-vm.sh`** and `*/app-vm.sh` — every component you'll actually use.
4. **`TRUST.md`** — the trust model you are signing up for.
5. **`README.md`** — sanity-check it matches the code.

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

2. Then for each qube it builds, watch for the verification lines:
    - `Brave keyring verified -- DBF1A116… 47D32A74… B2A3DCA3…`
    - `KeePassXC signing key verified: BF5A669F…` followed by `signature OK -- KeePassXC-…AppImage signed by KeePassXC Release key BF5A669F…`
    - `Signal signing key verified: DBA36B…`
    - `Docker signing key verified: 9DC858…`
    - `Microsoft signing key verified: BC528686…`
    - `Element signing key verified: 12D4CD…`
    - `signature OK -- bitbox_…deb signed by ShiftCrypto Security DD09E413…`
    - `signature OK -- Apache_OpenOffice_…tar.gz signed by A93D62EC…`
    - For each `brave-extension-*`: `installing Brave extension '<name>' (<id>) into Z-…`

3. Any line beginning with `ERROR:` is a hard stop. Don't keep going assuming the qube will work — read the error and fix it.

## 5. Spot-check the result

After install:

- `qvm-ls` shows the expected templates (`Z-*`) and app qubes (`A-*`). Pay attention to labels: `A-keepass` should be `black`, `A-wallet-ledger`/`A-wallet-trezor` `orange`, dev qubes `gray`, etc.
- `qvm-prefs A-keepass netvm` should print `(default) None` (the offline qube).
- For each wallet qube: `qvm-prefs A-wallet-ledger label` shows `orange`, `qvm-prefs A-wallet-ledger template` shows `Z-wallet-ledger`.
- Open each app and confirm it actually launches. Versions in About dialogs match what's pinned in TRUST.md / the scripts.
- From any non-browser qube, run `qvm-open-in-vm A-brave https://example.com` (or click an http(s) link inside the qube) — it should open in `A-brave`.
- Reboot any app qube; afterwards `~/QubesIncoming` and `~/Downloads` should be empty (the boot/shutdown cleanup service).

## 6. Ongoing maintenance

- **Key rotations**: when an upstream rotates its signing key, the install fails by design (fingerprint mismatch). Re-verify the new key against three independent sources (see TRUST.md for the pattern), then update the pin and the embedded key block in the component script. Don't bypass the check.
- **`BRAVE_EXTENSIONS`**: periodically prune. Remove abandoned/discontinued wallet extensions; review the maintained status of those that remain.
- **Re-running `setup-qubes.sh`**: `validateAllQubes` aborts if a target qube already exists. Use `./delete-vms.sh <name>` to clean specific qubes first (it matches `[A-Z]-<name>`, so it removes both `A-<name>` and `Z-<name>` in one go).
- **`OS_TEMPLATE_VM`**: when you upgrade to a newer Qubes / Debian template, change the value at the top of `setup-qubes.sh` and re-test that the component installs still work.

## 7. Honest residual risk

What this whole pipeline does **not** verify:

- That Brave / Signal / KeePassXC / Element / BitBox / etc. (the upstreams) build clean binaries from clean source. The pin proves you got *their* key; it does not vouch for what they sign.
- That `REPO_VM` hasn't been tampered with between repo checkout and install.
- That dom0 hasn't been tampered with.
- That **Ledger Live**, **pyenv**, **nvm**, **Claude Code**, the snap-installed **Telegram**, or the Brave **wallet extensions** match anything beyond what their upstream (and, for Telegram, Canonical's snap assertion chain) chose to publish. See `TRUST.md` §3 for the per-component trust level.

The `❌` and `⚠️` items in TRUST.md are not bugs — they are honest descriptions of trust gaps inherent to those upstreams. Treat the qubes that hold them as accordingly lower-trust domains.
