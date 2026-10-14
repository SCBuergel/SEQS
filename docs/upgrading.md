# Upgrading an existing SEQS installation

Use this procedure when Qubes was already configured by SEQS and you want to
apply a newer repository revision or intentionally change an advanced setting
in `salt/pillar/seqs/config.sls`.

An upgrade does **not** require reinstalling Qubes OS. The SEQS runner is
convergent: it stages a newly reviewed Salt tree in dom0, creates missing
managed qubes, and reapplies supported settings to existing managed qubes.

## Understand the three copies

An installed system normally has three relevant copies:

1. The repository checkout in the repository qube (the one you pass to
   `--repo-vm`), such as
   `seqs-repo:/home/user/SEQS`. This should be the long-term source of truth.
2. A small runner copied into dom0 as `s.sh`.
3. The root-owned tree currently staged in dom0 under `/srv/salt/seqs` and
   `/srv/pillar/seqs`.

Update and review the repository copy first. Always copy the new
`setup-qubes.sh` into dom0 as part of an upgrade: an old dom0 runner may not
understand new state files, validation, or upgrade behavior. A subsequent stage
replaces the `/srv` tree, so direct edits under `/srv` are temporary
unless also made in the repository source of truth.

## 1. Update and review the repository qube

In the qube holding the repository:

```bash
cd /home/user/SEQS
git status
git fetch --all --prune
git log --oneline --decorate --max-count=10
```

Review and check out the intended, independently verified revision using your
normal Git workflow. Qube selection is no longer a repository edit; choose the
run's entries later with `--qubes`. A normal checkout should therefore remain
clean. If you deliberately maintain machine-specific hardware settings or
custom catalogue definitions, do not blindly discard them: merge and inspect
those advanced changes explicitly.

```bash
git diff
less salt/pillar/seqs/config.sls
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
qvm-run -p seqs-repo "git -C /home/user/SEQS show HEAD:setup-qubes.sh" 2>/dev/null > ~/s.sh && chmod 700 ~/s.sh
```

The repository qube must already have the independently reviewed revision
checked out. Using `git show HEAD:` copies from that commit object instead of
the repository qube's live working tree. The `2>/dev/null` is a security
boundary: untrusted source-qube stderr must not reach the dom0 terminal during
the bootstrap window. Before execution, review the copied runner and,
preferably, compare it with the same verified revision on an independent
machine.

If the repository is in a temporary DisposableVM, replace `seqs-repo` in this
command and in the fetch command of the next step with its exact `dispNNNN` name and keep it running until the fetch in
the next step finishes. Once the fetch completes, it is no longer needed.

## 3. Fetch and review without applying

In dom0:

```bash
~/s.sh --repo-vm seqs-repo --fetch-only
```

The runner resolves the repository qube's checked-out `HEAD`, validates that
the answer is a full object ID, and asks Git to archive that exact commit's
`salt/` and `install-scripts/` paths. It validates every archive entry, records
the source-reported ID in
`/var/lib/seqs/fetched/source-commit`, displays the transfer hash, and saves the
fetched data without building qubes. Dom0 does not independently compare this
ID with the revision you reviewed, so confirm the recorded value yourself
before staging.

Inspect the fetched result as the normal dom0 user:

