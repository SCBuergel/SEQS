#!/usr/bin/env bash
# Layer 3 -- unit tests for the pure-ish bash helpers in setup-qubes.sh.
#
# setup-qubes.sh is sourced with SEQS_SOURCE_ONLY=1 so we get its functions
# without running the installer, then each helper is driven with table-driven
# inputs. These are the security-load-bearing bits (terminal sanitiser, tar
# entry validation, targets parsing, air-gap verification) so a regression
# here is exactly what we want a test to catch before it reaches a real dom0.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$*"; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }

# Source helpers only.
export SEQS_SOURCE_ONLY=1
# shellcheck disable=SC1091
source ./setup-qubes.sh

echo "== sanitize() strips terminal control bytes, keeps text/TAB/LF =="
# The ESC (0x1b) and BEL (0x07) control BYTES must be removed so the sequence
# can no longer drive the terminal; the now-inert '[31m' text is left behind
# (harmless printable chars). TAB and letters survive.
out="$(printf 'a\033[31mRED\033[0m\007b\tc' | sanitize)"
eq "sanitize colour+bell" "$out" "$(printf 'a[31mRED[0mb\tc')"
# A UTF-8-encoded C1 (0xC2 0x9B, CSI) must be dropped.
out="$(printf 'x\xc2\x9by' | sanitize)"
eq "sanitize utf8 C1" "$out" "xy"

echo "== confirm() aborts when no terminal can be opened =="
# confirm reads /dev/tty by design (a piped stdin must never count as
# approval), so run it under setsid -- a session with no controlling
# terminal -- to make the tty open fail the same way everywhere. Without
# that, an interactive run would sit here waiting for keyboard input.
# The accept path (typing y on a real pty) is exercised by the
# Layer 4 integration run via test/lib/pty_run.py.
if command -v setsid >/dev/null 2>&1; then
	if setsid bash -c 'SEQS_SOURCE_ONLY=1 source ./setup-qubes.sh && confirm "p"' \
			</dev/null >/dev/null 2>&1; then
		bad "confirm should abort when /dev/tty cannot be opened"
	else ok; fi
else
	printf '  skip: setsid not available\n'
fi

echo "== isManaged() accepts only a SEQS header line =="
sudo() { "$@"; }
tmpf="$(mktemp)"
printf '# Managed by SEQS (salt state seqs.dom0) -- manual edits will be overwritten.\nx\n' > "${tmpf}"
isManaged "${tmpf}" && ok || bad "a SEQS header must count as managed"
printf '# my rules, not Managed by SEQS\nqubes.OpenURL * @anyvm @anyvm allow\n' > "${tmpf}"
isManaged "${tmpf}" && bad "the marker inside an operator comment must not count" || ok
printf 'qubes.OpenURL * @anyvm @anyvm allow\n# Managed by SEQS\n' > "${tmpf}"
isManaged "${tmpf}" && bad "the marker on a later line must not count" || ok
rm -f "${tmpf}"
unset -f sudo

echo "== confirmPolicyTakeover() skips the USB keyboard policy only when sys-usb is known absent =="
# On Qubes 4.3, an operator's 30-user-input.policy needs confirmation unless
# qvm-ls positively lists no sys-usb; a failed qvm-ls must keep the prompt.
takeover() { # QVM_LS_OUTPUT QVM_LS_RC -> "prompt" or "skip"
	(
		tmpd="$(mktemp -d)"
		POLICY_DIR="${tmpd}" POLICY_FILES=("${tmpd}/30-user-input.policy")
		echo 'qubes.InputKeyboard * sys-usb @adminvm allow' > "${POLICY_FILES[0]}"
		sudo() { "$@"; }
		grep() { if [ "${*: -1}" = /etc/qubes-release ]; then echo 4.3; else command grep "$@"; fi; }
		qvm-ls() { printf '%b' "${QLS_OUT}"; return "${QLS_RC}"; }
		confirm() { echo prompt; }
		QLS_OUT="$1" QLS_RC="$2"
		out="$(confirmPolicyTakeover 2>/dev/null)"
		rm -rf "${tmpd}"
		echo "${out:-skip}"
	)
}
eq "sys-usb listed" "$(takeover 'dom0\nsys-usb\n' 0)" prompt
eq "sys-usb absent" "$(takeover 'dom0\nsys-net\n' 0)" skip
eq "qvm-ls failed" "$(takeover '' 1)" prompt

echo "== adb-pull treats the device's answers as data =="
# A hostile phone answers stat with a bash arithmetic payload; adb-pull must
# refuse it without running the embedded command.
tmpd="$(mktemp -d)"
cat > "${tmpd}/adb" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
	devices) printf 'List of devices attached\nphone\tdevice\n' ;;
	*getprop*) printf 'SER\033]0;x\0071\r\n' ;;
	*stat*) printf 'HOME[$(touch %s/pwned)]\r\n' "$(dirname "$0")" ;;
esac
MOCK
chmod +x "${tmpd}/adb"
sed "s#^ADB=/usr/bin/adb#ADB=${tmpd}/adb#" install-scripts/components/adb/adb-pull.sh > "${tmpd}/adb-pull"
out="$(HOME="${tmpd}" bash "${tmpd}/adb-pull" /sdcard/f "${tmpd}/out" 2>&1 </dev/null)" \
	&& bad "adb-pull must refuse a non-numeric size"
[ ! -e "${tmpd}/pwned" ] && ok || bad "adb-pull ran a command embedded in the device's size answer"
grep -q "Device serial captured: SER0x1$" <<< "${out}" && ok \
	|| bad "the device serial must lose its control characters: $(grep serial <<< "${out}")"
rm -rf "${tmpd}"

echo "== adb-pull resumes only a partial download of the remote file =="
tmpd="$(mktemp -d)"
printf 'remote file\n' > "${tmpd}/remote"
cat > "${tmpd}/adb" <<'MOCK'
#!/usr/bin/env bash
r="$(dirname "$0")/remote"
case "$*" in
	devices) printf 'List of devices attached\nphone\tdevice\n' ;;
	*getprop*) echo SER ;;
	*stat*) stat -c%s "${r}" ;;
	*sha256sum*) sha256sum "${r}" ;;
	*dd\ *) [[ "$*" =~ skip=([0-9]+)\ count=([0-9]+) ]] \
		&& dd if="${r}" bs=1M skip="${BASH_REMATCH[1]}" count="${BASH_REMATCH[2]}" 2>/dev/null ;;
