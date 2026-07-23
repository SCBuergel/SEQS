#!/usr/bin/env bash
set -Eeuo pipefail

ASSET_DIR="$(dirname "$0")"
sudo install -d -m 0700 /rw/config/seqs-wireguard
sudo install -m 0755 "${ASSET_DIR}/wireguard-boot.sh" /rw/config/seqs-wireguard/boot.sh
sudo install -m 0755 "${ASSET_DIR}/wireguard-firewall.sh" /rw/config/seqs-wireguard/firewall.sh
sudo touch /rw/config/rc.local /rw/config/qubes-firewall-user-script
sudo chmod 0755 /rw/config/rc.local /rw/config/qubes-firewall-user-script

if ! sudo grep -Fqx '/rw/config/seqs-wireguard/boot.sh' /rw/config/rc.local; then
	printf '%s\n' '/rw/config/seqs-wireguard/boot.sh' | sudo tee -a /rw/config/rc.local >/dev/null
fi
if ! sudo grep -Fqx '/rw/config/seqs-wireguard/firewall.sh' /rw/config/qubes-firewall-user-script; then
	printf '%s\n' '/rw/config/seqs-wireguard/firewall.sh' | sudo tee -a /rw/config/qubes-firewall-user-script >/dev/null
fi

echo "WireGuard NetVM ready. Copy a .conf file here, then run: seqs-wireguard-import FILE"
