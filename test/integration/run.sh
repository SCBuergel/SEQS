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
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3], got [$2]"; }

# mocks/bin/systemctl records any call that reached systemctl through PATH;
# without it, such a call could power off the machine running the tests.
# The xfconf-query and xfce4-panel tripwires do the same for the host's panel.
export SEQS_TRIPWIRE_LOG
SEQS_TRIPWIRE_LOG="$(mktemp)"

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
	export SEQS_DESKTOP_FILE="${SBX}/var/lib/seqs/desktop" XDG_CONFIG_HOME="${SBX}/config"
	export SEQS_REPO_ROOT="${REPO}"
	export SEQS_EXPECTED_COMMIT
	SEQS_EXPECTED_COMMIT="$(git -C "${REPO}" rev-parse HEAD)"
	export PATH="${HERE}/mocks/bin:${REPO_ORIG_PATH}"
	unset SEQS_MOCK_TAR SEQS_MOCK_NETVM SEQS_MOCK_STATE SEQS_MOCK_DEFAULT_DISPVM
	unset SEQS_MOCK_RESOLVED_COMMIT
	unset SEQS_MOCK_SUDO_LOG
	unset SEQS_MOCK_UPDATEVM SEQS_MOCK_QVM_CREATE_LOG SEQS_MOCK_APPMENUS_LOG
	unset SEQS_MOCK_FIREWALL_LOG SEQS_MOCK_POLICY_COPY SEQS_MOCK_DOM0_FAIL_RC
	export SEQS_MOCK_EXISTING="debian-13-xfce"
}
REPO_ORIG_PATH="${PATH}"

# write_names PREFIX... -- the record of names seqs.dom0 writes for
# delete-vms.sh, with these prefixes and the QR camera qubes (by default
# sys-usb-webcam and seqs-qr-scanner, or USB_QUBE and SCANNER_QUBE).
write_names() {
	mkdir -p "${SEQS_STATE_DIR}"
	{ echo "# Managed by SEQS (test)"; printf 'prefix %s\n' "$@"
	  echo "usb-qube ${USB_QUBE:-sys-usb-webcam}"; echo "qube ${SCANNER_QUBE:-seqs-qr-scanner}"; } > "${SEQS_STATE_DIR}/names"
}

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
export SEQS_MOCK_FIREWALL_LOG="${SBX}/qvm-firewall.log" SEQS_MOCK_POLICY_COPY="${SBX}/gnosis.policy"
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
# The download proxy may reach only DNS and the GnosisVPN host, and only the
# GnosisVPN template may use it, for its updates proxy service alone.
p=seqs-gnosisvpn-update-proxy
eq "the proxy's firewall" "$(cat "${SEQS_MOCK_FIREWALL_LOG}")" "$(printf '%s\n' "-- $p reset" "-- $p del --rule-no 0" \
	"-- $p add accept specialtarget=dns" "-- $p add accept dsthost=download.gnosisvpn.io proto=tcp dstports=443" \
	"-- $p add drop")"
eq "the temporary policy" "$(cat "${SEQS_MOCK_POLICY_COPY}")" "$(printf '%s\n' "# Managed by SEQS" \
	"qubes.UpdatesProxy * Z-gnosisvpn @default allow target=$p" "qubes.UpdatesProxy * Z-gnosisvpn @anyvm deny")"
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
# Neither may an ERROR line printed by another template narrow it down.
export SEQS_MOCK_FAIL_RC=0 SEQS_MOCK_FAIL_OUTPUT='          Result: False\nZ-signal: ERROR forged by a template'
out="$(run_setup --build-only --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "skipping A-keepass: its template failed" <<<"$out" && ok \
	|| bad "a forged ERROR line must not narrow an unattributed failure"
# With --verbose the output holds the templates' own lines, so a forged ERROR
# line must not narrow a non-zero exit either.
export SEQS_MOCK_FAIL_RC=20 SEQS_MOCK_FAIL_OUTPUT='Z-signal: ERROR forged by a template'
: > "${SEQS_MOCK_QUBESCTL_LOG}"
out="$(run_setup --build-only --verbose --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "skipping A-keepass: its template failed" <<<"$out" \
	&& ! grep -q -- "--targets=A-keepass\|--targets=.*,A-keepass" "${SEQS_MOCK_QUBESCTL_LOG}" && ok \
	|| bad "with --verbose a forged ERROR line must not narrow an unattributed failure"
# An app qube whose template cannot be read might be based on the failed one.
unset SEQS_MOCK_FAIL_QUIET SEQS_MOCK_FAIL_OUTPUT; export SEQS_MOCK_FAIL_RC=20
echo "A-signal template " > "${SBX}/prefs"; : > "${SEQS_MOCK_QUBESCTL_LOG}"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" run_setup --build-only --qubes keepass,signal 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "could not read the template of A-signal" <<<"$out" \
	&& ! grep -q -- "--targets=.*A-signal" "${SEQS_MOCK_QUBESCTL_LOG}" && ok \
	|| bad "an unreadable template must stop the run before app qubes are provisioned"
unset SEQS_MOCK_FAIL_TEMPLATE SEQS_MOCK_QUBESCTL_LOG SEQS_MOCK_FAIL_RC SEQS_MOCK_FAIL_QUIET SEQS_MOCK_FAIL_OUTPUT
rm -rf "${SBX}"

# ── Scenario 1a1: a failed dom0 state stops the run before any qube ──────
echo "== scenario: a failed seqs.dom0 apply provisions no qube =="
new_sandbox
export SEQS_MOCK_QUBESCTL_LOG="${SBX}/qubesctl.log"
# Exit 0 with a failed state in the output, then a non-zero exit.
for SEQS_MOCK_DOM0_FAIL_RC in 0 1; do
	export SEQS_MOCK_DOM0_FAIL_RC; : > "${SEQS_MOCK_QUBESCTL_LOG}"
	out="$(run_setup --qubes keepass,signal 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -q "seqs.dom0 failed -- nothing was provisioned" <<<"$out" \
		&& [ ! -s "${SEQS_MOCK_QUBESCTL_LOG}" ] && ok \
		|| bad "a failed seqs.dom0 apply (exit ${SEQS_MOCK_DOM0_FAIL_RC}) must stop the run before seqs.qube: ${out}"
done
unset SEQS_MOCK_DOM0_FAIL_RC SEQS_MOCK_QUBESCTL_LOG
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

# ── Scenario 1b1: qubes routed through a VPN qube ──────────────────────────
echo "== scenario: a qube with a 'netvm' is verified, then provisioned after its provider =="
new_sandbox
export SEQS_MOCK_QUBESCTL_LOG="${SBX}/qubesctl.log"
out="$(run_setup --qubes gnosisvpn,anon 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "NetVM verified: A-anon uses A-gnosisvpn" <<<"$out" \
	&& grep -q "NetVM verified: D-anon uses A-gnosisvpn" <<<"$out" && ok \
	|| bad "both NetVMs must be verified ($rc): $(tail -n 3 <<<"$out")"
grep -qF "No default disposable verified on A-anon A-gnosisvpn D-anon." <<<"$out" && ok \
	|| bad "the no_handoff qubes' default disposable must be verified: $(grep -i 'default disposable' <<<"$out")"
eq "the provider's wave comes first" "$(grep -o -- "--targets=A-[^ ]*" "${SEQS_MOCK_QUBESCTL_LOG}" | tail -n 2 | tr '\n' ' ')" \
	"--targets=A-gnosisvpn --targets=A-anon "
