#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Removes matching D-/A-/Z- qubes; run with --help and use --dry-run first.

# Prefixes to check for each configured base name. Ordered by dependency so
# removal succeeds: the named disposable (D-) before the dispvm template/app
# qube (A-) it derives from, and A- before the template (Z-) it is based on.
PREFIXES=(D A Z)

# How long to wait, in seconds, for a killed qube to actually leave the
# "running" state before we give up and try qvm-remove anyway.
SHUTDOWN_TIMEOUT=30

DRY_RUN=0

usage() {
	cat <<EOF
Usage: $0 [--dry-run] <name> [<name> ...]

Deletes qubes matching the SEQS prefix convention: for each <name>, removes
any qube called D-<name>, A-<name>, or Z-<name> that SEQS built (it carries
the seqs-managed feature); same-named qubes without it are skipped. Qubes
using a match as their NetVM are preserved but disconnected (netvm set to
none). If another qube uses a match as its template or default disposable, or
a match is a global default, nothing is changed.

Options:
  --dry-run    print what would be killed/removed and exit 0
  -h, --help   show this message
EOF
}

# Parse options. Allowed before, between, or after positional names.
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; ARGS+=("$@"); break ;;
		-*)        echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 1 ;;
		*)         ARGS+=("$1") ;;
	esac
	shift
done

if [ "${#ARGS[@]}" -eq 0 ]; then
	usage >&2
	exit 1
fi

# waitForShutdown VM [VM ...] -- poll until shutdown or SHUTDOWN_TIMEOUT.
waitForShutdown() {
	local deadline=$(( SECONDS + SHUTDOWN_TIMEOUT ))
	local vm still_running
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		still_running=()
		for vm in "$@"; do
			if qvm-check --running "${vm}" &>/dev/null; then
				still_running+=("${vm}")
			fi
		done
		if [ "${#still_running[@]}" -eq 0 ]; then
			return 0
		fi
		sleep 1
	done
	echo "WARNING: still running after ${SHUTDOWN_TIMEOUT}s: ${still_running[*]}" >&2
	return 1
}

# findUsers TARGET [TARGET ...] -- print "consumer property target" for each
# reference that stops Qubes from removing a target: any qube's netvm, a
# non-target's template or default_dispvm, and a global default (consumer
# dom0). netvm users are disconnected; the others block the deletion.
findUsers() {
	qvm-ls --raw-data --fields name,netvm,template,default_dispvm | awk -F'|' -v t=" $* " '
		{
			split("netvm template default_dispvm", prop, " ")
			for (i = 2; i <= 4; i++)
				if ($i != "-" && $i != "" && $i != $1 && index(t, " " $i " ") \
						&& (i == 2 || !index(t, " " $1 " ")))
					print $1, prop[i - 1], $i
		}'
	qubes-prefs | awk -v t=" $* " 'index(t, " " $3 " ") { print "dom0", $1, $3 }'
}

# Check every name before changing anything, so that a refusal for one name
# leaves the others untouched too.
found=()
for app in "${ARGS[@]}"; do
	# Reject anything that isn't a safe identifier. $app is interpolated into
	# qube names and passed straight to qvm-remove -f, so a value like '.*'
	# or '-h' must never reach the match loop below. First char must be
	# alphanumeric or underscore so '.', '..', and leading '-' are rejected.
	if ! [[ "${app}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
		echo "ERROR: refusing unsafe name '${app}' (allowed: [A-Za-z0-9_][A-Za-z0-9._-]*)" >&2
		exit 1
	fi

	# Build the kill list by literal name + existence check -- no regex. A
	# same-named qube that SEQS did not build (no seqs-managed feature) is
	# never touched.
	echo "looking for qubes matching ${PREFIXES[*]/%/-${app}}..."
	for prefix in "${PREFIXES[@]}"; do
		candidate="${prefix}-${app}"
		qvm-check "${candidate}" &>/dev/null || continue
		if [ "$(qvm-features -- "${candidate}" seqs-managed 2>/dev/null)" = "1" ]; then
			found+=("${candidate}")
		else
			echo "  skipping ${candidate}: SEQS did not build it (no seqs-managed feature)"
		fi
	done
done

if [ "${#found[@]}" -eq 0 ]; then
	echo "  no qubes match"
	exit 0
fi
echo "found:"
printf '  %s\n' "${found[@]}"

netvm_users=()
blockers=()
users="$(findUsers "${found[@]}")"
while read -r consumer prop provider; do
	case "${prop:-}" in
		'') ;;
		netvm) netvm_users+=("${consumer} ${provider}") ;;
		*) blockers+=("${consumer} has ${prop} ${provider}") ;;
	esac
done <<< "${users}"
if [ "${#blockers[@]}" -gt 0 ]; then
	echo "ERROR: nothing was changed; these use a target, so remove them or change the property first:" >&2
	printf '  %s\n' "${blockers[@]}" >&2
	exit 1
fi
if [ "${#netvm_users[@]}" -gt 0 ]; then
	echo "qubes using a target as netvm:"
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		echo "  ${consumer} -> ${provider}"
	done
fi

if [ "${DRY_RUN}" -eq 1 ]; then
	echo "  (dry-run: not killing or removing)"
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		echo "  (dry-run: would set ${consumer} netvm to none)"
	done
	exit 0
fi

# qvm-remove refuses to remove a NetVM in use. Preserve the consumers, but
# disconnect them explicitly.
if [ "${#netvm_users[@]}" -gt 0 ]; then
	echo "disconnecting netvm users..."
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		qvm-prefs -- "${consumer}" netvm none
	done
fi

# Surface kill errors before attempting removal.
echo "killing..."
for vm in "${found[@]}"; do
	qvm-kill "${vm}" || echo "  qvm-kill ${vm} failed (continuing)" >&2
done

echo "waiting for qubes to shut down..."
waitForShutdown "${found[@]}" || true

echo "removing..."
for vm in "${found[@]}"; do
	qvm-remove "${vm}" -f
done
