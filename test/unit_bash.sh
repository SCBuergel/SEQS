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
template Z-brave
template Z-keepass
app A-brave
app A-keepass offline
EOF
if readTargets 2>/dev/null; then
	eq "templates count" "${#TEMPLATE_TARGETS[@]}" "2"
	eq "apps count" "${#APP_TARGETS[@]}" "2"
	eq "offline count" "${#OFFLINE_TARGETS[@]}" "1"
	eq "offline is keepass" "${OFFLINE_TARGETS[0]}" "A-keepass"
else bad "readTargets failed on a valid file"; fi
# Unsafe qube name must abort.
printf 'template Z-brave\napp A-brave; rm -rf /\n' > "${TARGETS_FILE}"
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

echo
echo "bash unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
