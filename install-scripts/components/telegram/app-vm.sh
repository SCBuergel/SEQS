#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing telegram-desktop on appVM"

# wait for snapd to finish first-boot seeding, otherwise 'snap install' can
# fail with "too early for operation, device not yet seeded"
sudo snap wait system seed.loaded

sudo snap install telegram-desktop
