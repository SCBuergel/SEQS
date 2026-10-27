#!/usr/bin/env bash
set -Eeuo pipefail

ASSET_DIR="$(dirname "$0")"
install -d -m 0700 "${HOME}/WireGuard"
sudo install -d -m 0700 /rw/config/seqs-wireguard
sudo install -m 0755 "${ASSET_DIR}/wireguard-boot.sh" /rw/config/seqs-wireguard/boot.sh
sudo install -m 0755 "${ASSET_DIR}/wireguard-firewall.sh" /rw/config/seqs-wireguard/firewall.sh
sudo install -m 0755 "${ASSET_DIR}/wireguard-dns.sh" /rw/config/seqs-wireguard/dns.sh
# Qubes runs both hooks directly, and qubes-firewall fails at every start if it
# cannot: each needs an interpreter line. Qubes creates them with one, but a
# build before ee9ba52 left one without it if it was missing or empty; repair that.
for hook in /rw/config/rc.local /rw/config/qubes-firewall-user-script; do
	if [ "$(sudo head -c 2 "${hook}" 2>/dev/null)" != '#!' ]; then
		{ printf '#!/bin/sh\n'; sudo cat -- "${hook}" 2>/dev/null || true; } | sudo tee "${hook}.new" >/dev/null
		sudo mv -f -- "${hook}.new" "${hook}"
	fi
	sudo chmod 0755 "${hook}"
done

# A last line without its newline would swallow the added line.
if ! sudo grep -Fqx '/rw/config/seqs-wireguard/boot.sh' /rw/config/rc.local; then
	{ [ -z "$(sudo tail -c 1 -- /rw/config/rc.local)" ] || echo; printf '%s\n' '/rw/config/seqs-wireguard/boot.sh'; } | sudo tee -a /rw/config/rc.local >/dev/null
fi
if ! sudo grep -Fqx '/rw/config/seqs-wireguard/firewall.sh' /rw/config/qubes-firewall-user-script; then
	{ [ -z "$(sudo tail -c 1 -- /rw/config/qubes-firewall-user-script)" ] || echo; printf '%s\n' '/rw/config/seqs-wireguard/firewall.sh'; } | sudo tee -a /rw/config/qubes-firewall-user-script >/dev/null
fi

echo "WireGuard NetVM ready."
echo "Put a .conf file in ~/WireGuard, then run: seqs-wireguard-import ~/WireGuard/FILE.conf"
