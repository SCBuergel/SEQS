#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing telegram-desktop on appVM"

# wait for snapd to finish first-boot seeding, otherwise 'snap install' can
# fail with "too early for operation, device not yet seeded"
sudo snap wait system seed.loaded

sudo snap install telegram-desktop

# Qubes collects menu entries only from templates; report this qube's own,
# which now include the snap's, so dom0 can list Telegram in its menu.
/usr/lib/qubes/qrexec-client-vm dom0 qubes.SyncAppMenus /etc/qubes-rpc/qubes.GetAppmenus
