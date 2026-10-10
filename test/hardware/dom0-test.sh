#!/usr/bin/env bash

# SEQS hardware system test, dom0 side. test/hardware/system-test.sh copies
# this file into the test machine's dom0 together with the runner, and calls
# it through the seqs.TestShell service. Test machines only: `reset` deletes
# every SEQS qube and all SEQS state in dom0.
#
# Usage:
#   dom0-test.sh reset           remove SEQS qubes and dom0 state; keep the
#                                control qube, sys-net, and stock Qubes
#   dom0-test.sh install LIST    run the runner for LIST (comma-separated
#                                catalogue names) or "all", answering its
#                                prompts with y; output is time-stamped
#   dom0-test.sh check           verify what the last install built
#
# Output lines starting with CHECK-FAIL are findings; the exit status is
# non-zero when there is at least one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CTL_VM="${SEQS_TEST_CTL_VM:-test-ctl}"
# Never touched by reset, whatever they are called or tagged.
PROTECTED=(dom0 "${CTL_VM}" sys-net)
# SEQS qubes without a D-/A-/Z- prefix. Removed before the prefixed ones: a
# named disposable blocks removal of its disposable template.
SPECIAL_QUBES=(seqs-qr-scanner seqs-gnosisvpn-update-proxy sys-usb-webcam)

SALT_TREE="${SEQS_SALT_TREE:-/srv/salt/seqs}"
PILLAR_TREE="${SEQS_PILLAR_TREE:-/srv/pillar/seqs}"
STATE_DIR="${SEQS_STATE_DIR:-/var/lib/seqs}"
POLICY_DIR="${SEQS_POLICY_DIR:-/etc/qubes/policy.d}"
ETC_DIR="${SEQS_ETC_DIR:-/etc/seqs}"
QR_SCRIPT="${SEQS_QR_SCRIPT:-/usr/local/sbin/seqs-qr-sequential}"
TMP_DIR="${SEQS_TMP_DIR:-/tmp}"
SEQS_POLICIES=(00-seqs-qr-input-deny 01-seqs-qr-filecopy 20-seqs-gnosisvpn-updates
	28-browser-suppress 29-browser 30-user-input)
MARKER="Managed by SEQS"

SETUP="${SEQS_TEST_SETUP:-${HERE}/setup-qubes.sh}"
DELETE_VMS="${SEQS_TEST_DELETE_VMS:-${HERE}/delete-vms.sh}"
PTY_RUN="${SEQS_TEST_PTY_RUN:-${HERE}/pty_run.py}"

FAILS=0
fail() { printf 'CHECK-FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
pass() { printf 'CHECK-OK:   %s\n' "$*"; }
note() { printf '==> %s\n' "$*"; }

isProtected() {
	local p
	for p in "${PROTECTED[@]}"; do
		[ "$1" = "${p}" ] && return 0
	done
	[ "$(qvm-features -- "$1" seqs-test-control 2>/dev/null)" = "1" ]
}

isSpecial() {
	local s
	for s in "${SPECIAL_QUBES[@]}"; do
		[ "$1" = "${s}" ] && return 0
	done
	return 1
}

# isSeqsQube VM -- prefixed, a known SEQS name, or tagged by SEQS.
isSeqsQube() {
	[[ "$1" =~ ^[DAZ]- ]] && return 0
	isSpecial "$1" && return 0
	[ "$(qvm-features -- "$1" seqs-managed 2>/dev/null)" = "1" ] && return 0
	[ "$(qvm-features -- "$1" seqs-gnosisvpn-temporary-proxy 2>/dev/null)" = "1" ]
}

# seqsQubes -- every non-protected SEQS qube, one per line.
seqsQubes() {
	local vm
	while IFS= read -r vm; do
		[ -n "${vm}" ] || continue
		isProtected "${vm}" && continue
		isSeqsQube "${vm}" && printf '%s\n' "${vm}"
	done < <(qvm-ls --raw-list 2>/dev/null)
}

# isNone VALUE -- an unset qube reference, as printed by qvm-prefs.
isNone() {
	case "${1,,}" in ''|none) return 0 ;; *) return 1 ;; esac
}

# ---- reset ------------------------------------------------------------------

