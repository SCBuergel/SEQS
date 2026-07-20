#!/usr/bin/env bash
# Layer 4 -- integration test: run the REAL setup-qubes.sh end to end against a
# sandbox dom0 built from mock qvm-*/qubesctl/sudo commands (test/integration/
# mocks/bin) and scratch /srv + /var/lib paths (SEQS_* overrides).
#
# This exercises the parts no amount of Salt-rendering can: the fetch ->
# tar-validation -> stage -> build -> readTargets ->
# verifyAirgap control flow of the runner itself. It does NOT prove software
# installs correctly inside a qube (that needs real Qubes -- see test/README.md
# "Layer 5").

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$*"; }

# A fresh sandbox + environment for one run of setup-qubes.sh.
new_sandbox() {
	SBX="$(mktemp -d)"
	export SEQS_SALT_TREE="${SBX}/srv/salt/seqs"
	export SEQS_PILLAR_TREE="${SBX}/srv/pillar/seqs"
	export SEQS_TARGETS_FILE="${SBX}/var/lib/seqs/targets"
	export SEQS_SELECTION_FILE="${SBX}/var/lib/seqs/selection"
	export SEQS_RUN_MANIFEST="${SBX}/var/lib/seqs/last-run"
	export SEQS_FETCH_ROOT="${SBX}/var/lib/seqs/fetched"
	export SEQS_REPO_VM="personal"
	export SEQS_REPO_ROOT="${REPO}"
	export PATH="${HERE}/mocks/bin:${REPO_ORIG_PATH}"
	unset SEQS_MOCK_TAR SEQS_MOCK_NETVM SEQS_MOCK_STATE
	unset SEQS_MOCK_SUDO_LOG
	unset SEQS_BROWSER_SUPPRESS_POLICY
	export SEQS_MOCK_EXISTING="debian-13-xfce"
}
REPO_ORIG_PATH="${PATH}"

run_setup() {  # runs setup-qubes.sh under a pty, capturing combined output
	python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" "$@"
}

