# First SEQS installation

This walkthrough expands the README's install. §1–§2 apply to every user. The
remaining sections run the same install phase by phase — **fetch → stage →
build**, with `--fetch-only`, `--stage-only`, and `--build-only` — so a
**reviewer** can pause between phases and, before trusting or publishing a
commit, read the code that will run as root in dom0 (the trusted Qubes
administrative domain). Parts that only a reviewer needs are marked *reviewer
only*.

## 1. Install and verify Qubes OS

Follow [install-qubes.md](install-qubes.md) and the
[official Qubes OS documentation](https://doc.qubes-os.org/). In summary:

1. Obtain the Qubes ISO from the official Qubes site.
2. Verify its signature and the Qubes signing-key fingerprint independently.
3. Install Qubes and the `debian-13-xfce` template that SEQS builds on, apply
   all system and template updates, and reboot.

SEQS cannot compensate for an untrusted Qubes installation or dom0.

## 2. Download into a temporary DisposableVM

From the Qubes menu, start a fresh, networked Debian DisposableVM (a throwaway
qube deleted when it shuts down) and open a terminal in it. Keep that terminal
open until the install, or the `--fetch-only` step, finishes: closing the
disposable's last terminal shuts it down and deletes the checkout. Do not use a
daily `personal` qube: a disposable keeps the checkout away from personal data,
though it does not authenticate what GitHub served.

In the disposable's terminal:

```bash
git clone https://github.com/SCBuergel/SEQS.git   # skip if done in README step 2
cd SEQS
git checkout <COMMIT>               # the commit your trusted source published
git status --short                  # expected output: nothing
git rev-parse HEAD                  # must equal the published commit hash
hostname                            # the disposable's name, used as --repo-vm in dom0
```

Any output from `git status --short` needs investigation. Stop if the hash
differs. A Git commit hash covers every file in the commit, including
`setup-qubes.sh`, so a match proves you have exactly the published commit — not
that the code is safe; that judgment is the reviewer's. Take the hash from
someone you trust through a channel other than GitHub: a hash from the
repository's own page proves only that GitHub served a self-consistent tree. If
no one you trust publishes a hash, become the reviewer with
[VERIFY-HUMAN.md](../VERIFY-HUMAN.md) and continue with §3.

If the hash matches one published by a reviewer you trust, return to
[README step 3](../README.md#install-for-users).

## 3. Review what will become trusted (reviewer only)

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
   validation, and bootstrap-window defense.
4. If the chosen commit has a verifiable signature, verify it; do not assume
   every commit is signed.
5. Run the test suite. It needs `python3-jinja2` and `python3-yaml`. In the
   disposable's terminal:

   ```bash
   sudo apt-get install python3-jinja2 python3-yaml
   ./test/run-tests.sh
   ```

Passing tests detect structural and accidental failures; they do not establish
that the code is benign.

## 4. Choose the build selection

The reviewed checkout contains the available definitions in
`salt/pillar/seqs/config.sls`. Do **not** edit this file merely to choose what
to install: you pass catalogue base names to the runner with `--qubes` in §8.
Selection supplies base names only; it cannot alter reviewed labels,
components, or security flags. Use `--all` only when you deliberately want the
entire catalogue. See [configuration.md](configuration.md) for the available
components and exact selection semantics.

Editing `config.sls` is necessary only to customize the definitions themselves,
such as adding a new component combination, changing the base template, or
configuring qualified secure-QR hardware. Such an edit changes the *tree* (the
Salt state, pillar, and component-script files SEQS transfers and applies as a
unit) and must be committed, reviewed, fetched, and staged normally. Catalogue
definitions have this form:

```jinja
{%- set qube_catalog = [
  {'name': 'keepass', 'label': 'black', 'components': ['keepass'], 'offline': True},
  {'name': 'claude-code', 'label': 'orange', 'components': ['claude-code']},
  {'name': 'dev-full', 'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code']},
] %}
```

For security-sensitive hardware configuration such as QR transfer, complete
the qualification steps in [secure-qr-transfer.md](secure-qr-transfer.md)
before selecting a mode.

## 5. Copy only the runner into dom0

In a dom0 terminal (open it from the Qubes menu's gear-icon settings section),
replace `disp1234` with the disposable's `hostname` from §2:

```bash
qvm-run -p disp1234 'cd SEQS && git show HEAD:setup-qubes.sh' 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
less ~/s.sh
```

`git show HEAD:` reads the runner from the commit verified in §2, not from the
disposable's live working tree. The stderr redirection is deliberate: it
prevents source-qube terminal-control bytes from reaching dom0 before the
runner's sanitizer exists. See
[architecture.md#bootstrap-window](architecture.md#bootstrap-window). Review the
complete copied runner in `less`; quit with `q`.

## 6. Fetch without applying

In the dom0 terminal, while the disposable remains running:

```bash
~/s.sh --repo-vm disp1234 --fetch-only
```

The runner asks the repository qube to resolve its checked-out `HEAD`, accepts
only a full Git object ID, and then uses `git archive` to export that exact
commit's complete `salt/` and `install-scripts/` paths rather than the
disposable's live working tree. It validates every archive entry, records the
ID in `/var/lib/seqs/fetched/source-commit`, and saves the result under
`/var/lib/seqs/fetched`. No qubes are created and no Salt state is applied.

Dom0 cannot check that ID itself: compare the printed
`==> Fetching salt tree from source HEAD commit <id>` with the hash from §2 and
stop if it differs. The printed `Transfer SHA256` is a diagnostic for logs, not
a second trust anchor.

After `--fetch-only` succeeds, shut down the download disposable. Dom0 no
longer needs it.

## 7. Review and stage the fetched tree

The fetched tree under `/var/lib/seqs/fetched` is root-owned but readable by
the normal dom0 user. It is what will be staged and run, so reviewing it here is
the authoritative review.

### Understand the fetched layout (reviewer only)

The fetcher transfers all of `salt/` and `install-scripts/` — the full
catalogue and every component script, never narrowed by `--qubes` — and remaps
them into the layout Qubes Salt expects under `/srv`:

| Fetched path | Comes from the repository's |
|---|---|
| `/var/lib/seqs/fetched/pillar/` | `salt/pillar/seqs/` |
| `/var/lib/seqs/fetched/salt/` | `salt/seqs/` |
| `/var/lib/seqs/fetched/salt/files/lib`, `.../files/components` | `install-scripts/lib`, `install-scripts/components` |

This remapping, not any selection, is why a single top-level `diff` against
the checkout does not line up; there is no `.git` here either. The
`.seqs-managed` and `.seqs-complete` markers are added by SEQS.

### Read the fetched tree (reviewer only)

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

Dom0 receives whatever the disposable claims `HEAD` and its archive are; a
compromised disposable could lie, so this review of the fetched tree is what
covers the code that will run (see
[architecture.md](architecture.md#what-the-runner-does-in-order)).

### Stage the reviewed tree

When your review is satisfied, in the dom0 terminal:

```bash
~/s.sh --stage-only
```

`/srv` is not a SEQS product name. It is the standard location used by
[Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html):
states live under `/srv/salt` and pillar configuration under `/srv/pillar`.
SEQS owns only the `seqs` subdirectories. Staging makes the reviewed files
available to `qubesctl`; it still does not create or provision any qube.

### Verify the staged tree

Staging is a plain copy from `/var/lib/seqs/fetched` into `/srv`, so verifying it
means confirming two things: the staged tree is exactly the fetched tree you
already reviewed, and it is root-owned so nothing can alter it before the build
reads it. In the dom0 terminal:

1. **Staged matches fetched.** Both use the same layout, so compare them directly.
   Exclude the `.seqs-complete` marker that staging adds, exactly as the
   runner's own preview does:

   ```bash
   diff -r --exclude=.seqs-complete /var/lib/seqs/fetched/salt   /srv/salt/seqs
   diff -r --exclude=.seqs-complete /var/lib/seqs/fetched/pillar /srv/pillar/seqs
   ```

   No output means the staged files are byte-for-byte the fetched tree you
   reviewed — nothing was substituted between review and staging. Re-running
   `~/s.sh --stage-only` performs the same comparison for you: it reports
   `Fetched tree is identical to the tree already staged in /srv.`

2. **Root-owned and not user-writable.** Confirm the dom0 user cannot modify the
   staged tree before the build consumes it:

   ```bash
   ls -ld /srv/salt/seqs /srv/pillar/seqs
   sudo find /srv/salt/seqs /srv/pillar/seqs \( ! -user root -o -perm /go+w \)
   ```

   Expect `root root` on both directories and no output from `find` — nothing is
   owned by a non-root user, and nothing is group- or other-writable, so the
   staged tree the build reads cannot be altered from the dom0 user account.

## 8. Build the qubes

In the dom0 terminal, build without contacting any repository qube:

```bash
~/s.sh --build-only --qubes brave,signal,keepass
```

Watch for:

- no `Overwrite the file(s) above? [y/N]` prompt: it is not expected on a fresh
  install, so if it appears, answer `N` and find out what wrote the file shown;
- `Air gap verified: no netvm and no default disposable on <qubes>.` naming
  every `offline` qube you selected;
- if you add `--verbose`, the `key verified:` and `signature OK --` lines listed in
  [VERIFY-HUMAN.md](../VERIFY-HUMAN.md) §4; and
- the final `==> SEQS setup complete. All targets provisioned.`

`==> SEQS setup finished WITH FAILURES -- see warnings above.` means a run
failed; re-runs converge, so fix the reported cause and rerun `--build-only`
with the same selection. Some applications require a one-time app-qube reboot.

## 9. Verify before use

Complete the post-install checks in [VERIFY-HUMAN.md](../VERIFY-HUMAN.md):
verify the expected qubes, labels, templates, NetVM settings, `seqs-managed`
features, policies, application launches, and cleanup behavior. Do not place
secrets in the new qubes before those checks pass.

For future repository or configuration changes, use
[upgrading.md](upgrading.md), not this first-install workflow.
