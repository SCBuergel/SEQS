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
#   dom0-test.sh lifecycle       restart qubes: transient-directory cleanup on
#                                boot and shutdown, and state that must persist
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

# pillarValue KEY -- one scalar pillar value, as Salt sees it in dom0.
pillarValue() {
	sudo qubesctl --dom0-only --out=json pillar.get "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
print(d.get("local", "") if isinstance(d, dict) else d)'
}

# catField RECIPE FIELD -- one catalogue field of RECIPE ("True"/"False" for
# flags, empty when absent).
catField() {
	python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
v = data.get("local", data).get(sys.argv[1], {}).get(sys.argv[2], "")
print(v)
' "$1" "$2" <<< "${CATALOGUE_JSON}"
}

# noHandoff RECIPE -- the catalogue closes this recipe's link handoff.
noHandoff() {
	[ "$(catField "$1" offline)" = "True" ] || [ "$(catField "$1" no_handoff)" = "True" ] \
		|| [ -n "$(catField "$1" firewall)" ]
}

# checkSetup KIND VM RECIPE -- the qube settings SEQS declares, as qvm-prefs
# reports them, and the template menu entries.
checkSetup() {
	local kind="$1" vm="$2" recipe="$3" want got comp
	case "${kind}" in
		template)
			isNone "$(qvm-prefs -- "${vm}" netvm 2>/dev/null)" \
				&& pass "${vm}: template has no netvm" || fail "${vm}: template has a netvm"
			for comp in $(componentsFor "${recipe}"); do
				sudo test -f "${SALT_TREE}/files/components/${comp}/menu.desktop" || continue
				qvm-run --pass-io --no-gui "${vm}" "test -f /usr/share/applications/${comp}.desktop" </dev/null >/dev/null 2>&1 \
					&& pass "${vm}: menu entry for ${comp}" || fail "${vm}: menu entry for ${comp} is missing"
			done
			;;
		app)
			want="$(catField "${recipe}" label)"
			got="$(qvm-prefs -- "${vm}" label 2>/dev/null)"
			[ -z "${want}" ] || [ "${got}" = "${want}" ] \
				&& pass "${vm}: label ${got}" || fail "${vm}: label is '${got}', catalogue says '${want}'"
			if [ "$(catField "${recipe}" dispvm_template)" = "True" ]; then
				[ "$(qvm-prefs -- "${vm}" template_for_dispvms 2>/dev/null)" = "True" ] \
					&& pass "${vm}: is a disposable template" || fail "${vm}: template_for_dispvms is not set"
			fi
			if [ "$(catField "${recipe}" network_provider)" = "True" ]; then
				[ "$(qvm-prefs -- "${vm}" provides_network 2>/dev/null)" = "True" ] \
					&& pass "${vm}: provides network" || fail "${vm}: provides_network is not set"
			fi
			# Link handoff: set in qubes that hand links to the browser qube,
			# absent where offline or no_handoff closes that path.
			got="$(qvm-run --pass-io --no-gui "${vm}" 'xdg-settings get default-web-browser' 2>/dev/null </dev/null)"
			if [ "$(catField "${recipe}" offline)" = "True" ] || [ "$(catField "${recipe}" no_handoff)" = "True" ] \
					|| [ "${vm}" = "${BROWSER_VM}" ]; then
				[ "${got}" != "${BROWSER_DESKTOP}" ] && pass "${vm}: links are not handed to ${BROWSER_VM}" \
					|| fail "${vm}: hands links to ${BROWSER_VM} although it must not"
			else
				[ "${got}" = "${BROWSER_DESKTOP}" ] && pass "${vm}: hands links to ${BROWSER_VM}" \
					|| fail "${vm}: default browser is '${got}', not the handoff to ${BROWSER_VM}"
			fi
			;;
		disposable)
			want="A-${vm#D-}"
			got="$(qvm-prefs -- "${vm}" template 2>/dev/null)"
			[ "${got}" = "${want}" ] && pass "${vm}: based on ${want}" || fail "${vm}: based on '${got}', not ${want}"
			;;
	esac
}

