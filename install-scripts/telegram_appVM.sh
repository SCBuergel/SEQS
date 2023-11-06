#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing telegram-desktop on appVM"

sudo snap install telegram-desktop

echo "adding deleting of Qubes and Downloads folder to .bashrc"
echo "
rm -rf QubesIncoming
rm -rf Downloads/*" >> .bashrc
