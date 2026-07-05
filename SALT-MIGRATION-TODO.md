# Salt migration — remaining work & author remarks

The imperative `setup-qubes.sh` has been replaced by a Qubes Salt (`qubesctl`)
based setup. New layout:

```
setup-qubes.sh                    thin dom0 bootstrap/runner (the only code
                                  that still runs imperatively in dom0)
salt/seqs/dom0.sls|dom0.top       dom0 state: validation, qrexec policies,
                                  qube creation, /var/lib/seqs/targets
salt/seqs/qube.sls|qube.top       per-qube state: component installs, browser
                                  handler, cleanup service, xdg default browser
salt/pillar/seqs/config.sls|top   ALL configuration knobs (was the array block
                                  at the top of the old setup-qubes.sh)
install-scripts/                  unchanged; shipped as salt fileserver payload
                                  (salt://seqs/files/...) at bootstrap
```

Trust/exposure improvements delivered:

- **REPO_VM is contacted exactly once** (one tar transfer, every entry
  validated before extraction). The old installer pulled scripts, libs,
  assets and *directory listings* from the live repo qube throughout the
  build and interpolated those listings into remote shell commands.
- **Review gate before the fetched tree becomes root-run code**: a re-fetch
  is diffed against the tree already installed in /srv and requires a typed
  CONTINUE; an identical re-fetch skips the prompt. The first fetch requires
  CONTINUE after the hash display (or use `--fetch-only` for a full audit,
  then `--skip-fetch`). Applying with `--skip-fetch` never contacts REPO_VM.
- **dom0 no longer executes or parses qube output.** Per-qube provisioning
  runs via the Qubes salt management stack (salt-ssh over qrexec through the
  disposable management VM). `fetchFromVm`, `fetchRunClean`,
  `discoverLibFiles`, `vmRun` and their validation lattice are gone because
  the VM→dom0 dataflow they defended no longer exists. The terminal
  sanitizer survives only as a display-hardening wrapper around `qubesctl`
  output (`sanitize()` in setup-qubes.sh).
- **Declarative + convergent**: re-runs converge (component completion
  markers in `/rw/config/seqs/`, `file.managed` policies, `qvm.*` states)
  instead of the old refuse-and-rollback model. An interrupted run cannot
  lock out re-runs: intent markers in `/var/lib/seqs/intents/` bridge the
  window between creating a qube and tagging it `seqs-managed`, so the next
  run adopts the half-created qube instead of refusing it.
- **No-clobber preserved**: pre-existing qubes are refused unless they carry
  the `seqs-managed` qvm-feature (or an intent marker from an interrupted
  SEQS run); non-SEQS policy files require a literal `OVERWRITE`
  confirmation before salt takes ownership.
- **Air gap is verified, not assumed**: offline qubes get their netvm
  cleared with the same `qvm-prefs <vm> netvm none` invocation the old
  installer used in production, and setup-qubes.sh independently re-checks
  the pref after the dom0 apply — provisioning refuses to start if any
  offline qube still has a netvm.
- **Duplicate qube names abort again**: qube specs are a list, compiled into
  a map with duplicate detection in the pillar; duplicates fail the
  seqs.dom0 pre-flight (same strictness as the old validateAllQubes).
- **Config/top drift fails loudly**: the Z-*/A-* minion globs are duplicated
  in the .top files (top files cannot read pillar); seqs.dom0 cross-checks
  them against the pillar prefixes and aborts on mismatch instead of letting
  every `--targets` apply silently no-op.
- **qubesctl failures cannot pass silently**: the runner checks the exit
  code AND scans the sanitized output for salt's own failure markers
  (`Result: False` / non-zero `Failed:` summary), because qubesctl versions
  differ in whether failed states propagate non-zero.
- **Pillar is sliced per minion**: each qube receives only its own role/spec
  and the extension IDs it references — a compromised qube cannot read the
  full topology or wallet inventory from its pillar.

## TODO — needs a real Qubes system to verify (none of this was run on real
## Qubes hardware; every item below is a first-apply checklist entry)

1. **`qvm.clone` idempotence**: dom0.sls guards every clone with a
   render-time `qvm-check`, so this should be moot, but confirm the
   `qvm.clone` state on your Qubes release (4.2/4.3) behaves when re-run
   mid-converge.
2. **Air gap**: `qvm-prefs <vm> netvm none` is the form the old installer
   used, and the runner verifies the result (`verifyAirgap`), so this should
   fail closed — but still eyeball `qvm-prefs A-keepass netvm` after the
   first apply. If your release accepts a declarative `qvm.prefs` netvm
   clear, the `seqs-offline-*` cmd.run states can be folded into the
   `qvm.vm` prefs block.
