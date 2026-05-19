#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Persisting docker content on appVM"

# bind /var/lib/docker into /rw so images and containers survive reboots
sudo mkdir -p /rw/config/qubes-bind-dirs.d/
echo "binds+=( '/var/lib/docker' )" | sudo tee /rw/config/qubes-bind-dirs.d/50_user.conf > /dev/null
