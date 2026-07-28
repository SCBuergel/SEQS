#!/usr/bin/env bash
set -Eeuo pipefail

ASSET_DIR="$(dirname "$0")"
sudo "${ASSET_DIR}/seqs-gnosisvpn-prepare-app"

echo "GnosisVPN NetVM prerequisites and Qubes DNS hooks are ready."
echo "The pinned GnosisVPN stable release is installed for the rotsee network."
