#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Deletes all qubes whose name matches the prefix convention used by
# setup-qubes.sh -- <single-letter>-<arg> -- so we don't have to keep
# PREFIX_APP_VM / PREFIX_TEMPLATE_VM in sync with that script.
#
# Usage: ./delete-vms.sh keepass telegram wallet-ledger ...
# (each arg removes any qube named X-<arg> for any single uppercase letter X)

for app in "$@"; do
	echo "looking for qubes matching */-${app}..."
	found=$(qvm-ls --raw-list 2>/dev/null | grep -E "^[A-Z]-${app}\$" || true)
	if [ -z "${found}" ]; then
		echo "  no qubes match"
		continue
	fi
	echo "found:"; echo "${found}" | sed 's/^/  /'

	echo "killing..."
	while IFS= read -r vm; do qvm-kill "${vm}" 2>/dev/null || true; done <<< "${found}"
	echo "waiting for qubes to shut down..."
	sleep 3
	echo "removing..."
	while IFS= read -r vm; do qvm-remove "${vm}" -f; done <<< "${found}"
done
