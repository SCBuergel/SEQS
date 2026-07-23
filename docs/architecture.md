# How the SEQS runner works

`setup-qubes.sh` is a thin dom0 entry point around
[Qubes Salt](https://doc.qubes-os.org/en/latest/user/advanced-topics/salt.html),
the Qubes-native configuration-management stack. This document explains its
data flow and controls. For the per-component trust analysis see
[TRUST.md](../TRUST.md).

## What the runner does, in order

1. **Fetch (once).** The runner requires the full reviewed Git object ID as
   `--commit`. In `REPO_VM`, it verifies that object resolves to a commit and
   runs `git archive` for that commit's `salt/` + `install-scripts/` paths,
   never the live working tree. Every archive entry is validated before
   extraction
   (regular files/dirs only — no symlinks/hardlinks/devices — paths rooted at
   `salt/` or `install-scripts/`, safe charset, no `..`, no absolute paths).
   This is the **only** VM→dom0 data flow in the whole system. The transfer
   SHA256 is printed as a diagnostic; integrity is anchored by the git commit
   hash the operator verifies in the disposable, which covers the whole
   repository. The bootstrap command likewise obtains `setup-qubes.sh` with
   `git show <COMMIT>:setup-qubes.sh`.

2. **Stage.** `--fetch-only` saves validated data under
   `/var/lib/seqs/fetched` for review. `--stage-only` requires a completed fetch,
   shows the diff, and copies the reviewed Salt and pillar trees into `/srv`.

3. **Build.** `--build-only` requires a completed stage, plus either
   `--qubes NAME[,NAME...]` or explicit `--all`, and has no dependency
   on `REPO_VM`. It first applies dom0 (`qubesctl state.apply seqs.dom0`), which
   validates the whole catalogue and the runtime selection up front, installs
   the applicable qrexec policies, clones selected templates and creates
   selected app qubes — declaratively and idempotently. Pre-existing qubes NOT
   created by SEQS are refused via the `seqs-managed` qvm-feature guard (with
   intent markers so an interrupted run can be resumed, not locked out).
   Air-gapped (`offline`) qubes are independently re-verified by the runner
   before anything is provisioned.

   It then applies qubes (`qubesctl --skip-dom0 --targets=... state.apply seqs.qube`):
   provisions each template, then each app qube. Qubes Salt runs this through a
   **disposable management VM** over qrexec: dom0 pushes states and files down;
   dom0 never executes, parses, or interpolates anything a target qube produces.
   (qubesctl's own summary output is still routed through the runner's terminal
   sanitizer.)

## Why fetched data and `/srv` are separate

The three locations represent different trust and execution states:

| Location | Meaning |
|---|---|
| Repository qube | Network-fetched source; not present in dom0 yet |
| `/var/lib/seqs/fetched` | Validated SEQS review copy; not active in Salt |
| `/srv/salt/seqs` and `/srv/pillar/seqs` | Reviewed tree staged for `qubesctl` |
| `/var/lib/seqs/selection` | Root-owned intent for the current build; not part of the staged tree |
| `/var/lib/seqs/last-run` | Tree hash, plan hash, canonical selection, and result |

Qubes Salt convention—not SEQS naming—defines `/srv/salt` as the state root
and `/srv/pillar` as the pillar root. The runner uses `mkdir -p`, so it can
create missing `/srv` ancestors defensively, but it claims and replaces only
the `seqs` leaves carrying its management markers. Fetching alone cannot make
Salt see the data; staging alone cannot create qubes; only the build stage runs
`qubesctl`.

## Convergence

Re-running `setup-qubes.sh` converges: finished components are skipped via
completion markers in `/rw/config/seqs/`, existing qubes are reconfigured rather
than rebuilt, and qubes not created by SEQS are refused (no-clobber via the
`seqs-managed` qvm-feature). Catalogue entries omitted from a run are left
untouched; omission is never interpreted as deletion.

Convergence is deliberately non-destructive: removing configuration does not
automatically uninstall components or delete qubes, and changed component
installers remain skipped while their completion markers exist. See
[upgrading.md](upgrading.md) for the supported update procedure and exact
behavior by change type.

## Bootstrap window

The dom0 one-liner that copies the committed `setup-qubes.sh` object out of the
repo qube appends
`2>/dev/null` to the `qvm-run` step deliberately. The fetch happens **before**
`setup-qubes.sh` exists in dom0 (and therefore before its `sanitize()` terminal
filter is available), so any bytes the source qube writes to stderr would land
directly on the dom0 terminal. A compromised repo qube could otherwise emit
ANSI / CSI / OSC sequences (window-title smuggling, OSC 52 clipboard write,
repaint of earlier lines) during `git show`. Dropping stderr closes that
bootstrap window; if the export fails, `s.sh` ends up empty/partial and
`./s.sh` fails loudly on its own. The runner reuses the same defense on its own
fetch and routes every later display path through `sanitize()`.

Neither operation makes Git or `REPO_VM` independently verifiable by dom0.
A compromised source qube can lie about what `git show` or `git archive`
returned. Commit-object export prevents accidental or local working-tree drift;
the source qube remains an explicit trust assumption.

## Composition model

Every qube the setup builds is composed from one or more **components** in
`install-scripts/components/<name>/`. Single-tool qubes are 1-component;
mix-and-match qubes (wallet, developer) list several. The `seqs.dom0` state
clones the base template and creates the app qube; the `seqs.qube` state then
runs each component's `template-vm.sh` (system-wide install) in the template,
installs any `menu.desktop` it carries, runs each `app-vm.sh` (per-app-qube
setup) in the app qube, and wires up the browser-link policy and cleanup
service. See [configuration.md](configuration.md) for ordinary runtime
selection and for advanced catalogue extension.
