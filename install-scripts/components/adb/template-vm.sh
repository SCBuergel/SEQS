#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Installs the Android Debug Bridge (adb) and pv into the template. Both are
# Debian-signed packages -- this replaces the previous flow that downloaded an
# unsigned platform-tools zip from dl.google.com and installed adb into sys-usb
# itself (see TRUST.md, "ADB file transfer").
#
# The chunked, resumable adb-pull helper is shipped alongside this script as
# a per-component asset (adb-pull.sh) by setup-qubes.sh's fetchRunClean, and
# installed system-wide to /usr/bin/adb-pull so it's visible in every app qube
# based on this template.

echo "Installing adb and pv (Debian apt)..."
sudo apt-get update
sudo apt-get install -y adb pv

# fetchRunClean drops every file from the component dir alongside this script
# in /home/user/QubesIncoming/dom0/. Pick up adb-pull.sh from there.
ASSET_DIR="$(dirname "$0")"
if [ ! -f "${ASSET_DIR}/adb-pull.sh" ]; then
	echo "ERROR: adb-pull.sh not found next to template-vm.sh (expected at ${ASSET_DIR}/adb-pull.sh)" >&2
	exit 1
fi

echo "Installing /usr/bin/adb-pull..."
sudo install -m 0755 "${ASSET_DIR}/adb-pull.sh" /usr/bin/adb-pull
