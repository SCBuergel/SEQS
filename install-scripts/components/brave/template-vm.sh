#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# shared Brave helpers; the seqs.qube state copies brave.sh next to this script
. "$(dirname "$0")/brave.sh"

install_brave