# PIN_CHECK -- run with python3 as root in a template: every third-party APT
# source (not Debian or Qubes) must be blocked by a Package: * /
# Pin-Priority: -1 rule apart from an allowlist, and up to five packages it
# offers outside the allowlist must not be installable from it.
PIN_CHECK='
import glob, re, subprocess, sys
from urllib.parse import urlparse
bad, checked = [], []
# Third-party origins: every APT source host that is not Debian or Qubes.
hosts = set()
for f in glob.glob("/etc/apt/sources.list.d/*.list") + glob.glob("/etc/apt/sources.list.d/*.sources"):
    active = "\n".join(l for l in open(f).read().splitlines() if not l.lstrip().startswith("#"))
    for url in re.findall(r"(?:tor\+)?https?://[^\s\]]+", active):
        host = urlparse(url.split("+", 1)[-1]).hostname or ""
        qubes_onion = re.fullmatch(r"deb\.qubesos[a-z2-7]{49}\.onion", host)
        if host and not qubes_onion and not re.search(r"(^|\.)(debian\.org|debian\.net|qubes-os\.org)$", host):
            hosts.add(host)
pins = {}
for f in glob.glob("/etc/apt/preferences.d/*"):
    for block in open(f).read().split("\n\n"):
        d = dict(l.split(":", 1) for l in block.strip().splitlines() if ":" in l)
        m = re.match(r"\s*origin \"?([^\"\s]+)", d.get("Pin", ""))
        if not m:
            continue
        p = pins.setdefault(m.group(1), {"blocked": False, "allow": set()})
        pkgs, prio = d.get("Package", "").split(), d.get("Pin-Priority", "").strip()
        if pkgs == ["*"] and prio == "-1":
            p["blocked"] = True
        elif prio != "-1":
            p["allow"].update(pkgs)
for origin in sorted(hosts):
    p = pins.get(origin)
    if not p or not p["blocked"]:
        bad.append("%s: third-party source without a Package: * / Pin-Priority: -1 block" % origin)
        continue
    names = set()
    for lst in glob.glob("/var/lib/apt/lists/*%s*_Packages" % origin):
        names.update(re.findall(r"^Package: (\S+)", open(lst).read(), re.M))
    if not names:
        bad.append("%s: no package list found, so the pin cannot be checked" % origin)
        continue
    outside = sorted(names - p["allow"])
    for pkg in outside[:5]:
        out = subprocess.run(["apt-cache", "policy", pkg], capture_output=True, text=True).stdout
        cand = re.search(r"Candidate: (\S+)", out)
        cand = cand.group(1) if cand else "(none)"
        if cand == "(none)":
            continue
        sec = re.search(r"^ (?:\*\*\*| {3}) %s .*\n((?: {8}.*\n)*)" % re.escape(cand), out, re.M)
        if sec and origin in sec.group(1):
            bad.append("%s: %s %s is installable although not allowlisted" % (origin, pkg, cand))
    checked.append("%s (%d of %d outside the allowlist)" % (origin, min(5, len(outside)), len(outside)))
print("PIN-CHECKED " + "; ".join(checked))
for b in bad:
    print("PIN-FAIL " + b)
sys.exit(1 if bad else 0)
'

# checkTemplateApt VM RECIPE -- the template can still update through the
# Qubes updates proxy, its locked keyrings are locked, and third-party
# repositories can only ship their allowlisted packages.
checkTemplateApt() {
	local vm="$1" recipe="$2" out comp script path
	local -a paths=()
	out="$(qvm-run --pass-io --no-gui -u root "${vm}" 'apt-get update -q 2>&1' </dev/null 2>&1)"
	if grep -qE '^(E:|Err:)' <<< "${out}"; then
		fail "${vm}: apt-get update failed: $(grep -E '^(E:|Err:)' <<< "${out}" | head -n 2 | tr '\n' ' ')"
	else
		pass "${vm}: apt-get update works through the updates proxy"
		grep -E '^W:' <<< "${out}" | head -n 3 | sed "s/^/NOTE: ${vm} apt: /"
	fi
	for comp in $(componentsFor "${recipe}"); do
		script="${SALT_TREE}/files/components/${comp}/template-vm.sh"
		case "${comp}" in brave|brave-extension-*) script="${SALT_TREE}/files/lib/brave.sh" ;; esac
		sudo test -f "${script}" && sudo grep -q 'chattr +i' "${script}" || continue
		while IFS= read -r path; do
			paths+=("${path}")
		done < <(sudo grep -oiE 'keyring="/[^"]+"' "${script}" | cut -d'"' -f2)
	done
	for path in $(printf '%s\n' "${paths[@]}" | sort -u); do
		if qvm-run --pass-io --no-gui -u root "${vm}" "lsattr -d ${path} | cut -d' ' -f1 | grep -q i" </dev/null >/dev/null 2>&1; then
			pass "${vm}: ${path} is locked (immutable)"
		else
			fail "${vm}: ${path} is not locked"
		fi
	done
	if out="$(qvm-run --pass-io --no-gui -u root "${vm}" 'python3 -' <<< "${PIN_CHECK}" 2>&1)"; then
		pass "${vm}: third-party repositories are pinned: $(sed -n 's/^PIN-CHECKED //p' <<< "${out}")"
	else
		fail "${vm}: repository pinning: $(grep -E 'PIN-FAIL|Error' <<< "${out}" | head -n 3 | tr '\n' ' ')"
	fi
}