echo "A-anon netvm sys-firewall" > "${SBX}/prefs"; : > "${SEQS_MOCK_QUBESCTL_LOG}"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" run_setup --build-only --qubes gnosisvpn,anon 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "qube 'A-anon' does not have its netvm explicitly set to 'A-gnosisvpn'" <<<"$out" \
	&& ! grep -q "state.apply seqs.qube" "${SEQS_MOCK_QUBESCTL_LOG}" && ok \
	|| bad "a wrong NetVM must stop the build before anything is provisioned"
unset SEQS_MOCK_QUBESCTL_LOG
rm -rf "${SBX}"

# ── Scenario 1b2: a killed run's GnosisVPN proxy and policy are removed ─────
echo "== scenario: any build first removes a GnosisVPN proxy and policy a killed run left =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
printf '%s\n' "debian-13-xfce halted" "seqs-gnosisvpn-update-proxy halted" > "${SEQS_MOCK_STATE}"
echo "seqs-gnosisvpn-update-proxy seqs-gnosisvpn-temporary-proxy 1" > "${SBX}/features"
mkdir -p "${SEQS_POLICY_DIR}"
echo "# Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten." \
	| tee "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" > "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy.new"
# The air-gap check stops this build before its own proxy cleanup would run.
SEQS_MOCK_NETVM=sys-firewall SEQS_MOCK_FEATURES="${SBX}/features" run_setup --qubes keepass >/dev/null 2>&1
! grep -q "^seqs-gnosisvpn-update-proxy " "${SEQS_MOCK_STATE}" && ok \
	|| bad "a build must remove the temporary GnosisVPN proxy a killed run left"
[ ! -e "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" ] \
	&& [ ! -e "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy.new" ] && ok \
	|| bad "a build must remove the temporary GnosisVPN policy and its partial copy"
unset SEQS_MOCK_STATE
rm -rf "${SBX}"

# ── Scenario 1b3: a GnosisVPN proxy policy or qube SEQS did not make is kept ─
echo "== scenario: a GnosisVPN build refuses an unmarked proxy policy or proxy qube =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
mkdir -p "${SEQS_POLICY_DIR}"
echo "qubes.UpdatesProxy * @anyvm @default allow target=sys-firewall" > "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy"
echo "debian-13-xfce halted" > "${SEQS_MOCK_STATE}"
out="$(run_setup --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "20-seqs-gnosisvpn-updates.policy exists but is not managed by SEQS" <<<"$out" \
	&& grep -qF "target=sys-firewall" "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" \
	&& ! grep -q "^seqs-gnosisvpn-update-proxy " "${SEQS_MOCK_STATE}" && ok \
	|| bad "an unmarked GnosisVPN proxy policy must stop the build and stay: $(tail -n 1 <<<"$out")"
rm -f "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy"
printf '%s\n' "debian-13-xfce halted" "seqs-gnosisvpn-update-proxy halted" > "${SEQS_MOCK_STATE}"
out="$(run_setup --build-only --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "seqs-gnosisvpn-update-proxy exists but is not marked as the SEQS temporary proxy" <<<"$out" \
	&& grep -q "^seqs-gnosisvpn-update-proxy " "${SEQS_MOCK_STATE}" && ok \
	|| bad "an unmarked qube named like the GnosisVPN proxy must stop the build and stay: $(tail -n 1 <<<"$out")"
unset SEQS_MOCK_STATE
rm -rf "${SBX}"

# ── Scenario 1b4: a GnosisVPN proxy or policy that survives cleanup ────────
echo "== scenario: a GnosisVPN build fails when its proxy or policy cannot be removed =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
echo "debian-13-xfce halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_SUDO_REFUSE="rm -f *.policy" run_setup --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "temporary GnosisVPN updates policy was not removed" <<<"$out" && ok \
	|| bad "a policy that cleanup cannot remove must fail the build ($rc): $(tail -n 1 <<<"$out")"
rm -f "${SEQS_POLICY_DIR}/20-seqs-gnosisvpn-updates.policy"
# A qube that uses the proxy as its NetVM makes qvm-remove refuse it.
echo "debian-13-xfce halted" > "${SEQS_MOCK_STATE}"
export SEQS_MOCK_NETVM_STATE="${SBX}/netvms"
echo "stuck seqs-gnosisvpn-update-proxy" > "${SEQS_MOCK_NETVM_STATE}"
out="$(run_setup --build-only --qubes gnosisvpn 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "temporary GnosisVPN updates proxy was not removed" <<<"$out" && ok \
	|| bad "a proxy that cleanup cannot remove must fail the build ($rc): $(tail -n 1 <<<"$out")"
unset SEQS_MOCK_STATE SEQS_MOCK_NETVM_STATE
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
# Unsafe qube names on the command line stop the run before anything else.
out="$(python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
	--repo-vm -x --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "unsafe repo qube name: '-x'" <<<"$out" && ok \
	|| bad "an option-like --repo-vm should be refused: $(tail -n 1 <<<"$out")"
out="$(python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/setup-qubes.sh" \
	--build-only --qubes 'brave,-x' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "unsafe or empty qube base name in --qubes: '-x'" <<<"$out" && ok \
	|| bad "an option-like --qubes name should be refused: $(tail -n 1 <<<"$out")"
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
grep -qF "refusing non-regular tar entry (type 'l'): salt/steal" <<<"$out" && ok \
	|| bad "expected the symlink's 'refusing non-regular tar entry' message"
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
# GNU tar lists a trailing space unquoted, so the name must be checked unsplit.
python3 -c 'import io, sys, tarfile
t = tarfile.open(sys.argv[1], "w")
i = tarfile.TarInfo("salt/seqs/dom0.top "); i.size = 1
t.addfile(i, io.BytesIO(b"x")); t.close()' "${SEQS_MOCK_TAR}"
out="$(run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "refusing tar entry with whitespace around its name: 'salt/seqs/dom0.top'" <<<"$out" \
	&& [ ! -e "${SEQS_FETCH_ROOT}" ] && ok \
	|| bad "a name with a trailing space must be refused: rc=$rc $(tail -n 2 <<<"$out")"
# A compressed archive could expand past the size limit: tar must refuse it
# instead of decompressing it.
SEQS_MOCK_TAR="${SBX}/tree.tar.gz"
tar -C "${REPO}" -czf "${SEQS_MOCK_TAR}" salt install-scripts
out="$(run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "not a valid tar archive" <<<"$out" && ok \
	|| bad "a compressed archive must be refused: rc=$rc $(tail -n 2 <<<"$out")"
# A right-to-left override can make a line display as a comment while it runs
# as code, a terminal escape can hide it in a pager, and a zero-width space can
# make two names look alike, as can a tag or variation selector; the whole tree
# is refused, not only that file.
mkdir -p "${evil}/install-scripts"
for hide in 'right-to-left override:\xe2\x80\xae' 'terminal escape:\x1b[8m' 'zero-width space:\xe2\x80\x8b' \
	'tag character:\xf3\xa0\x80\x81' 'variation selector:\xef\xb8\x8f'; do
	printf "true # ${hide#*:}; reviewed\\n" > "${evil}/install-scripts/x.sh"
	SEQS_MOCK_TAR="${SBX}/hidden.tar"
	tar -C "${REPO}" -cf "${SEQS_MOCK_TAR}" salt install-scripts
	tar -C "${evil}" -rf "${SEQS_MOCK_TAR}" install-scripts/x.sh
	out="$(run_setup --fetch-only 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -qF "refusing archive: install-scripts/x.sh has control or invisible characters" <<<"$out" \
		&& [ ! -e "${SEQS_FETCH_ROOT}" ] && ok \
		|| bad "an archive with a ${hide%%:*} must be refused: rc=$rc $(tail -n 2 <<<"$out")"
