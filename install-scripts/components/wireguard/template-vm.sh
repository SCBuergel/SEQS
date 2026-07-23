#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing WireGuard..."
sudo apt-get update
sudo apt-get install -y wireguard-tools

ASSET_DIR="$(dirname "$0")"
# The local hierarchy is an AppVM-private bind mount in Qubes and would hide
# the template's copy. /usr is inherited from the template by A-wireguard.
sudo install -m 0755 "${ASSET_DIR}/seqs-wireguard" /usr/sbin/seqs-wireguard
sudo ln -sfn /usr/sbin/seqs-wireguard /usr/bin/seqs-wireguard-import
