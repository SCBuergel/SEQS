# Upgrading an existing SEQS installation

Use this procedure when Qubes was already configured by SEQS and you want to
apply a newer repository revision or change `salt/pillar/seqs/config.sls`—for
example, to add newly introduced USB/QR qubes.

An upgrade does **not** require reinstalling Qubes OS. The SEQS runner is
convergent: it stages a newly reviewed Salt tree in dom0, creates missing
managed qubes, and reapplies supported settings to existing managed qubes.

## Understand the three copies

An installed system normally has three relevant copies:

1. The repository checkout in `REPO_VM`, such as
   `personal:/home/user/SEQS`. This should be the long-term source of truth.
2. A small runner copied into dom0 as `s.sh`.
3. The root-owned tree currently staged in dom0 under `/srv/salt/seqs` and
   `/srv/pillar/seqs`.

Update and configure the repository copy first. Always copy the new
`setup-qubes.sh` into dom0 as part of an upgrade: an old dom0 runner may not
understand new state files, validation, or upgrade behavior. A subsequent stage
replaces the `/srv` tree, so direct edits under `/srv` are temporary
unless also made in the repository source of truth.

## 1. Update and configure the repository qube

In the qube holding the repository:

```bash
cd /home/user/SEQS
git status
git fetch --all --prune
git log --oneline --decorate --max-count=10
```

Review and check out the intended, independently verified revision using your
normal Git workflow. Do not blindly discard local changes: the checkout may
contain your machine-specific `config.sls`. Merge the upstream changes with
that configuration and inspect the final result:

```bash
git diff
sed -n '1,230p' salt/pillar/seqs/config.sls
```

Run the offline tests in the repository qube when their dependencies are
available:

```bash
./test/run-tests.sh
```

The repo qube supplies code that will run as root through Qubes Salt and must be
treated as part of the build's trust path. A Git commit identifier by itself is
not authentication; verify the revision by a trusted independent method.

## 2. Copy the current runner into dom0

The following example assumes a dedicated repo qube named `seqs-repo` and the
standard path `/home/user/SEQS`. Replace `seqs-repo` with the exact source-qube
name. A fresh temporary DisposableVM is also suitable; keep it alive through
`--fetch-only`. In dom0:

```bash
qvm-run -p seqs-repo "cat /home/user/SEQS/setup-qubes.sh" 2>/dev/null > ~/s.sh
chmod 700 ~/s.sh
```

The `2>/dev/null` is a security boundary: untrusted source-qube stderr must not
reach the dom0 terminal during the bootstrap window. Before execution, review
the copied runner and, preferably, compare it with the same verified revision
on an independent machine.

If the repository is in a temporary DisposableVM, replace `seqs-repo` in both
commands with its exact `dispNNNN` name and keep it running until the fetch in
the next step finishes. Once the fetch completes, it is no longer needed.

## 3. Fetch and review without applying

In dom0:

```bash
~/s.sh --repo-vm seqs-repo --fetch-only
```

The runner validates every archive entry, displays the transfer hash, and saves
the fetched data under `/var/lib/seqs/fetched` without building qubes.

Inspect the fetched result as the normal dom0 user:

```bash
less /var/lib/seqs/fetched/pillar/config.sls
less /var/lib/seqs/fetched/salt/dom0.sls
```

The transfer hash detects accidental differences and supports comparison with
an independent trusted copy. A hash produced only by the source repo qube does
not prove that a compromised source is honest.

## 4. Stage and build the reviewed local tree

The repo qube can be shut down after `--fetch-only`. In dom0:

```bash
~/s.sh --stage-only
~/s.sh --build-only --qubes brave,signal
```

Before replacing anything, `--stage-only` displays a recursive diff between
the reviewed fetched copy in `/var/lib/seqs/fetched` and the Salt tree currently
active under `/srv`. This preview shows changes to Salt states, component
scripts, and pillar configuration; it does not describe changes to installed
qubes. No diff means the two trees are identical, while "is not yet staged" is
expected for a tree being installed for the first time. A comparison or
permission error aborts staging instead of being treated as a difference.

These commands stage `/srv` and build without contacting `REPO_VM`. The runner:

1. validates configuration and applies dom0 policies/preferences;
2. creates missing templates and app qubes without adopting unrelated
   same-named VMs;
