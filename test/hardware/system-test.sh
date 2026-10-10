#!/usr/bin/env bash

# SEQS hardware system test driver. Runs on the computer that controls the
# test machine (see test/hardware/README.md) and installs SEQS there from
# scratch:
#
#   sync     push the commit under test to test-ctl, the runner's repo qube
#   reset    delete all SEQS qubes and dom0 state (dom0-test.sh reset)
#   install  run setup-qubes.sh for the selection (dom0-test.sh install)
#   check    verify what was built (dom0-test.sh check)
#   lifecycle restart qubes: cleanup on boot/shutdown, persistent state
#   rerun    install and check again: a second run must converge quickly
#
# Usage: test/hardware/system-test.sh [--qubes LIST | --all] [--no-rerun]
#                                     [--force-rerun] [--host HOST]
#
# --force-rerun empties every completion marker before the rerun, so it runs
# every component script a second time instead of skipping finished ones.
#
# The commit under test is the working tree's tracked content, including
# uncommitted changes. Results go to test/hardware/results/<time>/, with
# summary.txt listing phase results, durations, findings, and product size.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

HOST="seqs-test"
SELECTION="keepass,qr-display,brave"
RERUN=1
FORCE_RERUN=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--qubes) [ "$#" -gt 1 ] || { echo "--qubes needs a list" >&2; exit 2; }; SELECTION="$2"; shift ;;
		--all) SELECTION="all" ;;
		--no-rerun) RERUN=0 ;;
		--force-rerun) FORCE_RERUN=1 ;;
		--host) [ "$#" -gt 1 ] || { echo "--host needs a name" >&2; exit 2; }; HOST="$2"; shift ;;
		-h|--help) sed -n '3,22p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done
[[ "${SELECTION}" =~ ^(all|[a-z0-9][a-z0-9.-]*(,[a-z0-9][a-z0-9.-]*)*)$ ]] \
	|| { echo "invalid selection: ${SELECTION}" >&2; exit 2; }

CTL_VM="test-ctl"
REMOTE_REPO="/home/user/SEQS"
SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "${HOST}")
RESULTS="test/hardware/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${RESULTS}"
ln -sfn "${RESULTS##*/}" test/hardware/results/latest

# `git stash create` records the working tree as a commit without changing
# anything; with no local changes it prints nothing and HEAD is tested.
REV="$(git stash create)"
REV="${REV:-$(git rev-parse HEAD)}"
UNTRACKED="$(git ls-files --others --exclude-standard -- salt install-scripts setup-qubes.sh delete-vms.sh test/hardware test/lib)"

PHASES=()
FAILED_PHASES=()
OVERALL=0

# phase NAME COMMAND... -- run one phase, log it, record status and duration.
phase() {
	local name="$1" start rc log="${RESULTS}/$1.log"
	shift
	printf '\n### %s\n' "${name}"
	start="${SECONDS}"
	"$@" 2>&1 | tee "${log}"
	rc="${PIPESTATUS[0]}"
	PHASES+=("$(printf '%-9s %-4s %6ss' "${name}" "$([ "${rc}" -eq 0 ] && echo ok || echo FAIL)" "$((SECONDS - start))")")
	[ "${rc}" -eq 0 ] || { OVERALL=1; FAILED_PHASES+=("${name}"); }
	return "${rc}"
}

sync() {
	echo "Testing ${REV}${UNTRACKED:+ (untracked files are NOT included)}"
	"${SSH[@]}" "command -v git >/dev/null || sudo apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false install -y -q git" \
		|| return 1
	"${SSH[@]}" "git init -q ${REMOTE_REPO}" || return 1
	GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
		git push -q --force "ssh://${HOST}${REMOTE_REPO}" "${REV}:refs/heads/seqs-test" || return 1
	"${SSH[@]}" "git -C ${REMOTE_REPO} checkout -q --force --detach ${REV}"
}

# dom0 ARGS... -- copy the tools of the commit under test into dom0 and run
# dom0-test.sh there. The tools come from test-ctl's checkout, as the runner's
# own fetch does. The exit status travels back as a marker line, because it
# passes through SSH and qrexec.
dom0() {
	local out rc
	out="$(mktemp)"
	"${SSH[@]}" dom0 <<EOF | tee "${out}"
d="\$(getent passwd "\$(id -un)" | cut -d: -f6)/seqs-test"
mkdir -p "\$d"
for f in setup-qubes.sh delete-vms.sh test/lib/pty_run.py test/hardware/dom0-test.sh; do
	qvm-run --pass-io --no-gui ${CTL_VM} "git -C ${REMOTE_REPO} show HEAD:\$f" > "\$d/\${f##*/}" 2>/dev/null </dev/null \
		|| { echo "cannot copy \$f from ${CTL_VM}"; echo SEQS-PHASE-RC=1; exit 1; }
done
bash "\$d/dom0-test.sh" $* </dev/null
echo "SEQS-PHASE-RC=\$?"
EOF
	rc="$(sed -n 's/^SEQS-PHASE-RC=\([0-9]*\)$/\1/p' "${out}" | tail -n 1)"
	rm -f "${out}"
	return "${rc:-1}"
}

prompts() {
	local n
	n="$(grep -c '\[y/N\]' "${RESULTS}/$1.log" 2>/dev/null)"
	echo "${n:-0}"
}

summary() {
	local f lines
	{
		echo "SEQS hardware system test"
		echo "commit     ${REV}"
		echo "selection  ${SELECTION}"
		echo "host       ${HOST}"
		echo
		echo "phase     result  time"
		printf '%s\n' "${PHASES[@]}"
		echo
		echo "Runner steps (install):"
		grep -hE '^[0-9:]{8} ==> ' "${RESULTS}/install.log" 2>/dev/null | cut -c1-100
		echo
		echo "Prompts answered: install $(prompts install), rerun $(prompts rerun-install)"
		echo
		for f in "${FAILED_PHASES[@]}"; do
			echo "End of the failed ${f} log:"
			tail -n 5 "${RESULTS}/${f}.log" | sed 's/^/    /'
		done
		echo
		echo "Findings (errors, warnings, failed checks):"
		for f in "${RESULTS}"/*.log; do
			lines="$(grep -E 'ERROR|WARNING|CHECK-FAIL|Result:[[:space:]]*False|Failed:[[:space:]]*[1-9]|Traceback' "${f}" | sort -u | head -n 40)"
			[ -z "${lines}" ] || printf -- '-- %s\n%s\n' "${f##*/}" "${lines}"
		done
		echo
		echo "Product size (lines, for auditability):"
		git ls-tree -r --name-only "${REV}" -- setup-qubes.sh delete-vms.sh salt install-scripts \
			| while IFS= read -r f; do git show "${REV}:${f}"; done | wc -l
	} > "${RESULTS}/summary.txt"
	printf '\n'
	cat "${RESULTS}/summary.txt"
	echo "Logs: ${RESULTS}/"
}

# Bash reads a script while running it; keeping the run in a function makes
# it parse the whole file first, so editing it during a run is harmless.
main() {
	if phase sync sync && phase reset dom0 reset; then
		phase install dom0 install "${SELECTION}"
		phase check dom0 check
		phase lifecycle dom0 lifecycle
		if [ "${RERUN}" -eq 1 ]; then
			[ "${FORCE_RERUN}" -eq 0 ] || phase invalidate dom0 invalidate
			phase rerun-install dom0 install "${SELECTION}"
			phase rerun-check dom0 check
		fi
	fi
	summary
	exit "${OVERALL}"
}

main
