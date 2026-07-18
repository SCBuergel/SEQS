# Seb's QubesOS Scripts (SEQS)

SEQS builds a set of purpose-specific qubes (chat, wallets, dev, USB transfer, …)
on a fresh Qubes OS install. A thin dom0 runner (`setup-qubes.sh`) fetches this
repo **once**, installs a Salt state/pillar tree into `/srv`, and then
`qubesctl` creates every qube and installs its software declaratively.
Re-running converges — finished work is skipped, existing qubes are reconfigured
in place. Template VMs are prefixed `Z-[AppName]`; the app VMs you actually use
are prefixed `A-[AppName]`, to keep the Qubes menu tidy.

> **⚠️ WARNING — this runs code in dom0.** Bootstrapping copies one file from an
> app VM into dom0 and runs it, which exposes dom0 to scripts whose safety is not
> guaranteed. **Read every file yourself and only proceed if you understand and
> trust it.** Start with [VERIFY-HUMAN.md](VERIFY-HUMAN.md) and
> [TRUST.md](TRUST.md).

## First installation: the complete path

1. **[Install and verify Qubes OS](docs/install-qubes.md).**
2. **Download SEQS into a temporary networked DisposableVM** (§2).
3. **Review the exact revision and code that will become trusted** (§3).
4. **Configure what gets built inside that disposable** (§4).
5. **Copy only the runner into dom0 and fetch without applying** (§5).
6. **Review dom0's installed `/srv` tree, then apply it locally** (§6).

Already installed SEQS and want to add a newly introduced qube or setting?
Do not reinstall Qubes; follow [Upgrading an existing SEQS installation](docs/upgrading.md).

## Further reading

| Topic | Where |
|---|---|
| Full Qubes OS install + ISO verification | [docs/install-qubes.md](docs/install-qubes.md) |
| What to review before running anything   | [VERIFY-HUMAN.md](VERIFY-HUMAN.md), [TRUST.md](TRUST.md), [docs/architecture.md](docs/architecture.md) |
| Upgrade an existing SEQS installation or add new qubes | [docs/upgrading.md](docs/upgrading.md) |
| Components, flags, air gaps, adding your own | [docs/configuration.md](docs/configuration.md) |
| Verify before you trust the qubes        | [VERIFY-HUMAN.md](VERIFY-HUMAN.md), [VERIFY-LLM.md](VERIFY-LLM.md) |
| Extra recipes (VPN tray, firewall, ADB…) | [docs/recipes.md](docs/recipes.md) |
| Secure air-gapped QR transfer + webcam USB isolation | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Testing changes offline                   | [test/README.md](test/README.md) |

---

## 1. Install Qubes OS

Full walkthrough incl. ISO verification: [docs/install-qubes.md](docs/install-qubes.md).
Essentials:

