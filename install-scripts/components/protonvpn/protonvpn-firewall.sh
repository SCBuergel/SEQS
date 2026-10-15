#!/bin/sh
# qubes-firewall recreates these chains before calling this hook. Client
# qubes must not fall back to the upstream NetVM while Proton VPN is
# disconnected or failed: forwarded traffic may leave only through the
# tunnel. A missing chain stops the hook with an error in the qubes-firewall
# journal instead of passing silently; the IPv4 drop is added first.
set -e
nft add rule ip qubes custom-forward oifname "eth0" counter drop
nft add rule ip6 qubes custom-forward oifname "eth0" counter drop
