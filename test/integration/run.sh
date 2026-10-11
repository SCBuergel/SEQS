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
	mkdir "${SBX}/tmp"   # the runner's TMPDIR, so that a leftover is seen in isolation
	export SEQS_SALT_TREE="${SBX}/srv/salt/seqs"
	export SEQS_PILLAR_TREE="${SBX}/srv/pillar/seqs"
	export SEQS_TARGETS_FILE="${SBX}/var/lib/seqs/targets"
	export SEQS_SELECTION_FILE="${SBX}/var/lib/seqs/selection"
	export SEQS_RUN_MANIFEST="${SBX}/var/lib/seqs/last-run"
	export SEQS_FETCH_ROOT="${SBX}/var/lib/seqs/fetched"
	export SEQS_POLICY_DIR="${SBX}/etc/qubes/policy.d"
	export SEQS_REPO_ROOT="${REPO}"
	export SEQS_EXPECTED_COMMIT
	SEQS_EXPECTED_COMMIT="$(git -C "${REPO}" rev-parse HEAD)"
	export PATH="${HERE}/mocks/bin:${REPO_ORIG_PATH}"
	unset SEQS_MOCK_TAR SEQS_MOCK_NETVM SEQS_MOCK_STATE SEQS_MOCK_DEFAULT_DISPVM
	unset SEQS_MOCK_RESOLVED_COMMIT
	unset SEQS_MOCK_SUDO_LOG
	unset SEQS_MOCK_UPDATEVM SEQS_MOCK_QVM_CREATE_LOG SEQS_MOCK_APPMENUS_LOG
	export SEQS_MOCK_EXISTING="debian-13-xfce"
}
REPO_ORIG_PATH="${PATH}"

run_setup() {  # supplies the explicit repository qube to workflows with FETCH
	local arg
	for arg in "$@"; do
		case "${arg}" in
			--stage-only|--build-only)
				TMPDIR="${SBX}/tmp" python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" "$@"
				return
				;;
		esac
	done
	TMPDIR="${SBX}/tmp" python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
		--repo-vm test-repo "$@"
}

# ── Scenario 1: full happy-path install on a fresh dom0 ────────────────────
echo "== scenario: fresh full workflow (fetch + stage + build) =="
new_sandbox
export SEQS_MOCK_APPMENUS_LOG="${SBX}/qvm-appmenus.log"
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
[ ! -e "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" ] && ok \
	|| bad "temporary GnosisVPN update policy should be removed after provisioning"