# ── Scenario 1: full happy-path install on a fresh dom0 ────────────────────
echo "== scenario: fresh full workflow (fetch + stage + build) =="
new_sandbox
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "fresh install exited non-zero ($rc)"
grep -q "Transfer SHA256" <<<"$out" && ok || bad "expected the transfer hash to be shown"
grep -q "Staging complete" <<<"$out" && ok || bad "expected the salt tree to be staged"
grep -q "Air gap verified" <<<"$out" && ok || bad "expected air-gap verification to run"
grep -q "SEQS setup complete" <<<"$out" && ok || bad "expected a clean completion message"
# The tree really landed in the sandbox /srv, root markers and all.
[ -f "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "dom0.sls not installed into sandbox /srv"
[ -f "${SEQS_SALT_TREE}/.seqs-managed" ] && ok || bad "missing .seqs-managed marker"
[ -f "${SEQS_SALT_TREE}/files/components/brave/template-vm.sh" ] && ok \
	|| bad "component payload not staged into files/"
[ -f "${SEQS_TARGETS_FILE}" ] && ok || bad "targets file not written by dom0 apply"
grep -q "app A-keepass offline" "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "keepass should be listed offline in targets"
# The named disposable is listed as its own kind + offline, and the runner's
# air-gap pass names it alongside the offline app qubes.
grep -q "disposable D-qr-display offline" "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "the named disposable should be listed offline in targets"
grep -q "Air gap verified:.*D-qr-display" <<<"$out" && ok \
	|| bad "the named disposable should be independently air-gap verified"
rm -rf "${SBX}"

# ── Scenario 2: later stages refuse when prerequisites are absent ──────────
echo "== scenario: stage/build prerequisites are enforced =="
new_sandbox
out="$(run_setup --stage-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "--stage-only should fail before fetch"
grep -q "fetch stage is incomplete" <<<"$out" && ok || bad "expected fetch prerequisite error"
out="$(run_setup --build-only --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "--build-only should fail before staging"
grep -q "stage is incomplete" <<<"$out" && ok || bad "expected stage prerequisite error"
rm -rf "${SBX}"

# ── Scenario 3: hostile archive is rejected at the tar-validation gate ──────
echo "== scenario: malicious archive (path traversal) is rejected pre-install =="
new_sandbox
evil="$(mktemp -d)"
mkdir -p "${evil}/salt"
ln -s /etc/passwd "${evil}/salt/steal"   # symlink entry -> non-regular, must reject
export SEQS_MOCK_TAR="${SBX}/evil.tar"
tar -C "${evil}" -cf "${SEQS_MOCK_TAR}" salt
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "hostile archive should abort the run"
grep -qi "refusing" <<<"$out" && ok || bad "expected a 'refusing ... tar entry' message"
[ ! -d "${SEQS_SALT_TREE}" ] && ok || bad "nothing should have been installed from a hostile archive"
rm -rf "${SBX}" "${evil}"

# ── Scenario 4: air-gap verification fails closed ──────────────────────────
echo "== scenario: a live netvm on an offline qube halts provisioning =="
new_sandbox
export SEQS_MOCK_NETVM="sys-firewall"   # keepass 'offline' but netvm present
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "verifyAirgap should abort when an offline qube has a netvm"
grep -qi "air gap NOT in effect" <<<"$out" && ok || bad "expected an air-gap failure message"
rm -rf "${SBX}"

# ── Scenario 5: identical re-fetch skips the review-gate prompt ────────────
echo "== scenario: re-running recognizes an identical staged tree =="
new_sandbox
run_setup --all >/dev/null 2>&1      # first install (auto-confirmed via pty)
out="$(run_setup --all 2>&1)"; rc=$? # second run: tree identical
[ "$rc" -eq 0 ] && ok || bad "identical re-run should succeed"
grep -q "identical to the tree already staged" <<<"$out" && ok \
	|| bad "expected the identical staged-tree message on re-run"
rm -rf "${SBX}"

# ── Scenario 6: each explicit stage runs independently ────────────────────
echo "== scenario: explicit fetch, stage, and build commands compose =="
new_sandbox
run_setup --fetch-only >/dev/null 2>&1 && ok || bad "--fetch-only failed"
[ -f "${SEQS_FETCH_ROOT}/.seqs-complete" ] && ok || bad "fetch completion marker missing"
run_setup --stage-only >/dev/null 2>&1 && ok || bad "--stage-only failed"
[ -f "${SEQS_SALT_TREE}/.seqs-complete" ] && ok || bad "stage completion marker missing"
run_setup --build-only --all >/dev/null 2>&1 && ok || bad "--build-only failed"
[ -f "${SEQS_TARGETS_FILE}" ] && ok || bad "build did not create targets"
out="$(run_setup --build-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "build selection is required" <<<"$out" && ok \
	|| bad "build without --qubes/--all should be refused"
run_setup --build-only --qubes signal,brave >/dev/null 2>&1 \
	&& ok || bad "selected build failed"
grep -q '^template Z-brave$' "${SEQS_TARGETS_FILE}" \
	&& grep -q '^app A-signal$' "${SEQS_TARGETS_FILE}" \
	&& ! grep -q 'keepass' "${SEQS_TARGETS_FILE}" \
	&& ok || bad "selected build targets should contain only brave and signal"
[ -f "${SEQS_RUN_MANIFEST}" ] && grep -q '^selection=brave,signal$' "${SEQS_RUN_MANIFEST}" \
	&& ok || bad "run manifest should record canonical selection"
rm -rf "${SBX}"

# ── Scenario 7: protected staged trees are inspected through sudo ──────────
echo "== scenario: staged-tree guard and preview use privileged reads =="
new_sandbox
run_setup --fetch-only >/dev/null 2>&1
run_setup --stage-only >/dev/null 2>&1
export SEQS_MOCK_SUDO_LOG="${SBX}/sudo.log"
out="$(run_setup --stage-only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "privileged-preview stage exited non-zero ($rc)"
grep -Fq "test -e ${SEQS_SALT_TREE}" "${SEQS_MOCK_SUDO_LOG}" && ok \
	|| bad "staged-tree ownership guard did not use sudo"
grep -Fq "diff -r --exclude=.seqs-complete ${SEQS_SALT_TREE} ${SEQS_FETCH_ROOT}/salt" \
	"${SEQS_MOCK_SUDO_LOG}" && ok || bad "staged-tree preview did not use sudo"
grep -q "identical to the tree already staged" <<<"$out" && ok \
	|| bad "privileged preview should recognize the identical tree"
rm -rf "${SBX}"

# ── Scenario 8: delete-vms.sh removes only the named D-/A-/Z- qubes ─────────
# delete-vms.sh is the destructive half of the tooling, so its guard rails get
# a scenario of their own. The mock inventory (SEQS_MOCK_STATE) is stateful:
# qvm-kill marks a qube halted, qvm-remove drops it, qvm-check reads it back.
echo "== scenario: delete-vms.sh touches only the named D-/A-/Z- qubes =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
printf '%s\n' "A-keepass running" "Z-keepass halted" "A-brave halted" > "${SEQS_MOCK_STATE}"
export SEQS_BROWSER_SUPPRESS_POLICY="${SBX}/28-browser-suppress.policy"
cat > "${SEQS_BROWSER_SUPPRESS_POLICY}" <<'EOF'
# Managed by SEQS (test)
qubes.OpenURL  *  A-keepass  @anyvm  deny
qubes.OpenURL  *  A-wallet-ledger  @anyvm  deny
EOF
# Dry-run: announces itself, exits 0, changes nothing.
out="$(bash "${REPO}/delete-vms.sh" --dry-run keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "dry-run exited non-zero ($rc)"
grep -q "dry-run: not killing or removing" <<<"$out" && ok || bad "expected the dry-run notice"
grep -q "would remove stale browser deny for A-keepass" <<<"$out" && ok \
	|| bad "dry-run should report browser-policy cleanup"
grep -qxF "A-keepass running" "${SEQS_MOCK_STATE}" && ok || bad "dry-run must not touch the inventory"
grep -q "A-keepass" "${SEQS_BROWSER_SUPPRESS_POLICY}" && ok \
	|| bad "dry-run must not alter browser policy"
# Real run: A-keepass (running) and Z-keepass go, unrelated A-brave stays.
out="$(bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "delete run exited non-zero ($rc)"
grep -q "^A-keepass " "${SEQS_MOCK_STATE}" && bad "A-keepass should have been removed" || ok
grep -q "^Z-keepass " "${SEQS_MOCK_STATE}" && bad "Z-keepass should have been removed" || ok
grep -q "^A-brave " "${SEQS_MOCK_STATE}" && ok || bad "unrelated A-brave was removed"
grep -q "A-keepass" "${SEQS_BROWSER_SUPPRESS_POLICY}" && bad \
	"stale A-keepass browser deny should have been removed" || ok
grep -q "A-wallet-ledger" "${SEQS_BROWSER_SUPPRESS_POLICY}" && ok \
	|| bad "unrelated browser deny was removed"
# A named_disposable qube adds a D- object; all three of D-/A-/Z- must go, and
# the disposable (D-) must be removed before the A- dispvm template it derives
# from so qvm-remove does not fail on a live dependency.
printf '%s\n' "D-qr-display running" "A-qr-display halted" "Z-qr-display halted" \
	"A-brave halted" > "${SEQS_MOCK_STATE}"
out="$(bash "${REPO}/delete-vms.sh" qr-display 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "disposable delete run exited non-zero ($rc)"
grep -q "^D-qr-display " "${SEQS_MOCK_STATE}" && bad "D-qr-display should have been removed" || ok
grep -q "^A-qr-display " "${SEQS_MOCK_STATE}" && bad "A-qr-display should have been removed" || ok
grep -q "^Z-qr-display " "${SEQS_MOCK_STATE}" && bad "Z-qr-display should have been removed" || ok
grep -q "^A-brave " "${SEQS_MOCK_STATE}" && ok || bad "unrelated A-brave was removed"
# D- must be listed before A- in the removal order (dependency safety). The
# indented "found:" lines are unique per qube, unlike the header that names all.
d_line="$(grep -n '^  D-qr-display$' <<<"$out" | head -1 | cut -d: -f1)"
a_line="$(grep -n '^  A-qr-display$' <<<"$out" | head -1 | cut -d: -f1)"
[ -n "$d_line" ] && [ -n "$a_line" ] && [ "$d_line" -lt "$a_line" ] \
	&& ok || bad "the disposable D-qr-display must be removed before its A- template"
# An unmarked policy is outside SEQS ownership and must remain byte-for-byte.
cat > "${SEQS_BROWSER_SUPPRESS_POLICY}" <<'EOF'
qubes.OpenURL  *  A-ghost  @anyvm  deny
EOF
cp "${SEQS_BROWSER_SUPPRESS_POLICY}" "${SBX}/unmarked.before"
out="$(bash "${REPO}/delete-vms.sh" ghost 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "no-match cleanup exited non-zero ($rc)"
grep -q "stale browser deny.*unmarked policy" <<<"$out" && ok \
	|| bad "expected warning for an unmarked policy"
cmp -s "${SBX}/unmarked.before" "${SEQS_BROWSER_SUPPRESS_POLICY}" && ok \
	|| bad "unmarked browser policy must not be changed"
# Unsafe name: refused before anything is looked up.
out="$(bash "${REPO}/delete-vms.sh" '../evil' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "unsafe name must be refused"
grep -q "refusing unsafe name" <<<"$out" && ok || bad "expected the unsafe-name error"
rm -rf "${SBX}"

echo
echo "integration tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
