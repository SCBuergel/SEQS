#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# shared Brave helpers; setup-qubes.sh moves brave.sh in next to this script
. "$(dirname "$0")/brave.sh"

install_brave