esac
MOCK
chmod +x "${tmpd}/adb"
sed "s#^ADB=/usr/bin/adb#ADB=${tmpd}/adb#" install-scripts/components/adb/adb-pull.sh > "${tmpd}/adb-pull"
# A partial file shorter than one chunk restarts from its first byte.
printf 'rem' > "${tmpd}/out"
HOME="${tmpd}" bash "${tmpd}/adb-pull" /sdcard/f "${tmpd}/out" >/dev/null 2>&1 </dev/null \
	&& cmp -s "${tmpd}/remote" "${tmpd}/out" && ok \
	|| bad "adb-pull must restart a partial file shorter than one chunk"
# A larger file is not a partial download of it: refuse and keep it.
printf 'a longer local file\n' > "${tmpd}/out"
out="$(HOME="${tmpd}" bash "${tmpd}/adb-pull" /sdcard/f "${tmpd}/out" 2>&1 </dev/null)" \
	&& bad "adb-pull must refuse a local file larger than the remote one"
grep -q "is larger than the remote file" <<< "${out}" \
	&& [ "$(cat "${tmpd}/out")" = "a longer local file" ] && ok \
	|| bad "adb-pull must leave a larger local file unchanged: ${out}"
rm -rf "${tmpd}"

echo "== joinCsv() =="
eq "joinCsv" "$(joinCsv a b c)" "a,b,c"
eq "joinCsv one" "$(joinCsv solo)" "solo"

echo "== tar-entry validation accepts the real repo tree, rejects hostile entries =="
# validateTarListing dies (exits) on a rejected entry, so run it in a subshell.
validate_tar() { ( validateTarListing ) 2>&1; }
# Real tree must pass.
out="$(tar -cf - salt install-scripts | tar --numeric-owner -tvf - | validate_tar)" && ok \
	|| bad "validation rejected the real repo tree: ${out}"
# Hostile entries must each be rejected, for the stated reason.
reject() {
	local out
	out="$(printf '%s\n' "$1" | validate_tar)" && { bad "accepted hostile: $1"; return; }
	grep -qF "$2" <<< "${out}" && ok || bad "hostile [$1]: expected [$2], got [${out}]"
}
reject 'lrwxrwxrwx 0/0 0 2020-01-01 00:00 salt/evil' "non-regular tar entry"
reject '-rw-r--r-- 0/0 0 2020-01-01 00:00 salt/../etc/passwd' "containing '..'"
reject '-rw-r--r-- 0/0 0 2020-01-01 00:00 /etc/passwd' "unsafe tar path"
reject '-rw-r--r-- 0/0 0 2020-01-01 00:00 salt/a b' "whitespace in its name"
reject '-rw-r--r-- 0/0 0 2020-01-01 00:00 other/thing' "unsafe tar path"
reject '-rw-r--r-- 0/0 0 2020-01-01 00:00 salt/seqs/.seqs-complete' "named like a SEQS marker"
reject 'drwxr-xr-x 0/0 0 2020-01-01 00:00 salt/pillar/seqs/.seqs-managed/' "named like a SEQS marker"
# A field that is not in its fixed form could shift part of the name out of
# the path field, as these listings from crafted archives do: a huge mtime
# prints as one number, and an owner name may contain a space.
reject '-rw-r--r-- 0/0 1 1000000000000000000 /abs salt/y' "unexpected listing"
reject '-rw-r--r-- a b/0 1 1969-12-31 19:00 salt/ok' "unexpected listing"
reject '-rw-r--r-- root/root 1 2020-01-01 00:00 salt/ok' "unexpected listing"
# A sparse entry lists its full size but takes almost no archive space, so
# the listed sizes are capped as well as the transfer.
reject '-rw-r--r-- 0/0 1000000000 2020-01-01 00:00 salt/huge' "unexpected listing"
reject "$(printf -- '-rw-r--r-- 0/0 9000000 2020-01-01 00:00 salt/%s\n' a b)" "add up to"

echo "== SAFE_NAME accepts plain names only =="
for n in keepass A-brave sys-usb_2 a.b; do
	[[ "${n}" =~ ${SAFE_NAME} ]] && ok || bad "SAFE_NAME rejected the safe name [${n}]"
done
for n in '' - -h . .. a/b 'a b' '*' 'a;b' $'a\nb' '$(x)'; do
	[[ "${n}" =~ ${SAFE_NAME} ]] && bad "SAFE_NAME accepted the unsafe name [${n}]" || ok
done

echo "== readTargets() parses the targets file, rejects unsafe names =="
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export TARGETS_FILE="${tmp}/targets"
cat > "${TARGETS_FILE}" <<'EOF'
# comment
template Z-brave brave
template Z-keepass keepass
app A-brave brave
app A-keepass keepass offline
disposable D-qr-display qr-display offline
EOF
if readTargets; then
	eq "templates count" "${#TEMPLATE_TARGETS[@]}" "2"
	eq "apps count" "${#APP_TARGETS[@]}" "2"
	# The named disposable is verified but not provisioned: it lands in its own
	# list, is offline-checked, and never enters APP_TARGETS.
	eq "disposable count" "${#DISPOSABLE_TARGETS[@]}" "1"
	eq "disposable is D-qr-display" "${DISPOSABLE_TARGETS[0]}" "D-qr-display"
	eq "offline count" "${#OFFLINE_TARGETS[@]}" "2"
	eq "offline includes the disposable" "${OFFLINE_TARGETS[*]}" "A-keepass D-qr-display"
else bad "readTargets failed on a valid file"; fi
# Unsafe qube name must abort.
for line in 'app A-brave;x brave' 'app A-brave br$(x)ave'; do
	printf 'template Z-brave brave\n%s\n' "${line}" > "${TARGETS_FILE}"
	out="$( ( readTargets ) 2>&1 )" && bad "readTargets accepted [${line}]"
	grep -q "unsafe .* name in ${TARGETS_FILE}" <<< "${out}" && ok || bad "[${line}]: wrong message [${out}]"
done
# An unknown flag must abort: it may be a protection this runner cannot apply.
printf 'template Z-brave brave\napp A-brave brave online\n' > "${TARGETS_FILE}"
out="$( ( readTargets ) 2>&1 )" && bad "readTargets accepted an unknown flag"
grep -q "unknown flag in ${TARGETS_FILE}: 'online'" <<< "${out}" && ok || bad "unknown flag: wrong message [${out}]"