1. Download the latest [Qubes OS ISO](https://www.qubes-os.org/downloads/) onto a
   dedicated ≥8 GB USB stick (Ventoy is [not supported](https://github.com/QubesOS/qubes-issues/issues/8846)).
2. **Verify the ISO** before flashing — a tampered ISO compromises every qube you
   later build. Cross-check the Qubes Master Signing Key fingerprint
   `427F 11FD 0FAA 4B08 0123 F01C DDFA 1A3E 3687 9494` against three independent
   sources, then `gpg --verify` ([how](docs/install-qubes.md#2-verify-the-iso-before-flashing-it)).
3. Install, then run all system updates and reboot.

## 2. Download SEQS in a temporary DisposableVM

Do not use your daily `personal` qube as the bootstrap source. Start a fresh,
networked Debian DisposableVM from the Qubes application menu and open a
terminal in it. The disposable limits persistence and avoids mixing the
download with personal files; it does **not** authenticate what GitHub served.

Inside that disposable:

```bash
git clone https://github.com/SCBuergel/SEQS.git /home/user/SEQS
cd /home/user/SEQS
git status --short                  # expected output: nothing (clean checkout)
printf 'Revision to verify: '; git rev-parse HEAD
printf 'Use as REPO_VM in dom0: '; hostname
```

An empty `git status --short` means the checkout has no modified or untracked
files immediately after cloning. Any output at this point needs investigation.

The complete `Revision to verify` value identifies the exact source snapshot:
compare it through an independent trusted channel or with a separately obtained
known-good checkout during §3. It identifies bytes; it does not by itself prove
they are trustworthy.

The `Use as REPO_VM in dom0` value is the running disposable's Qubes name,
normally something like `disp1234`. Substitute that exact value for
`REPO_VM=disp1234` in §5 so dom0 knows which qube to fetch from. Keep the
disposable running until `--fetch-only` completes. If it shuts down earlier,
its checkout is destroyed, which is expected DisposableVM behavior.

For ongoing maintenance after installation, prefer a dedicated minimal repo
qube or repeat this fresh-disposable workflow; see
[docs/upgrading.md](docs/upgrading.md). The runner still has a legacy
`personal` fallback for compatibility, but this guide deliberately supplies an
explicit disposable name instead.

## 3. Establish what you are about to trust

Anything this checkout supplies can ultimately influence dom0 and every qube
SEQS creates. HTTPS and a Git commit ID provide transport and version identity;
they do not by themselves prove that the code is safe or that the intended
author approved it.

Before copying anything into dom0:

1. Follow [VERIFY-HUMAN.md](VERIFY-HUMAN.md), especially “Read what you'll
   run.” It gives the review order for the runner, pillar, Salt states, shared
   verification libraries, and every selected component installer.
2. Read [TRUST.md](TRUST.md) for what each component verifies and its residual
   risks. Items marked ⚠️ or ❌ require an explicit trust decision.
3. Read [docs/architecture.md](docs/architecture.md) for the VM→dom0 data flow,
   archive validation, review gate, and bootstrap-window defense.
4. Compare the full commit ID through an independent trusted channel or against
   a separately obtained known-good checkout. If the chosen revision has a
   verifiable signature, verify it; do not assume every commit is signed.
5. Inspect local changes and run the offline tests when dependencies are
   available:

   ```bash
   cd /home/user/SEQS
   git status
   git diff --check
   ./test/run-tests.sh
   ```

The test suite detects many accidental or structural failures, but passing
tests are not a security audit. Do not continue if the revision, diff, or code
does not match what you intended to trust.

## 4. Configure what gets built

Edit the repository while it is still in the DisposableVM.

For example, with the terminal editor supplied by the template:

```bash
cd /home/user/SEQS
nano salt/pillar/seqs/config.sls
```

In `nano`, save with `Ctrl+O`, press Enter, and exit with `Ctrl+X`. If `nano`
is not installed, use the template's available editor; do not move the
configuration step into dom0.

### 4.1 Choose your qubes (`salt/pillar/seqs/config.sls`)

**All software configuration lives in one file:** `salt/pillar/seqs/config.sls`.
Each qube is one entry in `qube_list`, built from a list of **components**:

```
{%- set qube_list = [
  {'name': 'keepass',       'label': 'black',  'components': ['keepass'], 'offline': True},
  {'name': 'dev-full',      'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code']},
  {'name': 'wallet-ledger', 'label': 'gray',   'components': ['ledger', 'brave-extension-rabby'], 'no_handoff': True},
] %}
```

Add an entry to spin up a new qube; edit an entry to add/remove components. The
**full component list**, per-qube flags (`offline`, `no_handoff`), wallet
extensions, and how to add your own component are in
[docs/configuration.md](docs/configuration.md).

For security-sensitive features such as offline QR transfer, complete their
hardware qualification before selecting a mode; see
[docs/secure-qr-transfer.md](docs/secure-qr-transfer.md).

Review the final configuration and diff again:

```bash
sed -n '1,230p' salt/pillar/seqs/config.sls
git diff --check
git diff
```

## 5. Copy the runner into dom0 and fetch only

Assume the disposable reported `disp1234`; replace that example with its exact
name. In a dom0 terminal:

```bash
REPO_VM=disp1234
REPO_PATH=/home/user/SEQS

qvm-run -p "$REPO_VM" \
  "cat $REPO_PATH/setup-qubes.sh" \
  2>/dev/null > ~/seqs-setup.sh
chmod 700 ~/seqs-setup.sh
less ~/seqs-setup.sh
```

The `2>/dev/null` is deliberate: it prevents source-qube terminal-control bytes
from reaching dom0 before the runner's sanitizer exists. Read the full rationale
in [the bootstrap-window section](docs/architecture.md#bootstrap-window).

Review the copied runner in dom0 with `less`; quit with `q`. Then fetch and
install the Salt tree without applying any state:

```bash
SEQS_REPO_VM="$REPO_VM" \
SEQS_REPO_PATH="$REPO_PATH" \
~/seqs-setup.sh --fetch-only
```

The runner validates the archive and displays its transfer hash. On the first
installation there is no prior `/srv` tree to compare, so the review obligation
is especially important. Type `CONTINUE` only for the revision and content you
already reviewed. After `--fetch-only` completes, shut down the download
DisposableVM; dom0 no longer needs it.

## 6. Review `/srv`, then apply locally

The exact root-owned tree that will run is now installed in dom0. Review at
least:

```bash
sudo less /srv/pillar/seqs/config.sls
sudo less /srv/salt/seqs/dom0.sls
sudo less /srv/salt/seqs/qube.sls
```

Follow the fuller file order in [VERIFY-HUMAN.md](VERIFY-HUMAN.md). When the
installed bytes match the revision and configuration you approved, apply
without contacting any repo/download qube:

```bash
~/seqs-setup.sh --skip-fetch
```

Watch for policy-takeover prompts, air-gap verification, failed Salt states,
and component signature checks as described in VERIFY-HUMAN. After completion,
perform its post-install spot checks before putting secrets in the new qubes.

For later changes, follow [docs/upgrading.md](docs/upgrading.md). Re-runs
converge, but removal and changed component installers have deliberately
non-destructive semantics explained there.
