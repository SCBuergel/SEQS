#!/usr/bin/env bash

# Full error trapping: exit on errors, undefined variable refs, and pipe
# failures. nvm.sh and the `nvm` command are NOT nounset-clean, so `set -u`
# is selectively disabled across that block via `set +u`/`set -u`.
set -Eeuo pipefail

echo "Installing nvm and Node.js on appVM"

# nvm (Node Version Manager), pinned to a specific release.
# NOTE: this is an unverified curl|bash installer -- see TRUST.md. nvm is kept,
# in preference to the apt nodejs package, for the flexibility of installing
# and switching Node versions, accepting the weaker trust.
NVM_VERSION="v0.40.4"
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash

# load nvm into this shell and install the current LTS Node
export NVM_DIR="${HOME}/.nvm"
set +u
. "${NVM_DIR}/nvm.sh"

echo "installing the current LTS Node..."
nvm install --lts
nvm alias default 'lts/*'
set -u
