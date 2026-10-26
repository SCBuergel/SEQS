# SEQS test harness

Testing a Qubes installer is awkward: the "real" test is a full dom0 that
clones templates, creates app qubes and installs software inside each one —
exactly the thing you don't want to reproduce on your laptop after every edit.

The good news is that **almost everything you can break while editing the setup
breaks in a way that is observable without Qubes**: a Jinja typo in a `.sls`, a
component you renamed but forgot to wire up, a prefix that no longer matches the
top files, a broken validation branch, a shell-syntax slip in an install
script, a regression in the tar-validation or air-gap logic of the runner.

So the harness is layered, cheap-first. Everything except Layer 5 runs in
under a minute, on any Linux box (or CI), with **no Qubes at all**.

```
./test/run-tests.sh            # run every Qubes-free layer, summarised
./test/run-tests.sh render     # or one layer: lint | render | unit | integration
./test/run-tests.sh fast       # lint plus render
./test/run-tests.sh prove      # do the new tests fail against the committed code?
./test/run-tests.sh mutate     # does every security check have a test?
```

The lint layer also warns when an embedded signing key expires within 180
days, and fails within 30, so a renewed key gets embedded before installs and
template updates break.

`prove` runs the working tree's tests against the product code of the last
commit (or a commit you name) in a temporary git worktree. A test written for a
change must fail there; one that passes would also have passed without the
change. The lint check that each `test/mutate.py` entry matches its file is
skipped there, since a new entry cannot match the old code.

`mutate` weakens one security check at a time, such as the archive validation,
the air-gap check, or a qrexec deny, from the list in `test/mutate.py`, and
runs the layers until one fails. A weakened check that every layer accepts has
no test. It takes several minutes; add an entry when you add a security check.

The only dependencies are `python3` with `jinja2` + `pyyaml` (for the render
layers) and `bash`; `prove` and `mutate` also need `git`. `shellcheck` and
`gpg` are used if present and skipped with a note if not; CI has all of them
(`.github/workflows/tests.yml`).

---

## The layers