```bash
less /var/lib/seqs/fetched/pillar/config.sls
less /var/lib/seqs/fetched/salt/dom0.sls
cat /var/lib/seqs/fetched/source-commit
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

Select every qube you want upgraded; an omitted one is left as it is. The
`selection=` line of `/var/lib/seqs/last-run` lists the previous run's qubes.

Before replacing anything, `--stage-only` prints a recursive diff between
the reviewed fetched copy in `/var/lib/seqs/fetched` and the Salt tree currently
active under `/srv`. This preview shows changes to Salt states, component
scripts, and pillar configuration; it does not describe changes to installed
qubes. No diff means the two trees are identical, while "is not yet staged" is
expected for a tree being installed for the first time. It stages right after
printing, without asking, so review the fetched tree before running it. A
comparison or permission error aborts staging instead of being treated as a
difference.

These commands stage `/srv` and build without contacting the repository qube.
The runner:

1. validates configuration and applies dom0 policies/preferences;
2. creates missing templates and app qubes without adopting unrelated
   same-named VMs;
3. verifies every selected offline app qube and named disposable has no NetVM
   and no default disposable;
4. provisions templates and shuts them down to commit their root volumes;
5. provisions app qubes and shuts them down; and
6. adds or refreshes the dom0 panel launcher of each app qube and named
   disposable it built ([panel launchers](configuration.md#panel-launchers)).

If a state fails, fix the reported cause and rerun the same `--build-only`
command with the same selection. Completed work is normally skipped.

An optional postfix identifies a separate managed instance of every selected
recipe:

```bash
~/s.sh --build-only --qubes gnosisvpn,signal --postfix alpha
```

Rerun that exact selection and postfix to upgrade or repair the `*-alpha`
instances. A run without the postfix continues to target only the canonical
instances. Existing managed templates and app qubes are reported and reconciled in
place; neither form overwrites or reclones them.

## 5. Verify the intended change

Verify the specific outcome instead of treating a successful summary as the
only check. Useful examples, in a dom0 terminal:

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
| Select recipes with `--postfix NAME` | Creates or converges separate `Z-<recipe>-NAME` and `A-<recipe>-NAME` instances |
| Change a supported label, firewall, policy, or generated dom0 file, or add `offline` | Reapplies the declared setting |
| Remove `offline` | Keeps the qube without a NetVM and default disposable (set them with `qvm-prefs` if you want it networked), but re-enables link handoff and disposables unless `no_handoff` or `firewall` is set |
| Add a component to an existing qube | Runs the new component because it has no completion marker |
| Change a component's files (installer, pinned version, key) or the shared libraries | Runs the component again over its earlier installation |
| Rerun with no change to a component | Skips it: its completion marker records the same content hash |
| Remove a component from a qube | Stops managing it; does not uninstall its existing software or data |
| Omit a catalogue entry from `--qubes` | Does not target or recreate its VMs; only updates their link-handoff tag |
| Remove a qube from a custom `qube_catalog` | Makes it unavailable to future selections; does not delete the existing VM |
| Change `base_template` | Affects newly cloned templates; does not replace existing managed templates |

These conservative rules avoid silently deleting qubes, software, or data.

### How a completion marker decides

Each finished component leaves a marker under `/rw/config/seqs/`
(`<component>.template.done` in the template, `<component>.app.done` in the app
qube) that holds the SHA-256 of everything staged for that component: its
scripts and assets plus the shared libraries in `install-scripts/lib/`. A run
skips the component while that hash still matches and runs it again when it
does not. Markers written before this rule existed are empty, so the first
build after upgrading SEQS runs every selected component once more.

Every component script must therefore be safe to run over its earlier
installation. To force one component to run again without a change, empty its
marker and rerun the build, for example in a dom0 terminal:

```bash
qvm-run -u root Z-qr-camera ': > /rw/config/seqs/qr-camera.template.done'
qvm-shutdown --wait Z-qr-camera
~/s.sh --build-only --qubes qr-camera
```

### Removing or rebuilding managed qubes

Removing an entry from configuration is intentionally non-destructive. If you
intend to destroy its qubes, copy the reviewed helper into dom0 and inspect
with a dry run, in a dom0 terminal:

```bash
qvm-run -p seqs-repo "git -C /home/user/SEQS show HEAD:delete-vms.sh" 2>/dev/null > ~/d.sh && chmod 700 ~/d.sh
~/d.sh --dry-run <base-name>
```

The destructive form removes `D-<base-name>` (if it exists), `A-<base-name>`,
and `Z-<base-name>` with their data. Use it only after backups and explicit review. Rebuilding a qube is not a
routine upgrade step.

## Example: add USB/QR support to an existing desktop

After updating the checkout to a revision containing the QR setup, complete the
hardware qualification at the start of
[secure-qr-transfer.md](secure-qr-transfer.md#choose-the-hardware-isolation-path).
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
{%- set webcam_usb_no_strict_reset = False %}  {# True only without a reset method #}
```

Then perform the normal upgrade steps above: verify and check out the reviewed
commit, copy its `HEAD` runner, fetch with `--repo-vm <VM> --fetch-only`,
review the fetched tree, stage with `--stage-only`, and build
with `--build-only --qubes qr-camera,qr-display,qr-staging` (omit
`qr-staging` in dedicated mode if it is not otherwise wanted).

Expected new managed qubes are:

```text
Z-qr-display    A-qr-display    D-qr-display
Z-qr-camera     A-qr-camera
Z-qr-staging    A-qr-staging
```

`D-qr-display` is a named disposable derived from the `A-qr-display` dispvm
template so the display ceremony is launchable from the Qubes menu (a bare
dispvm template only appears under "Templates").

An active webcam mode also creates `sys-usb-webcam` and `seqs-qr-scanner`;
sequential mode also installs `/usr/local/sbin/seqs-qr-sequential`. Do not run
the ceremony until the post-install checks in the QR guide pass on real Qubes
hardware.
