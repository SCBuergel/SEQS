# Installing Qubes OS

The detailed, one-time host install that precedes SEQS. The short version lives
in the [first-install guide](first-install.md#1-install-and-verify-qubes-os);
this is the full walkthrough.

## 1. Prepare the installer USB

- Start with an empty ≥8 GB USB stick.
- Download the latest [Qubes OS ISO](https://www.qubes-os.org/downloads/).
  Qubes [cannot boot from Ventoy-based installers](https://github.com/QubesOS/qubes-issues/issues/8846),
  so use a dedicated USB drive for the installer.

## 2. Verify the ISO before flashing it

A tampered ISO compromises the entire install — and therefore every qube you
later create on it. Full procedure: [Qubes: Verifying signatures](https://www.qubes-os.org/security/verifying-signatures/).
Summary:

1. Fetch the Qubes Master Signing Key (QMSK):
   ```
   gpg --fetch-keys https://keys.qubes-os.org/keys/qubes-master-signing-key.asc
   ```
2. Cross-check the QMSK fingerprint
   `427F 11FD 0FAA 4B08 0123  F01C DDFA 1A3E 3687 9494`
   against **three independent sources** — if the same fingerprint shows up
   across unrelated infrastructure, it is much harder for any single operator
   (or a MITM on your network) to have substituted a key:
   - Qubes website (primary): https://www.qubes-os.org/security/pack/
   - `qubes-secpack` repo on GitHub (different infra, separate TLS chain): https://github.com/QubesOS/qubes-secpack
   - `keys.openpgp.org` keyserver (independent operator): https://keys.openpgp.org/search?q=0xDDFA1A3E36879494
3. Mark the QMSK as trusted and fetch the release signing key (itself signed by
   the QMSK):
   ```
   gpg --edit-key 0x36879494    # then type: trust, 5, y, quit
   gpg --fetch-keys https://keys.qubes-os.org/keys/qubes-release-X-signing-key.asc
   ```
   (replace `X` with the major release number of the ISO you downloaded)
4. Verify the ISO against its detached signature (download the matching `.asc`
   from the same downloads page):
   ```
   gpg --verify Qubes-RX.X-x86_64.iso.asc Qubes-RX.X-x86_64.iso
   ```
   A `Good signature from "Qubes OS Release X Signing Key"` line — and **no
   warning about the key not being certified** — confirms the ISO is authentic.

## 3. Partitioning

Suggested partitions / mount points:

1. 500 MB `/boot/efi` (can be shared if you multiboot with other OSs)
2. 1 GB `/boot` (you cannot share a Qubes and e.g. Ubuntu `/boot`; Qubes will
   just boot you into a black screen)
3. whatever is left `/` (encrypted, LUKS2)

## 4. Post-install

- **Window tiling** (optional, for arranging windows neatly): Qubes menu →
  System Tools → Window Manager → Keyboard → scroll to the Tile settings and
  set them as shown:

  ![Qubes Window Manager Keyboard settings](https://github.com/SCBuergel/SEQS/blob/main/WindowManagerTile.png?raw=true)

- After connecting to wifi, the system-update icon should appear in the tray
  (top right). Run all updates and reboot.
