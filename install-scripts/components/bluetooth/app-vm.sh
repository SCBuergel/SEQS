#!/usr/bin/env bash
set -Eeuo pipefail

# Keep the pairings across restarts: /var/lib/bluetooth is on the root volume,
# which an app qube discards at shutdown. Takes effect at the next start.
sudo mkdir -p /rw/config/qubes-bind-dirs.d/
echo "binds+=( '/var/lib/bluetooth' )" | sudo tee /rw/config/qubes-bind-dirs.d/50-seqs-bluetooth.conf > /dev/null
