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
	export SEQS_GNOSIS_UPDATE_POLICY="${SBX}/etc/qubes/policy.d/20-seqs-gnosisvpn-updates.policy"
	export SEQS_REPO_ROOT="${REPO}"
	export SEQS_EXPECTED_COMMIT
	SEQS_EXPECTED_COMMIT="$(git -C "${REPO}" rev-parse HEAD)"
	export PATH="${HERE}/mocks/bin:${REPO_ORIG_PATH}"
	unset SEQS_MOCK_TAR SEQS_MOCK_NETVM SEQS_MOCK_STATE
	unset SEQS_MOCK_RESOLVED_COMMIT
	unset SEQS_MOCK_SUDO_LOG
	unset SEQS_MOCK_UPDATEVM SEQS_MOCK_QVM_CREATE_LOG
	unset SEQS_BROWSER_SUPPRESS_POLICY
	export SEQS_MOCK_EXISTING="debian-13-xfce"
}
REPO_ORIG_PATH="${PATH}"

run_setup() {  # supplies the explicit repository qube to workflows with FETCH
	local arg
	for arg in "$@"; do
		case "${arg}" in
			--stage-only|--build-only)
				python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" "$@"
				return
				;;
		esac
	done
	python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
		--repo-vm test-repo "$@"
}

# ── Scenario 1: full happy-path install on a fresh dom0 ────────────────────
echo "== scenario: fresh full workflow (fetch + stage + build) =="
new_sandbox
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "fresh install exited non-zero ($rc)"
grep -q "Transfer SHA256" <<<"$out" && ok || bad "expected the transfer hash to be shown"
grep -q "Fetching salt tree from source HEAD commit ${SEQS_EXPECTED_COMMIT}" <<<"$out" \
	&& ok || bad "expected the resolved source HEAD commit to be shown"
grep -q "Staging complete" <<<"$out" && ok || bad "expected the salt tree to be staged"
grep -q "Air gap verified" <<<"$out" && ok || bad "expected air-gap verification to run"
grep -q "SEQS setup complete" <<<"$out" && ok || bad "expected a clean completion message"
grep -q "Creating domain-restricted temporary GnosisVPN updates proxy" <<<"$out" \
	&& ok || bad "expected the scoped GnosisVPN proxy lifecycle"
[ ! -e "${SEQS_GNOSIS_UPDATE_POLICY}" ] && ok \
	|| bad "temporary GnosisVPN update policy should be removed after provisioning"
# The tree really landed in the sandbox /srv, root markers and all.
[ -f "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "dom0.sls not installed into sandbox /srv"
[ -f "${SEQS_SALT_TREE}/.seqs-managed" ] && ok || bad "missing .seqs-managed marker"
[ "$(cat "${SEQS_FETCH_ROOT}/source-commit" 2>/dev/null)" = "${SEQS_EXPECTED_COMMIT}" ] \
	&& ok || bad "fetched source commit was not recorded"
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

# ── Scenario 1b: nested UpdateVM templates resolve to a real TemplateVM ────
echo "== scenario: GnosisVPN proxy resolves a DisposableVM UpdateVM template chain =="
new_sandbox
export SEQS_MOCK_UPDATEVM=disp-updates
export SEQS_MOCK_QVM_CREATE_LOG="${SBX}/qvm-create.log"
out="$(run_setup --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok \
	|| bad "GnosisVPN install with a DisposableVM UpdateVM exited non-zero ($rc)"
grep -q -- '--class AppVM --template debian-13-xfce --label gray seqs-gnosisvpn-update-proxy' \
	"${SEQS_MOCK_QVM_CREATE_LOG}" 2>/dev/null && ok \
	|| bad "temporary proxy must resolve DispVM -> AppVM -> TemplateVM"
rm -rf "${SBX}"

# ── Scenario 1c: fetch requires an explicit source and validates its HEAD ──
echo "== scenario: fetch requires an explicit source and validates source HEAD =="
new_sandbox
out="$(python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "fetch requires --repo-vm" <<<"$out" && ok \
	|| bad "fetch without --repo-vm should be refused"
out="$(SEQS_REPO_VM=personal \
	python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
	--fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "fetch requires --repo-vm" <<<"$out" && ok \
	|| bad "SEQS_REPO_VM must not restore an implicit source qube"
export SEQS_MOCK_RESOLVED_COMMIT='HEAD;touch /tmp/unsafe'
out="$(python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
	--repo-vm test-repo --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "invalid full commit ID" <<<"$out" && ok \
	|| bad "unsafe source HEAD output should be refused"
unset SEQS_MOCK_RESOLVED_COMMIT
out="$(SEQS_REPO_PATH='/home/user/SEQS;touch_unsafe' \
	python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
	--repo-vm test-repo --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "unsafe repository path" <<<"$out" && ok \
	|| bad "a shell-active repository path should be refused"
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

# ── Scenario 6b: the single-step install runs fetch+stage+build in one go ──
# The default (no explicit-stage flag) install is one confirmed command; verify
# it fetches, stages, and builds without needing the separate sub-commands.
echo "== scenario: single-step install (one command, one confirmation) =="
new_sandbox
out="$(run_setup --qubes brave 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "single-step install exited non-zero ($rc)"
grep -q "SEQS setup complete" <<<"$out" && ok || bad "single-step install did not complete"
[ -f "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "single-step install did not stage /srv"
grep -q '^template Z-brave$' "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "single-step install did not build the selected qube"
# One combined confirmation, not the old three-phase prompt.
! grep -q "Step 1/3" <<<"$out" && ok || bad "install should not show the old 3-step prompts"
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
# A network provider cannot be removed until consumers are detached. Preserve
# the consumer but set its netvm to none, including when it is still running.
printf '%s\n' "A-wireguard running" "Z-wireguard halted" "A-anon running" \
	> "${SEQS_MOCK_STATE}"
export SEQS_MOCK_NETVM_STATE="${SBX}/netvms.state"
printf '%s\n' "A-wireguard sys-firewall" "Z-wireguard none" \
	"A-anon A-wireguard" > "${SEQS_MOCK_NETVM_STATE}"
before="$(cat "${SEQS_MOCK_NETVM_STATE}")"
out="$(bash "${REPO}/delete-vms.sh" --dry-run wireguard 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "netvm dependency dry-run exited non-zero ($rc)"
grep -q "A-anon -> A-wireguard" <<<"$out" && ok \
	|| bad "dry-run should report the netvm consumer"
[ "$(cat "${SEQS_MOCK_NETVM_STATE}")" = "$before" ] && ok \
	|| bad "dry-run must not disconnect a netvm consumer"
out="$(bash "${REPO}/delete-vms.sh" wireguard 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "network-provider delete run exited non-zero ($rc)"
grep -q "^A-wireguard " "${SEQS_MOCK_STATE}" && bad "A-wireguard should have been removed" || ok
grep -q "^Z-wireguard " "${SEQS_MOCK_STATE}" && bad "Z-wireguard should have been removed" || ok
grep -qxF "A-anon running" "${SEQS_MOCK_STATE}" && ok || bad "netvm consumer must be preserved"
grep -qxF "A-anon none" "${SEQS_MOCK_NETVM_STATE}" && ok \
	|| bad "netvm consumer should be disconnected before provider removal"
unset SEQS_MOCK_NETVM_STATE
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