### Layer 0 — lint (`test/lint.sh`)
`bash -n` on every shell script (every `*.sh`, and every other file that
starts with a shell's `#!` line), `shellcheck -x -S error` if available
(errors only — the repo deliberately carries some info/warning-level patterns,
and a gate that fails on style gets bypassed), a smoke render of every Salt
template, and `test/doc_coherence.py`, which fails when the docs do not name a catalogue
flag, setting, component, option, pinned fingerprint, or guarded policy file
that the code defines, a `--qubes` example names no catalogue entry, or a
relative Markdown link does not resolve, and `test/mutate.py --check`, which
fails when a mutation's original text no longer occurs exactly once in its
file, so a stale entry cannot hide an unguarded check.
Catches shell-syntax errors, "does it even compile" breakage, and docs that
fell behind the code instantly.

### Layer 1 — Salt render (`test/lib/salt_render.py`, `test/lint_render.py`)
The heart of the harness. Qubes' Salt states are Jinja-templated YAML; this
renders `dom0.sls`, `qube.sls` and the pillar `config.sls` with a Jinja
environment that stands in for Salt — it provides the `salt[...]` execution
modules, `grains`, `pillar` and the custom filters the states use, and answers
the `salt[...]` calls (`qvm-check`, `qvm-features`, file existence,
`/etc/qubes-release`, …) from a configurable `Scenario`. That means one template
can be exercised against many simulated dom0 states.

Want to *see* what Salt would generate? Use the eyeball tool:

```
test/render_states.py pillar dom0        # the full pillar dom0 receives
test/render_states.py pillar A-keepass   # the slice A-keepass receives
test/render_states.py dom0               # the rendered dom0 state
test/render_states.py qube Z-brave       # the rendered per-qube state
test/render_states.py dom0 --list        # just the state IDs it produced
```

### Layer 2 — render assertions (`test/test_render.py`)
Assertions on top of Layer 1: per-minion pillar slicing (dom0 sees the whole
map, an app qube only its own slice, wallet qubes get only the extension IDs
they use), the happy-path dom0 states, idempotent re-runs, the no-clobber /
intent-marker adoption logic, release-gated USB policy, the firewall states,
and the pre-flight **validation** logic driven with hand-built bad pillars
(unknown label / component / extension, unsafe name, `offline`+`firewall`,
duplicate qube, missing base template, …). This is where "did my edit change
what gets built?" is pinned down. **Adding a component or qube? Add a case
here.**

### Layer 3 — bash unit tests (`test/unit_bash.sh`)
Sources `setup-qubes.sh` with `SEQS_SOURCE_ONLY=1` (a test-only hook that stops
before the installer runs) and drives its security-load-bearing helpers with
table-driven inputs: `sanitize()` (terminal-control stripping),
`validateTarListing()` (accepts the real tree, rejects symlink / `..` /
absolute / spaced / out-of-root entries), `SAFE_NAME`, `readTargets()`,
`verifyAirgap()`, `isManaged()`, `joinCsv()`, `confirm()`. It also covers the
shared installer library (`lib/verify-gpg.sh`, with a throwaway test key),
`adb-pull`'s handling of device answers, that component scripts which lock a
file unlock it first, and the hardware-test helpers.

### Layer 4 — installer integration (`test/integration/`)
Runs the **real** `setup-qubes.sh` end to end against a sandbox dom0: mock
`qvm-*` / `qubesctl` / `sudo` on `PATH` (`test/integration/mocks/bin`) and
scratch `/srv` + `/var/lib` paths via the `SEQS_*` overrides. A small pty driver
(`test/lib/pty_run.py`) answers the `confirm()` prompts that read from
`/dev/tty`. Scenarios: full workflow and the single-step install, a failed template
skipping its app qube, a template left running by an interrupted run,
the GnosisVPN download proxy, fetch source and HEAD validation, stage/build
prerequisite guards, privileged reads of the staged tree, a hostile archive
rejected at the tar gate (leaving no temporary files), air-gap-fails-closed,
an identical re-fetch reported as already staged,
`delete-vms.sh` removing exactly the named SEQS-built `D-`/`A-`/`Z-` qubes
(dry-run inert, unrelated and unmanaged qubes untouched, dependent qubes and
global defaults refusing the whole run, unsafe names refused — the destructive
script gets its own guard-rail scenario against a stateful mock inventory), the
hardware-test reset, and the sequential QR script's refusals. This is the
only layer that exercises the runner's
fetch → validate → stage → build → verify control flow as one piece.

### Layer 5 — real Qubes (manual, hardware-bound)
Nothing above proves that software actually installs *inside* a qube — that
needs a real Salt run. Two options, in ascending fidelity:

1. **Render/compile on a Qubes dom0 without provisioning.** On a machine where
   a build has already run once (it enables the SEQS pillar and records the
   selection that `seqs.dom0` reads), fetch the tree
   (`./setup-qubes.sh --repo-vm <VM> --fetch-only`, then `--stage-only`) and
   dry-run the states:
   ```
   sudo qubesctl --skip-dom0 --targets=Z-brave state.show seqs.qube   # render only
   sudo qubesctl state.apply seqs.dom0 test=True                      # no changes
   ```
   `state.show` / `test=True` compile and (for test=True) diff without changing
   anything — a real-Salt superset of Layer 1.

2. **A throwaway Qubes VM.** Install Qubes in a nested VM (or a spare machine),
   pass a scratch qube holding the repo with `--repo-vm`, and run the full flow. Use
   a cut-down `qube_catalog` (one networked qube + `keepass`) for a fast smoke, and
   `delete-vms.sh` to reset between runs. This is the closest to production and
   the only thing that catches component install scripts breaking against a real
   template — but it's minutes, not milliseconds, so keep it for pre-release,
   not every edit.

   For a dedicated test machine that you drive over SSH instead of at its
   keyboard, see [hardware/README.md](hardware/README.md). Its
   `system-test.sh` resets that machine, installs the working copy from
   scratch, checks every built qube, and reports durations and findings.

---

## Adding tests when you change things

| You changed… | Add / update… |
|---|---|
| a `.sls` state or the pillar | a case in `test/test_render.py` |
| a config field (new qube, new flag) | a render assertion; the lint smoke render covers it automatically |
| a new component dir | it's picked up automatically; assert its `seqs-install-<c>` state renders |
| a helper in `setup-qubes.sh` | a case in `test/unit_bash.sh` |
| the fetch / apply orchestration | a scenario in `test/integration/run.sh` |
| `delete-vms.sh` | the delete scenario in `test/integration/run.sh` |

