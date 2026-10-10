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

echo "== joinCsv() =="
eq "joinCsv" "$(joinCsv a b c)" "a,b,c"
eq "joinCsv one" "$(joinCsv solo)" "solo"

echo "== tar-entry validation accepts the real repo tree, rejects hostile entries =="
# Build the exact archive setup-qubes.sh fetches, then run the SAME validation
# loop the script uses (extracted here to keep it in lockstep -- if the script
# changes the regex, update this string).
validate_tar() {  # reads `tar -tvf`-style lines on stdin, returns 1 on reject
	local perms f_owner f_size f_date f_time path extra
	while read -r perms f_owner f_size f_date f_time path extra; do
		[ -n "${extra}" ] && return 1
		case "${perms:0:1}" in d|-) ;; *) return 1 ;; esac
		[[ "${path}" == *..* ]] && return 1
		[[ "${path}" =~ ^(salt|install-scripts)(/[A-Za-z0-9._-]+)*/?$ ]] || return 1
	done
	return 0
}
# Real tree must pass.
if tar -cf - salt install-scripts | tar -tvf - | validate_tar; then ok
else bad "validation rejected the real repo tree"; fi
# Hostile entries must each be rejected.
reject() { if printf '%s\n' "$1" | validate_tar; then bad "accepted hostile: $1"; else ok; fi; }
reject 'lrwxrwxrwx user 0 2020-01-01 00:00 salt/evil'              # symlink type
reject '-rw-r--r-- user 0 2020-01-01 00:00 salt/../etc/passwd'     # .. traversal
reject '-rw-r--r-- user 0 2020-01-01 00:00 /etc/passwd'           # absolute path
reject '-rw-r--r-- user 0 2020-01-01 00:00 salt/a b'              # whitespace in name
reject '-rw-r--r-- user 0 2020-01-01 00:00 other/thing'          # outside allowed roots

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
if readTargets 2>/dev/null; then
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
printf 'template Z-brave brave\napp A-brave; rm -rf / brave\n' > "${TARGETS_FILE}"
if ( readTargets ) 2>/dev/null; then bad "readTargets accepted an unsafe name"; else ok; fi

echo "== verifyAirgap() only passes when offline qubes truly have no netvm =="
# Stub qvm-prefs on PATH so verifyAirgap can be exercised without Qubes.
stub="${tmp}/bin"; mkdir -p "${stub}"
cat > "${stub}/qvm-prefs" <<'EOF'
#!/usr/bin/env bash
# args: -- <vm> netvm  ; echo the netvm recorded in $NETVM_<vm>
vm=""; for a in "$@"; do case "$a" in --) ;; netvm) ;; *) vm="$a";; esac; done
eval "printf '%s' \"\${NETVM_${vm//-/_}:-}\""
EOF
chmod +x "${stub}/qvm-prefs"
export PATH="${stub}:${PATH}"
OFFLINE_TARGETS=(A-keepass)
if ( verifyAirgap ) >/dev/null 2>&1; then ok; else bad "verifyAirgap failed a truly-offline qube"; fi
export NETVM_A_keepass="sys-firewall"
if ( verifyAirgap ) >/dev/null 2>&1; then bad "verifyAirgap passed a qube that still has a netvm"; else ok; fi
unset NETVM_A_keepass

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
) > "${tmp}/testmachine.out" 2>&1
if grep -q FAIL "${tmp}/testmachine.out"; then
	while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep FAIL "${tmp}/testmachine.out")
else ok; fi

echo "== component scripts that lock a file unlock it first, so they can run twice =="
# A component runs again whenever its files change (hash markers). A file it
# locked with chattr +i on the first run must be unlocked before it is
# rewritten, or the rerun fails.
for f in install-scripts/components/*/*.sh install-scripts/lib/*.sh; do
	while IFS= read -r target; do
		lock_line="$(grep -nE "^[[:space:]]*sudo chattr \+i \"?${target}" "$f" | head -n 1 | cut -d: -f1)"
		unlock_line="$(grep -nE "^[[:space:]]*sudo chattr -i \"?${target}" "$f" | head -n 1 | cut -d: -f1)"
		if [ -n "${unlock_line}" ] && [ "${unlock_line}" -lt "${lock_line}" ]; then ok
		else bad "$f locks ${target} without unlocking it earlier"; fi
	done < <(grep -oE '^[[:space:]]*sudo chattr \+i "?[^" ]+' "$f" | sed -E 's/.*chattr \+i "?//; s/[$]/\\$/g; s/[{}]/\\&/g')
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
) > "${tmp}/dom0test.out" 2>&1
if grep -q FAIL "${tmp}/dom0test.out"; then
	while IFS= read -r line; do bad "${line#FAIL }"; done < <(grep FAIL "${tmp}/dom0test.out")
else ok; fi

echo
echo "bash unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
