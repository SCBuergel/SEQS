#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Claude Code prerequisites"

# curl is needed by the app-vm phase to fetch the Claude Code installer.
# Installing it here keeps the claude-code component self-sufficient.
sudo apt-get update
sudo apt-get install -y curl
