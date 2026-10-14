#!/usr/bin/env python3
"""Warn before an embedded signing key expires.

Each component that embeds an OpenPGP key refuses to install once the key that
signs its packages has expired, and a locked keyring then also breaks apt in
the template. This lists, for every embedded key block, the earliest expiry
among its signing-capable keys that are still valid, and fails within
FAIL_DAYS so that a renewed key is embedded in time.

Usage: python3 test/key_expiry.py
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

WARN_DAYS = 180
FAIL_DAYS = 30
BLOCK = re.compile(r"-----BEGIN PGP PUBLIC KEY BLOCK-----.*?-----END PGP PUBLIC KEY BLOCK-----", re.S)


def signing_expiries(block, home):
    """Expiry times (epoch) of the still-valid signing-capable keys in BLOCK."""
    out = subprocess.run(["gpg", "--homedir", home, "--with-colons", "--show-keys"],
                         input=block.encode(), capture_output=True).stdout.decode()
    now = time.time()
    result = []
    for line in out.splitlines():
        f = line.split(":")
        # pub/sub lines: field 2 validity, 7 expiry, 12 capabilities.
        if f[0] in ("pub", "sub") and "s" in f[11].lower() and f[1] not in ("r", "e"):
            if f[6] and int(f[6]) > now:
                result.append(int(f[6]))
            elif not f[6]:
                result.append(None)
    return result


def main():
    if shutil.which("gpg") is None:
        print("  skip: gpg not available")
        return 0
    failed = 0
    with tempfile.TemporaryDirectory() as home:
        os.chmod(home, 0o700)
        for path in sorted(glob.glob("install-scripts/components/*/*")):
            text = open(path, errors="replace").read()
            for block in BLOCK.findall(text):
                expiries = signing_expiries(block, home)
                if not expiries:
                    print("  FAIL %s: no valid signing key in the embedded block" % path)
                    failed = 1
                    continue
                dated = [e for e in expiries if e is not None]
                if not dated:
                    continue  # every signing key is without expiry
                # Which key signs is not known here, so warn on the earliest.
                days = (min(dated) - time.time()) / 86400
                date = time.strftime("%Y-%m-%d", time.gmtime(min(dated)))
                if days < FAIL_DAYS:
                    print("  FAIL %s: a signing key expires on %s; embed the renewed key" % (path, date))
                    failed = 1
                elif days < WARN_DAYS:
                    print("  WARN %s: a signing key expires on %s (%d days)" % (path, date, days))
    return failed


if __name__ == "__main__":
    sys.exit(main())