done
# An endless answer from the repository qube is cut off, not stored whole.
unset SEQS_MOCK_TAR
export SEQS_MOCK_ENDLESS_LOG="${SBX}/endless.log"
out="$(SEQS_MOCK_ENDLESS=archive run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "reached the 16000000-byte limit" <<<"$out" && ok \
	|| bad "an endless archive must be refused at the size limit: rc=$rc $(tail -n 2 <<<"$out")"
out="$(SEQS_MOCK_ENDLESS=commit run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qE "could not resolve repository HEAD|invalid full commit ID" <<<"$out" && ok \
	|| bad "an endless commit ID must be refused: rc=$rc $(tail -n 2 <<<"$out")"
[ ! -e "${SEQS_MOCK_ENDLESS_LOG}" ] && ok \
	|| bad "the runner read a whole oversized answer instead of stopping at its limit: $(cat "${SEQS_MOCK_ENDLESS_LOG}")"
unset SEQS_MOCK_ENDLESS_LOG
# git archive applies the commit's own .gitattributes: with export-subst, a
# file's $Format:%b$ becomes the commit message body, so the staged bytes are
# not the reviewed blobs. A commit holding one anywhere is refused unexported.
attr="$(mktemp -d)"
git -C "${REPO}" archive HEAD salt install-scripts | tar -C "${attr}" -xf -
git -C "${attr}" init -q -b main
for where in . install-scripts/lib; do
	echo '* export-subst' > "${attr}/${where}/.gitattributes"
	git -C "${attr}" add -A && git -C "${attr}" -c user.name=t -c user.email=t@example.invalid \
		-c commit.gpgsign=false commit -q -m attributes
	SEQS_EXPECTED_COMMIT="$(git -C "${attr}" rev-parse HEAD)"
	out="$(SEQS_REPO_ROOT="${attr}" run_setup --fetch-only 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -qF "refusing source HEAD commit ${SEQS_EXPECTED_COMMIT}: its tree holds a .gitattributes file" <<<"$out" \
		&& [ ! -e "${SEQS_FETCH_ROOT}" ] && ok \
		|| bad "a commit with ${where}/.gitattributes must be refused: rc=$rc $(tail -n 2 <<<"$out")"
	rm "${attr}/${where}/.gitattributes"
done
[ -z "$(ls -A "${SBX}/tmp")" ] && ok \
	|| bad "a refused fetch must leave no temporary files"
rm -rf "${SBX}" "${evil}" "${attr}"

# ── Scenario 3b: fetch never replaces a fetched area SEQS does not own ──────
echo "== scenario: fetch refuses to replace an unmarked fetched area =="
new_sandbox
out="$(run_setup --fetch-only 2>&1)" && ok || bad "a clean fetch failed: $(tail -n 2 <<<"$out")"
rm -f "${SEQS_FETCH_ROOT}/salt/.seqs-managed"; touch "${SEQS_FETCH_ROOT}/salt/user-file"
out="$(run_setup --fetch-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "salt exists but is not managed by SEQS" <<<"$out" \
	&& [ -e "${SEQS_FETCH_ROOT}/salt/user-file" ] && ok \
	|| bad "fetch must refuse to replace an unmarked fetched area: $(tail -n 1 <<<"$out")"
rm -rf "${SBX}"

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

echo "== scenario: a default disposable on a no_handoff qube halts provisioning =="
new_sandbox
out="$(SEQS_MOCK_DEFAULT_DISPVM=default-dvm run_setup --qubes wallet-ledger 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "qube 'A-wallet-ledger' does not have default_dispvm explicitly set to none" <<<"$out" && ok \
	|| bad "verifyNoDispvm should abort when a no_handoff qube has a default disposable: rc=$rc $(tail -n 1 <<<"$out")"
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

# ── Scenario 6b2: a second usb_keyboard_prompt assignment keeps the prompt ──
echo "== scenario: the 30-user-input takeover prompt survives a reassigned False =="
new_sandbox
run_setup --fetch-only >/dev/null 2>&1
run_setup --stage-only >/dev/null 2>&1
sed -i 's/^{%- set usb_keyboard_prompt = True %}$/{%- set usb_keyboard_prompt = False %}\n  {%- set usb_keyboard_prompt = True %}/' \
	"${SEQS_PILLAR_TREE}/config.sls"
mkdir -p "${SEQS_POLICY_DIR}"
printf '%s\n' 'qubes.InputKeyboard * sys-usb @adminvm deny' > "${SEQS_POLICY_DIR}/30-user-input.policy"
out="$(PTY_RUN_ANSWERS=n run_setup --build-only --qubes brave 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "##  ${SEQS_POLICY_DIR}/30-user-input.policy:" <<<"$out" \
	&& grep -qF "##      qubes.InputKeyboard * sys-usb @adminvm deny" <<<"$out" && ok \
	|| bad "a False line reassigned below must keep the 30-user-input takeover prompt: rc=$rc"
rm -rf "${SBX}"

# ── Scenario 6c: confirmation and ownership gates ──────────────────────────
echo "== scenario: only y confirms; unowned or incomplete trees are refused =="
new_sandbox
out="$(PTY_RUN_ANSWERS= run_setup --qubes brave 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "not confirmed -- aborting" <<<"$out" && [ ! -e "${SEQS_SALT_TREE}" ] && ok \
	|| bad "an empty answer (Enter) must abort before anything is staged: rc=$rc"
mkdir -p "${SEQS_POLICY_DIR}"
printf '%s\n' 'qubes.OpenURL * @anyvm A-brave ask' > "${SEQS_POLICY_DIR}/29-browser.policy"
printf '%s\n' 'admin.vm.List * A-x @anyvm allow target=dom0' > "${SEQS_POLICY_DIR}/50-seqs-audiovm.policy"
out="$(PTY_RUN_ANSWERS=y,n run_setup --qubes brave 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "were NOT written by SEQS" <<<"$out" \
	&& grep -q "qubes.OpenURL \* @anyvm A-brave ask" <<<"$out" \
	&& grep -q "admin.vm.List \* A-x @anyvm allow" <<<"$out" && ok \
	|| bad "an unmarked policy file must be shown and need a y to be overwritten: rc=$rc"
rm -rf "${SEQS_POLICY_DIR}/29-browser.policy" "${SEQS_POLICY_DIR}/50-seqs-audiovm.policy" "${SEQS_FETCH_ROOT}" "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}"
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
export SEQS_STATE_DIR="${SBX}/state"
write_names D- A- Z-
printf '%s\n' "A-keepass running" "Z-keepass halted" "A-brave halted" > "${SEQS_MOCK_STATE}"
# Dry-run: announces itself, exits 0, changes nothing.
out="$(bash "${REPO}/delete-vms.sh" --dry-run keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "dry-run exited non-zero ($rc)"
grep -q "dry-run: not killing or removing" <<<"$out" && ok || bad "expected the dry-run notice"
grep -qxF "A-keepass running" "${SEQS_MOCK_STATE}" && ok || bad "dry-run must not touch the inventory"
# Real run: A-keepass (running) and Z-keepass go, unrelated A-brave stays.
out="$(SEQS_MOCK_SUDO_LOG="${SBX}/sudo.log" bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "delete run exited non-zero ($rc)"
grep -qF "rm -f -- ${SEQS_STATE_DIR}/firewall/A-keepass " "${SBX}/sudo.log" && ok \
	|| bad "the removed qube's recorded firewall must be deleted"