3. **jinja whitespace in generated files**: eyeball the rendered
   `28-browser-suppress.policy`, `/var/lib/seqs/targets` and
   `/usr/sbin/seqs-cleanup` after the first apply (`{%- for %}` inside
   `contents: |` blocks is standard but worth one look).
4. **`xdg-settings` via `runuser -l user`** (qube.sls,
   `seqs-default-browser`): the old flow ran it through `qvm-run` as user;
   confirm it still writes `~/.config/mimeapps.list` headless under runuser.
5. **Management stack prerequisites**: stock debian templates ship
   `qubes-mgmt-salt-vm-connector`; if you ever move `base_template` to a
   *minimal* template, it must be installed there first, or every
   `--targets=` apply will hang/fail.
6. **Failure-marker scan**: runQubesctl greps for `Result: False` and a
   non-zero `Failed:` summary as a backstop for unreliable qubesctl exit
   codes. Verify one deliberately-broken state is caught on your release,
   and note a component installer that *prints* the literal string
   `Result: False` would false-positive (harmless: it just makes the run
   report failure).
7. **Timeout semantics**: per-component `timeout:` on `cmd.run` (default 900,
   pillar `component_timeout`) replaces the old per-qube watchdog + rollback.
   Salt kills only the command it spawned — decide whether the old
   "reboot dom0 after a timeout" warning from TRUST.md still applies and
   where it should surface now.

## TODO — decisions/polish left for you as the author

1. **Documentation is deliberately untouched.** README.md (bootstrap
   one-liner still fetches `setup-qubes.sh` — that still works, but the
   config-editing instructions now point at the wrong place), TRUST.md
   (entries for `vmRun`, `fetchFromVm`, watchdog/rollback are stale; the new
   trust surface is: one tar transfer + entry validation + the review gate +
   the qubes-mgmt-salt stack itself), VERIFY-HUMAN.md / VERIFY-LLM.md (file
   inventory changed).
2. **Transfer verification story**: setup-qubes.sh prints the tarball SHA256
   and diffs re-fetches against the installed tree, but the FIRST fetch is
   only hash-displayed, not content-verified. Decide whether to go further:
   `git tag -s` on releases + gpg verification in dom0 would remove the
   "trust the repo qube once" step entirely.
3. **Intent-marker edge case**: if a run is interrupted between writing an
   intent marker and creating the qube, and you then MANUALLY create a qube
   with that exact Z-/A- name before the next run, that run will adopt (tag
   and reconfigure) your manual qube. Window is tiny and requires operator
   action inside it; a leftover marker for a qube that was never created is
   otherwise self-healing. Stale markers in /var/lib/seqs/intents/ for
   renamed/removed specs are inert; delete freely.
4. **Removed knob**: `CLEANUP_DIRS` paths are now restricted to
   `[A-Za-z0-9._/-]` (no spaces) instead of the old printf-%q escaping —
   simpler to validate end-to-end. Document or lift if you ever need spaces.
5. **Retiring a qube** from the pillar map leaves its Z-/A- pair (any stale
   suppress-policy line is handled, but the qubes themselves are not
   deleted — deliberate, delete-vms.sh still covers that). Consider a
   `seqs.retire` state or documenting delete-vms.sh as the counterpart.
6. **Prefix duplication**: `Z-*`/`A-*` globs are hardcoded in the `.top`
   files because top files can't read pillar. seqs.dom0 now aborts on a
   mismatch with `config.top`; `qube.top`/`dom0.top` only matter if you
   opt into highstate, and are not cross-checked.
7. **install-scripts/ scripts are unchanged** and still run as user `user`
   with internal `sudo`, staged with libs alongside so
   `. "$(dirname "$0")/lib.sh"` keeps working. Longer-term you may want to
   convert the simpler ones (apt repo + key pinning) to native salt states
   (`pkgrepo.managed` + `pkg.installed`) and keep shell only for the genuinely
   scripty ones (pyenv/nvm/extension install); that would also make
   `test=True` dry runs meaningful per component.
8. **The old setup-qubes.sh** lives in git history only. If you want a
   transition period, restore it as `legacy/setup-qubes.sh` — but note both
   flows fight over the same policy files and qube names.
9. **No automated tests are included** — deliberately, per your preference
   for keeping the repo lean. The states were syntax-checked (bash -n,
   jinja render + YAML parse against mocked salt functions) during this
   rework, but that harness is not part of the repo. Everything above still
   needs one careful first apply on a real Qubes box.
