#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Claude Code on appVM"

# Native installer -> ~/.local/bin/claude, self-updating thereafter.
# NOTE: this is an unverified curl|bash installer (no signature/checksum) --
# see TRUST.md. -f ensures an HTTP error is not piped into the shell.
curl -fsSL https://claude.ai/install.sh | bash

echo "Claude Code installed -- ensure ~/.local/bin is on PATH (re-login if needed)"