grep -q "^A-keepass " "${SEQS_MOCK_STATE}" && bad "A-keepass should have been removed" || ok
grep -q "^Z-keepass " "${SEQS_MOCK_STATE}" && bad "Z-keepass should have been removed" || ok
grep -q "^A-brave " "${SEQS_MOCK_STATE}" && ok || bad "unrelated A-brave was removed"
# The removed qube's panel launcher and monitor go; another qube's, and the
# user's own launchers, stay.
mkdir -p "${SBX}/xbin" "${SBX}/config/xfce4/panel/launcher-16" "${SBX}/config/xfce4/panel/launcher-19" \
	"${SBX}/config/xfce4/panel/launcher-20" "${SBX}/config/xfce4/panel/launcher-1"
# Launchers added by hand carry no mark: only their entries that start the
# removed qube go, and a launcher left with none goes too.
printf '[Desktop Entry]\nX-Qubes-VmName=A-keepass\n' > "${SBX}/config/xfce4/panel/launcher-19/1.desktop"
printf '[Desktop Entry]\nX-Qubes-VmName=A-brave\n' > "${SBX}/config/xfce4/panel/launcher-19/2.desktop"
printf '[Desktop Entry]\nX-Qubes-VmName=A-keepass\n' > "${SBX}/config/xfce4/panel/launcher-20/3.desktop"
printf '[Desktop Entry]\nExec=xfce4-terminal\n' > "${SBX}/config/xfce4/panel/launcher-1/4.desktop"
printf '#!/bin/sh\nexec python3 %s "$@"\n' "${REPO}/test/lib/fake_xfconf.py" > "${SBX}/xbin/xfconf-query"
printf '#!/bin/sh\necho $PPID\n' > "${SBX}/xbin/pgrep"
printf '#!/bin/sh\necho restarted >> %s\n' "${SBX}/panel.log" > "${SBX}/xbin/xfce4-panel"
chmod +x "${SBX}/xbin/"*
echo '{"/panels": ["1", "2"], "/panels/panel-1/plugin-ids": ["1", "16", "17", "18", "19"],
  "/panels/panel-2/plugin-ids": ["20"],
  "/plugins/plugin-1": "launcher", "/plugins/plugin-1/items": ["4.desktop"],
  "/plugins/plugin-19": "launcher", "/plugins/plugin-19/items": ["1.desktop", "2.desktop"],
  "/plugins/plugin-20": "launcher", "/plugins/plugin-20/items": ["3.desktop"],
  "/plugins/plugin-18": "genmon", "/plugins/plugin-18/seqs-monitor": "A-keepass", "/plugins/plugin-18/command": "x",
  "/plugins/plugin-16": "launcher", "/plugins/plugin-16/seqs-qube": "A-keepass", "/plugins/plugin-16/items": ["seqs-1.desktop"],
  "/plugins/plugin-17": "launcher", "/plugins/plugin-17/seqs-qube": "A-brave"}' > "${SBX}/xfconf.json"
printf '%s\n' "A-keepass halted" "A-brave halted" > "${SEQS_MOCK_STATE}"
PATH="${SBX}/xbin:${PATH}" SEQS_FAKE_XFCONF="${SBX}/xfconf.json" XDG_CONFIG_HOME="${SBX}/config" \
	bash "${REPO}/delete-vms.sh" keepass >/dev/null 2>&1
python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))
sys.exit(s["/panels/panel-1/plugin-ids"] != ["1", "17", "19"]
         or any(k.startswith(("/plugins/plugin-16", "/plugins/plugin-18", "/plugins/plugin-20")) for k in s)
         or s.get("/plugins/plugin-17/seqs-qube") != "A-brave"
         or s.get("/plugins/plugin-19/items") != ["2.desktop"]
         or s.get("/plugins/plugin-1/items") != ["4.desktop"])' "${SBX}/xfconf.json" && ok \
	|| bad "only the removed qube's panel launchers, monitor and entries may go: $(cat "${SBX}/xfconf.json")"
# A panel whose only plugin went keeps existing, with no plugin list, as
# xfce4-panel itself saves an empty panel.
python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))
sys.exit(s["/panels"] != ["1", "2"] or any(k.startswith("/panels/panel-2/plugin-ids") for k in s))' \
	"${SBX}/xfconf.json" && ok || bad "an emptied panel must lose its plugin list but stay: $(cat "${SBX}/xfconf.json")"
L="${SBX}/config/xfce4/panel"
[ ! -e "${L}/launcher-16" ] && [ ! -e "${L}/launcher-20" ] && [ ! -e "${L}/launcher-19/1.desktop" ] \
	&& [ -e "${L}/launcher-19/2.desktop" ] && [ -e "${L}/launcher-1/4.desktop" ] && [ -s "${SBX}/panel.log" ] && ok \
	|| bad "the removed qube's launcher files and entries must go, others stay, and the panel restart"
# A qube built on a target blocks the deletion before anything changes.
printf '%s\n' "A-qr-camera halted" "Z-qr-camera halted" "sys-usb-webcam halted" > "${SEQS_MOCK_STATE}"
echo "sys-usb-webcam template A-qr-camera" > "${SBX}/prefs"
out="$(SEQS_MOCK_PREFS="${SBX}/prefs" bash "${REPO}/delete-vms.sh" qr-camera 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "deleting a template that another qube uses must fail"
grep -q "sys-usb-webcam has template A-qr-camera" <<<"$out" && ok || bad "the blocking qube must be named"
[ "$(wc -l < "${SEQS_MOCK_STATE}")" -eq 3 ] && grep -qxF "A-qr-camera halted" "${SEQS_MOCK_STATE}" && ok \
	|| bad "a blocked deletion must change nothing"
# Qubes refuses to remove a qube that is still another qube's management
# disposable, audio or GUI qube too: it blocks the deletion like a template.
for prop in management_dispvm audiovm guivm; do
	echo "sys-usb-webcam ${prop} A-qr-camera" > "${SBX}/prefs"
	out="$(SEQS_MOCK_PREFS="${SBX}/prefs" bash "${REPO}/delete-vms.sh" qr-camera 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -q "sys-usb-webcam has ${prop} A-qr-camera" <<<"$out" \
		&& grep -qxF "A-qr-camera halted" "${SEQS_MOCK_STATE}" && ok \
		|| bad "a qube using the match as ${prop} must block the deletion: $(tail -n 1 <<<"$out")"
done
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
export SEQS_LIBVIRT_DIR="${SBX}/libvirt"
mkdir -p "${SEQS_STATE_DIR}/intents" "${SEQS_LIBVIRT_DIR}"
touch "${SEQS_STATE_DIR}/intents/A-notes"
printf '%s\n' '{# Managed by SEQS (salt state seqs.dom0) #}' x > "${SEQS_LIBVIRT_DIR}/A-notes.xml"
printf '%s\n' '<!-- operator -->' > "${SEQS_LIBVIRT_DIR}/Z-notes.xml"
printf '%s\n' "A-notes halted" "Z-notes halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_UNMANAGED="A-notes" SEQS_MOCK_SUDO_LOG="${SBX}/sudo3.log" bash "${REPO}/delete-vms.sh" notes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q "^A-notes " "${SEQS_MOCK_STATE}" && ok \
	|| bad "a qube with a creation marker must be removed: ${out}"
grep -q "A-notes: no seqs-managed feature, but an interrupted SEQS build left its creation marker" <<<"$out" && ok \
	|| bad "a match by creation marker alone must be named as such: ${out}"
