#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Xournal++"

sudo apt install libportaudiocpp0 libzip4 xournalpp -y

echo "Make sure you change input settings for Xournal++: https://github.com/xournalpp/xournalpp/issues/5771#issuecomment-3180794310"
