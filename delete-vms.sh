#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Removes matching D-/A-/Z- qubes and their exact SEQS-managed browser deny;
# run with --help and use --dry-run first.

# Prefixes to check for each configured base name. Ordered by dependency so
# removal succeeds: the named disposable (D-) before the dispvm template/app
# qube (A-) it derives from, and A- before the template (Z-) it is based on.
PREFIXES=(D A Z)

# How long to wait, in seconds, for a killed qube to actually leave the
# "running" state before we give up and try qvm-remove anyway.
SHUTDOWN_TIMEOUT=30

DRY_RUN=0

# The override is for the test harness. A normal dom0 run uses the real policy.
BROWSER_SUPPRESS_POLICY="${SEQS_BROWSER_SUPPRESS_POLICY:-/etc/qubes/policy.d/28-browser-suppress.policy}"

usage() {
	cat <<EOF
Usage: $0 [--dry-run] <name> [<name> ...]

Deletes qubes matching the SEQS prefix convention: for each <name>, removes
any qube called D-<name>, A-<name>, or Z-<name>. After A-<name> is absent, also
removes its exact deny from the SEQS-managed browser-suppression policy.
Unmarked policy files are never changed.

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

# browserRuleExists VM -- match only the strict rule shape SEQS generates.
browserRuleExists() {
	local vm="$1"
	sudo awk -v vm="${vm}" '
		NF == 5 && $1 == "qubes.OpenURL" && $2 == "*" &&
		$3 == vm && $4 == "@anyvm" && $5 == "deny" { found=1 }
		END { exit !found }
	' "${BROWSER_SUPPRESS_POLICY}"
}

# removeBrowserSuppression BASE_NAME -- remove one exact stale deny after the
# corresponding A-* qube is gone. Never modify a policy we cannot identify as
# SEQS-managed. The same-directory temporary makes replacement atomic.
removeBrowserSuppression() {
	local vm="A-${1}" tmp

	sudo test -e "${BROWSER_SUPPRESS_POLICY}" || return 0
	browserRuleExists "${vm}" || return 0

	if ! sudo grep -q 'Managed by SEQS' "${BROWSER_SUPPRESS_POLICY}"; then
		echo "WARNING: stale browser deny for ${vm} remains in unmarked policy ${BROWSER_SUPPRESS_POLICY}; review it manually." >&2
		return 0
	fi

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "  (dry-run: would remove stale browser deny for ${vm} from ${BROWSER_SUPPRESS_POLICY})"
		return 0
	fi

	tmp="$(sudo mktemp "${BROWSER_SUPPRESS_POLICY}.tmp.XXXXXX")" \
		|| { echo "ERROR: could not create policy temporary" >&2; return 1; }
	if ! sudo awk -v vm="${vm}" '
		!(NF == 5 && $1 == "qubes.OpenURL" && $2 == "*" &&
		  $3 == vm && $4 == "@anyvm" && $5 == "deny")
	' "${BROWSER_SUPPRESS_POLICY}" | sudo tee "${tmp}" >/dev/null; then
		sudo rm -f -- "${tmp}"
		echo "ERROR: could not rewrite ${BROWSER_SUPPRESS_POLICY}" >&2
		return 1
	fi

	# Preserve the managed file's metadata, including its security context when
	# supported, before the atomic replacement.
	sudo chown --reference="${BROWSER_SUPPRESS_POLICY}" "${tmp}"
	sudo chmod --reference="${BROWSER_SUPPRESS_POLICY}" "${tmp}"
	sudo chcon --reference="${BROWSER_SUPPRESS_POLICY}" "${tmp}" 2>/dev/null || true
	sudo mv -f -- "${tmp}" "${BROWSER_SUPPRESS_POLICY}"
	echo "removed stale browser deny for ${vm} from ${BROWSER_SUPPRESS_POLICY}"
}

for app in "${ARGS[@]}"; do
	# Reject anything that isn't a safe identifier. $app is interpolated into
	# qube names and passed straight to qvm-remove -f, so a value like '.*'
	# or '-h' must never reach the match loop below. First char must be
	# alphanumeric or underscore so '.', '..', and leading '-' are rejected.
	if ! [[ "${app}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
		echo "ERROR: refusing unsafe name '${app}' (allowed: [A-Za-z0-9_][A-Za-z0-9._-]*)" >&2
		exit 1
	fi

	# Build the kill list by literal name + existence check -- no regex.
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
		removeBrowserSuppression "${app}"
		continue
	fi

	echo "found:"
	printf '  %s\n' "${found[@]}"

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "  (dry-run: not killing or removing)"
		removeBrowserSuppression "${app}"
		continue
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

	# Policy cleanup is deliberately last: never remove protection while the
	# corresponding app qube still exists because deletion failed.
	if ! qvm-check "A-${app}" &>/dev/null; then
		removeBrowserSuppression "${app}"
	fi
done