echo "== verifyAirgap() only passes when offline qubes are explicitly offline =="
# Stub qvm-prefs on PATH: "qvm-prefs -- VM" lists netvm and default_dispvm in
# qvm-prefs format, with the netvm from $NETVM and the flag from $FLAG.
stub="${tmp}/bin"; mkdir -p "${stub}"
cat > "${stub}/qvm-prefs" <<'EOF'
#!/usr/bin/env bash
printf 'default_dispvm  %s  None\nnetvm  %s  %s\n' "${FLAG:--}" "${FLAG:--}" "${NETVM:-None}"
EOF
chmod +x "${stub}/qvm-prefs"
export PATH="${stub}:${PATH}"
OFFLINE_TARGETS=(A-keepass)
if ( verifyAirgap ) >/dev/null 2>&1; then ok; else bad "verifyAirgap failed a truly-offline qube"; fi
if ( NETVM=sys-firewall verifyAirgap ) >/dev/null 2>&1; then bad "verifyAirgap passed a qube that still has a netvm"; else ok; fi
if ( FLAG=D verifyAirgap ) >/dev/null 2>&1; then bad "verifyAirgap passed an air gap inherited from a global default"; else ok; fi

echo "== readTargets() and verifyNetvm(): a declared NetVM is set explicitly =="
printf 'template Z-anon anon\napp A-anon anon netvm=A-gnosisvpn\ndisposable D-anon anon netvm=A-gnosisvpn\n' > "${TARGETS_FILE}"
eq "netvm entries, none offline" "$( ( readTargets && echo "${NETVM_TARGETS[*]}|${#OFFLINE_TARGETS[@]}" ) 2>&1 )" \
	"A-anon A-gnosisvpn D-anon A-gnosisvpn|0"
printf 'template Z-anon anon\napp A-anon anon netvm=x;id\n' > "${TARGETS_FILE}"
out="$( ( readTargets ) 2>&1 )" && bad "readTargets accepted an unsafe netvm"
grep -q "unsafe netvm in ${TARGETS_FILE}: 'netvm=x;id'" <<< "${out}" && ok || bad "unsafe netvm: wrong message [${out}]"
NETVM_TARGETS=("A-anon A-gnosisvpn")
if ( NETVM=A-gnosisvpn verifyNetvm ) >/dev/null 2>&1; then ok; else bad "verifyNetvm failed the declared NetVM"; fi
out="$( ( NETVM=sys-firewall verifyNetvm ) 2>&1 )" && bad "verifyNetvm passed another NetVM"
grep -q "qube 'A-anon' does not have its netvm explicitly set to 'A-gnosisvpn'" <<< "${out}" && ok || bad "verifyNetvm: wrong message [${out}]"
if ( NETVM=A-gnosisvpn FLAG=D verifyNetvm ) >/dev/null 2>&1; then bad "verifyNetvm passed an inherited NetVM"; else ok; fi

echo "== test machine setup: input validation and generated qube scripts =="
# test/hardware/setup-test-machine.sh interpolates these values into scripts
# that run as root in test-ctl and sys-net, so its validators must hold.
# Sourced in a subshell: it redefines sanitize()/die().
(
	SEQS_SOURCE_ONLY=1 source ./test/hardware/setup-test-machine.sh
	t() { if "$@"; then echo 1; else echo 0; fi; }
	for c in 192.168.1.0/24 10.0.0.0/8 192.168.1.7/32; do
		[ "$(t validCidr "$c")" = 1 ] || echo "FAIL validCidr rejected $c"
	done
	for c in 0.0.0.0/0 10.0.0.0/7 256.1.1.1/24 192.168.1.0/33 "192.168.1.0/24;id" 192.168.1.0 "1.2.3.4/24 "; do
		[ "$(t validCidr "$c")" = 0 ] || echo "FAIL validCidr accepted $c"
	done
	for p in 22 2222 65535; do [ "$(t validPort "$p")" = 1 ] || echo "FAIL validPort rejected $p"; done
	for p in 0 65536 -1 22x ""; do [ "$(t validPort "$p")" = 0 ] || echo "FAIL validPort accepted $p"; done
	[ "$(t validUrl https://github.com/someone.keys)" = 1 ] || echo "FAIL validUrl rejected a plain URL"
	for u in http://github.com/x.keys "https://x/'y" 'https://x/$(id)' "https://x/ y" 'https://x/`id`' "https://x/;id"; do
		[ "$(t validUrl "$u")" = 0 ] || echo "FAIL validUrl accepted $u"
	done
	for n in user test_user; do [ "$(t validUser "$n")" = 1 ] || echo "FAIL validUser rejected $n"; done
	for n in root\;id "a b" Root ""; do [ "$(t validUser "$n")" = 0 ] || echo "FAIL validUser accepted $n"; done
	for n in debian-13-xfce fedora-42-xfce; do [ "$(t validVmName "$n")" = 1 ] || echo "FAIL validVmName rejected $n"; done
	for n in "a b" "x;id" "-x" ""; do [ "$(t validVmName "$n")" = 0 ] || echo "FAIL validVmName accepted $n"; done

	k="${tmp}/keys"
	printf '# laptop\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE fake@example\n\n' > "$k"
	[ "$(t validKeys "$k")" = 1 ] || echo "FAIL validKeys rejected a plain key"
	printf 'ecdsa-sha2-nistp256 AAAAE2VjZHNhFAKE==\n' > "$k"
	[ "$(t validKeys "$k")" = 1 ] || echo "FAIL validKeys rejected an ecdsa key"
	for bad_keys in '' '# only a comment\n' 'command="id" ssh-ed25519 AAAAFAKE\n' \
			'ssh-ed25519 AAAA$(id)\n' 'ssh-dss AAAAFAKE\n' '<html>not found</html>\n'; do
		printf "$bad_keys" > "$k"
		[ "$(t validKeys "$k")" = 0 ] || echo "FAIL validKeys accepted [$bad_keys]"
	done

	# The default allowed range is derived from sys-net's own address.
	[ "$(networkOf 192.168.1.50 24)" = 192.168.1.0/24 ] || echo "FAIL networkOf /24"
	[ "$(networkOf 10.20.30.40 16)" = 10.20.0.0/16 ] || echo "FAIL networkOf /16"
	[ "$(networkOf 172.16.5.9 32)" = 172.16.5.9/32 ] || echo "FAIL networkOf /32"
	validCidr "$(networkOf 100.64.1.2 6)" && echo "FAIL a /6 LAN must not pass validCidr"

	# The QR code carries "seqs-test-v1 <key line>"; anything else is refused.
	key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE seqs-test'
	[ "$(parseQrPayload "seqs-test-v1 ${key}")" = "${key}" ] || echo "FAIL parseQrPayload plain"
	[ "$(parseQrPayload "$(printf 'seqs-test-v1 %s\r\nextra' "${key}")")" = "${key}" ] \
		|| echo "FAIL parseQrPayload CR/LF"
	for qr in "${key}" "https://example.com" "" "xseqs-test-v1 ${key}"; do
		parseQrPayload "${qr}" >/dev/null && echo "FAIL parseQrPayload accepted [${qr}]"
	done

	# The scripts sent to test-ctl and sys-net must parse and carry the values.
	runIn() { cat; }
	ALLOW_FROM=192.168.1.0/24 PORT=2222 CTL_IP=10.137.0.42
	configureCtl > "${tmp}/ctl.sh"
	configureNet install > "${tmp}/net.sh"
	configureNet remove > "${tmp}/netrm.sh"
	for f in ctl net netrm; do
		bash -n "${tmp}/${f}.sh" 2>/dev/null || echo "FAIL generated ${f} script does not parse"
	done
	grep -q 'dport 2222 dnat to 10.137.0.42:22' "${tmp}/net.sh" || echo "FAIL sys-net DNAT rule missing"
	grep -q 'ip saddr 192.168.1.0/24 tcp dport 22 accept' "${tmp}/ctl.sh" || echo "FAIL test-ctl input rule missing"
	if grep -q 'dnat to' "${tmp}/netrm.sh"; then echo "FAIL remove still installs the DNAT rule"; fi
	echo CHECKS-DONE
) > "${tmp}/testmachine.out" 2>&1
# A subshell that stops early, such as on a failed source, checked nothing.
grep -qx CHECKS-DONE "${tmp}/testmachine.out" \
	|| bad "the test machine setup checks stopped early: $(tail -n 3 "${tmp}/testmachine.out")"
if grep -q FAIL "${tmp}/testmachine.out"; then
	while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep FAIL "${tmp}/testmachine.out")
