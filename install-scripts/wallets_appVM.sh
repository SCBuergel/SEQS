#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing wallets on appVM"

echo "downloading Ledger Live..."
curl https://download.live.ledger.com/latest/linux -LGso LedgerLive.AppImage
chmod +x LedgerLive.AppImage

echo "adding deleting of Qubes and Downloads folder to .bashrc"
echo "
rm -rf QubesIncoming
rm -rf Downloads/*" >> .bashrc
