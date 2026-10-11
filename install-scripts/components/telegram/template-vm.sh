#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing snapd for telegram-desktop"

sudo apt-get update
sudo apt-get install -y snapd qubes-snapd-helper
