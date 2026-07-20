# Seb's QubesOS Scripts (SEQS)

[SEQS](https://github.com/SCBuergel/SEQS) turns a
[Qubes OS](https://www.qubes-os.org/) installation into a configurable set of
purpose-specific security domains for browsing, chat, wallets, development,
offline storage, and controlled data transfer. It creates a separate `Z-*`
TemplateVM and `A-*` AppVM for each selected workload, keeping unrelated tools
and data out of the same qube while making the resulting layout reproducible
from one reviewed configuration.

> **Warning:** SEQS installs [Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html)
> code that runs as root in dom0. A malicious checkout can compromise the
> whole machine. Before proceeding, use
> [VERIFY-HUMAN.md](VERIFY-HUMAN.md) to review what will run and
> [TRUST.md](TRUST.md) to understand what remains trusted. Those repository
> documents are guidance, not independent proof.

## Minimal first install

For explanations and verification details, follow
[docs/first-install.md](docs/first-install.md). SEQS first **fetches** and
validates the repository into a review-only area in dom0, then **stages** the
reviewed Salt files where Qubes can use them, and finally **builds** the
configured TemplateVMs and AppVMs. The minimum command path is:

1. [Install and verify Qubes OS](docs/install-qubes.md), update it, and reboot.

2. Start a fresh networked Debian DisposableVM. In its terminal:

   ```bash
   git clone https://github.com/SCBuergel/SEQS.git /home/user/SEQS
   cd /home/user/SEQS
   git status --short
   ```

   Do not edit the checkout merely to choose which qubes to install. The
   reviewed `qube_catalog` already describes everything available; the
   mandatory `--qubes` argument in dom0 selects the desired entries. Edit
   `config.sls` only for advanced catalogue or hardware-policy customization,
   such as qualified secure-QR controller settings.

   Keep the disposable running. Review the checkout before trusting it; the
   [first-install guide](docs/first-install.md) explains the revision and code
   checks.

3. In dom0, replace both `disp1234` occurrences with the disposable's name:

   ```bash
   qvm-run -p disp1234 "cat /home/user/SEQS/setup-qubes.sh" 2>/dev/null > ~/s.sh
   chmod 700 ~/s.sh
   ~/s.sh --repo-vm disp1234 --fetch-only
   ```

4. Follow the [fetched-tree review instructions](docs/first-install.md#7-review-and-stage-the-fetched-tree),
   then stage and build it. The disposable can be shut down after fetching:

   ```bash
   ~/s.sh --stage-only
   ~/s.sh --build-only --qubes brave,signal,keepass
   ```

Running `~/s.sh --repo-vm disp1234 --all` without a stage flag performs fetch,
stage, and a full-catalogue build in order, requiring `CONTINUE` before each
stage. Every build requires either `--qubes NAME[,NAME...]` or explicit `--all`.

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
| Select available qubes or customize their definitions | [docs/configuration.md](docs/configuration.md) |
| Upgrade an existing installation | [docs/upgrading.md](docs/upgrading.md) |
| Delete or rebuild managed qubes | [docs/deleting-vms.md](docs/deleting-vms.md) |
| Configure secure QR transfer | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Use additional recipes | [docs/recipes.md](docs/recipes.md) |
| Run repository tests | [test/README.md](test/README.md) |
