# First SEQS installation

This is the expanded walkthrough behind the README's minimal command path. It
explains how to obtain, review, select, fetch, and apply SEQS without using a
daily qube as the bootstrap source.

## 1. Install and verify Qubes OS

Follow [install-qubes.md](install-qubes.md) and the
[official Qubes OS documentation](https://doc.qubes-os.org/). In summary:

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

## 4. Choose the build selection

The reviewed checkout already contains the available definitions in:

```text
salt/pillar/seqs/config.sls
```

Do **not** edit this file merely to choose what to install. Decide which
catalogue base names you want, then pass them to the runner later in dom0:

```bash
~/s.sh --build-only --qubes brave,signal,keepass
```

Each available qube is an entry in `qube_catalog`. Selection supplies base
names only; it cannot alter reviewed labels, components, or security flags.
Use `--all` only when you deliberately want the entire catalogue. See
[configuration.md](configuration.md) for the available components and exact
selection semantics.

Editing `config.sls` remains necessary only for advanced customization of the
definitions themselves—such as adding a new component combination, changing a
base template, or configuring qualified secure-QR hardware. Such an edit
changes the reviewed *tree* — the directory of Salt state, pillar, and
component-script files SEQS transfers and applies as a unit — and must be
reviewed, fetched, and staged normally.
For example, catalogue definitions have this form:

```jinja
{%- set qube_catalog = [
  {'name': 'keepass', 'label': 'black', 'components': ['keepass'], 'offline': True},
  {'name': 'dev-full', 'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode']},
] %}
```

For security-sensitive hardware configuration such as QR transfer, complete
the qualification steps in [secure-qr-transfer.md](secure-qr-transfer.md)
before selecting a mode.

For an unmodified ordinary install, confirm that the checkout remains clean:

```bash
git diff --check
git status --short                  # expected output: nothing
```

## 5. Copy only the runner into dom0

Assume the disposable reported `disp1234`; replace it with the exact hostname.
In dom0:

```bash
qvm-run -p disp1234 "cat /home/user/SEQS/setup-qubes.sh" 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
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
saves the result under `/var/lib/seqs/fetched`. The hash supports
comparison with an independent trusted copy; a hash produced only from the
download qube does not prove that qube is honest.

After `--fetch-only` succeeds, shut down the download disposable. Dom0 no
longer needs it.

`/var/lib/seqs/fetched` is a SEQS-owned review area, not an active Salt tree.
No qubes are created and no Salt state is applied during this step.

## 7. Review and stage the fetched tree

The validated fetched data is root-owned but readable by the normal dom0 user
under `/var/lib/seqs/fetched`. This *tree* — the directory of Salt state,
pillar, and component-script files under `/var/lib/seqs/fetched` — is what will
be staged and run, so reviewing it here is the authoritative review.

### Understand the fetched layout

The fetcher copies the repository completely but not verbatim. It transfers all
of `salt/` and `install-scripts/` — always the full catalogue and every
component script, never narrowed by `--qubes` (which selects only what the later
build creates) — and then *remaps* those files into the layout Qubes Salt
expects under `/srv`:

| Fetched path | Comes from the repository's |
|---|---|
| `/var/lib/seqs/fetched/pillar/` | `salt/pillar/seqs/` |
| `/var/lib/seqs/fetched/salt/` | `salt/seqs/` |
| `/var/lib/seqs/fetched/salt/files/lib`, `.../files/components` | `install-scripts/lib`, `install-scripts/components` |

Because the contents are complete, every fetched file does correspond to a file
in the checkout — so it is the *rearrangement* (folders remapped, and the
component payload from `install-scripts/` overlaid under `salt/files/`), not any
selection, that stops a single top-level `diff` from lining up; there is no
`.git` here to run `git` against either. You do not have to reconcile the
mapping by hand: the `Content SHA256` check below applies it for you. The
`.seqs-managed` and `.seqs-complete` markers are added by SEQS and are not part
of the repository.

### Read the fetched tree

These are [Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html)
files (`.sls`) that run as root in dom0. If Salt is unfamiliar, first skim how
[states](https://docs.saltproject.io/en/latest/topics/states/index.html) declare
the target configuration, how
[pillar](https://docs.saltproject.io/en/latest/topics/pillar/index.html) supplies
per-qube data, and how
[Jinja](https://docs.saltproject.io/en/latest/topics/jinja/index.html) templates
render them — the `{%- ... %}` and `{{ ... }}` markup you will see. At minimum
inspect:

```bash
less /var/lib/seqs/fetched/pillar/config.sls   # catalogue and all input data
less /var/lib/seqs/fetched/salt/dom0.sls        # dom0: validation, policy, qube creation
less /var/lib/seqs/fetched/salt/qube.sls        # provisioning inside each qube
```

What to look for in each:

- **`pillar/config.sls`** — the reviewed catalogue: prefixes, `base_template`,
  `browser_vm`, and each `qube_catalog` entry's label, components, and
  `offline`/`no_handoff` flags. Confirm the labels and flags match the trust you
  intend — e.g. `keepass` is marked `offline` (no NetVM), and the hardware-wallet
  qubes are marked `no_handoff`, which blocks them from handing web links off to
  the networked browser qube (a qrexec exfiltration path a firewall cannot gate).
- **`salt/dom0.sls`** — the privileged code: the pre-flight validation block, the
  generated qrexec policy, the no-clobber guard, and qube creation. Check that
  each policy grants only the narrow access it describes and that no pillar value
  reaches a shell command unquoted.
- **`salt/qube.sls`** — what is installed inside each template and app qube. Then
  read the matching component installers under
  `/var/lib/seqs/fetched/salt/files/components/<name>/` for the qubes you will
  build — pay special attention to any download, added repository, or signing key,
  and confirm each is pinned and honestly described in [TRUST.md](../TRUST.md).

Watch for: a NetVM or OpenURL handoff on a qube meant to be `offline`; a download
with no pinned version or verified signature; a qrexec policy broader than the
feature needs; and untrusted strings interpolated into a shell or Salt command.

For the fuller file-by-file order and rationale, use
[VERIFY-HUMAN.md](../VERIFY-HUMAN.md) §2; for how the pieces fit together, read
[architecture.md](architecture.md); for what each catalogue option means, read
[configuration.md](configuration.md).

### Tie the fetched tree to the revision you approved

Reviewing the tree tells you what the code does; the two outputs you already
collected let you anchor that review to a revision you can corroborate with
others. Use both:

1. **Corroborate the revision (from step 2).** The disposable printed
   `Revision to verify: <40-hex>`. Compare that commit ID against an independent
   trusted channel — a second device, network path, or a copy someone you trust
   obtained separately — and, if the revision carries a verifiable signature,
   verify it. This is the only step that speaks to whether the *source* is
   trustworthy; HTTPS and a matching hash do not.

2. **Confirm the fetched bytes are that revision.** `--fetch-only` prints a
   `Content SHA256` and records it in `/var/lib/seqs/fetched/content-sha256`.
   This is a layout-independent digest of the fetched file *contents at their
   repository-relative paths*, so — unlike the dom0-local `Staged tree SHA256`
   or the tar-stream `Transfer SHA256` — you can reproduce it from a plain
   checkout with **one** command and no need to recreate any dom0 layout.

   On your independent checkout at the approved commit (`git checkout <revision>`):

   ```bash
   find salt/seqs salt/pillar/seqs install-scripts/lib install-scripts/components \
     -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
   ```

   If that value equals the `Content SHA256` the runner printed, the fetched
   files are exactly the contents — and repository paths — of the revision you
   approved. Because the digest is keyed by path, it catches a changed *or*
   moved file; combined with your direct review and the fetcher's rejection of
   any unexpected path, a match settles this step. To recheck the recorded value
   later, `cat /var/lib/seqs/fetched/content-sha256`; `--stage-only` reprints it
   too.

The `Transfer SHA256` from step 6 is a different, weaker artifact: the hash of
the tar stream the source qube produced. You can reproduce it *inside that qube
while it is still running* (`tar -C /home/user/SEQS -cf - salt install-scripts |
sha256sum`) to confirm dom0 received exactly the bytes it sent, but that only
proves faithful transport from the same unauthenticated origin, and it is not
reproducible on a second machine because archive ordering and timestamps vary.
Prefer the `Content SHA256` above for independent verification.

Once the review passes and the digest matches, place the reviewed tree under
`/srv`:

```bash
~/s.sh --stage-only
```

`/srv` is not a SEQS product name. It is the standard location used by
[Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html):
states live under `/srv/salt` and pillar configuration under `/srv/pillar`.
SEQS owns only the `seqs` subdirectories. Staging makes the reviewed files
available to `qubesctl`; it still does not create or provision any qube.

The staged `/srv/salt/seqs` and `/srv/pillar/seqs` trees are also readable
without `sudo`; root ownership prevents the dom0 user from changing them.

### Verify the staged tree

Staging is a plain copy from `/var/lib/seqs/fetched` into `/srv`, so verifying it
means confirming two things: the staged tree is exactly the fetched tree you
already reviewed and hashed, and it is root-owned so nothing can alter it before
the build reads it. In dom0:

1. **Staged matches fetched.** Both use the same layout, so compare them directly.
   Use `sudo` (the tree is root-owned, and `/srv` may not be traversable
   otherwise); exclude the `.seqs-complete` marker that staging adds, exactly as
   the runner's own preview does:

   ```bash
   sudo diff -r --exclude=.seqs-complete /var/lib/seqs/fetched/salt   /srv/salt/seqs
   sudo diff -r --exclude=.seqs-complete /var/lib/seqs/fetched/pillar /srv/pillar/seqs
   ```

   No output means the staged files are byte-for-byte the fetched tree whose
   `Content SHA256` you verified above — nothing was substituted between review
   and staging. Re-running `~/s.sh --stage-only` performs the same comparison for
   you: it reports `Fetched tree is identical to the tree already staged in /srv.`
   and reprints the recorded `Content SHA256`.

2. **Root-owned and not user-writable.** Confirm the dom0 user cannot modify the
   staged tree before the build consumes it:

   ```bash
   ls -ld /srv/salt/seqs /srv/pillar/seqs
   sudo find /srv/salt/seqs /srv/pillar/seqs \( ! -user root -o -perm /go+w \)
   ```

   Expect `root root` on both directories and no output from `find` — nothing is
   owned by a non-root user, and nothing is group- or other-writable, so the
   staged tree the build reads cannot be altered from the dom0 user account. SEQS
   owns only these `seqs` subdirectories; the rest of `/srv/salt` and
   `/srv/pillar` is left as Qubes shipped it.

## 8. Build the qubes

Build without contacting any repo/download qube:

```bash
~/s.sh --build-only --qubes brave,signal,keepass
```

Watch for:

- the staged-tree hash, build-plan hash, and requested names matching your intent;
- policy-takeover prompts;
- the independent air-gap verification;
- failed Salt states or non-zero failure summaries; and
- component key/signature checks documented in `VERIFY-HUMAN.md`.

Re-runs converge after a failure; fix the reported cause and rerun
`--build-only` with the same explicit selection. Some applications require a
one-time app-qube reboot.

## 9. Verify before use

Complete the post-install checks in [VERIFY-HUMAN.md](../VERIFY-HUMAN.md):
verify the expected qubes, labels, templates, NetVM settings, `seqs-managed`
features, policies, application launches, and cleanup behavior. Do not place
secrets in the new qubes before those checks pass.

For future repository or configuration changes, use
[upgrading.md](upgrading.md), not this first-install workflow.