3. verifies every selected offline app qube has no NetVM;
4. provisions templates and shuts them down to commit their root volumes; and
5. provisions app qubes and shuts them down.

If a state fails, fix the reported cause and rerun the same `--build-only`
command with the same selection. Completed work is normally skipped.

## 5. Verify the intended change

Verify the specific outcome instead of treating a successful summary as the
only check. Useful examples include:

```bash
qvm-ls
qvm-prefs <qube> netvm
qvm-prefs <qube> template
qvm-features <qube> seqs-managed
```

For security-sensitive additions, follow their own post-install checklist. The
USB/QR setup has hardware and policy checks in
[secure-qr-transfer.md](secure-qr-transfer.md).

## What convergence does and does not do

| Repository/configuration change | Upgrade behavior |
|---|---|
| Add a new `qube_catalog` entry and select it | Creates and provisions its missing `Z-*` and `A-*` qubes |
| Change a supported label, offline flag, firewall, policy, or generated dom0 file | Reapplies the declared setting |
| Add a component to an existing qube | Runs the new component because it has no completion marker |
| Change an installer script for a component already completed | Skipped until its completion marker is deliberately removed |
| Remove a component from a qube | Stops managing it; does not uninstall its existing software or data |
| Remove a qube from `qube_catalog` | Makes it unavailable to future runs; does not delete the existing VM |
| Change `base_template` | Affects newly cloned templates; does not replace existing managed templates |

These conservative rules avoid silently deleting qubes, software, or data.

### Deliberately rerunning a changed component

Component completion markers live under `/rw/config/seqs/`. After reviewing a
changed installer, remove only the marker for that component and role, then
rerun `--build-only`. For example, to rerun the `qr-camera` template installer:

```bash
qvm-run -u root Z-qr-camera 'rm -f /rw/config/seqs/qr-camera.template.done'
qvm-shutdown --wait Z-qr-camera
~/s.sh --build-only --qubes qr-camera
```

An app-qube marker uses `.app.done` instead of `.template.done`. Do not delete
all markers casually: that may rerun network downloads, package installation,
or per-qube initialization that was designed as a one-time action.

### Removing or rebuilding managed qubes

Removing an entry from configuration is intentionally non-destructive. If you
intend to destroy its qubes, copy the reviewed helper into dom0 and inspect
with a dry run:

```bash
qvm-run -p seqs-repo "cat /home/user/SEQS/delete-vms.sh" 2>/dev/null > ~/seqs-delete-vms.sh
chmod 700 ~/seqs-delete-vms.sh
~/seqs-delete-vms.sh --dry-run <base-name>
```

The destructive form removes both `A-<base-name>` and `Z-<base-name>` and their
data. Use it only after backups and explicit review. Rebuilding a qube is not a
routine upgrade step.

## Example: add USB/QR support to an existing desktop

After updating the checkout to a revision containing the QR setup, complete the
hardware qualification at the start of
[secure-qr-transfer.md](secure-qr-transfer.md#start-here-determine-which-path-the-machine-qualifies-for).
Then edit the repository's `salt/pillar/seqs/config.sls`.

For a separately isolated webcam controller:

```jinja
{%- set webcam_usb_mode = 'dedicated' %}
{%- set webcam_usb_controller = '03_00.0' %}  {# use the verified BDF #}
```

For a shared controller that qualifies only for the reduced-assurance,
power-off-based fallback:

```jinja
{%- set webcam_usb_mode = 'sequential' %}
{%- set webcam_usb_controller = '00_14.0' %}  {# use the verified BDF #}
{%- set webcam_usb_no_strict_reset = False %}
```

Then perform the normal upgrade steps above: copy the new runner, fetch with
`--fetch-only`, review the fetched tree, stage with `--stage-only`, and build
with `--build-only`.

Expected new managed qubes are:

```text
Z-qr-display    A-qr-display
Z-qr-camera     A-qr-camera
Z-qr-staging    A-qr-staging
```

An active webcam mode also creates `sys-usb-webcam`; sequential mode creates
`seqs-qr-scanner` and installs `/usr/local/sbin/seqs-qr-sequential`. Do not run
the ceremony until the post-install checks in the QR guide pass on real Qubes
hardware.