# checkMenu KIND VM RECIPE -- every component of RECIPE that ships its own
# menu entry has a generated dom0 menu entry that starts it in VM; a
# disposable template must have none.
checkMenu() {
	local kind="$1" vm="$2" recipe="$3" comp found
	for comp in $(componentsFor "${recipe}"); do
		sudo test -f "${SALT_TREE}/files/components/${comp}/menu.desktop" || continue
		found=0
		grep -lF "qubes.StartApp+${comp}" ~/.local/share/applications/*.desktop 2>/dev/null \
			| xargs -r grep -lF -- "-- ${vm} qubes.StartApp" >/dev/null 2>&1 && found=1
		if [ "${kind}" = "app" ] && [ "$(catField "${recipe}" dispvm_template)" = "True" ]; then
			[ "${found}" -eq 0 ] && pass "${vm}: no menu entry for ${comp} in the disposable template" \
				|| fail "${vm}: disposable template offers ${comp} in its menu"
		else
			[ "${found}" -eq 1 ] && pass "${vm}: menu entry for ${comp}" || fail "${vm}: no menu entry for ${comp}"
		fi
	done
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

# refused VM TARGET SERVICE... -- each qrexec call from VM to TARGET must be
# refused. A refusal comes back at once; a timeout would mean a confirmation
# dialog appeared instead, which is also a failure.
refused() {
	local vm="$1" target="$2" svc out
	shift 2
	for svc in "$@"; do
		out="$(qvm-run --pass-io --no-gui "${vm}" \
			"echo https://example.com | timeout 20 qrexec-client-vm ${target} ${svc}; echo rc=\$?" 2>&1 </dev/null)"
		if grep -qi "refused" <<< "${out}" && ! grep -q "rc=124" <<< "${out}"; then
			pass "${vm}: ${svc} to ${target} is refused"
		else
			fail "${vm}: ${svc} to ${target} was not refused: $(tail -n 2 <<< "${out}" | tr '\n' ' ')"
		fi
	done
}

# hasTag VM -- VM carries seqs-no-handoff, which the dom0 policy denies by.
hasTag() {
	qvm-tags -- "$1" list 2>/dev/null | grep -qx seqs-no-handoff \
		&& pass "$1: tagged seqs-no-handoff" || fail "$1: not tagged seqs-no-handoff"
}

# policyDecision SERVICE SOURCE TARGET -- what dom0's qrexec policy decides,
# evaluated without running anything: AllowResolution, AskResolution, or
# AccessDenied.
policyDecision() {
	python3 - "$@" 2>/dev/null <<'PY'
import pathlib, sys
from qrexec.policy.parser import FilePolicy, Request
from qrexec.utils import get_system_info
try:
    r = FilePolicy(policy_path=pathlib.Path("/etc/qubes/policy.d")).evaluate(
        Request(sys.argv[1], "+", sys.argv[2], sys.argv[3], system_info=get_system_info()))
    print(type(r).__name__)
except Exception as e:
    print(type(e).__name__)
PY
}

# unnamedDisposableRefused TEMPLATE -- a disposable started by hand from a
# disposable template inherits the tag, so its link handoff is refused too.
unnamedDisposableRefused() {
	local out
	out="$(qvm-run --dispvm="$1" --pass-io --no-gui \
		"echo https://example.com | timeout 20 qrexec-client-vm ${BROWSER_VM} qubes.OpenURL; echo rc=\$?" 2>&1 </dev/null)"
	if grep -qi "refused" <<< "${out}"; then
		pass "a disposable started from $1: qubes.OpenURL to ${BROWSER_VM} is refused"
	else
		fail "a disposable started from $1 could hand a link to ${BROWSER_VM}: $(tail -n 1 <<< "${out}")"
	fi
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
	local kind name recipe flags tpl klass nv dv d ours started=()
	local targets="${STATE_DIR}/targets"
	sudo test -r "${targets}" || { fail "${targets} missing -- the dom0 state did not run"; return 1; }
	if sudo grep -qx 'result=success' "${STATE_DIR}/last-run" 2>/dev/null; then
		pass "runner recorded result=success"
	else
		fail "runner did not record result=success in ${STATE_DIR}/last-run"
	fi
	CATALOGUE_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:catalogue 2>/dev/null)"
	EXTENSIONS_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:brave_extensions 2>/dev/null)"
	BROWSER_VM="$(pillarValue seqs:browser_vm)"
	BROWSER_DESKTOP="$(pillarValue seqs:browser_desktop)"
	[ -n "${BROWSER_VM}" ] && [ -n "${BROWSER_DESKTOP}" ] || fail "could not read browser_vm and browser_desktop from the pillar"

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
					checkSetup template "${name}" "${recipe}"
					checkTemplateApt "${name}" "${recipe}"
				fi
				;;
			app)
				tpl="$(qvm-prefs -- "${name}" template 2>/dev/null)"
				grep -qE "^template ${tpl} " < <(sudo cat "${targets}") \
					|| fail "${name} is based on ${tpl:-?}, not on a SEQS template"
				qvm-check --running --quiet -- "${name}" >/dev/null 2>&1 || ours=1
				checkMarkers "${name}" app "${recipe}"
				checkSetup app "${name}" "${recipe}"
				checkMenu app "${name}" "${recipe}"
				smoke "${name}" "${recipe}"
				# An offline, no_handoff, or firewalled qube can hand nothing to
				# the browser qube and start no disposable through any service
				# the default policy allows: a networked disposable would be a
				# way out.
				if noHandoff "${recipe}"; then
					hasTag "${name}"
					[ "$(catField "${recipe}" dispvm_template)" != "True" ] || unnamedDisposableRefused "${name}"
					refused "${name}" "${BROWSER_VM}" qubes.OpenURL qubes.OpenInVM
					refused "${name}" @dispvm qubes.OpenURL qubes.OpenInVM qubes.StartApp+xterm \
						qubes.GetImageRGBA qubes.VMShell qubes.VMExec+true qubes.VMExecGUI+true qubes.PdfConvert
				elif [ "${name}" != "${BROWSER_VM}" ]; then
					d="$(policyDecision qubes.OpenURL "${name}" "${BROWSER_VM}")"
					[ "${d}" = AllowResolution ] && pass "${name}: policy allows links to ${BROWSER_VM}" \
						|| fail "${name}: policy gives ${d:-nothing} for links to ${BROWSER_VM}"
				fi
				;;
			disposable)
				checkSetup disposable "${name}" "${recipe}"
				! noHandoff "${recipe}" || hasTag "${name}"
				checkMenu disposable "${name}" "${recipe}"
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
	# A qube SEQS did not build keeps the Qubes default for link handoff,
	# which asks, rather than the silent allow that SEQS qubes get.
	d="$(policyDecision qubes.OpenURL sys-firewall "${BROWSER_VM}")"
	[ "${d}" = AskResolution ] && pass "sys-firewall: links to ${BROWSER_VM} need the Qubes prompt" \
		|| fail "sys-firewall: policy gives ${d:-nothing} for links to ${BROWSER_VM}, expected the Qubes default ask"
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

# ---- lifecycle ----------------------------------------------------------------

# inQube VM CMD -- run CMD as the user in VM (starting it if needed).
inQube() {
	qvm-run --pass-io --no-gui "$1" "$2" </dev/null 2>/dev/null
}

# restart VM [kill] -- shut VM down cleanly, or kill it so that no shutdown
# hook runs, then start it again.
restart() {
	if [ "${2:-}" = "kill" ]; then
		qvm-kill -- "$1" >/dev/null 2>&1
	else
		qvm-shutdown --wait -- "$1" >/dev/null 2>&1
	fi
	qvm-start --skip-if-running -- "$1" >/dev/null 2>&1
}

SEED='mkdir -p ~/QubesIncoming/seqs-src ~/Downloads/seqs-sub ~/Documents && echo x > ~/QubesIncoming/seqs-src/f && echo x > ~/Downloads/seqs-a && echo x > ~/Downloads/seqs-sub/b && echo keep > ~/Documents/seqs-keep && sync'
CLEAN='[ ! -e ~/QubesIncoming ] && [ -d ~/Downloads ] && [ -z "$(ls -A ~/Downloads)" ] && [ -f ~/Documents/seqs-keep ]'

# lifecycle -- restart real qubes and check what must disappear and what
# must survive: the transient-directory cleanup on boot and shutdown, its
# absence in templates and preserve_incoming qubes, and private state that
# components keep through bind-dirs.
lifecycle() {
	local kind name recipe flags subject="" tpl way dir comp
	CATALOGUE_JSON="$(sudo qubesctl --dom0-only --out=json pillar.get seqs:catalogue 2>/dev/null)"
	while read -r kind name recipe flags; do
		[ "${kind}" = "app" ] || continue
		if [ "$(catField "${recipe}" preserve_incoming)" = "True" ]; then
			inQube "${name}" 'mkdir -p ~/QubesIncoming/seqs-src && echo x > ~/QubesIncoming/seqs-src/f'
			restart "${name}"
			inQube "${name}" 'test -f ~/QubesIncoming/seqs-src/f' \
				&& pass "${name}: QubesIncoming survives a restart (preserve_incoming)" \
				|| fail "${name}: QubesIncoming was wiped although preserve_incoming is set"
			inQube "${name}" 'rm -rf ~/QubesIncoming/seqs-src'
			qvm-shutdown --wait -- "${name}" >/dev/null 2>&1
			continue
		fi
		[ -n "${subject}" ] || subject="${name}"
		for comp in $(componentsFor "${recipe}"); do
			case "${comp}" in
				gnosisvpn) dir=/var/lib/gnosisvpn ;;
				docker) dir=/var/lib/docker ;;
				*) continue ;;
			esac
			qvm-run --pass-io --no-gui -u root "${name}" "echo x > ${dir}/seqs-persist" </dev/null >/dev/null 2>&1
			restart "${name}"
			if qvm-run --pass-io --no-gui -u root "${name}" "test -f ${dir}/seqs-persist && rm -f ${dir}/seqs-persist" </dev/null >/dev/null 2>&1; then
				pass "${name}: ${dir} survives a restart"
			else
				fail "${name}: ${dir} was lost on restart"
			fi
			qvm-shutdown --wait -- "${name}" >/dev/null 2>&1
		done
	done < <(sudo cat "${STATE_DIR}/targets")

	if [ -z "${subject}" ]; then
		echo "No app qube with the cleanup service in this selection."
	else
		# stop-hook: the shutdown cleanup alone, run in the live qube, so the
		# files are gone before the qube is off; kill: no shutdown hook runs,
		# so only the boot cleanup can remove them; shutdown: the normal path.
		for way in stop-hook kill shutdown; do
			inQube "${subject}" "${SEED}" || fail "${subject}: could not create the test files"
			inQube "${subject}" '[ -f ~/QubesIncoming/seqs-src/f ] && [ -f ~/Downloads/seqs-a ]' \
				|| fail "${subject}: test files vanished while the qube was running"
			if [ "${way}" = "stop-hook" ]; then
				qvm-run --pass-io --no-gui -u root "${subject}" 'systemctl stop seqs-cleanup.service' </dev/null >/dev/null 2>&1
			else
				restart "${subject}" "${way}"
			fi
			if inQube "${subject}" "${CLEAN}"; then
				pass "${subject}: QubesIncoming and Downloads wiped after ${way}, other files kept"
			else
				fail "${subject}: cleanup after ${way} is wrong: $(inQube "${subject}" 'ls -A ~/QubesIncoming ~/Downloads ~/Documents/seqs-keep 2>&1' | tr '\n' ' ')"
			fi
		done
		qvm-run --pass-io --no-gui -u root "${subject}" 'systemctl start seqs-cleanup.service' </dev/null >/dev/null 2>&1
		inQube "${subject}" 'rm -f ~/Documents/seqs-keep'
		qvm-shutdown --wait -- "${subject}" >/dev/null 2>&1

		# The template carries the cleanup service but must not run it.
		tpl="$(qvm-prefs -- "${subject}" template 2>/dev/null)"
		inQube "${tpl}" 'mkdir -p ~/Downloads && echo x > ~/Downloads/seqs-template-keep'
		restart "${tpl}"
		inQube "${tpl}" 'test -f ~/Downloads/seqs-template-keep' \
			&& pass "${tpl}: the cleanup leaves the template's Downloads alone" \
			|| fail "${tpl}: the cleanup wiped the template's Downloads"
		inQube "${tpl}" 'rm -f ~/Downloads/seqs-template-keep'
		qvm-shutdown --wait -- "${tpl}" >/dev/null 2>&1
	fi
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
	lifecycle) lifecycle ;;
	*) sed -n '3,22p' "$0"; exit 2 ;;
esac
