#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing telegram-desktop on appVM"

# wait for snapd to finish first-boot seeding, otherwise 'snap install' can
# fail with "too early for operation, device not yet seeded"
sudo snap wait system seed.loaded

sudo snap install telegram-desktop