else ok; fi

echo "== component scripts that lock a file unlock it first, so they can run twice =="
# A component runs again whenever its files change (hash markers). A file it
# locked with chattr +i or lock_keyring on the first run must be unlocked
# before it is rewritten, or the rerun fails. lock_keyring's own chattr on its
# argument "${1}" is the helper, not a lock.
lock_re='^[[:space:]]*(sudo chattr \+i|lock_keyring) "?'
for f in install-scripts/components/*/*.sh install-scripts/lib/*.sh; do
	while IFS= read -r target; do
		[ "${target}" = '\$\{1\}' ] && continue
		lock_line="$(grep -nE "${lock_re}${target}" "$f" | head -n 1 | cut -d: -f1)"
		unlock_line="$(grep -nE "^[[:space:]]*sudo chattr -i \"?${target}" "$f" | head -n 1 | cut -d: -f1)"
		if [ -n "${unlock_line}" ] && [ "${unlock_line}" -lt "${lock_line}" ]; then ok
		else bad "$f locks ${target} without unlocking it earlier"; fi
	done < <(grep -oE "${lock_re}"'[^" ]+' "$f" | sed -E 's/.*(chattr \+i|lock_keyring) "?//; s/[$]/\\$/g; s/[{}]/\\&/g')
done

echo "== hardware system test: dom0-side helpers =="
(
	SEQS_SOURCE_ONLY=1 source ./test/hardware/dom0-test.sh
	# A selection reaches the runner's command line, so only catalogue-shaped
	# lists and "all" pass; nothing is run for a rejected one.
	for s in "x;id" "" "Brave" "a,,b" "-all" "a b"; do
		install "$s" >/dev/null 2>&1; [ $? -eq 2 ] || echo "FAIL install accepted [$s]"
	done
	for v in "" None none; do isNone "$v" || echo "FAIL isNone [$v]"; done
	isNone sys-firewall && echo "FAIL isNone sys-firewall"
	# qubesctl wraps salt-call output in {"local": ...}; both shapes parse.
	CATALOGUE_JSON='{"local": {"dev-full": {"components": ["docker", "python"]}}}'
	[ "$(componentsFor dev-full)" = "docker python" ] || echo "FAIL componentsFor local"
	CATALOGUE_JSON='{"keepass": {"components": ["keepass"]}}'
	[ "$(componentsFor keepass)" = "keepass" ] || echo "FAIL componentsFor plain"
	CATALOGUE_JSON='not json'
	[ -z "$(componentsFor keepass)" ] || echo "FAIL componentsFor must be empty on bad JSON"

	# Every component the catalogue uses has a smoke test, and each smoke
	# command is valid shell for the qube.
	CATALOGUE_JSON="$(python3 test/render_states.py pillar dom0 2>/dev/null)"
	EXTENSIONS_JSON="${CATALOGUE_JSON}"
	CATALOGUE_JSON="$(python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["seqs"]["catalogue"]))' <<< "${CATALOGUE_JSON}")"
	EXTENSIONS_JSON="$(python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["seqs"]["brave_extensions"]))' <<< "${EXTENSIONS_JSON}")"
	comps="$(python3 -c 'import json, sys; print("\n".join(sorted({c for q in json.load(sys.stdin).values() for c in q["components"]})))' <<< "${CATALOGUE_JSON}")"
	[ -n "${comps}" ] || echo "FAIL no catalogue components found"
	for c in ${comps}; do
		cmd="$(smokeCmd "$c")"
		[ -n "${cmd}" ] || echo "FAIL component $c has no smoke test"
		bash -n <<< "${cmd}" 2>/dev/null || echo "FAIL smoke test of $c is not valid shell"
		[[ "${cmd}" != false* ]] || echo "FAIL smoke test of $c could not be built: ${cmd}"
	done
	# The scripts run inside the provider qubes are valid shell.
	bash -n <<< "${WG_IMPORT}" 2>/dev/null || echo "FAIL WG_IMPORT is not valid shell"
	bash -n <<< "${GV_DNS}" 2>/dev/null || echo "FAIL GV_DNS is not valid shell"
	# A qube carries exactly the handoff tag its recipe calls for.
	CATALOGUE_JSON='{"keepass": {"offline": true}, "signal": {}}'
	tag() { qvm-tags() { printf '%b' "${TAGS}"; }; TAGS="$3" handoffTag "$1" "$2"; }
	[[ "$(tag A-keepass keepass 'seqs-no-handoff\n')" == CHECK-OK* ]] || echo "FAIL handoffTag offline"
	[[ "$(tag A-signal signal 'seqs-handoff\n')" == CHECK-OK* ]] || echo "FAIL handoffTag handoff"
	[[ "$(tag A-keepass keepass 'seqs-no-handoff\nseqs-handoff\n')" == CHECK-FAIL* ]] || echo "FAIL handoffTag accepted both tags"
	[[ "$(tag A-signal signal 'seqs-no-handoff\n')" == CHECK-FAIL* ]] || echo "FAIL handoffTag accepted the wrong tag"
	[[ "$(tag A-keepass keepass '')" == CHECK-FAIL* ]] || echo "FAIL handoffTag accepted no tag"
	# failsClosed passes only on a client that ran and was blocked, after the
	# same client got out through the default NetVM.
	probe() {
		qvm-check() { return 0; }; qvm-shutdown() { :; }; qubes-prefs() { echo sys-firewall; }
		qvm-prefs() { NET="$4"; }
		qvm-run() { local r; [ "${NET}" = sys-firewall ] && r="${BASE}" || r="${OUT}"; [ -z "$r" ] || echo "$r"; }
		CLIENT_BASELINE="" BASE="$1" OUT="$2" failsClosed A-vpn
	}
	[[ "$(probe REACHED BLOCKED)" == CHECK-OK* ]] || echo "FAIL failsClosed blocked"
	[[ "$(probe REACHED REACHED)" == *"CHECK-FAIL: A-vpn: a client reached"* ]] || echo "FAIL failsClosed accepted a leak"
	[[ "$(probe REACHED '')" == *"CHECK-FAIL: A-vpn: could not run"* ]] || echo "FAIL failsClosed accepted a client that did not run"
	[[ "$(probe BLOCKED BLOCKED)" == *"CHECK-FAIL: seqs-test-client could not reach"* ]] || echo "FAIL failsClosed ran without a baseline"
	[[ "$(probe '' BLOCKED)" == *"did not run"* ]] || echo "FAIL failsClosed accepted a baseline that did not run"
	echo CHECKS-DONE
) > "${tmp}/dom0test.out" 2>&1
# A subshell that stops early, such as on a failed source, checked nothing.
grep -qx CHECKS-DONE "${tmp}/dom0test.out" \
	|| bad "the hardware check helpers stopped early: $(tail -n 3 "${tmp}/dom0test.out")"
if grep -q FAIL "${tmp}/dom0test.out"; then
	while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep FAIL "${tmp}/dom0test.out")
else ok; fi

echo "== seqs-wireguard-import accepts a provider export, refuses hooks =="
# A stub sudo records what the import would install instead of doing it. The
# test runs a copy that calls the stub by absolute path: a missing stub fails,
# and never falls through to this machine's own sudo.
wg="${tmp}/wg"; mkdir -p "${wg}/bin"
printf '#!/bin/sh\necho "$*" >> "%s/sudo.log"\n' "${wg}" > "${wg}/bin/sudo"; chmod +x "${wg}/bin/sudo"
sed -E "s#(^|[^-/A-Za-z_])sudo #\\1${wg}/bin/sudo #g" install-scripts/components/wireguard/seqs-wireguard > "${wg}/import"
grep -vE '^[[:space:]]*#' "${wg}/import" | grep -qE '(^|[^-/A-Za-z_])sudo ' \
	&& bad "the WireGuard import copy still calls sudo through PATH" || ok
wg_conf() {  # EXTRA-LINE... -- a complete full-tunnel config plus the given lines
	printf '%s\n' '[Interface]' '# provider comment' 'PrivateKey = AAAA' 'Address = 10.2.0.2/32' \
		'DNS = 10.2.0.1' '[Peer]' 'PublicKey = BBBB' 'Endpoint = 198.51.100.1:51820' \
		'AllowedIPs = 0.0.0.0/0, ::/0' 'PersistentKeepalive = 25' "$@" > "${wg}/t.conf"
}
wg_import() { bash "${wg}/import" "${wg}/t.conf" 2>&1; }
wg_conf; rm -f "${wg}/sudo.log"
out="$(wg_import)" && grep -q "seqs-wireguard/wg0.conf" "${wg}/sudo.log" && ok || bad "a provider export was refused: ${out}"
wg_conf; sed -i 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0 # all traffic|' "${wg}/t.conf"; rm -f "${wg}/sudo.log"
out="$(wg_import)" && ok || bad "a full tunnel with a trailing comment was refused: ${out}"
for extra in 'PostUp = touch /tmp/x' $'Post\x01Up = touch /tmp/x' 'Table = off' 'SaveConfig = true'; do
	wg_conf "${extra}"; rm -f "${wg}/sudo.log"
	out="$(wg_import)" && bad "the import accepted [${extra}]"
	grep -q "wg-quick hooks such as PostUp would run as root" <<< "${out}" && [ ! -e "${wg}/sudo.log" ] && ok \
		|| bad "[${extra}]: wrong message or installed anyway [${out}]"
done
# A NUL byte inside a key: grep sees two words, wg-quick's bash parser PostUp.
wg_conf; printf 'Post\0Up = touch /tmp/x\n' >> "${wg}/t.conf"; rm -f "${wg}/sudo.log"
out="$(wg_import)" && bad "the import accepted Post<NUL>Up"
[ ! -e "${wg}/sudo.log" ] && ok || bad "Post<NUL>Up was installed"
# Only an exact 0.0.0.0/0 entry is a full tunnel.
wg_conf; sed -i 's|^AllowedIPs = .*|AllowedIPs = 100.0.0.0/08|' "${wg}/t.conf"; rm -f "${wg}/sudo.log"
out="$(wg_import)" && bad "the import accepted a split tunnel"
grep -q "not a complete full-tunnel" <<< "${out}" && ok || bad "split tunnel: wrong message [${out}]"

echo "== runQubesctl() fails on a failed state even when qubesctl exits 0 =="
# Shell functions, not stubs on PATH: they cannot fall through to the host's sudo.
qctl() { ( sudo() { "$@"; }; qubesctl() { printf '%b\n' "$1"; }; runQubesctl "$1" ) >/dev/null 2>&1; }
qctl '    Result: True\nSucceeded: 3\nFailed:    0' && ok || bad "runQubesctl failed a clean run"
qctl '    Result: False\nSucceeded: 3' && bad "runQubesctl passed a 'Result: False' state" || ok
qctl $'    Result: \e[0;31mFalse' && bad "runQubesctl passed a colored 'Result: False'" || ok
qctl 'Succeeded: 2\nFailed:    1' && bad "runQubesctl passed 'Failed: 1'" || ok
qctl 'Z-brave: ERROR (exit code 20)' && bad "runQubesctl passed a qube reported as ERROR" || ok

echo "== lib/verify-gpg.sh: pinned keys, signed downloads, pinned apt repos =="
# require_exact_keys reads gpg --with-colons output: only primary keys count,
# in any order, and the set must match exactly.
colons() { for f in "$@"; do printf 'pub:u:255:22:X:1::::::scESC:\nfpr:::::::::%s:\nsub:u:255:18:Y:1::::::e:\nfpr:::::::::SUB%s:\n' "$f" "$f"; done; }
req() { ( set -Eeuo pipefail; . install-scripts/lib/verify-gpg.sh; colons "${@:2}" | require_exact_keys test $1 ) 2>&1; }
req "A B" B A >/dev/null && ok || bad "require_exact_keys must accept the pinned keys in any order"
out="$(req A A B)" && bad "require_exact_keys accepted an extra key"
grep -q "test must hold exactly the pinned key" <<< "${out}" && ok || bad "extra key: wrong message [${out}]"
req "A B" A >/dev/null && bad "require_exact_keys accepted a missing key" || ok
req A >/dev/null && bad "require_exact_keys accepted no key" || ok
req A A A >/dev/null && bad "require_exact_keys accepted a duplicated key" || ok
if command -v gpg >/dev/null 2>&1; then
	g="${tmp}/gpg"; mkdir -p "${g}/home" "${g}/src" "${g}/root"; chmod 700 "${g}/home"
	export GNUPGHOME="${g}/home"
	for n in 1 2; do gpg --batch --quiet --passphrase '' --quick-gen-key "seqs-test-${n} <t@invalid>" ed25519 sign never 2>/dev/null; done
	mapfile -t fprs < <(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; w=0}')
	gpg --armor --export "${fprs[0]}" > "${g}/one.asc"
	gpg --armor --export > "${g}/two.asc"
	echo data > "${g}/src/f.bin"
	gpg --batch --yes --quiet --local-user "${fprs[0]}" --armor --detach-sign -o "${g}/src/f.bin.asc" "${g}/src/f.bin"
	unset GNUPGHOME
	# Mocks: sudo writes below ${g}/root, apt-get is a no-op, and curl copies
	# from ${g}/src.
	lib() {
		( set -Eeuo pipefail
		sudo() { case "$1" in tee) mkdir -p "${g}/root${2%/*}"; command tee "${g}/root$2" ;; *) "$@" ;; esac; }
		curl() { local url="${*: -1}"; cp "${g}/src/${url##*/}" "$5"; }
		. install-scripts/lib/verify-gpg.sh
		"$@" ) 2>&1
	}
	out="$(lib add_pinned_apt_repo demo /k.gpg "${fprs[0]}" amd64 "https://r.invalid/ s main" r.invalid "p1 p2" < "${g}/one.asc")" \
		|| bad "add_pinned_apt_repo failed: ${out}"
	eq "pin file" "$(cat "${g}/root/etc/apt/preferences.d/demo.pref")" "$(printf 'Package: *\nPin: origin "r.invalid"\nPin-Priority: -1\n\nPackage: p1 p2\nPin: origin "r.invalid"\nPin-Priority: 500')"
	eq "sources line" "$(cat "${g}/root/etc/apt/sources.list.d/demo.list")" "deb [arch=amd64 signed-by=/k.gpg] https://r.invalid/ s main"
	eq "keyring" "$(gpg --show-keys --with-colons "${g}/root/k.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')" "${fprs[0]}"
	rm -rf "${g}/root"
	out="$(lib add_pinned_apt_repo demo /k.gpg "${fprs[0]}" amd64 x r.invalid p1 < "${g}/two.asc")" \
		&& bad "add_pinned_apt_repo accepted a key block with a second key"
	grep -q "the key block must hold exactly the pinned key" <<< "${out}" && [ ! -e "${g}/root/k.gpg" ] && ok \
		|| bad "a second key must stop add_pinned_apt_repo before it writes the keyring: ${out}"
	sha="$(sha256sum "${g}/src/f.bin" | cut -d' ' -f1)"
	fetch() { rm -rf "${g}/dl"; mkdir -p "${g}/dl"; lib fetch_signed "${fprs[0]}" https://x.invalid/f.bin .asc "${g}/dl" "$@" < "${g}/one.asc"; }
	out="$(fetch "${sha}")" && grep -q "signature OK -- f.bin" <<< "${out}" && grep -q "sha256 OK -- f.bin" <<< "${out}" \
		&& ok || bad "fetch_signed rejected a good signature: ${out}"
	# A file with a good signature but another hash is another release.
	out="$(fetch "$(printf '%064d' 0)")" && bad "fetch_signed accepted a file with another SHA-256"
	grep -q "f.bin does not have the pinned SHA-256" <<< "${out}" && ok || bad "other hash: wrong message [${out}]"
	# The hash is checked first, so gpg never parses bytes the pin rejects.
	! grep -q "signature OK" <<< "${out}" && ok || bad "fetch_signed ran gpg on a file with another SHA-256"
	# A file signed by another key names the cause.
	GNUPGHOME="${g}/home" gpg --batch --yes --quiet --local-user "${fprs[1]}" --armor --detach-sign -o "${g}/src/f.bin.asc" "${g}/src/f.bin"
	out="$(fetch "${sha}")" && bad "fetch_signed accepted a signature by another key"
	grep -qE "rejected: gpg emitted (ERRSIG|NO_PUBKEY)" <<< "${out}" && ok || bad "other key: wrong message [${out}]"
	echo tampered > "${g}/src/f.bin"
	GNUPGHOME="${g}/home" gpg --batch --yes --quiet --local-user "${fprs[0]}" --armor --detach-sign -o "${g}/src/f.bin.asc" "${g}/src/f.bin"
	echo tampered again > "${g}/src/f.bin"
	out="$(fetch "$(sha256sum "${g}/src/f.bin" | cut -d' ' -f1)")" && bad "fetch_signed accepted a tampered file"
	grep -q "rejected: gpg emitted BADSIG" <<< "${out}" && ok || bad "tampered file: wrong message [${out}]"
	# gpg's exit code counts even when its status lines look good.
	out="$( ( set -Eeuo pipefail; . install-scripts/lib/verify-gpg.sh
		gpg() { printf '[GNUPG:] GOODSIG X\n[GNUPG:] VALIDSIG a b %s\n' "${fprs[0]}"; return 2; }
		verify_detached_sig s d "${fprs[0]}" f.bin ) 2>&1 )" && bad "verify_detached_sig ignored gpg's exit code"
	grep -q "f.bin signature verification FAILED (gpg exit 2" <<< "${out}" && ok || bad "gpg exit: wrong message [${out}]"
	# lock_keyring locks a keyring only while it holds exactly the pinned key.
	GNUPGHOME="${g}/home" gpg --export "${fprs[0]}" > "${g}/one.gpg"
	GNUPGHOME="${g}/home" gpg --export > "${g}/two.gpg"
	lock() { ( set -Eeuo pipefail; . install-scripts/lib/verify-gpg.sh; sudo() { echo "sudo $*"; }; lock_keyring "$1" "${fprs[0]}" ) 2>&1; }
	out="$(lock "${g}/one.gpg")" && grep -qx "sudo chattr +i ${g}/one.gpg" <<< "${out}" && ok \
		|| bad "lock_keyring did not lock a keyring with the pinned key: ${out}"
	out="$(lock "${g}/two.gpg")" && bad "lock_keyring accepted a keyring with a second key"
	grep -q "must hold exactly the pinned key" <<< "${out}" && ! grep -q chattr <<< "${out}" && ok \
		|| bad "a second key must stop lock_keyring before chattr: ${out}"
	gpgconf --homedir "${g}/home" --kill all 2>/dev/null
	rm -rf "${g}"
