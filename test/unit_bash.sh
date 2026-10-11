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

echo "== runQubesctl() fails on a failed state even when qubesctl exits 0 =="
printf '#!/bin/sh\nexec "$@"\n' > "${stub}/sudo"
printf '#!/bin/sh\nprintf "%%b\\n" "$QOUT"\n' > "${stub}/qubesctl"
chmod +x "${stub}/sudo" "${stub}/qubesctl"
qctl() { ( export PATH="${stub}:${PATH}" QOUT="$1"; runQubesctl state.apply ) >/dev/null 2>&1; }
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
	# A file signed by another key names the cause.
	GNUPGHOME="${g}/home" gpg --batch --yes --quiet --local-user "${fprs[1]}" --armor --detach-sign -o "${g}/src/f.bin.asc" "${g}/src/f.bin"
	out="$(fetch "${sha}")" && bad "fetch_signed accepted a signature by another key"
	grep -qE "rejected: gpg emitted (ERRSIG|NO_PUBKEY)" <<< "${out}" && ok || bad "other key: wrong message [${out}]"
	echo tampered > "${g}/src/f.bin"
	GNUPGHOME="${g}/home" gpg --batch --yes --quiet --local-user "${fprs[0]}" --armor --detach-sign -o "${g}/src/f.bin.asc" "${g}/src/f.bin"
	echo tampered again > "${g}/src/f.bin"
	out="$(fetch "${sha}")" && bad "fetch_signed accepted a tampered file"
	grep -q "rejected: gpg emitted BADSIG" <<< "${out}" && ok || bad "tampered file: wrong message [${out}]"
	# gpg's exit code counts even when its status lines look good.
	out="$( ( set -Eeuo pipefail; . install-scripts/lib/verify-gpg.sh
		gpg() { printf '[GNUPG:] GOODSIG X\n[GNUPG:] VALIDSIG a b %s\n' "${fprs[0]}"; return 2; }
		verify_detached_sig s d "${fprs[0]}" f.bin ) 2>&1 )" && bad "verify_detached_sig ignored gpg's exit code"
	grep -q "f.bin signature verification FAILED (gpg exit 2" <<< "${out}" && ok || bad "gpg exit: wrong message [${out}]"
	gpgconf --homedir "${g}/home" --kill all 2>/dev/null
	rm -rf "${g}"
else
	printf '  skip: gpg not available\n'
fi

echo
echo "bash unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