# On dom0 only root can read the pinning directory.
grep -qF "head -n 1 -- ${SEQS_LIBVIRT_DIR}/A-notes.xml" "${SBX}/sudo3.log" && ok \
	|| bad "the CPU-pinning file must be read through sudo"
[ ! -e "${SEQS_STATE_DIR}/intents/A-notes" ] && ok || bad "the removed qube's creation marker must be deleted"
[ ! -e "${SEQS_LIBVIRT_DIR}/A-notes.xml" ] && [ -e "${SEQS_LIBVIRT_DIR}/Z-notes.xml" ] && ok \
	|| bad "only the CPU-pinning file SEQS wrote may be deleted"
unset SEQS_LIBVIRT_DIR
# A failing qube listing must stop the deletion, not skip the blocker check.
printf '%s\n' "A-keepass halted" > "${SEQS_MOCK_STATE}"
out="$(SEQS_MOCK_QVM_LS_FAIL=1 bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "^A-keepass " "${SEQS_MOCK_STATE}" \
	&& grep -q "ERROR: could not list the qubes -- nothing was changed" <<<"$out" && ok \
	|| bad "delete-vms.sh must stop, and say why, when qvm-ls fails: rc=$rc ${out}"
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
# Configured prefixes: the record names them, and only they are looked for.
write_names app- tpl-
printf '%s\n' "app-keepass halted" "tpl-keepass halted" "A-keepass halted" > "${SEQS_MOCK_STATE}"
printf '%s\n' "app-keepass seqs-managed 1" "tpl-keepass seqs-managed 1" > "${SBX}/features"
out="$(SEQS_MOCK_FEATURES="${SBX}/features" bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "looking for qubes matching app-keepass tpl-keepass\.\.\." <<<"$out" \
	&& [ "$(cut -d' ' -f1 "${SEQS_MOCK_STATE}")" = "A-keepass" ] && ok \
	|| bad "with configured prefixes, exactly app-keepass and tpl-keepass must go: rc=$rc ${out}"
# Without a valid record, nothing is deleted.
printf '%s\n' "app-keepass halted" > "${SEQS_MOCK_STATE}"
for record in "prefix app- tpl-" "prefix ../" "prefix" "usb-qube x"$'\n'"qube seqs-qr-scanner" "prefix A-" "name app-"; do
	echo "${record}" > "${SEQS_STATE_DIR}/names"
	out="$(SEQS_MOCK_FEATURES="${SBX}/features" bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
	[ "$rc" -ne 0 ] && grep -qxF "ERROR: ${SEQS_STATE_DIR}/names is not a valid list of SEQS names -- nothing was changed" <<<"$out" \
		&& grep -qxF "app-keepass halted" "${SEQS_MOCK_STATE}" && ok \
		|| bad "the record '${record}' must be refused: rc=$rc ${out}"
done
rm -f "${SEQS_STATE_DIR}/names"
out="$(SEQS_MOCK_FEATURES="${SBX}/features" bash "${REPO}/delete-vms.sh" keepass 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "^ERROR: ${SEQS_STATE_DIR}/names is missing, so the names SEQS gives its qubes are unknown" <<<"$out" \
	&& grep -qxF "app-keepass halted" "${SEQS_MOCK_STATE}" && ok \
	|| bad "without the record, a deletion must be refused: rc=$rc ${out}"
unset SEQS_STATE_DIR
rm -rf "${SBX}"

# ── Scenario 9a: delete-vms.sh --reset removes every SEQS qube and dom0 file ─
echo "== scenario: delete-vms.sh --reset removes SEQS qubes and dom0 state, nothing else =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state"
# Listed so that plain list order would remove a NetVM before its user and a
# template before its app qube. A-notes is the user's own qube under a SEQS
# name; A-orphan was created by an interrupted build that never marked it;
# my-wallet-backup is the user's clone of a SEQS qube, with its features.
printf '%s\n' "sys-net running" "sys-firewall running" "debian-13-xfce halted" "personal halted" "vault halted" \
	"Z-keepass halted" "A-keepass running" "A-gnosisvpn running" "A-signal running" "Z-gnosisvpn halted" "Z-signal halted" \
	"A-qr-camera halted" "Z-qr-camera halted" "sys-usb-webcam halted" "seqs-qr-scanner halted" \
	"seqs-gnosisvpn-update-proxy halted" "A-notes halted" "A-orphan halted" "my-wallet-backup halted" > "${SEQS_MOCK_STATE}"
export SEQS_MOCK_UNMANAGED="A-notes A-orphan"
export SEQS_STATE_DIR="${SBX}/var/lib/seqs" SEQS_POLICY_DIR="${SBX}/policy.d" SEQS_ETC_DIR="${SBX}/etc/seqs"
export SEQS_QR_SCRIPT="${SBX}/sbin/seqs-qr-sequential" SEQS_VPN_MONITOR="${SBX}/bin/seqs-vpn-monitor"
export SEQS_NUC11_FW="${SBX}/firmware/seqs-nuc11-headset.fw" SEQS_NUC11_CONF="${SBX}/modprobe.d/seqs-nuc11-headset.conf"
mkdir -p "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}" "${SEQS_STATE_DIR}/intents" "${SEQS_POLICY_DIR}" \
	"${SEQS_ETC_DIR}" "${SBX}/sbin" "${SBX}/bin" "${SBX}/config/xfce4/panel" "${SBX}/firmware" "${SBX}/modprobe.d"
# The headset fix's files: one marked by SEQS, one rewritten by hand.
printf '# Managed by SEQS (salt state seqs.dom0)\n[codec]\n' > "${SEQS_NUC11_FW}"
printf 'options snd-hda-intel patch=mine.fw\n' > "${SEQS_NUC11_CONF}"
write_names D- A- Z-
touch "${SEQS_STATE_DIR}/intents/A-orphan" "${SEQS_SALT_TREE}/dom0.sls" "${SEQS_ETC_DIR}/qr-sequential.conf" \
	"${SBX}/config/xfce4/panel/seqs-dom0-launchers"
printf '#!/bin/sh\n# Managed by SEQS. Sequential-path QR scan\n' > "${SEQS_QR_SCRIPT}"
# A hand-written wrapper that mentions SEQS is not SEQS's file.
printf '#!/bin/sh\n# wrapper around the SEQS monitor\n' > "${SEQS_VPN_MONITOR}"
for p in 00-seqs-qr-input-deny 28-browser-suppress 29-browser 50-seqs-audiovm; do
	echo "# Managed by SEQS (test)" > "${SEQS_POLICY_DIR}/${p}.policy"
done
printf '%s\n' "qubes.InputKeyboard * sys-usb @adminvm allow" "# Managed by SEQS? No, by hand." \
	> "${SEQS_POLICY_DIR}/30-user-input.policy"
printf '%s\n' "# SEQS keyboard rule, replaced by hand" "qubes.Filecopy * seqs-qr-scanner @anyvm deny" \
	> "${SEQS_POLICY_DIR}/01-seqs-qr-filecopy.policy"
echo "# mine" > "${SEQS_POLICY_DIR}/40-mine.policy"
printf '%s\n' "seqs-gnosisvpn-update-proxy seqs-gnosisvpn-temporary-proxy 1" \
	"sys-usb-webcam seqs-managed 1" "seqs-qr-scanner seqs-managed 1" "my-wallet-backup seqs-managed 1" > "${SBX}/features"
export SEQS_MOCK_FEATURES="${SBX}/features"
printf '%s\n' "sys-usb-webcam template A-qr-camera" "seqs-qr-scanner template A-qr-camera" \
	"my-wallet-backup template Z-keepass" > "${SBX}/prefs"
