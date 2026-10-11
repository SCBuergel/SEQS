#!/usr/bin/env bash
set -Eeuo pipefail

echo "Persisting docker content on appVM"

# bind /var/lib/docker into /rw so images and containers survive reboots
sudo mkdir -p /rw/config/qubes-bind-dirs.d/
echo "binds+=( '/var/lib/docker' )" | sudo tee /rw/config/qubes-bind-dirs.d/50-seqs-docker.conf > /dev/null
