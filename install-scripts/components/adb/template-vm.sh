#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Install Debian-signed adb and pv plus the bundled resumable adb-pull helper.

echo "Installing adb and pv (Debian apt)..."
sudo apt-get update
sudo apt-get install -y adb pv

# Salt stages component assets alongside this script.
ASSET_DIR="$(dirname "$0")"
if [ ! -f "${ASSET_DIR}/adb-pull.sh" ]; then
	echo "ERROR: adb-pull.sh not found next to template-vm.sh (expected at ${ASSET_DIR}/adb-pull.sh)" >&2
	exit 1
fi

echo "Installing /usr/bin/adb-pull..."
sudo install -m 0755 "${ASSET_DIR}/adb-pull.sh" /usr/bin/adb-pull
