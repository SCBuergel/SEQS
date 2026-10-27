#!/usr/bin/env bash
set -Eeuo pipefail

ASSET_DIR="$(dirname "$0")"
hook=/rw/config/qubes-firewall-user-script
entry=/rw/config/seqs-protonvpn-firewall.sh
sudo install -m 0755 "${ASSET_DIR}/protonvpn-firewall.sh" "${entry}"
# qubes-firewall runs the hook directly and fails at every start if it
# cannot: the hook needs an interpreter line.
if [ "$(sudo head -c 2 "${hook}" 2>/dev/null)" != '#!' ]; then
	{ printf '#!/bin/sh\n'; sudo cat -- "${hook}" 2>/dev/null || true; } | sudo tee "${hook}.new" >/dev/null
	sudo mv -f -- "${hook}.new" "${hook}"
fi
sudo chmod 0755 "${hook}"
if ! sudo grep -Fqx "${entry}" "${hook}"; then
	# A last line without its newline would swallow the entry.
	{ [ -z "$(sudo tail -c 1 -- "${hook}")" ] || echo; printf '%s\n' "${entry}"; } | sudo tee -a "${hook}" >/dev/null
fi

echo "Proton VPN NetVM ready: start Proton VPN from the menu and sign in."
