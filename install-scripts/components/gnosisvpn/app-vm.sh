#!/usr/bin/env bash
set -Eeuo pipefail

sudo /usr/sbin/seqs-gnosisvpn-prepare-app

echo "GnosisVPN NetVM prerequisites and Qubes DNS hooks are ready."
echo "GnosisVPN itself is intentionally not installed."
