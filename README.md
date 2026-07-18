# Seb's QubesOS Scripts (SEQS)

SEQS builds purpose-specific Qubes OS qubes for chat, wallets, development,
offline storage, USB transfer, and related tasks. Templates are named `Z-*` and
their app qubes `A-*`. Re-running the installer converges an existing setup.

> **Warning:** SEQS installs Salt code that runs as root in dom0. A malicious
> checkout can compromise the whole machine. Before proceeding, use
> [VERIFY-HUMAN.md](VERIFY-HUMAN.md) to review what will run and
> [TRUST.md](TRUST.md) to understand what remains trusted. Those repository
> documents are guidance, not independent proof.

## Minimal first install

For explanations and verification details, follow
[docs/first-install.md](docs/first-install.md). The minimum command path is:

1. [Install and verify Qubes OS](docs/install-qubes.md), update it, and reboot.

2. Start a fresh networked Debian DisposableVM. In its terminal:

   ```bash
   git clone https://github.com/SCBuergel/SEQS.git /home/user/SEQS
   cd /home/user/SEQS
   printf 'Use as REPO_VM in dom0: '; hostname
   nano salt/pillar/seqs/config.sls
   ```

   Keep the disposable running. Review the checkout before trusting it; the
   [first-install guide](docs/first-install.md) explains the revision and code
   checks. In `nano`, save with `Ctrl+O`, Enter, then exit with `Ctrl+X`.

3. In dom0, replace `disp1234` with the disposable name printed above:

   ```bash
   REPO_VM=disp1234
   REPO_PATH=/home/user/SEQS

   qvm-run -p "$REPO_VM" \
     "cat $REPO_PATH/setup-qubes.sh" \
     2>/dev/null > ~/seqs-setup.sh
   chmod 700 ~/seqs-setup.sh

   SEQS_REPO_VM="$REPO_VM" \
   SEQS_REPO_PATH="$REPO_PATH" \
   ~/seqs-setup.sh --fetch-only
   ```

4. After reviewing the installed `/srv/salt/seqs` and `/srv/pillar/seqs`
   trees, shut down the download disposable and apply locally in dom0:

   ```bash
   ~/seqs-setup.sh --skip-fetch
   ```

Do not put secrets into the resulting qubes until completing the post-install
checks in [VERIFY-HUMAN.md](VERIFY-HUMAN.md).

Already installed SEQS? Use [docs/upgrading.md](docs/upgrading.md); do not
reinstall Qubes.

## Documentation

| Need | Read |
|---|---|
| Full first-install walkthrough | [docs/first-install.md](docs/first-install.md) |
| Verify Qubes ISO and install Qubes | [docs/install-qubes.md](docs/install-qubes.md) |
| Review what SEQS runs | [VERIFY-HUMAN.md](VERIFY-HUMAN.md) |
| Understand trust and residual risk | [TRUST.md](TRUST.md) |
| Understand the runner and dom0 data flow | [docs/architecture.md](docs/architecture.md) |
| Select qubes, components, and flags | [docs/configuration.md](docs/configuration.md) |
| Upgrade an existing installation | [docs/upgrading.md](docs/upgrading.md) |
| Configure secure QR transfer | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Use additional recipes | [docs/recipes.md](docs/recipes.md) |
| Run repository tests | [test/README.md](test/README.md) |
