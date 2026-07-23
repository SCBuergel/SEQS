#!/usr/bin/env bash
set -Eeuo pipefail

config=/rw/config/seqs-wireguard/wg0.conf
[[ -f "$config" ]] || exit 0

wg-quick down wg0 >/dev/null 2>&1 || true
wg-quick up "$config"
