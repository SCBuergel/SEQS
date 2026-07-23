#!/usr/bin/env bash
set -Eeuo pipefail

config=/rw/config/seqs-wireguard/wg0.conf
[[ -f "$config" ]] || exit 0

# Qubes owns /etc/resolv.conf and does not expose it through resolvconf.
# Preserve DNS= in the stored provider file, but remove it from the runtime
# wg-quick input; dns.sh programs Qubes' native dnat-dns chain instead.
runtime_dir=/run/seqs-wireguard
install -d -m 0700 "$runtime_dir"
sed '/^[[:space:]]*DNS[[:space:]]*=/Id' "$config" > "${runtime_dir}/wg0.conf"
chmod 0600 "${runtime_dir}/wg0.conf"

wg-quick down "${runtime_dir}/wg0.conf" >/dev/null 2>&1 || true
wg-quick up "${runtime_dir}/wg0.conf"
if ! /rw/config/seqs-wireguard/dns.sh; then
	wg-quick down "${runtime_dir}/wg0.conf" >/dev/null 2>&1 || true
	exit 1
fi
