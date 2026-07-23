#!/usr/bin/env bash
set -Eeuo pipefail

# qubes-firewall recreates these tables/chains before calling this hook.
# Blocking eth0 makes client qubes fail closed when wg0 is absent or fails.
nft list chain ip qubes custom-forward >/dev/null 2>&1 &&
	nft add rule ip qubes custom-forward oifname "eth0" counter drop
nft list chain ip6 qubes custom-forward >/dev/null 2>&1 &&
	nft add rule ip6 qubes custom-forward oifname "eth0" counter drop

# Client qubes send DNS to Qubes' synthetic DNS addresses. Redirect those
# requests to the first IPv4 DNS server in the provider configuration so DNS
# follows the tunnel instead of being forwarded to the upstream NetVM.
config=/rw/config/seqs-wireguard/wg0.conf
if [[ -r "$config" ]]; then
	dns4=$(
		awk -F= '
			/^[[:space:]]*DNS[[:space:]]*=/ {
				gsub(/[[:space:]]/, "", $2)
				n = split($2, servers, ",")
				for (i = 1; i <= n; i++)
					if (servers[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
						print servers[i]
						exit
					}
			}
		' "$config"
	)
	if [[ -n "$dns4" ]]; then
		if ! nft list chain ip qubes seqs-dns >/dev/null 2>&1; then
			nft add chain ip qubes seqs-dns '{ type nat hook prerouting priority dstnat; }'
		fi
		nft add rule ip qubes seqs-dns iifname "vif*" udp dport 53 dnat to "$dns4"
		nft add rule ip qubes seqs-dns iifname "vif*" tcp dport 53 dnat to "$dns4"
	fi
fi