reset() {
	local vm p f
	local -a others=() bases=()
	note "Removing SEQS qubes"
	while IFS= read -r vm; do
		if [[ "${vm}" =~ ^[DAZ]-(.+)$ ]]; then
			bases+=("${BASH_REMATCH[1]}")
		else
			others+=("${vm}")
		fi
	done < <(seqsQubes)
	for vm in "${others[@]}"; do
		echo "    ${vm}"
		qvm-kill -- "${vm}" >/dev/null 2>&1 || true
		qvm-remove --force -- "${vm}" || fail "could not remove ${vm}"
	done
	if [ "${#bases[@]}" -gt 0 ]; then
		mapfile -t bases < <(printf '%s\n' "${bases[@]}" | sort -u)
		bash "${DELETE_VMS}" "${bases[@]}" || fail "delete-vms.sh failed for: ${bases[*]}"
	fi

	note "Removing SEQS state from dom0"
	sudo qubesctl top.disable seqs.config pillar=true >/dev/null 2>&1 || true
	for p in "${SEQS_POLICIES[@]}"; do
		f="${POLICY_DIR}/${p}.policy"
		sudo test -e "${f}" || continue
		if sudo grep -qF "${MARKER}" "${f}"; then
			sudo rm -f -- "${f}"
		else
			fail "${f} is not marked as SEQS-managed; left in place"
		fi
	done
	sudo rm -rf -- "${SALT_TREE}" "${PILLAR_TREE}" "${STATE_DIR}" "${ETC_DIR}" "${QR_SCRIPT}"
	find "${TMP_DIR}" -maxdepth 1 -name 'seqs-*' -exec sudo rm -rf -- {} + 2>/dev/null

	note "Verifying the reset"
	vm="$(seqsQubes | tr '\n' ' ')"
	[ -z "${vm}" ] && pass "no SEQS qubes left" || fail "SEQS qubes left: ${vm}"
	for f in "${SALT_TREE}" "${PILLAR_TREE}" "${STATE_DIR}" "${ETC_DIR}" "${QR_SCRIPT}"; do
		sudo test ! -e "${f}" || fail "${f} still exists"
	done
	for vm in "${CTL_VM}" sys-net; do
		qvm-check --quiet -- "${vm}" >/dev/null 2>&1 && pass "${vm} kept" || fail "${vm} is missing"
	done
	[ "${FAILS}" -eq 0 ]
}

# ---- install ----------------------------------------------------------------

# stamp -- prefix each line with the time, for per-step durations.
stamp() {
	local line
	while IFS= read -r line; do
		printf '%(%H:%M:%S)T %s\n' -1 "${line%$'\r'}"
	done
}

install() {
	local -a sel
	if [ "${1:-}" = "all" ]; then
		sel=(--all)
	elif [[ "${1:-}" =~ ^[a-z0-9][a-z0-9.-]*(,[a-z0-9][a-z0-9.-]*)*$ ]]; then
		sel=(--qubes "$1")
	else
		echo "ERROR: install needs \"all\" or a comma-separated list of catalogue names" >&2
		return 2
	fi
	# pty_run.py gives the runner a terminal and answers each [y/N] with y.
	PTY_RUN_IDLE_TIMEOUT=0 python3 "${PTY_RUN}" bash "${SETUP}" --repo-vm "${CTL_VM}" "${sel[@]}" 2>&1 | stamp
	return "${PIPESTATUS[0]}"
}

# ---- check ------------------------------------------------------------------

# componentsFor RECIPE -- the catalogue's components for RECIPE, from the
# pillar Salt sees; empty output means unknown.
componentsFor() {
	python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
data = data.get("local", data)
print(" ".join(data.get(sys.argv[1], {}).get("components", [])))
' "$1" <<< "${CATALOGUE_JSON}"
}

# checkMarkers VM ROLE RECIPE -- every component left its .done marker.
checkMarkers() {
	local vm="$1" role="$2" comps comp have missing=""
	comps="$(componentsFor "$3")"
	if [ -z "${comps}" ]; then
		echo "    (no components known for $3; markers not checked)"
		return
	fi
	have="$(qvm-run --pass-io --no-gui -u root "${vm}" 'ls /rw/config/seqs' 2>/dev/null </dev/null)"
	for comp in ${comps}; do
		[ "${role}" = "app" ] && [[ "${comp}" == brave-extension-* ]] && continue
		grep -qxF "${comp}.${role}.done" <<< "${have}" || missing+=" ${comp}"
	done
	[ -z "${missing}" ] && pass "${vm}: components installed (${comps})" \
		|| fail "${vm}: no completion marker for${missing}"
}

