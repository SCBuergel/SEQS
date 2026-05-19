#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing wallets on appVM"

echo "downloading Ledger Live..."
# Ledger publishes no GPG signature for the Linux AppImage and the URL is
# unversioned ("latest"), so this download cannot be cryptographically
# verified or version-pinned -- see TRUST.md. -f at least makes curl fail on
# an HTTP error instead of saving an error page as the AppImage.
curl -fsSL https://download.live.ledger.com/latest/linux -o LedgerLive.AppImage
chmod +x LedgerLive.AppImage
