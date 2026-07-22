# Agent guide

This is the single source of truth for AI coding assistants working in SEQS.
Tool-specific instruction files must import this file rather than duplicate it.

## Project purpose and risk

SEQS builds purpose-specific Qubes OS TemplateVMs and AppVMs with Qubes Salt.
The code staged in dom0 runs with high privilege. Treat changes to
`setup-qubes.sh`, `delete-vms.sh`, `salt/`, and qrexec policy generation as
security-sensitive even when they look mechanical.

Do not claim that Qubes behavior has been tested unless it was tested on Qubes.
The local harness validates rendering and orchestration with mocks; its limits
are documented in `test/README.md`.

## Start here

1. Read `README.md` for the user workflow.
2. Read the relevant document under `docs/` before changing behavior.
3. For security or trust-boundary changes, read `TRUST.md` and the applicable
   checks in `VERIFY-HUMAN.md`.
4. Inspect `git status --short` and preserve unrelated user changes.

Use `rg`/`rg --files` for discovery. Prefer small patches. Do not perform broad
formatting or cleanup alongside a functional change.

## Repository map

- `setup-qubes.sh`: fetch, validate, stage, build, and verify orchestration.
- `delete-vms.sh`: guarded deletion of SEQS-managed qubes.
- `salt/pillar/seqs/config.sls`: catalogue and derived per-minion data.
- `salt/seqs/dom0.sls`: dom0 validation, VM creation, policy, and firewall state.
- `salt/seqs/qube.sls`: component installation inside templates and app qubes.
- `install-scripts/components/<name>/`: component template/app installation.
- `install-scripts/lib/`: shared installer helpers.
- `test/`: Qubes-free lint, render, unit, and mocked integration layers.

## Invariants

- Never weaken fetch/archive validation, confirmation gates, policy ownership,
  air-gap verification, or unsafe-name rejection to make a workflow pass.
- Untrusted strings reaching a dom0 terminal must remain sanitized.
- Validate values before interpolating them into shell or Salt state commands.
- An `offline` qube must have no NetVM and no OpenURL handoff.
- Do not overwrite an existing unmarked qrexec policy.
- Keep the catalogue independent of the runtime `--qubes`/`--all` selection.
- Component scripts must be idempotent enough for the marker-controlled rerun
  behavior described by the existing states.
- New downloads and repositories require explicit provenance, pinning where
  possible, and an honest update to `TRUST.md` about residual risk.
- Never put secrets, network access, or executable project code into dom0.

## Tests

Run commands from the repository root. The portable entry point is
`./test/run-tests.sh help`; it requires no task runner. If `make` is installed,
the Makefile provides equivalent short aliases through `make help`.

- `./test/run-tests.sh lint`: shell syntax, optional ShellCheck, and Salt render
  smoke tests.
- `./test/run-tests.sh render`: detailed pillar and Salt render assertions.
- `./test/run-tests.sh unit`: bash helper tests.
- `./test/run-tests.sh integration`: end-to-end orchestration against mock
  Qubes commands.
- `./test/run-tests.sh fast`: lint plus render assertions.
- `./test/run-tests.sh`: every Qubes-free layer; run before completing a code
  change.

The underlying entry point is `./test/run-tests.sh [layer]`. Dependencies are
Python 3 with `jinja2` and `pyyaml`; ShellCheck is optional locally and enabled
in CI. Do not install missing dependencies without permission. Report a skipped
check and the missing dependency.

Test changes at the narrowest layer first, then run `./test/run-tests.sh`. When
modifying:

- `.sls` or pillar behavior: add/update a case in `test/test_render.py`.
- a runner helper: add/update a case in `test/unit_bash.sh`.
- fetch/apply/delete orchestration: add/update `test/integration/run.sh`.
- a component or catalogue entry: verify its rendered state and documentation.
- trust or verification behavior: keep `TRUST.md` and `VERIFY-HUMAN.md`
  consistent with the actual implementation.

Hardware-bound verification commands are documented in `test/README.md`; do
not run provisioning or deletion commands merely to validate a repository edit.

## Completion standard

Before reporting completion, inspect the diff, run the relevant focused tests
and `./test/run-tests.sh`, and state exactly what was and was not verified.
Documentation must describe current behavior rather than intended behavior.