else
	printf '  skip: gpg not available\n'
fi

echo "== test/lib/pty_run.py leaves no process behind =="
# A process left running after its test could act on this machine after the
# test's sandbox, and the mocks in it, are gone.
gone() { sleep 1; [ -s "${tmp}/pid" ] && ! kill -0 "$(cat "${tmp}/pid")" 2>/dev/null; }
rm -f "${tmp}/pid"
PTY_RUN_IDLE_TIMEOUT=1 python3 test/lib/pty_run.py bash -c "sleep 60 & echo \$! > ${tmp}/pid; wait" >/dev/null
[ "$?" -eq 143 ] && gone && ok || bad "pty_run.py left a process running after its idle timeout"
rm -f "${tmp}/pid"
# The child ignores the hangup of its terminal, as the QR script's trap does.
python3 test/lib/pty_run.py bash -c "trap '' HUP; echo \$\$ > ${tmp}/pid; exec sleep 60" >/dev/null & sleep 1; { kill -9 "$!"; wait "$!"; } 2>/dev/null
gone && ok || bad "pty_run.py left its child running after it was killed"

echo "== addPanelPlugins() adds one launcher per qube, and a VPN monitor, once =="
# A panel with a launcher, an expanding separator, a notification area and a
# clock; menu entries for A-x only. xfconf-query, qvm-features, pgrep and xfce4-panel are fakes.
px="$(mktemp -d)"
export SEQS_FAKE_XFCONF="${px}/xfconf.json"
echo '{"/panels": ["1"], "/panels/panel-1/plugin-ids": ["1", "15", "6", "2"], "/plugins/plugin-1": "launcher",
  "/plugins/plugin-15": "separator", "/plugins/plugin-15/expand": "true", "/plugins/plugin-6": "systray",
  "/plugins/plugin-2": "clock"}' > "${SEQS_FAKE_XFCONF}"
