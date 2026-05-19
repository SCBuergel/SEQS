#!/usr/bin/env bash

# exit on errors, ensure pipe errors surface. 'nounset' is intentionally off:
# nvm.sh is not nounset-clean when sourced.
set -Eeo pipefail

echo "Installing nvm and Node.js on appVM"

# nvm (Node Version Manager), pinned to a specific release.
# NOTE: this is an unverified curl|bash installer -- see TRUST.md. nvm is kept,
# in preference to the apt nodejs package, for the flexibility of installing
# and switching Node versions, accepting the weaker trust.
NVM_VERSION="v0.40.4"
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash

# load nvm into this shell and install the current LTS Node
export NVM_DIR="${HOME}/.nvm"
. "${NVM_DIR}/nvm.sh"

echo "installing the current LTS Node..."
nvm install --lts
nvm alias default 'lts/*'
