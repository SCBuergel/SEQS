#!/usr/bin/env bash
set -Eeuo pipefail

sudo /usr/sbin/seqs-gnosisvpn-prepare-app

echo "GnosisVPN NetVM prerequisites and Qubes DNS hooks are ready."
echo "The pinned GnosisVPN snapshot is installed for the rotsee network."
