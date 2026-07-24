# Seb's QubesOS Scripts (SEQS)

[SEQS](https://github.com/SCBuergel/SEQS) turns a
[Qubes OS](https://www.qubes-os.org/) installation into a configurable set of
purpose-specific security domains for browsing, chat, wallets, development,
offline storage, and controlled data transfer. It creates a separate `Z-*`
TemplateVM and `A-*` AppVM for each selected workload, keeping unrelated tools
and data out of the same qube while making the resulting layout reproducible
from one reviewed configuration.

> **Warning:** SEQS installs [Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html)
> code that runs as root in dom0. A malicious checkout can compromise the whole
> machine. Install only a commit published through an independent channel by a
> reviewer you trust. The commit-bound export prevents working-tree drift, but
> dom0 does not verify Git: the repository qube remains trusted. See
> [TRUST.md](TRUST.md).

## Install (for users)

1. [Install and verify Qubes OS](docs/install-qubes.md), update it, and reboot.

2. In a fresh networked Debian DisposableVM, check out the independently
   published commit:

   ```bash
   git clone https://github.com/SCBuergel/SEQS.git
   cd SEQS
   git checkout <COMMIT>
   git status --short
   git rev-parse HEAD
   ```

   `git status --short` must be empty and the printed hash must equal the
   independently published full commit ID. A hash copied from the same hosting
   page as the clone is not an independent trust anchor.

3. Copy the runner into dom0 and install in one step. Replace both `disp1234`
   occurrences with the disposable's name, and pick the qubes you want:

   ```bash
   qvm-run -p disp1234 "git -C /home/user/SEQS show <COMMIT>:setup-qubes.sh" 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
   ~/s.sh --commit <COMMIT> --repo-vm disp1234 --qubes brave,signal,keepass
   ```

   Use the same full commit ID twice. The disposable can be shut down after the
   command finishes. Use `--all` instead of `--qubes` for the full catalogue.

Do not put secrets into the resulting qubes until completing the post-install
checks in [VERIFY-HUMAN.md](VERIFY-HUMAN.md). Already installed SEQS? Use
[docs/upgrading.md](docs/upgrading.md); do not reinstall Qubes.

## Reviewers

If you are the one **auditing SEQS and publishing an authoritative commit hash**
for others (or you want to audit before trusting anyone else's), do not stop at
the hash — read the code that will run as root in dom0:
[VERIFY-HUMAN.md](VERIFY-HUMAN.md) is the structured review walkthrough
(including the rules for using an LLM to assist the audit), and
[TRUST.md](TRUST.md) explains what remains trusted. The
[full first-install walkthrough](docs/first-install.md) covers the fetch → stage
→ build stages in detail and the separate `--fetch-only` / `--stage-only` /
`--build-only` commands for pausing between them.

## Documentation

| Need | Read |
|---|---|
| Full first-install walkthrough | [docs/first-install.md](docs/first-install.md) |
| Verify Qubes ISO and install Qubes | [docs/install-qubes.md](docs/install-qubes.md) |
| Review what SEQS runs | [VERIFY-HUMAN.md](VERIFY-HUMAN.md) |
| Understand trust and residual risk | [TRUST.md](TRUST.md) |
| Understand the runner and dom0 data flow | [docs/architecture.md](docs/architecture.md) |
| Select available qubes or customize their definitions | [docs/configuration.md](docs/configuration.md) |
| Configure and use the WireGuard NetVM | [docs/wireguard.md](docs/wireguard.md) |
| Prepare and test a manual GnosisVPN NetVM | [docs/gnosisvpn.md](docs/gnosisvpn.md) |
| Upgrade an existing installation | [docs/upgrading.md](docs/upgrading.md) |
| Delete or rebuild managed qubes | [docs/deleting-vms.md](docs/deleting-vms.md) |
| Configure secure QR transfer | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Use additional recipes | [docs/recipes.md](docs/recipes.md) |
| Run repository tests | [test/README.md](test/README.md) |
