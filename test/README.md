# SEQS test harness

Testing a Qubes installer is awkward: the "real" test is a full dom0 that
clones templates, creates app qubes and installs software inside each one —
exactly the thing you don't want to reproduce on your laptop after every edit.

The good news is that **almost everything you can break while editing the setup
breaks in a way that is observable without Qubes**: a Jinja typo in a `.sls`, a
component you renamed but forgot to wire up, a prefix that no longer matches the
top files, a broken validation branch, a shell-syntax slip in an install
script, a regression in the tar-validation or air-gap logic of the runner.

So the harness is layered, cheap-first. Everything except Layer 5 runs in well
under a second, on any Linux box (or CI), with **no Qubes at all**.

```
./test/run-tests.sh            # run every Qubes-free layer, summarised
./test/run-tests.sh render     # or just one layer: lint | render | unit | integration
```

The only dependencies are `python3` with `jinja2` + `pyyaml` (for the render
layers) and `bash`. `shellcheck` is used if present and skipped with a note if
not. CI installs all three (`.github/workflows/tests.yml`).

---

## The layers

### Layer 0 — lint (`test/lint.sh`)
`bash -n` on every `*.sh`, `shellcheck -x -S error` if available (errors only —
the repo deliberately carries some info/warning-level patterns, and a gate that
fails on style gets bypassed), and a smoke render of every Salt template.
Catches shell-syntax errors and "does it even compile" breakage instantly.

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
table-driven inputs: `sanitize()` (terminal-control stripping), the tar-entry
validation (accepts the real tree, rejects symlink / `..` / absolute / spaced /
out-of-root entries), `readTargets()`, `verifyAirgap()`, `joinCsv()`,
`confirm()`.

### Layer 4 — installer integration (`test/integration/`)
Runs the **real** `setup-qubes.sh` end to end against a sandbox dom0: mock
`qvm-*` / `qubesctl` / `sudo` on `PATH` (`test/integration/mocks/bin`) and
scratch `/srv` + `/var/lib` paths via the `SEQS_*` overrides. A small pty driver
(`test/lib/pty_run.py`) answers the `confirm()` prompts that read from
`/dev/tty`. Scenarios: fresh full install, `--skip-fetch` guard, a hostile
archive rejected at the tar gate, air-gap-fails-closed, an identical re-fetch
skipping the review prompt, and `delete-vms.sh` removing exactly the named
`A-`/`Z-` qubes (dry-run inert, unrelated qubes untouched, unsafe names
refused — the destructive script gets its own guard-rail scenario against a
stateful mock inventory). This is the only layer that exercises the runner's
fetch → validate → gate → install → apply → verify control flow as one piece.

### Layer 5 — real Qubes (manual, hardware-bound)
Nothing above proves that software actually installs *inside* a qube — that
needs a real Salt run. Two options, in ascending fidelity:

1. **Render/compile on a Qubes dom0 without provisioning.** Fetch the tree
   (`./setup-qubes.sh --fetch-only`) then dry-run the states:
   ```
   sudo qubesctl --skip-dom0 --targets=Z-brave state.show seqs.qube   # render only
   sudo qubesctl state.apply seqs.dom0 test=True                      # no changes
   ```
   `state.show` / `test=True` compile and (for test=True) diff without changing
   anything — a real-Salt superset of Layer 1.

2. **A throwaway Qubes VM.** Install Qubes in a nested VM (or a spare machine),
   set `REPO_VM` to a scratch qube holding the repo, and run the full flow. Use
   a cut-down `qube_list` (one networked qube + `keepass`) for a fast smoke, and
   `delete-vms.sh` to reset between runs. This is the closest to production and
   the only thing that catches component install scripts breaking against a real
   template — but it's minutes, not milliseconds, so keep it for pre-release,
   not every edit.

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

Run `./test/run-tests.sh` before every push (or wire it into a pre-push hook /
let CI do it).
