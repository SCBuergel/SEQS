#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing Node.js prerequisites"

# curl is needed by the app-vm phase to fetch the nvm installer.
sudo apt-get update
sudo apt-get install -y curl
