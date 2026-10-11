#!/usr/bin/env bash
set -Eeuo pipefail

# Install Debian-signed adb and pv plus the bundled resumable adb-pull helper.

echo "Installing adb and pv (Debian apt)..."
sudo apt-get update
sudo apt-get install -y adb pv

# Salt stages component assets alongside this script.
echo "Installing /usr/bin/adb-pull..."
sudo install -m 0755 "$(dirname "$0")/adb-pull.sh" /usr/bin/adb-pull
