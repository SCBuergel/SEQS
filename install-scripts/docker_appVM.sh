#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Persisting docker content on appVM"

sudo mkdir /rw/config/qubes-bind-dirs.d/
cd /rw/config/qubes-bind-dirs.d/
echo "binds+=( '/var/lib/docker' )" | sudo tee 50_user.conf
