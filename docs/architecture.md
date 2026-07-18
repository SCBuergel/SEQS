# How the SEQS runner works

`setup-qubes.sh` is a thin dom0 entry point around the Qubes-native Salt
management stack. It replaces the old imperative installer (a ~1400-line dom0
bash script that repeatedly pulled files from a live app qube and piped VM
output through the dom0 terminal — preserved in git history). This document
explains what it does and why the trust story is better. For the per-component
trust analysis see [TRUST.md](../TRUST.md).

## What the runner does, in order

1. **Fetch (once).** A single `tar` transfer of `salt/` + `install-scripts/`
   from `REPO_VM` into dom0. Every archive entry is validated before extraction
   (regular files/dirs only — no symlinks/hardlinks/devices — paths rooted at
   `salt/` or `install-scripts/`, safe charset, no `..`, no absolute paths).
   This is the **only** VM→dom0 data flow in the whole system. The transfer
   SHA256 is printed for out-of-band comparison. The old installer, by contrast,
   re-fetched scripts, libs, assets and directory listings from the untrusted
   repo qube throughout the entire build and interpolated its listings into
   remote shell commands.

2. **Review gate.** Before the fetched tree becomes root-owned salt code you
   must type `CONTINUE`. On a re-fetch the incoming tree is diffed against what
   is already installed in `/srv` so you see exactly what changed; an identical
   re-fetch skips the prompt. For a full audit, run
   `./setup-qubes.sh --fetch-only`, read `/srv/salt/seqs` and
   `/srv/pillar/seqs` at leisure, then apply with `./setup-qubes.sh --skip-fetch`
   (which never contacts the repo qube).

3. **Install.** The verified tree is copied to `/srv/salt/seqs` and
   `/srv/pillar/seqs`. From here on the build has **no** dependency on
   `REPO_VM`; `--skip-fetch` re-runs never contact it at all.

4. **Apply dom0** (`qubesctl state.apply seqs.dom0`): validates the whole
   configuration up front, installs the qrexec policies, clones templates and
   creates app qubes — declaratively and idempotently. Pre-existing qubes NOT
   created by SEQS are refused via the `seqs-managed` qvm-feature guard (with
   intent markers so an interrupted run can be resumed, not locked out).
   Air-gapped (`offline`) qubes are independently re-verified by the runner
   before anything is provisioned.

5. **Apply qubes** (`qubesctl --skip-dom0 --targets=... state.apply seqs.qube`):
   provisions each template, then each app qube. Qubes Salt runs this through a
   **disposable management VM** over qrexec: dom0 pushes states and files down;
   dom0 never executes, parses, or interpolates anything a target qube produces.
   (qubesctl's own summary output is still routed through the runner's terminal
   sanitizer.)

## Convergence

Re-running `setup-qubes.sh` converges: finished components are skipped via
completion markers in `/rw/config/seqs/`, existing qubes are reconfigured rather
than rebuilt, and qubes not created by SEQS are refused (no-clobber via the
`seqs-managed` qvm-feature).

Convergence is deliberately non-destructive: removing configuration does not
automatically uninstall components or delete qubes, and changed component
installers remain skipped while their completion markers exist. See
[upgrading.md](upgrading.md) for the supported update procedure and exact
behavior by change type.

## Bootstrap window

The dom0 one-liner that copies `setup-qubes.sh` out of the repo qube appends
`2>/dev/null` to the `qvm-run` step deliberately. The fetch happens **before**
`setup-qubes.sh` exists in dom0 (and therefore before its `sanitize()` terminal
filter is available), so any bytes the source qube writes to stderr would land
directly on the dom0 terminal. A compromised repo qube could otherwise emit
ANSI / CSI / OSC sequences (window-title smuggling, OSC 52 clipboard write,
repaint of earlier lines) during the `cat`. Dropping stderr closes that
bootstrap window; if the `cat` fails, `s.sh` ends up empty/partial and `./s.sh`
fails loudly on its own. The runner reuses the same defense on its own fetch and
routes every later display path through `sanitize()`.

## Composition model

Every qube the setup builds is composed from one or more **components** in
`install-scripts/components/<name>/`. Single-tool qubes are 1-component;
mix-and-match qubes (wallet, developer) list several. The `seqs.dom0` state
clones the base template and creates the app qube; the `seqs.qube` state then
runs each component's `template-vm.sh` (system-wide install) in the template,
installs any `menu.desktop` it carries, runs each `app-vm.sh` (per-app-qube
setup) in the app qube, and wires up the browser-link policy and cleanup
service. See [configuration.md](configuration.md) for how to edit and extend
this.