export SEQS_MOCK_PREFS="${SBX}/prefs"
printf '%s\n' "A-signal A-gnosisvpn" "personal A-gnosisvpn" "sys-firewall sys-net" > "${SBX}/netvm"
export SEQS_MOCK_NETVM_STATE="${SBX}/netvm"
reset_vms() {  # the inventory, sorted on one line
	cut -d' ' -f1 "${SEQS_MOCK_STATE}" | sort | tr '\n' ' '
}
before="$(reset_vms)"
# A name and --reset do not mix.
out="$(bash "${REPO}/delete-vms.sh" --reset keepass 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "takes no name" <<<"$out" && [ "$(reset_vms)" = "${before}" ] && ok \
	|| bad "--reset with a name must be refused: ${out}"
# The clone of an app qube still uses its SEQS template: it is not selected,
# and that reference stops the reset before anything changes.
out="$(bash "${REPO}/delete-vms.sh" --reset --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qxF "  my-wallet-backup: carries a SEQS feature but is not a SEQS name (a clone?): not selected" <<<"$out" \
	&& grep -q "^ERROR: nothing was changed; these use a target" <<<"$out" \
	&& grep -qxF "  my-wallet-backup has template Z-keepass" <<<"$out" && [ "$(reset_vms)" = "${before}" ] && ok \
	|| bad "a clone on a SEQS template must stop the reset: rc=$rc ${out}"
# Moved to a template SEQS did not build, the clone no longer blocks anything.
sed -i 's/^my-wallet-backup template .*/my-wallet-backup template debian-13-xfce/' "${SBX}/prefs"
# Dry run: names every SEQS qube and dom0 file, not the user's, and changes nothing.
out="$(bash "${REPO}/delete-vms.sh" --reset --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "dry-run: not killing" <<<"$out" && ok || bad "a reset dry run must exit 0: ${out}"
for vm in A-keepass Z-keepass A-gnosisvpn A-signal sys-usb-webcam seqs-qr-scanner seqs-gnosisvpn-update-proxy A-orphan; do
	grep -q "^  ${vm}$" <<<"$out" && ok || bad "the dry run must list ${vm}: ${out}"
done
for vm in A-notes personal vault debian-13-xfce sys-net my-wallet-backup; do
	grep -q "^  ${vm}$" <<<"$out" && bad "the dry run must not list ${vm}" || ok
done
grep -qxF "  my-wallet-backup: carries a SEQS feature but is not a SEQS name (a clone?): not selected" <<<"$out" && ok \
	|| bad "the dry run must report the clone it does not select: ${out}"
grep -q "would set personal netvm to none" <<<"$out" && ok || bad "the dry run must name the NetVM user: ${out}"
grep -q "^  ${SEQS_SALT_TREE}$" <<<"$out" && grep -q "^  ${SEQS_POLICY_DIR}/29-browser.policy$" <<<"$out" \
	&& grep -q "^  ${SEQS_NUC11_FW}$" <<<"$out" && ok || bad "the dry run must list the dom0 files: ${out}"
# What the run keeps, the preview already shows as kept, never as removed.
to_remove="$(awk '/^SEQS files in dom0 to remove:/ { p = 1; next } /^[^ ]/ { p = 0 } p' <<<"$out")"
kept="$(awk '/^not written by SEQS, left in place:/ { p = 1; next } /^[^ ]/ { p = 0 } p' <<<"$out")"
for f in "${SEQS_POLICY_DIR}/30-user-input.policy" "${SEQS_POLICY_DIR}/01-seqs-qr-filecopy.policy" "${SEQS_NUC11_CONF}" "${SEQS_VPN_MONITOR}"; do
	grep -qxF "  ${f}" <<<"$kept" && ! grep -qxF "  ${f}" <<<"$to_remove" && ok \
		|| bad "the dry run must show ${f} as kept, not removed: ${out}"
