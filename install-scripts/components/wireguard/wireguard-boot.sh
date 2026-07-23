#!/usr/bin/env bash
set -Eeuo pipefail

config=/rw/config/seqs-wireguard/wg0.conf
[[ -f "$config" ]] || exit 0

wg-quick down wg0 >/dev/null 2>&1 || true
wg-quick up "$config"

# Client qubes intentionally keep Qubes' synthetic resolvers (10.139.1.1/.2).
# wg-quick has now selected the provider's DNS through resolvconf; refresh the
# Qubes-owned dnat-dns chain so those synthetic addresses map to that resolver.
# Do not maintain a competing NAT chain in qubes-firewall-user-script.
if [[ -x /usr/lib/qubes/qubes-setup-dnat-to-ns ]]; then
	/usr/lib/qubes/qubes-setup-dnat-to-ns
elif [[ -x /usr/lib/qubes/qubes_setup_dnat_to_ns ]]; then
	# Compatibility with older Qubes agent packages.
	/usr/lib/qubes/qubes_setup_dnat_to_ns
else
	echo "ERROR: Qubes DNS DNAT helper is missing" >&2
	wg-quick down wg0 >/dev/null 2>&1 || true
	exit 1
fi
