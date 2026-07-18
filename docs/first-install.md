# First SEQS installation

This is the expanded walkthrough behind the README's minimal command path. It
explains how to obtain, review, configure, fetch, and apply SEQS without using a
daily qube as the bootstrap source.

## 1. Install and verify Qubes OS

Follow [install-qubes.md](install-qubes.md). In summary:

1. Obtain the Qubes ISO from the official Qubes site.
2. Verify its signature and the Qubes signing-key fingerprint independently.
3. Install Qubes, apply all system and template updates, and reboot.

SEQS cannot compensate for an untrusted Qubes installation or dom0.

## 2. Download into a temporary DisposableVM

Start a fresh, networked Debian DisposableVM from the Qubes application menu
and open a terminal. Do not use a daily `personal` qube. A disposable limits
persistence and avoids mixing the checkout with personal data; it does not
authenticate what GitHub served.

Inside the disposable:

```bash
git clone https://github.com/SCBuergel/SEQS.git /home/user/SEQS
cd /home/user/SEQS
git status --short                  # expected output: nothing (clean checkout)
printf 'Revision to verify: '; git rev-parse HEAD
printf 'Use as REPO_VM in dom0: '; hostname
```

An empty `git status --short` means there are no modified or untracked files
immediately after cloning. Any output at this point needs investigation.

The complete revision identifies the exact source snapshot. Compare it through
an independent trusted channel or with a separately obtained known-good
checkout. It identifies bytes; it does not prove they are safe or author-approved.

The hostname is the running disposable's Qubes name, normally `dispNNNN`. It is
used as `REPO_VM` in dom0 later. Keep this disposable alive through the
`--fetch-only` step; closing it earlier destroys its checkout.

For ongoing maintenance, repeat this disposable workflow or use a dedicated,
minimal repo qube. Always pass the source qube explicitly with `--repo-vm`.

## 3. Review what will become trusted

Anything in the checkout can ultimately influence dom0 and every qube SEQS
creates. HTTPS and a commit ID are not a security audit.

Before copying anything into dom0:

1. Follow [VERIFY-HUMAN.md](../VERIFY-HUMAN.md), especially “Read what you'll
   run.” It supplies a convenient review order for the runner, pillar, Salt
   states, verification libraries, and selected component installers. Do not
   trust that guide blindly either; check its claims against the code.
2. Read [TRUST.md](../TRUST.md). Items marked ⚠️ or ❌ require an explicit
   decision.
3. Read [architecture.md](architecture.md) for the VM→dom0 transfer, archive
   validation, review gate, and bootstrap-window defense.
4. Compare the complete revision through an independent trusted channel. If the
   chosen revision has a verifiable signature, verify it; do not assume every
   commit is signed.
5. Inspect and test the checkout when dependencies are available:

   ```bash
   cd /home/user/SEQS
   git status
   git diff --check
   ./test/run-tests.sh
   ```

Passing tests detect structural and accidental failures; they do not establish
that the code is benign.

## 4. Configure the build

All software configuration is in:

```text
salt/pillar/seqs/config.sls
```

Edit it inside the disposable:

```bash
cd /home/user/SEQS
vim salt/pillar/seqs/config.sls
```

Save in `vim` by pressing `Esc`, typing `:wq`, and pressing Enter. Do not move
this configuration step into dom0. See [configuration.md](configuration.md) for the
component catalogue, `offline`, `no_handoff`, DisposableVM templates, firewall
rules, and extension settings.

Each qube is an entry in `qube_list`, for example:

```jinja
{%- set qube_list = [
  {'name': 'keepass', 'label': 'black', 'components': ['keepass'], 'offline': True},
  {'name': 'dev-full', 'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode']},
] %}
```

For security-sensitive hardware configuration such as QR transfer, complete
the qualification steps in [secure-qr-transfer.md](secure-qr-transfer.md)
before selecting a mode.

Review the final local changes:

```bash
sed -n '1,230p' salt/pillar/seqs/config.sls
git diff --check
git diff
```

## 5. Copy only the runner into dom0

Assume the disposable reported `disp1234`; replace it with the exact hostname.
In dom0:

```bash
qvm-run -p disp1234 "cat /home/user/SEQS/setup-qubes.sh" 2>/dev/null > ~/s.sh
chmod 700 ~/s.sh
less ~/s.sh
```

The stderr redirection is deliberate: it prevents source-qube terminal-control
bytes from reaching dom0 before the runner's sanitizer exists. See
[architecture.md#bootstrap-window](architecture.md#bootstrap-window).

Review the complete copied runner in `less`; quit with `q`.

## 6. Fetch without applying

Still in dom0, while the disposable remains running:

```bash
~/s.sh --repo-vm disp1234 --fetch-only
```

The runner validates every archive entry, displays the transfer hash, and
installs the tree under `/srv`. On a first install no prior tree exists for a
diff, so the review obligation is particularly important. The hash supports
comparison with an independent trusted copy; a hash produced only from the
download qube does not prove that qube is honest.

Type `CONTINUE` only for content you already intended to trust. After
`--fetch-only` succeeds, shut down the download disposable. Dom0 no longer
needs it.

## 7. Review the installed tree

The exact root-owned code that will run is now under `/srv`. At minimum inspect:

```bash
sudo less /srv/pillar/seqs/config.sls
sudo less /srv/salt/seqs/dom0.sls
sudo less /srv/salt/seqs/qube.sls
```

Use the fuller file order in [VERIFY-HUMAN.md](../VERIFY-HUMAN.md). Confirm the
installed bytes match the revision and machine configuration you approved.

## 8. Apply locally

Apply without contacting any repo/download qube:

```bash
~/s.sh --skip-fetch
```

Watch for:

- policy-takeover prompts;
- the independent air-gap verification;
- failed Salt states or non-zero failure summaries; and
- component key/signature checks documented in `VERIFY-HUMAN.md`.

Re-runs converge after a failure; fix the reported cause and rerun
`--skip-fetch`. Some applications require a one-time app-qube reboot.

## 9. Verify before use

Complete the post-install checks in [VERIFY-HUMAN.md](../VERIFY-HUMAN.md):
verify the expected qubes, labels, templates, NetVM settings, `seqs-managed`
features, policies, application launches, and cleanup behavior. Do not place
secrets in the new qubes before those checks pass.

For future repository or configuration changes, use
[upgrading.md](upgrading.md), not this first-install workflow.
