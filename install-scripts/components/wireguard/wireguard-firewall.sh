#!/usr/bin/env bash
set -Eeuo pipefail

# qubes-firewall recreates these tables/chains before calling this hook.
# Blocking eth0 makes client qubes fail closed when wg0 is absent or fails. A
# missing chain fails the hook loudly instead of skipping the kill switch.
nft add rule ip qubes custom-forward oifname "eth0" counter drop
nft add rule ip6 qubes custom-forward oifname "eth0" counter drop

# Qubes may rebuild its firewall and DNS NAT tables when network state changes.
# Reassert the provider DNS after the Qubes-owned chains exist.
/rw/config/seqs-wireguard/dns.sh
