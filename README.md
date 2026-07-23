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
> is the one security check you must not skip. Verifying the hash authenticates
> the reviewed Git object; the commit-bound export below prevents local
> working-tree drift from entering the install. It does not, by itself, prove
> the code is safe — that judgment is what you delegate to the reviewer. Who
> that trusted source is, and why you trust them, is **out of scope of this repository**:
> nothing a repository says about its own trustworthiness can anchor it. If you
> have no such source, you are the reviewer (see below).

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
   content-addressing authenticates the committed object. A clean
   `git status --short` separately confirms that the checkout has no local
   modifications or untracked files.
   The published hash must reach you through a channel **independent of this
   repository and the page you cloned it from** — a hash read off the same
   GitHub page you clone verifies nothing, because whoever controls that page
   controls both values.

3. Copy the runner into dom0 and install in one step. Replace both `disp1234`
   occurrences with the disposable's name, and pick the qubes you want:

   ```bash
   qvm-run -p disp1234 "git -C /home/user/SEQS show <COMMIT>:setup-qubes.sh" 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
   ~/s.sh --commit <COMMIT> --repo-vm disp1234 --qubes brave,signal,keepass
   ```

   Use the same full commit ID in both commands. The runner asks Git in the
   disposable to archive `salt/` and `install-scripts/` from that commit object,
   never from the live working tree. This one command fetches, stages, and
   builds after a single confirmation; the disposable can be shut down once it
   finishes. Use `--all` instead of `--qubes` for the entire catalogue — every
   install requires one or the other.

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
| Upgrade an existing installation | [docs/upgrading.md](docs/upgrading.md) |
| Delete or rebuild managed qubes | [docs/deleting-vms.md](docs/deleting-vms.md) |
| Configure secure QR transfer | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Use additional recipes | [docs/recipes.md](docs/recipes.md) |
| Run repository tests | [test/README.md](test/README.md) |
