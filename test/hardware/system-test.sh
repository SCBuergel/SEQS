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
#   update   with --update: update the templates as a user would, check again
#   reboot   with --reboot: reboot the test machine, wait until it is back,
#            check again: what SEQS set up must survive a restart. Only for a
#            test machine that boots unattended: a disk passphrase prompt at
#            boot keeps it offline until someone types it
#
# Usage: test/hardware/system-test.sh [--quick | --qubes LIST | --all]
#                                     [--no-rerun] [--force-rerun] [--update]
#                                     [--reboot] [--host HOST]
#
# --quick builds a small set that covers each kind of qube (offline, link
# handoff, browser, disposable template with a named disposable) without the
# rerun: the check after each change. Use --all, with the rerun, for
# milestones; add --force-rerun when installers changed, so every component
# script runs a second time instead of skipping finished ones.
#
# Progress goes to test/hardware/results/<time>/progress.log, one line per
# phase start and end, with an ETA taken from the last run of the same
# selection and options.
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
UPDATE=0
REBOOT=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--qubes) [ "$#" -gt 1 ] || { echo "--qubes needs a list" >&2; exit 2; }; SELECTION="$2"; shift ;;
		--all) SELECTION="all" ;;
		--quick) SELECTION="keepass,signal,brave,qr-display"; RERUN=0 ;;
		--no-rerun) RERUN=0 ;;
		--force-rerun) FORCE_RERUN=1 ;;
		--update) UPDATE=1 ;;
		--reboot) REBOOT=1 ;;
		--host) [ "$#" -gt 1 ] || { echo "--host needs a name" >&2; exit 2; }; HOST="$2"; shift ;;
		-h|--help) sed -n '3,35p' "$0"; exit 0 ;;
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
# anything; with no local changes it prints nothing and HEAD is tested. If it
# fails (an intent-to-add file does that), stop rather than test HEAD.
REV="$(git stash create)" || { echo "git stash create failed; refusing to test HEAD instead" >&2; exit 2; }
REV="${REV:-$(git rev-parse HEAD)}"
UNTRACKED="$(git ls-files --others --exclude-standard -- salt install-scripts setup-qubes.sh delete-vms.sh test/hardware test/lib)"

PHASES=()
FAILED_PHASES=()
OVERALL=0

# The phases this run will go through, and how long each took in the last
# finished run with the same selection and options, for the ETA.
PLAN=(sync reset install check lifecycle)
[ "${RERUN}" -eq 0 ] || { [ "${FORCE_RERUN}" -eq 0 ] || PLAN+=(invalidate); PLAN+=(rerun-install rerun-check); }
[ "${UPDATE}" -eq 0 ] || PLAN+=(update update-check)
[ "${REBOOT}" -eq 0 ] || PLAN+=(reboot reboot-check)
OPTIONS="selection ${SELECTION} rerun ${RERUN} force ${FORCE_RERUN} update ${UPDATE} reboot ${REBOOT}"
declare -A EXPECT=()
previous="$(grep -lxF "options    ${OPTIONS}" test/hardware/results/*/summary.txt 2>/dev/null | sort | tail -n 1)"
if [ -n "${previous}" ]; then
	while read -r name result secs; do
		EXPECT["${name}"]="${secs%s}"
	done < <(awk '/^phase / { p = 1; next } p && NF == 3 { print } p && NF != 3 { exit }' "${previous}")
fi

# progress TEXT -- one time-stamped line in progress.log and on the terminal.
progress() {
	printf '%s %s\n' "$(date +%H:%M)" "$*" | tee -a "${RESULTS}/progress.log"
}

# eta PHASE -- clock time this run should end if PHASE starts now, or nothing.
eta() {
	local p left=0 seen=0
	for p in "${PLAN[@]}"; do
		[ "${p}" = "$1" ] && seen=1
		[ "${seen}" -eq 1 ] || continue
		[ -n "${EXPECT[${p}]:-}" ] || return 0
		left=$((left + EXPECT[${p}]))
	done
	date -d "+${left} seconds" +%H:%M
}

# phase NAME COMMAND... -- run one phase, log it, record status and duration.
phase() {
	local name="$1" start rc log="${RESULTS}/$1.log"
	shift
	printf '\n### %s\n' "${name}"
	progress "start ${name}${EXPECT[${name}]:+ (last time ${EXPECT[${name}]}s)}$(e="$(eta "${name}")"; [ -z "${e}" ] || echo "; run ends about ${e}")"
	start="${SECONDS}"
	"$@" 2>&1 | tee "${log}"
	rc="${PIPESTATUS[0]}"
	progress "$([ "${rc}" -eq 0 ] && echo done || echo FAILED) ${name} in $((SECONDS - start))s"
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
	# On disk next to the logs: a phase can print hundreds of MB, and the marker
	# must not depend on room in a RAM-backed /tmp.
	out="$(mktemp -p "${RESULTS}")"
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

# rebootMachine -- reboot the test machine and wait up to 15 minutes until
# dom0 answers through test-ctl again (test-ctl and sys-net start at boot).
rebootMachine() {
	local deadline
	"${SSH[@]}" dom0 <<<'sudo systemctl reboot' >/dev/null 2>&1 &
	sleep 60
	deadline=$((SECONDS + 900))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if ssh -o BatchMode=yes -o ConnectTimeout=5 "${HOST}" dom0 <<<'qvm-ls --raw-list | wc -l' 2>/dev/null | grep -q '^[0-9]'; then
			echo "test machine is back after $((SECONDS - deadline + 960))s"
			return 0
		fi
		sleep 20
	done
	echo "test machine did not come back within 16 minutes" >&2
	return 1
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
		echo "options    ${OPTIONS}"
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
		if [ "${UPDATE}" -eq 1 ]; then
			phase update dom0 update
			phase update-check dom0 check
		fi
		if [ "${REBOOT}" -eq 1 ] && phase reboot rebootMachine; then
			phase reboot-check dom0 check
		fi
	fi
	summary
	progress "finished: $([ "${OVERALL}" -eq 0 ] && echo all phases ok || echo "FAILED ${FAILED_PHASES[*]}")"
	exit "${OVERALL}"
}

main
