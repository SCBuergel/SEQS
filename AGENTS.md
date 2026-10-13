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

## Design priorities

Judge every change to SEQS and to its tests by these criteria, in this order:

1. It is secure.
2. Nothing is wrong: code, tests, and docs match actual behaviour.
3. Explanations are understandable for people.
4. Explanations are as short as possible.
5. Code is readable, short, and auditable.

Fix a flaw in code rather than documenting it when code can fix it. Prefer
test-only scaffolding over adding flags or code paths to the product for the
sake of testing.

## Start here

1. Read `README.md` for the user workflow.
2. Read the relevant document under `docs/` before changing behavior.
3. For security or trust-boundary changes, read `TRUST.md` and the applicable
   checks in `VERIFY-HUMAN.md`.
4. Inspect `git status --short` and preserve unrelated user changes.

Use `rg`/`rg --files` for discovery. Prefer small patches. Do not perform broad
formatting or cleanup alongside a functional change.

## Documentation style

- Start every section and subsection by saying what it covers or what will
  happen there.
- Before adding a section, step, command, example, or explanation, verify that
  it is necessary for the document's objective or for these documentation
  rules. Trace what later decision or action uses it, and place it immediately
  before its first actual use. Remove material that has no downstream use or is
  redundant, premature, or explained more clearly where the reader needs it.
- For command instructions, first name the terminal in which the command is
  entered, then show the command, then explain what output or effect to look
  for. A directly continuing command block in the same subsection does not
  need the terminal repeated.
- At first use, briefly explain terminology that a moderately technical Linux
  user may not know from Qubes OS. Prefer a short parenthetical immediately
  after the first use instead of a separate sentence that defines the term
  before using it. Do not rely on a later section to define a concept needed
  now; if a forward dependency is unavoidable, include the minimum explanation
  at the first use.
- Before finalizing documentation, review the order in which concepts and modes
  appear. Introduce and briefly explain each one before any list, prerequisite,
  or procedure refers to it; do not assume that a later heading repairs an
  unexplained earlier reference.
- At first use of external software, technology, or a service, give its shortest
  useful description and link to its authoritative documentation in the same
  parenthetical when practical. Do not explain universally familiar concepts
  merely to satisfy this rule.
- Never commit secrets, credentials, private keys, recovery material, or secret
  command output. Never record any such value in `AGENTS.md`, logs, fixtures,
  examples, or other repository files; examples must use unmistakably fake
  placeholders or freshly generated disposable test data.
- Keep `README.md` as a bare-minimum user entry point. Put checkout verification,
  one-time checks, explanations, alternatives, and troubleshooting in the
  applicable document under `docs/` and link to it from the README.
- Do not expand the README with repeated post-install checks already covered by
  `VERIFY-HUMAN.md` or the detailed first-install walkthrough.
- The normal first install is the single fetch-stage-build invocation:
  `~/s.sh --repo-vm disp1234 --qubes ...`. Do not present `--build-only` as a
  complete first-install command. The runner currently names the disposable
  repository source with `--repo-vm`; it does not accept `--dispvm`.
- Keep the dom0 runner-copy command compact, but retain the commit-bound
  `git show HEAD:setup-qubes.sh` export rather than copying the live working-tree
  file.
- Minimize commands typed in dom0. Dom0 has no clipboard by design, and typing
  complex commands there increases both operator error and exposure of the
  trusted administrative domain. When an equivalent read-only command can run
  directly in a qube terminal, instruct the user to run it there instead of
  wrapping it in `qvm-run` from dom0.

## Repository map

- `setup-qubes.sh`: fetch, validate, stage, build, and verify orchestration.
- `delete-vms.sh`: guarded deletion of SEQS-managed qubes.
- `salt/pillar/seqs/config.sls`: catalogue and derived per-minion data.
- `salt/seqs/dom0.sls`: dom0 validation, VM creation, policy, and firewall state.
- `salt/seqs/qube.sls`: component installation inside templates and app qubes.
- `install-scripts/components/<name>/`: component template/app installation.
- `install-scripts/lib/`: shared installer helpers.
- `test/`: Qubes-free lint, render, unit, and mocked integration layers.
- `test/hardware/`: dom0 remote-control setup for a dedicated test machine.
  It deliberately breaks Qubes isolation; never use it on a real installation.

## Invariants

- Never weaken fetch/archive validation, confirmation gates, policy ownership,
  air-gap verification, or unsafe-name rejection to make a workflow pass.
- Untrusted strings reaching a dom0 terminal must remain sanitized.
- Validate values before interpolating them into shell or Salt state commands.
- An `offline` qube must have no NetVM, no default disposable, and no
  OpenURL, OpenInVM, or other disposable route out.
- Do not overwrite an existing unmarked qrexec policy.
- Keep the catalogue independent of the runtime `--qubes`/`--all` selection.
- Component scripts must be safe to run twice: a component runs again whenever
  its files or the shared libraries change (its completion marker records
  their hash). `test/hardware/system-test.sh --force-rerun` checks this on
  hardware.
- New downloads and repositories require explicit provenance, pinning where
  possible, and an honest update to `TRUST.md` about residual risk.
- Never put secrets or network access into dom0. Executable project code in
  dom0 is limited to `setup-qubes.sh`, `delete-vms.sh`, and the small helpers
  the `seqs.dom0` state installs (the sequential QR script and the GnosisVPN
  panel monitor). A helper never runs anything a qube supplies, and accepts
  from a qube only narrowly validated data.

## Tests

Run commands from the repository root. The portable entry point is
`./test/run-tests.sh help`; it requires no task runner. If `make` is installed,
the Makefile provides equivalent short aliases, without the REV and NAME
arguments, through `make help`.

- `./test/run-tests.sh lint`: shell syntax, optional ShellCheck, Salt render
  smoke tests, the expiry of embedded signing keys, and whether the docs name
  what the code defines (`test/doc_coherence.py`).
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

A new or changed test must be shown to detect the change it was written for:
before committing, run `./test/run-tests.sh prove`, which runs the working
tree's tests against the committed product code and must report the new
checks as failing. A test that passes there passes for the wrong reason
unless it only guards behaviour that already existed. Assert the specific
message or state, not just that validation failed somewhere.
When you add or change a security check, add an entry for it to
`test/mutate.py` and run `./test/run-tests.sh mutate NAME`: the weakened check
must make a test fail.

Hardware-bound verification commands are documented in `test/README.md`; do
not run provisioning or deletion commands merely to validate a repository edit.

When the user has set up the dedicated test machine described in
`test/hardware/README.md` and asks for a hardware run, use
`test/hardware/system-test.sh` from the controlling qube. It resets the test
machine, installs the working copy from scratch, checks the result, and
writes `test/hardware/results/<run>/summary.txt`. Work in a loop: read the
summary and the phase logs, fix the root cause in the product (never by
weakening a check or an invariant above), rerun, and compare durations and
product size with the previous run. Only the test machine may be targeted;
never run these scripts against another Qubes installation.

Use `--quick` after each change; it takes about 10 minutes. Use `--all` with
its rerun before pushing a batch that touches several components or the
runner, and add `--force-rerun` when installers changed. While a run is in
progress, watch its `progress.log` and give the user a short status with the
ETA at every phase change, and at least every 20 minutes. Do not plan steps
that need the user at the test machine unless they offer.

## Completion standard

Before reporting completion, inspect the diff, run the relevant focused tests
and `./test/run-tests.sh`, and state exactly what was and was not verified.
Documentation must describe current behavior rather than intended behavior.
