#!/usr/bin/env bash
set -Eeuo pipefail

config=/rw/config/seqs-wireguard/wg0.conf
[[ -r "$config" ]] || exit 0

# Extract at most two IPv4 resolvers. Values remain data: both provider and
# QubesDB addresses are restricted before interpolation into the nft batch.
mapfile -t provider_dns < <(
	awk -F= '
		/^[[:space:]]*DNS[[:space:]]*=/ {
			gsub(/[[:space:]]/, "", $2)
			n = split($2, servers, ",")
			for (i = 1; i <= n; i++)
				if (servers[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
					print servers[i]
					if (++found == 2)
						exit
				}
		}
	' "$config"
)
if [[ ${#provider_dns[@]} -eq 0 ]]; then
	echo "ERROR: WireGuard configuration has no IPv4 DNS server" >&2
	exit 1
fi

mapfile -t qubes_dns < <(
	for key in /qubes-netvm-primary-dns /qubes-netvm-secondary-dns; do
		qubesdb-read "$key" 2>/dev/null || true
	done
)
if [[ ${#qubes_dns[@]} -eq 0 ]]; then
	echo "ERROR: QubesDB exposes no client DNS addresses" >&2
	exit 1
fi

is_ipv4() {
	local address=$1 octet
	local -a octets
	[[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS=. read -r -a octets <<< "$address"
	for octet in "${octets[@]}"; do
		((10#$octet <= 255)) || return 1
	done
}

for address in "${provider_dns[@]}" "${qubes_dns[@]}"; do
	if ! is_ipv4 "$address"; then
		echo "ERROR: refusing malformed DNS address" >&2
		exit 1
	fi
done

# Match Qubes' own atomic replacement pattern: replace only dnat-dns inside
# table ip qubes, leaving all other Qubes firewall state untouched.
rules=$'add table ip qubes\n'
rules+=$'add chain ip qubes dnat-dns\n'
rules+=$'delete chain ip qubes dnat-dns\n'
rules+=$'add chain ip qubes seqs-wireguard-dns-output\n'
rules+=$'delete chain ip qubes seqs-wireguard-dns-output\n'
rules+=$'table ip qubes {\nchain dnat-dns {\n'
rules+=$'type nat hook prerouting priority dstnat; policy accept;\n'
for i in "${!qubes_dns[@]}"; do
	destination=${provider_dns[$((i % ${#provider_dns[@]}))]}
	rules+="ip daddr ${qubes_dns[$i]} udp dport 53 dnat to ${destination}"$'\n'
	rules+="ip daddr ${qubes_dns[$i]} tcp dport 53 dnat to ${destination}"$'\n'
done
rules+=$'}\nchain seqs-wireguard-dns-output {\n'
rules+=$'type nat hook output priority dstnat; policy accept;\n'
for i in "${!qubes_dns[@]}"; do
	destination=${provider_dns[$((i % ${#provider_dns[@]}))]}
	rules+="ip daddr ${qubes_dns[$i]} udp dport 53 dnat to ${destination}"$'\n'
	rules+="ip daddr ${qubes_dns[$i]} tcp dport 53 dnat to ${destination}"$'\n'
done
rules+=$'}\n}\n'
nft --file - <<< "$rules"