mkdir -p "${px}/data/applications"
for app in signal-desktop xfce4-terminal thunar; do
	printf '[Desktop Entry]\nX-Qubes-VmName=A-x\nX-Qubes-AppName=%s\n' "${app}" \
		> "${px}/data/applications/org.qubes-os.vm._A_dx.${app}.desktop"
done
declare -A FEAT=([A-x seqs-launcher-items]="signal-desktop.desktop xfce4-terminal.desktop thunar.desktop"
	[A-x seqs-vpn-monitor]=1 [A-y seqs-launcher-items]="bad;name.desktop")
qvm-features() { shift; if [ "$#" -eq 3 ]; then FEAT["$1 $2"]="$3"; else [ -n "${FEAT["$1 $2"]:-}" ] && echo "${FEAT["$1 $2"]}"; fi; }
xfconf-query() { python3 test/lib/fake_xfconf.py "$@"; }
pgrep() { echo "$$"; }  # a process whose environment can be read
xfce4-panel() { echo restarted >> "${px}/panel.log"; }
qvm-appmenus() { true; }
xf() { xfconf-query -c xfce4-panel -p "$1" | tr '\n' ' '; }
# Run in this shell (not in $(...)), so the qube features it sets persist.
XDG_DATA_HOME="${px}/data" XDG_CONFIG_HOME="${px}/config" addPanelPlugins A-x A-y A-z > "${px}/out" 2>&1
out="$(cat "${px}/out")"
eq "launcher before the expanding separator, monitor before the notification area" \
	"$(xf /panels/panel-1/plugin-ids)" "Value is an array with 6 items:  1 16 15 17 6 2 "
