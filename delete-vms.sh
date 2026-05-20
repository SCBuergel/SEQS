#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Deletes qubes matching the SEQS prefix convention used by setup-qubes.sh:
# for each <name>, removes any qube called A-<name> (app qube) or Z-<name>
# (template qube). Names are matched as literal strings, not regex.
#
# Usage:
#   ./delete-vms.sh [--dry-run] [--yes] <name> [<name> ...]
#
# Options:
#   --dry-run     print what would be killed/removed and exit 0
#   --yes, -y     skip the interactive "type DELETE" confirmation prompt
#   -h, --help    show this message

# Prefixes to check for each <name>. Keep in sync with PREFIX_APP_VM /
# PREFIX_TEMPLATE_VM in setup-qubes.sh.
PREFIXES=(A Z)

# How long to wait, in seconds, for a killed qube to actually leave the
# "running" state before we give up and try qvm-remove anyway.
SHUTDOWN_TIMEOUT=30

DRY_RUN=0
ASSUME_YES=0

usage() {
	cat <<EOF
Usage: $0 [--dry-run] [--yes] <name> [<name> ...]

Deletes qubes matching the SEQS prefix convention: for each <name>, removes
any qube called A-<name> or Z-<name>.

Options:
  --dry-run    print what would be killed/removed and exit 0
  --yes, -y    skip the interactive confirmation prompt
  -h, --help   show this message
EOF
}

# Parse options. Allowed before, between, or after positional names.
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--yes|-y)  ASSUME_YES=1 ;;
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

# waitForShutdown VM [VM ...] -- poll qvm-check --running until none of the
# named qubes are running, or SHUTDOWN_TIMEOUT elapses. Replaces the previous
# fixed 'sleep 3' which was a guess and unreliable under load.
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

for app in "${ARGS[@]}"; do
	# Reject anything that isn't a safe identifier. $app is interpolated into
	# qube names and passed straight to qvm-remove -f, so a value like '.*'
	# must never reach the match loop below.
	if ! [[ "${app}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo "ERROR: refusing unsafe name '${app}' (allowed: [A-Za-z0-9._-])" >&2
		exit 1
	fi

	# Build the kill list by literal name + existence check -- no regex.
	# Explicit per-prefix loop makes the prefix set (A-, Z-) clear, instead of
	# the previous '^[A-Z]-...' which would have also matched B-, C-, ...
	echo "looking for qubes matching ${PREFIXES[*]/%/-${app}}..."
	found=()
	for prefix in "${PREFIXES[@]}"; do
		candidate="${prefix}-${app}"
		if qvm-check "${candidate}" &>/dev/null; then
			found+=("${candidate}")
		fi
	done

	if [ "${#found[@]}" -eq 0 ]; then
		echo "  no qubes match"
		continue
	fi

	echo "found:"
	printf '  %s\n' "${found[@]}"

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "  (dry-run: not killing or removing)"
		continue
	fi

	# Explicit confirmation -- accidentally typing 'y' on a footgun-prone
	# command shouldn't be enough. --yes bypasses for scripted use.
	if [ "${ASSUME_YES}" -eq 0 ]; then
		read -rp "Delete the ${#found[@]} qube(s) above? type DELETE to confirm: " confirm
		if [ "${confirm}" != "DELETE" ]; then
			echo "  aborted"
			continue
		fi
	fi

	# Surface kill errors instead of silently swallowing them with 2>/dev/null
	# (the previous behavior could let qvm-remove run against a still-running
	# qube without the user ever seeing why the shutdown didn't take).
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
done
