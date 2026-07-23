#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing WireGuard and its DNS helper..."
sudo apt-get update
sudo apt-get install -y wireguard-tools resolvconf

ASSET_DIR="$(dirname "$0")"
sudo install -m 0755 "${ASSET_DIR}/seqs-wireguard" /usr/local/sbin/seqs-wireguard
sudo ln -sfn /usr/local/sbin/seqs-wireguard /usr/local/bin/seqs-wireguard-import