eq "the monitor runs seqs-vpn-monitor for its qube" "$(xf /plugins/plugin-17/command)" "/usr/local/bin/seqs-vpn-monitor A-x "
eq "the monitor updates every two seconds" "$(xf /plugins/plugin-17/update-period)" "2000 "
eq "the monitor is labelled with its qube" "$(xf /plugins/plugin-17/text)" "A-x "
eq "launcher marked with its qube" "$(xf /plugins/plugin-16/seqs-qube)" "A-x "
eq "main app first, then terminal and file manager" "$(xf /plugins/plugin-16/items)" \
	"Value is an array with 3 items:  seqs-1.desktop seqs-2.desktop seqs-3.desktop "
grep -qx "X-Qubes-AppName=signal-desktop" "${px}/config/xfce4/panel/launcher-16/seqs-1.desktop" && ok \
	|| bad "the launcher's first item must be a copy of the main app's menu entry"
grep -q "A-y: unexpected seqs-launcher-items" <<< "${out}" && ok || bad "an unexpected item list must be refused: ${out}"
[ "$(xfconf-query -c xfce4-panel -l | grep -cE '/seqs-(qube|monitor)$')" -eq 2 ] && ok || bad "only A-x may get panel plugins"
eq "the panel restarts to show it" "$(cat "${px}/panel.log")" "restarted"
XDG_DATA_HOME="${px}/data" XDG_CONFIG_HOME="${px}/config" addPanelPlugins A-x >/dev/null 2>&1
eq "a rerun adds no second launcher or monitor" "$(xf /panels/panel-1/plugin-ids)" "Value is an array with 6 items:  1 16 15 17 6 2 "
# The user removes both from the panel: the next build leaves them removed.
xfconf-query -c xfce4-panel -p /plugins/plugin-16 -r -R
xfconf-query -c xfce4-panel -p /plugins/plugin-17 -r -R
xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids -n -a -t int -s 1 -t int -s 15 -t int -s 6 -t int -s 2
XDG_DATA_HOME="${px}/data" XDG_CONFIG_HOME="${px}/config" addPanelPlugins A-x >/dev/null 2>&1
eq "plugins the user removed are not added again" "$(xf /panels/panel-1/plugin-ids)" "Value is an array with 4 items:  1 15 6 2 "
# A menu entry that does not exist is left out, with a warning.
unset 'FEAT[A-x seqs-launcher-added]'
rm "${px}/data/applications/org.qubes-os.vm._A_dx.signal-desktop.desktop"
out="$(XDG_DATA_HOME="${px}/data" XDG_CONFIG_HOME="${px}/config" addPanelPlugins A-x 2>&1)"
grep -q "A-x has no menu entry signal-desktop.desktop" <<< "${out}" && ok || bad "a missing menu entry must be named: ${out}"
eq "the remaining items stay" "$(xf /plugins/plugin-16/items)" "Value is an array with 2 items:  seqs-1.desktop seqs-2.desktop "
# Without a running panel nothing is touched.
pgrep() { false; }
cp "${SEQS_FAKE_XFCONF}" "${px}/before.json"
out="$(addPanelPlugins A-x 2>&1)"
cmp -s "${SEQS_FAKE_XFCONF}" "${px}/before.json" && grep -q "No XFCE panel" <<< "${out}" && ok \
	|| bad "without a panel, the build must change no panel setting"
