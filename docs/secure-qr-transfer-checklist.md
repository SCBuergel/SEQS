# Secure QR transfer checklist

This checklist is for repeating a transfer after the one-time setup in
[secure-qr-transfer.md](secure-qr-transfer.md) is complete, including its
setup checks and the
[rehearsal with a throwaway file](secure-qr-transfer.md#rehearse-with-a-throwaway-file). Each item links to the step that holds the commands and the
full instructions; follow the step whenever you are unsure, and stop wherever
the step says to stop.

Before you start:

- [ ] A fresh sheet of paper is ready for the passphrase.
- [ ] The webcam is unplugged, and every built-in camera on both computers is
      covered or switched off with a hardware switch.
- [ ] The paper and any screen showing the passphrase will stay out of every
      camera's view.

Sending computer:

- [ ] [Step 1](secure-qr-transfer.md#step-1-encrypt-the-file-sending-computer):
      encrypt `master.key` in the source key qube, write the passphrase on
      paper, and close that terminal window.
- [ ] [Step 2](secure-qr-transfer.md#step-2-copy-the-encrypted-file-to-the-display-qube-sending-computer):
      start `D-qr-display` first, then copy `key.asc` to it. Keep the source
      `key.asc`.
- [ ] [Step 3](secure-qr-transfer.md#step-3-show-the-qr-code-sending-computer):
      put the paper away, then show the QR code in `D-qr-display`; cancel any
      dialog from `D-qr-display` and treat it like a fingerprint mismatch.

Receiving computer, one of:

- [ ] [Step 4a](secure-qr-transfer.md#step-4a-scan-on-the-dedicated-controller-path-receiving-computer),
      dedicated-controller path: the webcam appears only under
      `sys-usb-webcam`, as a single device; accept exactly one copy dialog;
      afterwards unplug the webcam and confirm the camera qubes have stopped.
- [ ] [Step 4b](secure-qr-transfer.md#step-4b-scan-on-the-sequential-path-receiving-computer),
      sequential path: run the dom0 script, check that it lists nothing in
      `sys-usb` except your USB keyboard and mouse and internal devices you
      found on another controller, unplug the keyboard and mouse within 10
      seconds of `START`, plug the webcam into the socket you chose for it,
      remove all power after the power-off, then copy `key.asc` from
      `A-qr-staging`.

Both computers:

- [ ] [Step 5](secure-qr-transfer.md#step-5-compare-fingerprints-both-computers):
      the incoming folder held only `key.asc`, and all four fingerprint groups
      match character by character. On any difference, do not decrypt.
- [ ] [Step 6](secure-qr-transfer.md#step-6-decrypt-receiving-computer): the
      passphrase prompt has the target key qube's colour border, and the last
      line shows `600 master.key`.
- [ ] [Step 7](secure-qr-transfer.md#step-7-clean-up): delete the leftover
      `key.asc` copies, then destroy the paper.