check() {
	local kind name recipe flags tpl klass nv dv started=()
	local targets="${STATE_DIR}/targets"
	sudo test -r "${targets}" || { fail "${targets} missing -- the dom0 state did not run"; return 1; }
	if sudo grep -qx 'result=success' "${STATE_DIR}/last-run" 2>/dev/null; then
		pass "runner recorded result=success"
	else
		fail "runner did not record result=success in ${STATE_DIR}/last-run"
	fi
	CATALOGUE_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:catalogue 2>/dev/null)"

	while read -r kind name recipe flags; do
		case "${kind}" in ''|\#*) continue ;; esac
		if ! qvm-check --quiet -- "${name}" >/dev/null 2>&1; then
			fail "${name} was not created"
			continue
		fi
		[ "$(qvm-features -- "${name}" seqs-managed 2>/dev/null)" = "1" ] \
			|| fail "${name} is not tagged seqs-managed"
		klass="$(qvm-prefs -- "${name}" klass 2>/dev/null)"
		case "${kind}:${klass}" in
			template:TemplateVM|app:AppVM|disposable:DispVM) ;;
			*) fail "${name} is a ${klass:-?}, expected for a ${kind} entry" ;;
		esac
		nv="$(qvm-prefs -- "${name}" netvm 2>/dev/null)"
		dv="$(qvm-prefs -- "${name}" default_dispvm 2>/dev/null)"
		case "${kind}" in
			template)
				if qvm-check --running --quiet -- "${name}" >/dev/null 2>&1; then
					fail "${name} is still running after the install"
				else
					started+=("${name}")
					checkMarkers "${name}" template "${recipe}"
				fi
				;;
			app)
				tpl="$(qvm-prefs -- "${name}" template 2>/dev/null)"
				grep -qE "^template ${tpl} " < <(sudo cat "${targets}") \
					|| fail "${name} is based on ${tpl:-?}, not on a SEQS template"
				qvm-check --running --quiet -- "${name}" >/dev/null 2>&1 || started+=("${name}")
				checkMarkers "${name}" app "${recipe}"
				;;
		esac
		if [[ " ${flags} " == *" offline "* ]]; then
			if isNone "${nv}" && isNone "${dv}"; then
				pass "${name}: no netvm and no default disposable"
			else
				fail "${name} is offline but has netvm '${nv}', default_dispvm '${dv}'"
			fi
			if [ "${kind}" = "app" ]; then
				# shellcheck disable=SC2016 # runs inside the qube
				if qvm-run --pass-io --no-gui "${name}" \
						'timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443"' >/dev/null 2>&1 </dev/null; then
					fail "${name} is offline but reached 1.1.1.1:443"
				else
					pass "${name}: cannot reach the internet"
				fi
			fi
		elif [ "${kind}" = "app" ] && isNone "${nv}"; then
			fail "${name} should have network access but has no netvm"
		fi
	done < <(sudo cat "${targets}")

	for name in "${SEQS_POLICIES[@]}"; do
		name="${POLICY_DIR}/${name}.policy"
		if sudo test -e "${name}" && ! sudo grep -qF "${MARKER}" "${name}"; then
			fail "${name} exists without the SEQS marker"
		fi
	done
	! qvm-check --quiet -- seqs-gnosisvpn-update-proxy >/dev/null 2>&1 \
		|| fail "the temporary GnosisVPN updates proxy was left behind"
	sudo test ! -e "${POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" \
		|| fail "the temporary GnosisVPN updates policy was left behind"
	[ -z "$(find "${TMP_DIR}" -maxdepth 1 -name 'seqs-*' 2>/dev/null)" ] \
		|| fail "the runner left temporary files in ${TMP_DIR}"

	for name in "${started[@]}"; do
		qvm-shutdown --wait -- "${name}" >/dev/null 2>&1 || true
	done
	echo "checks failed: ${FAILS}"
	[ "${FAILS}" -eq 0 ]
}

# ---- Main -------------------------------------------------------------------

if [ "${SEQS_SOURCE_ONLY:-0}" = "1" ]; then
	return 0 2>/dev/null || true
fi

case "${1:-}" in
	reset) reset ;;
	install) install "${2:-}" ;;
	check) check ;;
	*) sed -n '3,19p' "$0"; exit 2 ;;
esac