unset -f qvm-features xfconf-query pgrep xfce4-panel qvm-appmenus xf
unset FEAT SEQS_FAKE_XFCONF
rm -rf "${px}"

echo "== seqs-vpn-monitor shows only four numbers from the VPN qube =="
# The panel interprets markup in what the monitor prints: anything but four
# numbers from the qube must show n/a. qvm-run is a fake that prints $OUT.
vb="$(mktemp -d)"
printf '#!/bin/sh\necho "$*" >> "%s/args"; printf "%%s" "$OUT"\n' "${vb}" > "${vb}/qvm-run"
chmod +x "${vb}/qvm-run"
mon() { OUT="$1" PATH="${vb}:${PATH}" bash salt/seqs/files/seqs-vpn-monitor "$2"; }
eq "traffic is shown" "$(mon '1073741824 2048 1048576 0' A-gnosisvpn)" " ↑ 2.00KiB (+ 0.00B), ↓ 1.00GiB (+ 1.00MiB)"
eq "markup is refused" "$(mon '<span>1</span> 2 3 4' A-gnosisvpn)" " VPN: n/a"
eq "a fifth number is refused" "$(mon '1 2 3 4 5' A-gnosisvpn)" " VPN: n/a"
eq "no output (tunnel down) shows n/a" "$(mon '' A-gnosisvpn)" " VPN: n/a"
grep -q -- "--no-autostart --pass-io -- A-gnosisvpn seqs-gnosisvpn-rates" "${vb}/args" && ok \
	|| bad "the monitor must not start the qube: $(head -n 1 "${vb}/args")"
: > "${vb}/args"
eq "an unsafe qube name is refused" "$(mon '1 2 3 4' '-x')" " VPN: n/a"
[ ! -s "${vb}/args" ] && ok || bad "an unsafe qube name must not reach qvm-run"

echo "== seqs-gnosisvpn-rates reports totals and the last second's traffic =="
# Against the loopback interface: four numbers, totals first.
R=install-scripts/components/gnosisvpn/seqs-gnosisvpn-rates
before="$(cat /sys/class/net/lo/statistics/rx_bytes)"
out="$(sh "${R}" lo)"
if [[ "${out}" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] && [ "${out%% *}" -ge "${before}" ]; then ok
else bad "the rates of lo must be four numbers, total received first: ${out}"; fi
eq "no tunnel: no output" "$(sh "${R}" seqs-no-such-interface)" ""
rm -rf "${vb}"

echo "== seqs-gnosisvpn-autoconnect starts the worker, then connects to the configured exit =="
# A fake gnosis_vpn-ctl logs its arguments and lists two destinations; the
# script runs with its exit file moved into the test directory.
ab="$(mktemp -d)"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n[ "$1" != destinations ] || printf "Netherlands\\nSouth Korea\\n"\n' "${ab}" > "${ab}/gnosis_vpn-ctl"
chmod +x "${ab}/gnosis_vpn-ctl"
sed "s|/rw/config/seqs-gnosisvpn-exit|${ab}/exit|" install-scripts/components/gnosisvpn/seqs-gnosisvpn-autoconnect > "${ab}/run"
ac() { : > "${ab}/calls"; PATH="${ab}:${PATH}" sh "${ab}/run" 2>&1; }
out="$(ac)"
[ ! -s "${ab}/calls" ] && grep -q "not connecting" <<< "${out}" && ok || bad "without an exit file nothing must be started: ${out}"
printf 'South Korea\nUK\n' > "${ab}/exit"
ac >/dev/null
eq "start, then connect to the first line" "$(grep -v -e info -e destinations "${ab}/calls" | tr '\n' '|')" "start-client 1h|connect South Korea|"
printf 'Nowhere\n' > "${ab}/exit"
out="$(ac)" && bad "an unknown exit must fail"
grep -q "'Nowhere' in ${ab}/exit is not a GnosisVPN destination" <<< "${out}" && ! grep -q start-client "${ab}/calls" && ok \
	|| bad "an unknown exit must be refused before the worker starts: ${out}"
rm -rf "${ab}"

echo
echo "bash unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
