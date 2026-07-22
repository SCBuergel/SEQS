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
> machine. Your safety rests on installing a **git commit that a source you
> trust has reviewed and published** — verifying that commit hash (step 2 below)
> is the one security check you must not skip. Verifying the hash proves the
> code is exactly that reviewed revision; it does not, by itself, prove the code
> is safe — that judgment is what you delegate to the reviewer.

## Install (for users)

You install by pinning a specific SEQS commit, confirming its hash matches what
a trusted source published, and running a single command in dom0. The commit
hash covers the entire repository — including `setup-qubes.sh` itself — so one
verified hash is the whole integrity check.

1. [Install and verify Qubes OS](docs/install-qubes.md), update it, and reboot.

2. Start a fresh networked Debian DisposableVM, clone SEQS, check out the commit
   your trusted source published, and confirm the hash matches:

   ```bash
   git clone https://github.com/SCBuergel/SEQS.git /home/user/SEQS
   cd /home/user/SEQS && git checkout <COMMIT> && git rev-parse HEAD
   ```

   The printed hash **must** equal the one published by the source you trust
   (release announcement, maintainer channel, etc.). If it differs, stop. Git's
   content-addressing guarantees the working tree is exactly that commit.

3. Copy the runner into dom0 and install in one step. Replace both `disp1234`
   occurrences with the disposable's name, and pick the qubes you want:

   ```bash
   qvm-run -p disp1234 "cat /home/user/SEQS/setup-qubes.sh" 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
   ~/s.sh --repo-vm disp1234 --qubes brave,signal,keepass
   ```

   This one command fetches, stages, and builds after a single confirmation; the
   disposable can be shut down once it finishes. Use `--all` instead of `--qubes`
   for the entire catalogue — every install requires one or the other.

Do not put secrets into the resulting qubes until completing the post-install
checks in [VERIFY-HUMAN.md](VERIFY-HUMAN.md). Already installed SEQS? Use
[docs/upgrading.md](docs/upgrading.md); do not reinstall Qubes.

## Reviewers

If you are the one **auditing SEQS and publishing an authoritative commit hash**
for others (or you want to audit before trusting anyone else's), do not stop at
the hash — read the code that will run as root in dom0:
[VERIFY-HUMAN.md](VERIFY-HUMAN.md) is the structured review walkthrough,
[VERIFY-LLM.md](VERIFY-LLM.md) the machine-runnable cross-check, and
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
| Upgrade an existing installation | [docs/upgrading.md](docs/upgrading.md) |
| Delete or rebuild managed qubes | [docs/deleting-vms.md](docs/deleting-vms.md) |
| Configure secure QR transfer | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Use additional recipes | [docs/recipes.md](docs/recipes.md) |
| Run repository tests | [test/README.md](test/README.md) |