done
[ "$(reset_vms)" = "${before}" ] && [ -e "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "a reset dry run must change nothing"
# Only the typed word RESET confirms.
out="$(PTY_RUN_PROMPT="Type RESET" PTY_RUN_ANSWERS="y" python3 "${REPO}/test/lib/pty_run.py" \
	bash "${REPO}/delete-vms.sh" --reset 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "not confirmed -- nothing was changed" <<<"$out" && [ "$(reset_vms)" = "${before}" ] \
	&& [ -e "${SEQS_SALT_TREE}/dom0.sls" ] && ok || bad "an answer other than RESET must change nothing: ${out}"
# The confirmed reset: SEQS qubes go in dependency order (the qvm-remove mock
# refuses a template or NetVM still in use), the user's qubes stay, the
# NetVM user is disconnected, marked dom0 files go, unmarked ones stay.
out="$(PTY_RUN_PROMPT="Type RESET" PTY_RUN_ANSWERS="RESET" SEQS_MOCK_SUDO_LOG="${SBX}/sudo.log" \
	XDG_CONFIG_HOME="${SBX}/config" python3 "${REPO}/test/lib/pty_run.py" bash "${REPO}/delete-vms.sh" --reset 2>&1)"; rc=$?
[ "$(reset_vms)" = "A-notes debian-13-xfce my-wallet-backup personal sys-firewall sys-net vault " ] && ok \
	|| bad "reset left the wrong qubes: $(reset_vms); ${out}"
[ "$(awk '$1 == "personal" { print $2 }' "${SBX}/netvm")" = "none" ] && ok || bad "the NetVM user must be disconnected"
for f in "${SEQS_SALT_TREE}" "${SEQS_PILLAR_TREE}" "${SEQS_STATE_DIR}" "${SEQS_ETC_DIR}" "${SEQS_QR_SCRIPT}" \
		"${SEQS_POLICY_DIR}/29-browser.policy" "${SEQS_POLICY_DIR}/50-seqs-audiovm.policy" \
		"${SBX}/config/xfce4/panel/seqs-dom0-launchers" "${SEQS_NUC11_FW}"; do
	[ ! -e "${f}" ] && ok || bad "reset left ${f}"
done
# Files under SEQS names that only mention SEQS, or carry the marker below
# the first line, were written by hand and stay.
for f in "${SEQS_POLICY_DIR}/30-user-input.policy" "${SEQS_POLICY_DIR}/01-seqs-qr-filecopy.policy" \
		"${SEQS_POLICY_DIR}/40-mine.policy" "${SEQS_NUC11_CONF}" "${SEQS_VPN_MONITOR}"; do
	[ -e "${f}" ] && ok || bad "reset must keep the hand-written ${f}"
done
[ "$rc" -ne 0 ] && grep -q "30-user-input.policy was not written by SEQS; left in place" <<<"$out" \
	&& grep -q "finished with the files reported above left in place" <<<"$out" && ok \
	|| bad "reset must report the unmarked policy it kept and exit non-zero: rc=$rc ${out}"
grep -q "qubesctl top.disable seqs.config pillar=true" "${SBX}/sudo.log" && ok || bad "reset must disable the SEQS pillar"
grep -q "webcam's USB controller now belongs to no qube" <<<"$out" && ok || bad "reset must say what the webcam controller needs"
# With nothing of SEQS left, a reset finds nothing to do and succeeds.
rm -f "${SEQS_POLICY_DIR}/30-user-input.policy" "${SEQS_POLICY_DIR}/01-seqs-qr-filecopy.policy" "${SEQS_NUC11_CONF}" "${SEQS_VPN_MONITOR}"
out="$(PTY_RUN_PROMPT="Type RESET" PTY_RUN_ANSWERS="RESET" python3 "${REPO}/test/lib/pty_run.py" \
	bash "${REPO}/delete-vms.sh" --reset 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "SEQS reset complete" <<<"$out" \
	&& [ "$(reset_vms)" = "A-notes debian-13-xfce my-wallet-backup personal sys-firewall sys-net vault " ] && ok \
	|| bad "a second reset must succeed and change nothing: rc=$rc ${out}"
unset SEQS_STATE_DIR SEQS_POLICY_DIR SEQS_ETC_DIR SEQS_QR_SCRIPT SEQS_VPN_MONITOR SEQS_NUC11_FW SEQS_NUC11_CONF SEQS_MOCK_UNMANAGED
unset SEQS_MOCK_FEATURES SEQS_MOCK_PREFS SEQS_MOCK_NETVM_STATE
unset -f reset_vms
rm -rf "${SBX}"

# ── Scenario 9c: delete-vms.sh --reset follows the configured names ─────────
# With other prefixes and QR qube names, the qubes under them go, and an A-
# qube or one called sys-usb-webcam is a clone.
# Without the record, a reset that would remove dom0 files refuses while a
# qube carries a SEQS feature: its deny policies would go while it stays.
echo "== scenario: delete-vms.sh --reset uses the recorded prefixes, refuses without them =="
new_sandbox
export SEQS_MOCK_STATE="${SBX}/qubes.state" SEQS_MOCK_FEATURES="${SBX}/features"
export SEQS_STATE_DIR="${SBX}/var/lib/seqs" SEQS_POLICY_DIR="${SBX}/policy.d" SEQS_ETC_DIR="${SBX}/etc/seqs"
export SEQS_QR_SCRIPT="${SBX}/qr" SEQS_VPN_MONITOR="${SBX}/monitor" SEQS_NUC11_FW="${SBX}/fw" SEQS_NUC11_CONF="${SBX}/conf"
mkdir -p "${SEQS_POLICY_DIR}"
echo "# Managed by SEQS (test)" > "${SEQS_POLICY_DIR}/28-browser-suppress.policy"
printf '%s\n' "app-keepass halted" "tpl-keepass halted" "A-keepass halted" "cam-usb halted" "cam-scan halted" \
	"sys-usb-webcam halted" > "${SEQS_MOCK_STATE}"
printf '%s seqs-managed 1\n' app-keepass tpl-keepass cam-usb cam-scan sys-usb-webcam > "${SEQS_MOCK_FEATURES}"
rm -rf "${SEQS_STATE_DIR}"
out="$(bash "${REPO}/delete-vms.sh" --reset --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qxF "  app-keepass: carries a SEQS feature, but without ${SEQS_STATE_DIR}/names it is unknown whether it has a SEQS name: not selected" <<<"$out" \
	&& grep -q "^ERROR: nothing was changed; the qubes above that carry a SEQS feature may be SEQS qubes that use these files" <<<"$out" \
	&& [ "$(wc -l < "${SEQS_MOCK_STATE}")" -eq 6 ] && [ -e "${SEQS_POLICY_DIR}/28-browser-suppress.policy" ] && ok \
	|| bad "without the record, a reset that would remove dom0 files must refuse: rc=$rc ${out}"
USB_QUBE=cam-usb SCANNER_QUBE=cam-scan write_names app- tpl-
out="$(PTY_RUN_PROMPT="Type RESET" PTY_RUN_ANSWERS="RESET" python3 "${REPO}/test/lib/pty_run.py" \
	bash "${REPO}/delete-vms.sh" --reset 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qF "  A-keepass: carries a SEQS feature but is not a SEQS name (a clone?): not selected" <<<"$out" \
	&& grep -qF "  sys-usb-webcam: carries a SEQS feature but is not a SEQS name (a clone?): not selected" <<<"$out" \
	&& grep -q "webcam's USB controller now belongs to no qube" <<<"$out" \
	&& [ "$(cut -d' ' -f1 "${SEQS_MOCK_STATE}" | tr '\n' ' ')" = "A-keepass sys-usb-webcam " ] \
	&& [ ! -e "${SEQS_POLICY_DIR}/28-browser-suppress.policy" ] && ok \
	|| bad "a reset must remove the qubes under the recorded names, and only those: rc=$rc ${out}"
unset SEQS_STATE_DIR SEQS_POLICY_DIR SEQS_ETC_DIR SEQS_QR_SCRIPT SEQS_VPN_MONITOR SEQS_NUC11_FW SEQS_NUC11_CONF SEQS_MOCK_FEATURES
rm -rf "${SBX}"

# ── Scenario 9b: hardware test reset keeps the control path ─────────────────
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
write_names D- A- Z-
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
# An unmarked file under a SEQS policy name is reported and kept, also when
# the marker appears below its first line.
printf '%s\n' "qubes.InputKeyboard * sys-usb @adminvm allow" "# Managed by SEQS? No, by hand." \
	> "${SEQS_POLICY_DIR}/30-user-input.policy"
out="$(bash "${REPO}/test/hardware/dom0-test.sh" reset 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "30-user-input.policy is not marked as SEQS-managed; left in place" <<<"${out}" && ok \
	|| bad "reset should fail on an unmarked SEQS policy name: ${out}"
[ -e "${SEQS_POLICY_DIR}/30-user-input.policy" ] && ok || bad "reset removed an unmarked policy"
unset SEQS_STATE_DIR SEQS_POLICY_DIR SEQS_ETC_DIR SEQS_QR_SCRIPT SEQS_TMP_DIR SEQS_TEST_DELETE_VMS SEQS_TEST_CTL_VM SEQS_MOCK_UNMANAGED
rm -rf "${SBX}"

# ── Scenario 10: the sequential QR script refuses before the camera phase ───
# Every check before "Type START" must stop the script without powering off.
# The test runs a copy that reads its configuration from the sandbox, skips
# the root check, and calls the mocks local to this scenario by absolute path:
# a missing mock fails, and never falls through to the host's own command.
echo "== scenario: sequential QR script refuses an unsafe state before START =="
SBX="$(mktemp -d)"
mkdir -p "${SBX}/bin"
QR_MOCKED='qvm-(check|prefs|run|usb|kill|shutdown|start)|systemctl|sleep|sync'
sed -E -e "s#^CONF=.*#CONF=${SBX}/conf#" -e 's/^\[ "\$\{EUID\}" -eq 0 \].*$/:/' \
	-e "s#(^|[^-/A-Za-z_])(${QR_MOCKED})\\b#\\1${SBX}/bin/\\2#g" \
	"${REPO}/salt/seqs/files/qr-sequential.sh" > "${SBX}/qr.sh"
grep -vE '^[[:space:]]*#' "${SBX}/qr.sh" | grep -E '(^|[^-/A-Za-z_])systemctl\b|(^|[;&|({]|then|do|else)[[:space:]]*(poweroff|reboot|halt|shutdown)\b' \
	&& bad "the QR script copy still calls a power command through PATH" || ok
write_mock() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${SBX}/bin/$1"; chmod +x "${SBX}/bin/$1"; }
write_mock sync ':'
# The watchdog's 840-second sleep records its own and its subshell's PID for
# qr_stop_watchdog and returns only once a hanging attach has started; every
# other sleep returns at once.
write_mock sleep '[ "$1" = 840 ] || exit 0; echo "$PPID $$" > "'"${SBX}"'/watchdog.pid"
for _ in $(seq 600); do [ -e "'"${SBX}"'/attach_started" ] && exit 0; /bin/sleep 0.1; done'
qr_stop_watchdog() {  # NAME -- end the watchdog of the last run; it must exist
	local _ pids
	for _ in $(seq 50); do [ -s "${SBX}/watchdog.pid" ] && break; /bin/sleep 0.1; done
	[ -s "${SBX}/watchdog.pid" ] && ok || bad "$1: no power-off watchdog was started"
	pids="$(cat "${SBX}/watchdog.pid" 2>/dev/null)"; rm -f "${SBX}/watchdog.pid"
	# An orderly power-off stops it with TERM, which it must not ignore.
	# shellcheck disable=SC2086
	kill -TERM ${pids} 2>/dev/null; /bin/sleep 0.2
	# shellcheck disable=SC2086
	! kill -0 ${pids} 2>/dev/null && ok || { bad "$1: the watchdog ignores TERM"; kill -KILL ${pids} 2>/dev/null; }
}
write_mock qvm-check 'n="${!#}"; case " $* " in *" --running "*) grep -qx "$n" "'"${SBX}"'/running" ;; *) grep -qx "$n" "'"${SBX}"'/exists" ;; esac'
# The fixture holds "<vm> <property> <flag> <value>" lines; "qvm-prefs -- VM"
# lists them as "<property> <flag> <value>".
write_mock qvm-prefs 'awk -v v="${!#}" '"'"'$1 == v { print $2, $3, $4 }'"'"' "'"${SBX}"'/prefs"'
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
		printf '%s netvm - None\n%s default_dispvm - None\n' "${vm}" "${vm}" >> "${SBX}/prefs"
	done
}
if command -v setsid >/dev/null 2>&1; then
	qr_reset; qr_case "a safe state" "SEQS SEQUENTIAL-PATH QR SCAN"
	qr_reset; echo 'SCANNER_QUBE="x;y"' >> "${SBX}/conf"; qr_case "unsafe name" "unsafe qube name"
	qr_reset; echo 'CONTROLLER=00_14.0x' >> "${SBX}/conf"; qr_case "bad BDF" "invalid controller BDF"
	qr_reset; sed -i '/^A-qr-staging$/d' "${SBX}/exists"; qr_case "missing qube" "required qube 'A-qr-staging' is missing"
	# A webcam backend running before the script has had the shared
	# controller: refuse, but end this boot with a power-off.
	qr_reset; echo sys-usb-webcam >> "${SBX}/running"; rm -f "${SBX}/systemctl.log"
	out="$(PATH="${SBX}/bin:${PATH}" setsid bash "${SBX}/qr.sh" </dev/null 2>&1)"
	grep -qF "sys-usb-webcam is already running" <<<"${out}" && grep -qx poweroff "${SBX}/systemctl.log" 2>/dev/null && ok \
		|| bad "webcam backend running: expected a refusal and a power-off, got: $(tail -n 1 <<<"${out}")"
	qr_stop_watchdog "webcam backend running"
	rm -f "${SBX}/systemctl.log"
	qr_reset; echo seqs-qr-scanner >> "${SBX}/running"; qr_case "scanner running" "seqs-qr-scanner is already running"
	qr_reset; echo PRESENT > "${SBX}/staged"; qr_case "old key.asc" "already holds an incoming key.asc"
	qr_reset; : > "${SBX}/staged"; qr_case "staging unreadable" "could not check A-qr-staging"
	for vm in sys-usb-webcam seqs-qr-scanner A-qr-staging; do
		# A NetVM or default disposable, or a None inherited from a global
		# default (flag D), which turns networked when that default changes.
		for pref in netvm default_dispvm; do
			for value in "- sys-firewall" "D None"; do
				qr_reset; sed -i "s/^${vm} ${pref} - None$/${vm} ${pref} ${value}/" "${SBX}/prefs"
				rm -f "${SBX}/qvm-run.log"
				qr_case "${vm} ${pref} ${value}" "'${vm}' does not have netvm and default_dispvm explicitly set to none"
				[ ! -e "${SBX}/qvm-run.log" ] && ok \
					|| bad "${vm} ${pref} ${value}: the script started a qube before refusing a networked camera side"
			done
		done
	done
