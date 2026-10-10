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
#   dom0-test.sh invalidate      empty the completion markers in every built
#                                qube, so the next install runs every
#                                component script again
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
	# Only a marker holding a content hash counts: an empty one means the last
	# install of that component did not finish.
	have="$(qvm-run --pass-io --no-gui -u root "${vm}" \
		"find /rw/config/seqs -maxdepth 1 -name '*.done' ! -empty -printf '%f\n'" 2>/dev/null </dev/null)"
	for comp in ${comps}; do
		[ "${role}" = "app" ] && [[ "${comp}" == brave-extension-* ]] && continue
		grep -qxF "${comp}.${role}.done" <<< "${have}" || missing+=" ${comp}"
	done
	[ -z "${missing}" ] && pass "${vm}: components installed (${comps})" \
		|| fail "${vm}: no completion marker for${missing}"
}

# ---- smoke tests -------------------------------------------------------------

# smokeCmd COMPONENT -- a terminal-only command, run as the user inside an app
# qube that has COMPONENT, that exits 0 only if the component works. Where a
# GUI app cannot be exercised without a display or an account, the test is
# limited to the installed package or binary, and says so.
smokeCmd() {
	case "$1" in
		brave) echo "timeout 90 brave-browser --headless=new --disable-gpu --no-first-run --dump-dom 'data:text/html,<p>seqs-smoke-ok</p>' 2>/dev/null | grep -q seqs-smoke-ok" ;;
		brave-extension-*)
			local id
			id="$(python3 -c 'import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
print(d.get("local", d).get(sys.argv[1], ""))' "${1#brave-extension-}" <<< "${EXTENSIONS_JSON}")"
			[[ "${id}" =~ ^[a-p]{32}$ ]] || { echo "false # extension id unknown"; return; }
			echo "test -f /opt/brave.com/brave/extensions/${id}.json" ;;
		keepass) echo 'd=$(mktemp -d) && k="keepassxc.AppImage cli" && printf "pw\npw\n" | $k db-create --set-password "$d/t.kdbx" >/dev/null 2>&1 && printf "pw\n" | $k add -u seqs-smoke "$d/t.kdbx" entry >/dev/null 2>&1 && printf "pw\n" | $k show -a UserName "$d/t.kdbx" entry 2>/dev/null | grep -qx seqs-smoke' ;;
		openoffice) echo 's=$(ls /opt/openoffice*/program/soffice.bin 2>/dev/null | head -n 1) && [ -x "$s" ] && ! ldd "$s" | grep -q "not found" # binary and libraries only' ;;
		docker) echo 'timeout 180 sudo docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"' ;;
		python) echo 'bash -lc "python -c \"import sys; print(sys.version_info[:2])\"" 2>/dev/null | grep -qx "(3, 13)"' ;;
		node) echo 'bash -lc ". ~/.nvm/nvm.sh && node -e \"console.log(6 * 7)\"" 2>/dev/null | grep -qx 42' ;;
		vscode) echo 'timeout 60 code --version >/dev/null 2>&1' ;;
		claude-code) echo 'timeout 60 ~/.local/bin/claude --version >/dev/null 2>&1' ;;
		element|signal|xournalpp)
			local pkg="$1"
			[ "$1" = element ] && pkg=element-desktop
			[ "$1" = signal ] && pkg=signal-desktop
			echo "dpkg-query -W -f='\${Status}' ${pkg} 2>/dev/null | grep -q 'install ok installed' # package only" ;;
		telegram) echo 'snap list telegram-desktop >/dev/null 2>&1 # package only' ;;
		adb) echo 'adb version >/dev/null 2>&1 && test -x /usr/bin/adb-pull' ;;
		ledger) echo 'test -x /usr/bin/LedgerLive.AppImage && test -f /etc/udev/rules.d/20-hw1.rules # files only' ;;
		trezor) echo 'test -f /etc/udev/rules.d/51-trezor.rules # udev rules only' ;;
		qr-display) echo 'qrencode -o - seqs-smoke | head -c 4 | grep -q PNG' ;;
		qr-camera) echo 'command -v zbarimg >/dev/null && command -v zbarcam >/dev/null' ;;
		wireguard) echo 'wg --version >/dev/null && test -x /usr/bin/seqs-wireguard-import && sudo grep -qx /rw/config/seqs-wireguard/boot.sh /rw/config/rc.local' ;;
		gnosisvpn) echo 'dpkg-query -W -f="\${Status}" gnosisvpn 2>/dev/null | grep -q "install ok installed" && systemctl is-enabled --quiet seqs-gnosisvpn-dns.path && test -d /rw/bind-dirs/var/lib/gnosisvpn' ;;
		*) echo "" ;;
	esac
}

# smoke VM RECIPE -- run the smoke test of every component of RECIPE in VM.
smoke() {
	local vm="$1" comp cmd out note
	for comp in $(componentsFor "$2"); do
		cmd="$(smokeCmd "${comp}")"
		[ -n "${cmd}" ] || continue
		note=""
		[[ "${cmd}" != *" # "* ]] || note=" (${cmd##* # })"
		if out="$(qvm-run --pass-io --no-gui "${vm}" "${cmd}" 2>&1 </dev/null)"; then
			pass "${vm}: ${comp} works${note}"
		else
			fail "${vm}: ${comp} smoke test failed${out:+: $(tail -n 2 <<< "${out}" | tr '\n' ' ')}"
		fi
	done
}

