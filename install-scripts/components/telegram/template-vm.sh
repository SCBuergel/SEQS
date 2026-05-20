#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing snapd for telegram-desktop"

sudo apt-get update
sudo apt-get install -y snapd qubes-snapd-helper
