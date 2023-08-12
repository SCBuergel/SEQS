#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing wallets on appVM"

echo "downloading Ledger Live..."
curl https://download.live.ledger.com/latest/linux -LGso LedgerLive.AppImage
chmod +x LedgerLive.AppImage