# refusesHandoff VM -- an offline qube must not be able to open a link or a
# file elsewhere. A refusal comes back at once; a timeout would mean a
# confirmation dialog appeared instead, which is also a failure.
refusesHandoff() {
	local vm="$1" svc out
	for svc in qubes.OpenURL qubes.OpenInVM; do
		out="$(qvm-run --pass-io --no-gui "${vm}" \
			"echo https://example.com | timeout 20 qrexec-client-vm @dispvm ${svc}; echo rc=\$?" 2>&1 </dev/null)"
		if grep -qi "refused" <<< "${out}" && ! grep -q "rc=124" <<< "${out}"; then
			pass "${vm}: ${svc} to a disposable is refused"
		else
			fail "${vm}: ${svc} to a disposable was not refused: $(tail -n 2 <<< "${out}" | tr '\n' ' ')"
		fi
	done
}

# qrRoundTrip -- the QR transfer without the webcam: A-qr-display encodes a
# random payload, dom0 carries the image, A-qr-camera decodes it.
qrRoundTrip() {
	local payload got
	payload="seqs-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
	got="$(qvm-run --pass-io --no-gui A-qr-display "qrencode -o - ${payload}" 2>/dev/null </dev/null \
		| qvm-run --pass-io --no-gui A-qr-camera 'f=$(mktemp) && cat > "$f" && zbarimg --raw -q "$f"' 2>/dev/null)"
	if [ "${got}" = "${payload}" ]; then
		pass "QR code from A-qr-display decodes in A-qr-camera"
	else
		fail "QR round trip returned '${got}' instead of '${payload}'"
	fi
}

check() {
	local kind name recipe flags tpl klass nv dv ours started=()
	local targets="${STATE_DIR}/targets"
	sudo test -r "${targets}" || { fail "${targets} missing -- the dom0 state did not run"; return 1; }
	if sudo grep -qx 'result=success' "${STATE_DIR}/last-run" 2>/dev/null; then
		pass "runner recorded result=success"
	else
		fail "runner did not record result=success in ${STATE_DIR}/last-run"
	fi
	CATALOGUE_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:catalogue 2>/dev/null)"
	EXTENSIONS_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:brave_extensions 2>/dev/null)"

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
		ours=0
		case "${kind}" in
			template)
				if qvm-check --running --quiet -- "${name}" >/dev/null 2>&1; then
					fail "${name} is still running after the install"
				else
					ours=1
					checkMarkers "${name}" template "${recipe}"
				fi
				;;
			app)
				tpl="$(qvm-prefs -- "${name}" template 2>/dev/null)"
				grep -qE "^template ${tpl} " < <(sudo cat "${targets}") \
					|| fail "${name} is based on ${tpl:-?}, not on a SEQS template"
				qvm-check --running --quiet -- "${name}" >/dev/null 2>&1 || ours=1
				checkMarkers "${name}" app "${recipe}"
				smoke "${name}" "${recipe}"
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
				refusesHandoff "${name}"
			fi
		elif [ "${kind}" = "app" ] && isNone "${nv}"; then
			fail "${name} should have network access but has no netvm"
		fi
		# Stop a qube this check started as soon as it is checked, so that a
		# large selection does not run every qube at once; wait at the end.
		if [ "${ours}" -eq 1 ]; then
			qvm-shutdown -- "${name}" >/dev/null 2>&1 || true
			started+=("${name}")
		fi
	done < <(sudo cat "${targets}")

	for name in "${SEQS_POLICIES[@]}"; do
		name="${POLICY_DIR}/${name}.policy"
		if sudo test -e "${name}" && ! sudo grep -qF "${MARKER}" "${name}"; then
			fail "${name} exists without the SEQS marker"
		fi
	done
	if grep -q "^app A-qr-display " < <(sudo cat "${targets}") && grep -q "^app A-qr-camera " < <(sudo cat "${targets}"); then
		qrRoundTrip
		qvm-shutdown -- A-qr-display A-qr-camera >/dev/null 2>&1 || true
	fi
	! qvm-check --quiet -- seqs-gnosisvpn-update-proxy >/dev/null 2>&1 \
		|| fail "the temporary GnosisVPN updates proxy was left behind"
	sudo test ! -e "${POLICY_DIR}/20-seqs-gnosisvpn-updates.policy" \
		|| fail "the temporary GnosisVPN updates policy was left behind"
	[ -z "$(find "${TMP_DIR}" -maxdepth 1 -name 'seqs-*' 2>/dev/null)" ] \
		|| fail "the runner left temporary files in ${TMP_DIR}"

	if [ "${#started[@]}" -gt 0 ]; then
		qvm-shutdown --wait -- "${started[@]}" >/dev/null 2>&1 || true
	fi
	echo "checks failed: ${FAILS}"
	[ "${FAILS}" -eq 0 ]
}

# ---- invalidate ---------------------------------------------------------------

# invalidate -- an empty marker never matches a content hash, so the next
# install reruns every component: this proves the scripts can run twice, as
# they do whenever a component's files or the shared libraries change.
invalidate() {
	local kind name rest
	local -a done_qubes=()
	while read -r kind name rest; do
		case "${kind}" in template|app) ;; *) continue ;; esac
		# shellcheck disable=SC2016 # runs inside the qube
		if qvm-run --pass-io --no-gui -u root "${name}" \
				'for f in /rw/config/seqs/*.done; do [ -f "$f" ] && : > "$f"; done; true' </dev/null; then
			pass "${name}: completion markers emptied"
		else
			fail "could not empty the completion markers in ${name}"
		fi
		qvm-shutdown -- "${name}" >/dev/null 2>&1 || true
		done_qubes+=("${name}")
	done < <(sudo cat "${STATE_DIR}/targets")
	if [ "${#done_qubes[@]}" -gt 0 ]; then
		qvm-shutdown --wait -- "${done_qubes[@]}" >/dev/null 2>&1 || true
	fi
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
	invalidate) invalidate ;;
	*) sed -n '3,20p' "$0"; exit 2 ;;
esac