else
	printf '  skip: setsid not available\n'
fi
# After START, the keyboard's controller is exposed to the camera side: every
# outcome, success included, must end in a power-off. The camera phase runs
# under a pseudo-terminal that types the answer.
write_mock qvm-start ':'
write_mock qvm-shutdown 'sed -i "/^${!#}$/d" "'"${SBX}"'/running"'
# With attach_hangs, an attach hangs until the watchdog forces the power-off.
# It first sends the watchdog the hangup of a closed terminal, which it must
# survive.
write_mock qvm-usb 'if [ "${1:-}" = attach ] && [ -e "'"${SBX}"'/attach_hangs" ]; then
	for _ in $(seq 50); do [ -s "'"${SBX}"'/watchdog.pid" ] && break; /bin/sleep 0.1; done
	kill -HUP $(cat "'"${SBX}"'/watchdog.pid"); /bin/sleep 0.2
	touch "'"${SBX}"'/attach_started"
	for _ in $(seq 100); do grep -qx -- "poweroff --force --force" "'"${SBX}"'/systemctl.log" 2>/dev/null && exit 1; /bin/sleep 0.1; done
	exit 1
fi; cat "'"${SBX}"'/usb" 2>/dev/null; :'
write_mock qvm-run 'case "$*" in *zbarcam*) exit "$(cat "'"${SBX}"'/scan_rc")" ;; *) cat "'"${SBX}"'/staged" ;; esac'
qr_camera() {  # NAME ANSWER EXPECTED-OUTPUT POWEROFF(yes|no)
	local out
	rm -f "${SBX}/systemctl.log"
	out="$(PATH="${SBX}/bin:${PATH}" PTY_RUN_PROMPT="Type START" PTY_RUN_ANSWERS="$2" \
		python3 "${REPO}/test/lib/pty_run.py" bash "${SBX}/qr.sh" 2>&1)"
	grep -qF -- "$3" <<<"${out}" && ok || bad "$1: expected '$3', got: $(tail -n 2 <<<"${out}" | tr -d '\r')"
	if [ "$4" = yes ]; then
		grep -qx poweroff "${SBX}/systemctl.log" 2>/dev/null && ok || bad "$1: the camera phase must end in a power-off"
		qr_stop_watchdog "$1"
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
# A hang in the camera phase, here a USB attach that never returns, cannot
# keep the boot running: the watchdog forces the power-off.
touch "${SBX}/attach_hangs"
qr_camera "hanging attach" START "could not attach the webcam to seqs-qr-scanner" yes
grep -qx -- "poweroff --force --force" "${SBX}/systemctl.log" && ok \
	|| bad "hanging attach: the watchdog must force a power-off"
rm -f "${SBX}/attach_hangs" "${SBX}/attach_started"
# A refused orderly power-off falls back to the forced one.
write_mock systemctl 'echo "$*" >> "'"${SBX}"'/systemctl.log"; [ "$*" != poweroff ]'
qr_camera "refused power-off" START "scan/copy failed" yes
grep -qx -- "poweroff --force --force" "${SBX}/systemctl.log" && ok || bad "a refused power-off must be forced"
rm -rf "${SBX}"

[ ! -s "${SEQS_TRIPWIRE_LOG}" ] && ok \
	|| bad "a test reached systemctl, xfconf-query or xfce4-panel through PATH: $(head -n 3 "${SEQS_TRIPWIRE_LOG}")"
rm -f "${SEQS_TRIPWIRE_LOG}"

echo
echo "integration tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
