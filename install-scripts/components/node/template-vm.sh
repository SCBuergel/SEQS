#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Node.js and npm"

# Node.js straight from the Debian repository -- apt-verified against the
# template's Debian archive keyring, no third-party repo or vendored installer.
sudo apt-get update
sudo apt-get install -y nodejs npm
