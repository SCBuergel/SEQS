#!/usr/bin/env bash
set -Eeuo pipefail

ASSET_DIR="$(dirname "$0")"
sudo "${ASSET_DIR}/seqs-gnosisvpn-prepare-app"

echo "GnosisVPN NetVM prerequisites and Qubes DNS hooks are ready."
echo "GnosisVPN from its stable APT repository is installed for the jura-prod network."
