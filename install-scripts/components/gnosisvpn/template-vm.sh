#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing GnosisVPN NetVM prerequisites (not GnosisVPN itself)..."
sudo apt-get update
sudo apt-get install -y openresolv wireguard-tools

ASSET_DIR="$(dirname "$0")"
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-dns" /usr/sbin/seqs-gnosisvpn-dns
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-firewall" /usr/sbin/seqs-gnosisvpn-firewall
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-prepare-app" /usr/sbin/seqs-gnosisvpn-prepare-app
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.service" /etc/systemd/system/seqs-gnosisvpn-dns.service
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.path" /etc/systemd/system/seqs-gnosisvpn-dns.path
sudo systemctl daemon-reload
sudo systemctl enable seqs-gnosisvpn-dns.path

echo "GnosisVPN itself was not installed."
