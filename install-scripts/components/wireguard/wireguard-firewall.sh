#!/usr/bin/env bash
set -Eeuo pipefail

# qubes-firewall recreates these tables/chains before calling this hook.
# Blocking eth0 makes client qubes fail closed when wg0 is absent or fails. A
# missing chain stops the hook with an error in the qubes-firewall journal
# instead of passing silently; the IPv4 drop is added first.
nft add rule ip qubes custom-forward oifname "eth0" counter drop
nft add rule ip6 qubes custom-forward oifname "eth0" counter drop