# The tree really landed in the sandbox /srv, root markers and all.
[ -f "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "dom0.sls not installed into sandbox /srv"
[ -f "${SEQS_SALT_TREE}/.seqs-managed" ] && ok || bad "missing .seqs-managed marker"
[ "$(cat "${SEQS_FETCH_ROOT}/source-commit" 2>/dev/null)" = "${SEQS_EXPECTED_COMMIT}" ] \
	&& ok || bad "fetched source commit was not recorded"
[ -f "${SEQS_SALT_TREE}/files/components/brave/template-vm.sh" ] && ok \
	|| bad "component payload not staged into files/"
[ -f "${SEQS_TARGETS_FILE}" ] && ok || bad "targets file not written by dom0 apply"
grep -q "app A-keepass keepass offline" "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "keepass should be listed offline in targets"
# The named disposable is listed as its own kind + offline, and the runner's
# air-gap pass names it alongside the offline app qubes.
grep -q "disposable D-qr-display qr-display offline" "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "the named disposable should be listed offline in targets"
grep -q "Air gap verified:.*D-qr-display" <<<"$out" && ok \
	|| bad "the named disposable should be independently air-gap verified"
# Named disposables get their menus refreshed after the template step: dom0
# refreshes only a template's direct children when it reports new entries.
grep -qx -- "--update -- D-qr-display" "${SEQS_MOCK_APPMENUS_LOG}" 2>/dev/null && ok \
	|| bad "the runner must refresh the named disposable's menu"
! grep -q "A-qr-display" "${SEQS_MOCK_APPMENUS_LOG}" 2>/dev/null && ok \
	|| bad "only named disposables need the runner's menu refresh"
rm -rf "${SBX}"

# ── Scenario 1a: a failed template skips its app qube, not the others ─────
echo "== scenario: an app qube of a failed template is not provisioned =="
new_sandbox
export SEQS_MOCK_FAIL_TEMPLATE=Z-keepass SEQS_MOCK_QUBESCTL_LOG="${SBX}/qubesctl.log"
out="$(run_setup --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "a failed template must fail the run"
grep -q "skipping A-keepass: its template failed" <<<"$out" && ok \
	|| bad "the app qube of the failed template must be reported as skipped"
grep -q -- "--targets=A-signal state.apply" "${SEQS_MOCK_QUBESCTL_LOG}" && ok \
	|| bad "the other app qube must still be provisioned"
! grep -q -- "--targets=A-keepass\|--targets=.*,A-keepass" "${SEQS_MOCK_QUBESCTL_LOG}" && ok \
	|| bad "the app qube of the failed template must not be provisioned"
grep -q "WITH FAILURES" <<<"$out" && ok || bad "the run must end with the failure message"
# Some qubesctl versions exit 0 after a failed qube; its ERROR line still counts.
export SEQS_MOCK_FAIL_RC=0
out="$(run_setup --build-only --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "WITH FAILURES" <<<"$out" && ok \
	|| bad "a qube reported as ERROR must fail the run even when qubesctl exits 0"
# A failure without a per-qube ERROR line counts for every template.
export SEQS_MOCK_FAIL_TEMPLATE=Z-keepass SEQS_MOCK_FAIL_QUIET=1 SEQS_MOCK_FAIL_RC=20
: > "${SEQS_MOCK_QUBESCTL_LOG}"
out="$(run_setup --build-only --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "skipping A-signal: its template failed" <<<"$out" && ok \
	|| bad "an unattributed template failure must skip every app qube"
unset SEQS_MOCK_FAIL_TEMPLATE SEQS_MOCK_QUBESCTL_LOG SEQS_MOCK_FAIL_RC SEQS_MOCK_FAIL_QUIET
rm -rf "${SBX}"

# ── Scenario 1a2: a template left running by an interrupted run is stopped ──
echo "== scenario: a template still running from an interrupted run is shut down first =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
printf '%s\n' "debian-13-xfce halted" "Z-keepass running" > "${SEQS_MOCK_STATE}"
out="$(run_setup --qubes keepass 2>&1)"; rc=$?
grep -q "Z-keepass is still running, perhaps from an interrupted run; shutting it down" <<<"$out" && ok \
	|| bad "a running target template must be shut down before provisioning ($rc)"
unset SEQS_MOCK_STATE
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
# An UpdateVM that provides network itself (sys-whonix) becomes the proxy's
# NetVM, so the download takes the UpdateVM's route.
echo "disp-updates provides_network True" > "${SBX}/prefs"
export SEQS_MOCK_NETVM_STATE="${SBX}/netvms"; : > "${SEQS_MOCK_NETVM_STATE}"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" run_setup --build-only --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qx "seqs-gnosisvpn-update-proxy disp-updates" "${SEQS_MOCK_NETVM_STATE}" && ok \
	|| bad "the proxy must use a network-providing UpdateVM as its NetVM ($rc): $(cat "${SEQS_MOCK_NETVM_STATE}")"
unset SEQS_MOCK_NETVM_STATE
# A Whonix gateway as UpdateVM enforces no client firewall: refuse before the
# proxy exists.
echo "debian-13-xfce whonix-gw 1" > "${SBX}/features"
: > "${SEQS_MOCK_QVM_CREATE_LOG}"
out="$(SEQS_MOCK_FEATURES="${SBX}/features" run_setup --build-only --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "is a Whonix gateway" <<<"$out" \
	&& ! grep -q seqs-gnosisvpn-update-proxy "${SEQS_MOCK_QVM_CREATE_LOG}" && ok \
	|| bad "a Whonix UpdateVM must stop the GnosisVPN build before the proxy exists"
rm -rf "${SBX}"

# ── Scenario 1c: existing GnosisVPN targets are rebuilt like other qubes ───
# Hash-based completion markers make a rerun reinstall a changed component,
# so an existing GnosisVPN instance converges in place like every other qube.
echo "== scenario: existing GnosisVPN targets converge like other qubes =="
new_sandbox
run_setup --fetch-only >/dev/null 2>&1
run_setup --stage-only >/dev/null 2>&1
export SEQS_MOCK_EXISTING="debian-13-xfce Z-gnosisvpn A-gnosisvpn"
out="$(run_setup --build-only --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "a build with existing GnosisVPN targets should succeed ($rc)"
grep -q "Applying dom0 state" <<<"$out" && ok \
	|| bad "existing GnosisVPN targets must reach the dom0 state"
grep -q "Creating domain-restricted temporary GnosisVPN updates proxy" <<<"$out" && ok \
	|| bad "existing GnosisVPN targets must still download through the temporary proxy"
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
# Only a full 40- or 64-digit object ID may reach the archive command.
for SEQS_MOCK_RESOLVED_COMMIT in 'HEAD;touch /tmp/unsafe' "${SEQS_EXPECTED_COMMIT};touch /tmp/unsafe" \
		"${SEQS_EXPECTED_COMMIT:0:12}"; do
	export SEQS_MOCK_RESOLVED_COMMIT
	out="$(python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
		--repo-vm test-repo --fetch-only 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -q "invalid full commit ID" <<<"$out" && ok \
		|| bad "source HEAD output [${SEQS_MOCK_RESOLVED_COMMIT}] should be refused"
done
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
[ -z "$(ls -A "${SBX}/tmp")" ] && ok \
	|| bad "a refused archive must leave no temporary files"
[ ! -d "${SEQS_SALT_TREE}" ] && ok || bad "nothing should have been installed from a hostile archive"
# tar warns about an unknown pax keyword and quotes it; its escape bytes must
# not reach the dom0 terminal.
python3 -c 'import io, sys, tarfile
t = tarfile.open(sys.argv[1], "w", format=tarfile.PAX_FORMAT)
i = tarfile.TarInfo("salt/x"); i.size = 1
i.pax_headers = {"EVIL\x1b]0;PWNED\x07": "1"}
t.addfile(i, io.BytesIO(b"x")); t.close()' "${SEQS_MOCK_TAR}"
out="$(run_setup --all 2>&1)"
! grep -q $'\x1b' <<<"$out" && ok || bad "an escape byte from the archive reached the terminal"
# An endless answer from the repository qube is cut off, not stored whole.
unset SEQS_MOCK_TAR
out="$(SEQS_MOCK_ENDLESS=archive run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "reached the 16000000-byte limit" <<<"$out" && ok \
	|| bad "an endless archive must be refused at the size limit: rc=$rc $(tail -n 2 <<<"$out")"
out="$(SEQS_MOCK_ENDLESS=commit run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qE "could not resolve repository HEAD|invalid full commit ID" <<<"$out" && ok \
	|| bad "an endless commit ID must be refused: rc=$rc $(tail -n 2 <<<"$out")"
[ -z "$(ls -A "${SBX}/tmp")" ] && ok \
	|| bad "a refused fetch must leave no temporary files"
rm -rf "${SBX}" "${evil}"

# ── Scenario 4: air-gap verification fails closed ──────────────────────────
echo "== scenario: a live netvm on an offline qube halts provisioning =="
new_sandbox
export SEQS_MOCK_NETVM="sys-firewall"   # keepass 'offline' but netvm present
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "verifyAirgap should abort when an offline qube has a netvm"
grep -qi "air gap NOT in effect" <<<"$out" && ok || bad "expected an air-gap failure message"
rm -rf "${SBX}"

echo "== scenario: a default disposable on an offline qube halts provisioning =="
new_sandbox
export SEQS_MOCK_DEFAULT_DISPVM="default-dvm"   # reachable via qubes.OpenInVM
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "verifyAirgap should abort when an offline qube has a default_dispvm"
grep -q "air gap NOT in effect" <<<"$out" && ok || bad "expected a default_dispvm failure message"
rm -rf "${SBX}"

echo "== scenario: an air gap inherited from a global default halts provisioning =="
new_sandbox
export SEQS_MOCK_PREFS_INHERITED=1   # None now, but only because of a global default
out="$(run_setup --all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "air gap NOT in effect" <<<"$out" && ok \
	|| bad "verifyAirgap must refuse netvm and default_dispvm that are only inherited as None"
unset SEQS_MOCK_PREFS_INHERITED
rm -rf "${SBX}"

# ── Scenario 5: an identical re-fetch is reported as already staged ────────
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
grep -q '^template Z-brave brave$' "${SEQS_TARGETS_FILE}" \
	&& grep -q '^app A-signal signal$' "${SEQS_TARGETS_FILE}" \
	&& ! grep -q 'keepass' "${SEQS_TARGETS_FILE}" \
	&& ok || bad "selected build targets should contain only brave and signal"
[ -f "${SEQS_RUN_MANIFEST}" ] && grep -q '^selection=brave=>brave,signal=>signal$' "${SEQS_RUN_MANIFEST}" \
	&& ok || bad "run manifest should record canonical selection"

out="$(run_setup --build-only --qubes gnosisvpn,signal --postfix alpha 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "postfixed multi-qube build failed"
grep -q '^template Z-gnosisvpn-alpha gnosisvpn$' "${SEQS_TARGETS_FILE}" \
	&& grep -q '^app A-signal-alpha signal$' "${SEQS_TARGETS_FILE}" \
	&& ok || bad "postfix should apply to every selected qube"
grep -q 'selection=gnosisvpn=>gnosisvpn-alpha,signal=>signal-alpha' \
	"${SEQS_RUN_MANIFEST}" && ok || bad "manifest should record recipe-to-instance mapping"
grep -q 'Z-gnosisvpn-alpha' <<<"$out" && ok \
	|| bad "GnosisVPN preparation should target the postfixed template"
out="$(run_setup --build-only --qubes brave --postfix '../unsafe' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "unsafe or empty postfix" <<<"$out" && ok \
	|| bad "unsafe postfix should be refused before the build"
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
grep -q '^template Z-brave brave$' "${SEQS_TARGETS_FILE}" 2>/dev/null && ok \
	|| bad "single-step install did not build the selected qube"
# One combined confirmation, not the old three-phase prompt.
! grep -q "Step 1/3" <<<"$out" && ok || bad "install should not show the old 3-step prompts"
rm -rf "${SBX}"

# ── Scenario 6c: confirmation and ownership gates ──────────────────────────
echo "== scenario: only y confirms; unowned or incomplete trees are refused =="
new_sandbox
out="$(PTY_RUN_ANSWERS= run_setup --qubes brave 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "not confirmed -- aborting" <<<"$out" && [ ! -e "${SEQS_SALT_TREE}" ] && ok \
	|| bad "an empty answer (Enter) must abort before anything is staged: rc=$rc"
mkdir -p "${SEQS_POLICY_DIR}"
printf '%s\n' 'qubes.OpenURL * @anyvm A-brave ask' > "${SEQS_POLICY_DIR}/29-browser.policy"
out="$(PTY_RUN_ANSWERS=y,n run_setup --qubes brave 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "were NOT written by SEQS" <<<"$out" \
	&& grep -q "qubes.OpenURL \* @anyvm A-brave ask" <<<"$out" && ok \
	|| bad "an unmarked policy file must be shown and need a y to be overwritten: rc=$rc"
rm -rf "${SEQS_POLICY_DIR}/29-browser.policy" "${SEQS_FETCH_ROOT}" "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}"
mkdir -p "${SEQS_FETCH_ROOT}/salt"
out="$(run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "fetched/salt exists but is not managed by SEQS" <<<"$out" && ok \
	|| bad "a fetch area SEQS does not own must not be replaced: rc=$rc"
rm -rf "${SEQS_FETCH_ROOT}"
run_setup --fetch-only >/dev/null 2>&1
mkdir -p "${SEQS_SALT_TREE}"
out="$(run_setup --stage-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "seqs exists but is not managed by SEQS" <<<"$out" && ok \
	|| bad "a staged tree SEQS does not own must not be replaced: rc=$rc"
rmdir "${SEQS_SALT_TREE}"
rm "${SEQS_FETCH_ROOT}/.seqs-complete"
out="$(run_setup --stage-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "fetch stage is incomplete" <<<"$out" && ok \
	|| bad "an incomplete fetch must not be staged: rc=$rc"
export SEQS_MOCK_TAR="${SBX}/garbage.tar"
printf 'not a tar archive\n' > "${SEQS_MOCK_TAR}"
out="$(run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "fetched data is not a valid tar archive" <<<"$out" && ok \
	|| bad "a fetch that is not a tar archive must be refused: rc=$rc"
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
# Dry-run: announces itself, exits 0, changes nothing.
out="$(bash "${REPO}/delete-vms.sh" --dry-run keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "dry-run exited non-zero ($rc)"
grep -q "dry-run: not killing or removing" <<<"$out" && ok || bad "expected the dry-run notice"
grep -qxF "A-keepass running" "${SEQS_MOCK_STATE}" && ok || bad "dry-run must not touch the inventory"
# Real run: A-keepass (running) and Z-keepass go, unrelated A-brave stays.
out="$(SEQS_MOCK_SUDO_LOG="${SBX}/sudo.log" bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "delete run exited non-zero ($rc)"
grep -qF "rm -f -- /var/lib/seqs/firewall/A-keepass " "${SBX}/sudo.log" && ok \
	|| bad "the removed qube's recorded firewall must be deleted"
grep -q "^A-keepass " "${SEQS_MOCK_STATE}" && bad "A-keepass should have been removed" || ok
grep -q "^Z-keepass " "${SEQS_MOCK_STATE}" && bad "Z-keepass should have been removed" || ok
grep -q "^A-brave " "${SEQS_MOCK_STATE}" && ok || bad "unrelated A-brave was removed"
# A qube built on a target blocks the deletion before anything changes.
printf '%s\n' "A-qr-camera halted" "Z-qr-camera halted" "sys-usb-webcam halted" > "${SEQS_MOCK_STATE}"
echo "sys-usb-webcam template A-qr-camera" > "${SBX}/prefs"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" bash "${REPO}/delete-vms.sh" qr-camera 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "deleting a template that another qube uses must fail"
grep -q "sys-usb-webcam has template A-qr-camera" <<<"$out" && ok || bad "the blocking qube must be named"
[ "$(wc -l < "${SEQS_MOCK_STATE}")" -eq 3 ] && grep -qxF "A-qr-camera halted" "${SEQS_MOCK_STATE}" && ok \
	|| bad "a blocked deletion must change nothing"
# A refusal for one name leaves the other names untouched too.
printf '%s\n' "A-keepass halted" "Z-keepass halted" "A-qr-camera halted" "Z-qr-camera halted" \
	"sys-usb-webcam halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" bash "${REPO}/delete-vms.sh" keepass qr-camera 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qxF "A-keepass halted" "${SEQS_MOCK_STATE}" && ok \
	|| bad "a blocked name must leave every other name's qubes in place"
# A target that is a global default blocks the deletion as well.
printf '%s\n' "A-wireguard halted" "Z-wireguard halted" > "${SEQS_MOCK_STATE}"
echo "updatevm                  -  A-wireguard" > "${SBX}/global"
out="$(SEQS_MOCK_GLOBAL_PREFS="${SBX}/global" bash "${REPO}/delete-vms.sh" wireguard 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "dom0 has updatevm A-wireguard" <<<"$out" \
	&& grep -qxF "A-wireguard halted" "${SEQS_MOCK_STATE}" && ok \
	|| bad "a global default must block the deletion and be named"
# A same-named qube that SEQS did not build is never removed; here it also
# uses the managed Z-notes as its template, so nothing is removed at all.
printf '%s\n' "A-notes halted" "Z-notes halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_UNMANAGED="A-notes" bash "${REPO}/delete-vms.sh" notes 2>&1)"; rc=$?
grep -q "skipping A-notes: SEQS did not build it" <<<"$out" && ok || bad "the unmanaged A-notes must be reported as skipped"
[ "$rc" -ne 0 ] && grep -q "A-notes has template Z-notes" <<<"$out" && ok \
	|| bad "Z-notes is A-notes's template, so its removal must be refused"
grep -q "^A-notes " "${SEQS_MOCK_STATE}" && grep -q "^Z-notes " "${SEQS_MOCK_STATE}" && ok \
	|| bad "a refused deletion must remove nothing"
# A qube whose creation was interrupted carries no seqs-managed feature yet,
# only its creation marker: SEQS built it, so it is removed with its marker.
# The CPU-pinning file SEQS wrote for a removed qube goes too; one without
# SEQS's marker is the operator's and stays.
export SEQS_STATE_DIR="${SBX}/state" SEQS_LIBVIRT_DIR="${SBX}/libvirt"
mkdir -p "${SEQS_STATE_DIR}/intents" "${SEQS_LIBVIRT_DIR}"
touch "${SEQS_STATE_DIR}/intents/A-notes"
printf '%s\n' '{# Managed by SEQS (salt state seqs.dom0) #}' x > "${SEQS_LIBVIRT_DIR}/A-notes.xml"
printf '%s\n' '<!-- operator -->' > "${SEQS_LIBVIRT_DIR}/Z-notes.xml"
printf '%s\n' "A-notes halted" "Z-notes halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_UNMANAGED="A-notes" SEQS_MOCK_SUDO_LOG="${SBX}/sudo3.log" bash "${REPO}/delete-vms.sh" notes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q "^A-notes " "${SEQS_MOCK_STATE}" && ok \
	|| bad "a qube with a creation marker must be removed: ${out}"
# On dom0 only root can read the pinning directory.
grep -qF "head -n 1 -- ${SEQS_LIBVIRT_DIR}/A-notes.xml" "${SBX}/sudo3.log" && ok \
	|| bad "the CPU-pinning file must be read through sudo"
[ ! -e "${SEQS_STATE_DIR}/intents/A-notes" ] && ok || bad "the removed qube's creation marker must be deleted"
[ ! -e "${SEQS_LIBVIRT_DIR}/A-notes.xml" ] && [ -e "${SEQS_LIBVIRT_DIR}/Z-notes.xml" ] && ok \
	|| bad "only the CPU-pinning file SEQS wrote may be deleted"
unset SEQS_STATE_DIR SEQS_LIBVIRT_DIR
# A failing qube listing must stop the deletion, not skip the blocker check.
printf '%s\n' "A-keepass halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_QVM_LS_FAIL=1 bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "^A-keepass " "${SEQS_MOCK_STATE}" && ok \
	|| bad "delete-vms.sh must stop when qvm-ls fails: rc=$rc ${out}"
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
# A target that uses another target as netvm is disconnected too, so the
# removal order between names does not matter.
printf '%s\n' "A-wireguard halted" "Z-wireguard halted" "A-mail halted" "Z-mail halted" > "${SEQS_MOCK_STATE}"
printf '%s\n' "A-wireguard sys-firewall" "Z-wireguard none" "A-mail A-wireguard" > "${SEQS_MOCK_NETVM_STATE}"
out="$(bash "${REPO}/delete-vms.sh" wireguard mail 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "A-mail none" "${SEQS_MOCK_NETVM_STATE}" && ok \
	|| bad "a target's netvm on another target must be disconnected before removal ($rc)"
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
# Unsafe name: refused before anything is looked up.
out="$(bash "${REPO}/delete-vms.sh" '../evil' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "unsafe name must be refused"
grep -q "refusing unsafe name" <<<"$out" && ok || bad "expected the unsafe-name error"
rm -rf "${SBX}"

# ── Scenario 9: hardware test reset keeps the control path ──────────────────
# test/hardware/dom0-test.sh reset deletes every SEQS qube on a test machine.
# It must never remove the control qube or sys-net, must leave stock and
# unrelated qubes alone, and must not delete an unmarked policy file.
echo "== scenario: hardware test reset removes SEQS state, keeps test-ctl and sys-net =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
# The controller is named like a SEQS app qube, so only the protection keeps it.
export SEQS_TEST_CTL_VM="A-ctl"
printf '%s\n' "A-ctl running" "sys-net running" "sys-firewall running" \
	"debian-13-xfce halted" "personal halted" "Z-keepass halted" "A-keepass running" \
	"Z-qr-display halted" "A-qr-display halted" "D-qr-display halted" \
	"seqs-qr-scanner running" "A-orphan halted" > "${SEQS_MOCK_STATE}"
# A-orphan stands for a qube an interrupted run created but never tagged:
# delete-vms.sh skips it, so reset must remove it itself.
export SEQS_MOCK_UNMANAGED="A-orphan"
export SEQS_STATE_DIR="${SBX}/var/lib/seqs" SEQS_POLICY_DIR="${SBX}/policy.d"
export SEQS_ETC_DIR="${SBX}/etc/seqs" SEQS_QR_SCRIPT="${SBX}/sbin/seqs-qr-sequential"
export SEQS_TMP_DIR="${SBX}/tmp" SEQS_TEST_DELETE_VMS="${REPO}/delete-vms.sh"
mkdir -p "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}" "${SEQS_STATE_DIR}" "${SEQS_POLICY_DIR}" \
	"${SEQS_ETC_DIR}" "${SBX}/sbin" "${SEQS_TMP_DIR}/seqs-stage.x"
touch "${SEQS_QR_SCRIPT}"
for p in 28-browser-suppress 29-browser; do
	echo "# Managed by SEQS (test)" > "${SEQS_POLICY_DIR}/${p}.policy"
done
echo "# Managed by SEQS test machine setup" > "${SEQS_POLICY_DIR}/20-seqs-test-control.policy"
out="$(bash "${REPO}/test/hardware/dom0-test.sh" reset 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "reset exited non-zero ($rc): ${out}"
remaining="$(cut -d' ' -f1 "${SEQS_MOCK_STATE}" | sort | tr '\n' ' ')"
[ "${remaining}" = "A-ctl debian-13-xfce personal sys-firewall sys-net " ] && ok \
	|| bad "reset left the wrong qubes: ${remaining}"
for d in "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}" "${SEQS_STATE_DIR}" "${SEQS_ETC_DIR}" \
		"${SEQS_QR_SCRIPT}" "${SEQS_TMP_DIR}/seqs-stage.x" "${SEQS_POLICY_DIR}/29-browser.policy"; do
	[ ! -e "${d}" ] && ok || bad "reset left ${d}"
done
[ -e "${SEQS_POLICY_DIR}/20-seqs-test-control.policy" ] && ok \
	|| bad "reset must not remove the test-control policy"
# An unmarked file under a SEQS policy name is reported and kept.
echo "qubes.InputKeyboard * sys-usb @adminvm allow" > "${SEQS_POLICY_DIR}/30-user-input.policy"
out="$(bash "${REPO}/test/hardware/dom0-test.sh" reset 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "reset should fail on an unmarked SEQS policy name"
[ -e "${SEQS_POLICY_DIR}/30-user-input.policy" ] && ok || bad "reset removed an unmarked policy"
unset SEQS_STATE_DIR SEQS_POLICY_DIR SEQS_ETC_DIR SEQS_QR_SCRIPT SEQS_TMP_DIR SEQS_TEST_DELETE_VMS SEQS_TEST_CTL_VM SEQS_MOCK_UNMANAGED
rm -rf "${SBX}"

# ── Scenario 10: the sequential QR script refuses before the camera phase ───
# Every check before "Type START" must stop the script without powering off.
# The test runs a copy that reads its configuration from the sandbox and
# skips the root check; mocks local to this scenario stand in for Qubes.
echo "== scenario: sequential QR script refuses an unsafe state before START =="
SBX="$(mktemp -d)"
mkdir -p "${SBX}/bin"
sed -e "s#^CONF=.*#CONF=${SBX}/conf#" -e 's/^\[ "\${EUID}" -eq 0 \].*$/:/' \
	"${REPO}/salt/seqs/files/qr-sequential.sh" > "${SBX}/qr.sh"
write_mock() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${SBX}/bin/$1"; chmod +x "${SBX}/bin/$1"; }
write_mock qvm-check 'n="${!#}"; case " $* " in *" --running "*) grep -qx "$n" "'"${SBX}"'/running" ;; *) grep -qx "$n" "'"${SBX}"'/exists" ;; esac'
write_mock qvm-prefs 'awk -v k="$2 $3" '"'"'$1" "$2 == k { print $3; f=1 } END { exit !f }'"'"' "'"${SBX}"'/prefs"'
write_mock qvm-run 'echo "$*" >> "'"${SBX}"'/qvm-run.log"; cat "'"${SBX}"'/staged"'
write_mock qvm-usb ':'
write_mock qvm-kill ':'
write_mock qvm-shutdown ':'
write_mock systemctl 'echo "$*" >> "'"${SBX}"'/systemctl.log"'
qr_case() {  # NAME EXPECTED-OUTPUT -- run with the current fixture files
	local out
	out="$(PATH="${SBX}/bin:${PATH}" setsid bash "${SBX}/qr.sh" </dev/null 2>&1)" \
		&& bad "$1: the script must not succeed without START"
	grep -qF -- "$2" <<<"${out}" && ok || bad "$1: expected '$2', got: $(tail -n 1 <<<"${out}")"
	[ ! -e "${SBX}/systemctl.log" ] && ok || bad "$1: the script powered off before the camera phase"
}
qr_reset() {
	local vm
	printf '%s\n' "NORMAL_USB_QUBE=sys-usb" "WEBCAM_USB_QUBE=sys-usb-webcam" "SCANNER_QUBE=seqs-qr-scanner" \
		"STAGING_QUBE=A-qr-staging" "CONTROLLER=00_14.0" > "${SBX}/conf"
	printf '%s\n' sys-usb sys-usb-webcam seqs-qr-scanner A-qr-staging > "${SBX}/exists"
	echo sys-usb > "${SBX}/running"
	echo ABSENT > "${SBX}/staged"
	: > "${SBX}/prefs"
	for vm in sys-usb-webcam seqs-qr-scanner A-qr-staging; do
		printf '%s netvm \n%s default_dispvm \n' "${vm}" "${vm}" >> "${SBX}/prefs"
	done
}
if command -v setsid >/dev/null 2>&1; then
	qr_reset; qr_case "a safe state" "SEQS SEQUENTIAL-PATH QR SCAN"
	qr_reset; echo 'SCANNER_QUBE="x;y"' >> "${SBX}/conf"; qr_case "unsafe name" "unsafe qube name"
	qr_reset; echo 'CONTROLLER=00_14.0x' >> "${SBX}/conf"; qr_case "bad BDF" "invalid controller BDF"
	qr_reset; sed -i '/^A-qr-staging$/d' "${SBX}/exists"; qr_case "missing qube" "required qube 'A-qr-staging' is missing"
	qr_reset; echo sys-usb-webcam >> "${SBX}/running"; qr_case "webcam backend running" "sys-usb-webcam is already running"
	qr_reset; echo seqs-qr-scanner >> "${SBX}/running"; qr_case "scanner running" "seqs-qr-scanner is already running"
	qr_reset; echo PRESENT > "${SBX}/staged"; qr_case "old key.asc" "already holds an incoming key.asc"
	qr_reset; : > "${SBX}/staged"; qr_case "staging unreadable" "could not check A-qr-staging"
	for vm in sys-usb-webcam seqs-qr-scanner A-qr-staging; do
		for pref in netvm default_dispvm; do
			qr_reset; sed -i "s/^${vm} ${pref} $/${vm} ${pref} sys-firewall/" "${SBX}/prefs"
			rm -f "${SBX}/qvm-run.log"
			qr_case "${vm} ${pref}" "'${vm}' has ${pref} set"
			[ ! -e "${SBX}/qvm-run.log" ] && ok \
				|| bad "${vm} ${pref}: the script started a qube before refusing a networked camera side"
		done
	done
else
	printf '  skip: setsid not available\n'
fi
# After START, the keyboard's controller is exposed to the camera side: every
# outcome, success included, must end in a power-off. The camera phase runs
# under a pseudo-terminal that types the answer.
write_mock sleep ':'
write_mock qvm-start ':'
write_mock qvm-shutdown 'sed -i "/^${!#}$/d" "'"${SBX}"'/running"'
write_mock qvm-usb 'cat "'"${SBX}"'/usb" 2>/dev/null; :'
write_mock qvm-run 'case "$*" in *zbarcam*) exit "$(cat "'"${SBX}"'/scan_rc")" ;; *) cat "'"${SBX}"'/staged" ;; esac'
qr_camera() {  # NAME ANSWER EXPECTED-OUTPUT POWEROFF(yes|no)
	local out
	rm -f "${SBX}/systemctl.log"
	out="$(PATH="${SBX}/bin:${PATH}" PTY_RUN_PROMPT="Type START" PTY_RUN_ANSWERS="$2" \
		python3 "${REPO}/test/lib/pty_run.py" bash "${SBX}/qr.sh" 2>&1)"
	grep -qF -- "$3" <<<"${out}" && ok || bad "$1: expected '$3', got: $(tail -n 2 <<<"${out}" | tr -d '\r')"
	if [ "$4" = yes ]; then
		grep -qx poweroff "${SBX}/systemctl.log" 2>/dev/null && ok || bad "$1: the camera phase must end in a power-off"
	else
		[ ! -e "${SBX}/systemctl.log" ] && ok || bad "$1: the script powered off without START"
	fi
}
qr_reset; echo 0 > "${SBX}/scan_rc"; printf 'sys-usb-webcam:2-1 Webcam\n' > "${SBX}/usb"
qr_camera "wrong answer" start "Not confirmed; nothing changed." no
qr_camera "one webcam" START "Ciphertext copy completed" yes
printf 'sys-usb-webcam:2-1 Webcam\nsys-usb-webcam:2-2 Keyboard\n' > "${SBX}/usb"
qr_camera "two devices" START "expected exactly one USB device in sys-usb-webcam, found 2" yes
printf 'sys-usb-webcam:2-1;x Webcam\n' > "${SBX}/usb"
qr_camera "unsafe device" START "unsafe device identifier" yes
printf 'sys-usb-webcam:2-1 Webcam\n' > "${SBX}/usb"; echo 1 > "${SBX}/scan_rc"
qr_camera "failed scan" START "scan/copy failed" yes
rm -rf "${SBX}"

echo
echo "integration tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
