#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing vscode stuff on appVM"

sudo apt update

echo "installing  nvm..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash

echo "installing latest version of node..."
nvm install node
nvm use node
