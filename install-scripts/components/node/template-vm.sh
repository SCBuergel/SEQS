#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Node.js prerequisites"

# curl is needed by the app-vm phase to fetch the nvm installer.
sudo apt-get update
sudo apt-get install -y curl
