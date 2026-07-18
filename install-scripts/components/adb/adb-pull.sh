#!/bin/bash
set -euo pipefail

# Chunked, resumable wrapper around `adb pull` for transferring large files
# from an Android device to the local qube. Installed to /usr/bin/adb-pull by
# the adb component (install-scripts/components/adb/template-vm.sh). Designed
# to run inside A-usb-data-transfer with the phone either USB-attached via
# qvm-usb or paired over wireless ADB.
#
# adb and pv are expected to be pre-installed by the template; this script no
# longer downloads platform-tools from dl.google.com (that path was unsigned
# and is gone -- see TRUST.md, "ADB file transfer").

# ─── Configuration ───────────────────────────────────────────────────────────
ADB=/usr/bin/adb
CONNECTION_FILE=~/.adb-pull-device  # persists IP:port between runs
DEFAULT_CHUNK_MB=5
MAX_RETRIES=5
RETRY_DELAY=5
ADB_TIMEOUT=8                      # seconds before a stuck adb command is killed

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <remote-file> <local-output>

Transfer a file from an Android device over ADB in resumable chunks.

Options:
  -c, --chunk-size MB   Chunk size in megabytes (default: $DEFAULT_CHUNK_MB)
  -h, --help            Show this help message

Examples:
  $0 /sdcard/backup.tar.gz ./backup.tar.gz
  $0 -c 10 /sdcard/big-file.zip /home/user/big-file.zip
EOF
    exit "${1:-0}"
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
CHUNK_MB=$DEFAULT_CHUNK_MB

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--chunk-size)
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -eq 0 ]]; then
                echo "ERROR: --chunk-size requires a positive integer (MB)."
                exit 1
            fi
            CHUNK_MB="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 2 ]]; then
    usage 1
fi

REMOTE="$1"
OUTPUT="$2"

# Single-quote-escaped form of REMOTE for safe interpolation into commands
# that run inside the device shell (adb shell / adb exec-out concatenates
# its args with spaces and hands the whole string to the device's shell).
# Without this, a filename containing ' would break out of the quotes and
# whatever followed would be parsed by that shell. ${var@Q} (bash 4.4+)
# produces POSIX-safe single-quoted output with '\'' escapes.
REMOTE_Q="${REMOTE@Q}"

if [[ -d "$OUTPUT" ]]; then
    OUTPUT="$OUTPUT/$(basename "$REMOTE")"
fi

# ─── Dependency check ────────────────────────────────────────────────────────
# adb and pv come from the template (apt-installed). Fail clearly if missing
# -- this script no longer self-installs them from unsigned sources.
if [[ ! -x "$ADB" ]]; then
    echo "ERROR: $ADB not found. Run this inside A-usb-data-transfer (or any qube based on Z-usb-data-transfer)."
    exit 1
fi
if ! command -v pv &>/dev/null; then
    echo "WARNING: pv not installed -- per-chunk progress bars disabled."
fi

# ─── Saved device connection ────────────────────────────────────────────────
# Reads saved IP:port from ~/.adb-pull-device so you don't re-enter it each run.

load_saved_device() {
    if [[ -f "$CONNECTION_FILE" ]]; then
        cat "$CONNECTION_FILE"
    fi
}

save_device() {
    # 0600: the saved file contains the LAN IP:port of the phone -- not a
    # secret per se, but useful reconnaissance for anyone with read access
    # to the qube's filesystem. Default umask would leave it 0644.
    (umask 077 && echo "$1" > "$CONNECTION_FILE")
}

# ─── Connection helpers ─────────────────────────────────────────────────────

# Prompt for IP:port (pre-filled with saved value) and optionally pair
adb_connect_prompt() {
    local saved ip port target
    saved=$(load_saved_device)

    if [[ -n "$saved" ]]; then
        read -rp "Device IP:port [$saved]: " target
        target="${target:-$saved}"
    else
        read -rp "Device IP:port: " target
        # Default port to 5555 if only an IP was entered
        if [[ "$target" != *:* ]]; then
            target="$target:5555"
        fi
    fi

    # Offer pairing (first-time wireless)
    read -rp "Pair first? (only needed once per device) [y/N]: " do_pair
    if [[ "${do_pair,,}" == "y" ]]; then
        local pair_port pair_code
        read -rp "Pairing port (shown on device): " pair_port
        read -rp "Pairing code (shown on device): " pair_code
        local pair_ip="${target%%:*}"
        echo "Pairing with $pair_ip:$pair_port ..."
        $ADB pair "$pair_ip:$pair_port" "$pair_code"
        echo ""
    fi

    echo "Connecting to $target ..."
    if $ADB connect "$target" 2>/dev/null | grep -q 'connected'; then
        save_device "$target"
        echo "Connected (saved to $CONNECTION_FILE for next time)."
    else
        echo "WARNING: connection may have failed — will verify below."
    fi
    echo ""
}

# Tracks whether the user has confirmed the saved IP:port this run.
# First call prompts; subsequent in-run calls (e.g. wifi-blip reconnects
# during a transfer) skip the prompt -- the user has already approved this
# session and re-asking on every retry would be noise. We instead verify
# the hardware serial below so a silent reconnect can't land on a hijacker.
SAVED_DEVICE_CONFIRMED=0

# Hardware serial captured after the FIRST successful connect; every
# subsequent in-run reconnect must produce the same serial or we abort.
# Catches the case where the saved IP:port has been taken over by another
# host on the LAN between transfers (common on hotel / cafe / coworking
# networks where DHCP leases roll over, or under a deliberate ARP/DHCP
# attack). Without this, a silent reconnect would resume the chunked
# transfer from the attacker's host and the end-of-transfer SHA-256
# check would compare hashes the attacker produced -- it would print
# "PASSED" against attacker bytes.
INITIAL_SERIAL=""

# get_device_serial: read the connected device's hardware serial. Returns
# empty on failure. ro.serialno is queried via `adb shell`, so a hostile
# peer could lie -- but a hijacker on the LAN does NOT know the original
# phone's serial, so a mismatch on reconnect is a strong signal.
get_device_serial() {
    timeout "$ADB_TIMEOUT" $ADB shell getprop ro.serialno 2>/dev/null \
        | tr -d '\r\n' || true
}

# verify_device_identity: abort if the current device's serial differs
# from the one captured on first connect. No-op until INITIAL_SERIAL is
# set (i.e. during the very first connect).
verify_device_identity() {
    [[ -z "$INITIAL_SERIAL" ]] && return 0
    local now
    now=$(get_device_serial)
    if [[ -z "$now" ]]; then
        echo "ERROR: could not read device serial after reconnect -- aborting." >&2
        exit 1
    fi
    if [[ "$now" != "$INITIAL_SERIAL" ]]; then
        echo "ERROR: device serial CHANGED mid-run!" >&2
        echo "  expected (start of session): $INITIAL_SERIAL" >&2
        echo "  got      (after reconnect):  $now" >&2
        echo "Refusing to continue -- the saved IP:port may have been taken" >&2
        echo "over by another host on this network." >&2
        exit 1
    fi
}

# Try reconnecting to a saved device after explicit confirmation; its IP may
# have changed hands since it was saved.
adb_reconnect_saved() {
    local saved ans
    saved=$(load_saved_device)
    [[ -z "$saved" ]] && return 1
    if [[ "$SAVED_DEVICE_CONFIRMED" -eq 0 ]]; then
        read -rp "Reconnect to saved device $saved? [Y/n]: " ans
        case "${ans,,}" in
            n|no) return 1 ;;
        esac
        SAVED_DEVICE_CONFIRMED=1
    fi
    timeout "$ADB_TIMEOUT" $ADB connect "$saved" &>/dev/null || true
    $ADB devices 2>/dev/null | grep -q 'device$' || return 1
    # Re-verify the hardware serial after the reconnect (no-op on first
    # successful connect since INITIAL_SERIAL is still empty at that point).
    verify_device_identity
    return 0
}

# Check for connected device; auto-reconnect or prompt as needed
adb_wait() {
    # Already connected?
    if $ADB devices 2>/dev/null | grep -q 'device$'; then
        verify_device_identity
        return 0
    fi

    # Try saved device first (silent)
    if adb_reconnect_saved; then
        return 0
    fi

    # No device — prompt for connection
    echo "No ADB device detected."
    adb_connect_prompt

    # Retry loop
    local attempt
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        if $ADB devices 2>/dev/null | grep -q 'device$'; then
            verify_device_identity
            return 0
        fi
        # Try saved reconnect between waits
        if adb_reconnect_saved; then
            return 0
        fi
        echo "  [wait] attempt $attempt/$MAX_RETRIES (retry in ${RETRY_DELAY}s)..."
        sleep "$RETRY_DELAY"
    done

    echo "ERROR: device not connected after $MAX_RETRIES attempts."
    return 1
}

# ─── Initial connection check ────────────────────────────────────────────────
adb_wait

# Capture the device serial right after the first successful connect.
# From here on, every adb_wait re-check (including silent reconnects
# during the chunk-retry loop) compares against this value via
# verify_device_identity and aborts on mismatch.
INITIAL_SERIAL=$(get_device_serial)
if [[ -z "$INITIAL_SERIAL" ]]; then
    echo "ERROR: could not read device serial -- aborting." >&2
    echo "       (adb shell getprop ro.serialno returned empty)" >&2
    exit 1
fi
echo "Device serial captured: $INITIAL_SERIAL"

# ─── Get remote file size ────────────────────────────────────────────────────
SIZE=$(timeout "$ADB_TIMEOUT" $ADB shell "stat -c%s $REMOTE_Q" 2>/dev/null | tr -d '\r')
if [[ -z "$SIZE" ]] || [[ "$SIZE" -eq 0 ]]; then
    echo "ERROR: Could not stat remote file or file is empty: $REMOTE"
    exit 1
fi

CHUNK_BYTES=$((CHUNK_MB * 1048576))
TOTAL_CHUNKS=$(( (SIZE + CHUNK_BYTES - 1) / CHUNK_BYTES ))

echo "Remote file: $REMOTE"
echo "Local output: $OUTPUT"
echo "File size: $SIZE bytes ($(( SIZE / 1048576 )) MB)"
echo "Chunk size: ${CHUNK_MB} MB, $TOTAL_CHUNKS chunks total"
echo ""

# ─── Determine resume point ──────────────────────────────────────────────────
START_CHUNK=0
if [[ -f "$OUTPUT" ]]; then
    HAVE=$(stat -c%s "$OUTPUT")
    START_CHUNK=$(( HAVE / CHUNK_BYTES ))
    if [[ "$HAVE" -eq "$SIZE" ]]; then
        echo "File already fully transferred ($HAVE bytes). Skipping to verification."
        START_CHUNK=$TOTAL_CHUNKS
    elif [[ "$START_CHUNK" -gt 0 ]]; then
        TRUNCATE_TO=$(( START_CHUNK * CHUNK_BYTES ))
        echo "Found partial download: $HAVE bytes on disk."
        echo "Truncating to last clean chunk boundary: $TRUNCATE_TO bytes."
        truncate -s "$TRUNCATE_TO" "$OUTPUT"
        sync "$OUTPUT"
        echo "Resuming from chunk $START_CHUNK / $TOTAL_CHUNKS"
    fi
else
    echo "Starting fresh download."
fi

echo ""

# ─── Transfer loop ───────────────────────────────────────────────────────────
TMPCHUNK="${OUTPUT}.chunk.tmp"
# Scale per-chunk timeout: at least ADB_TIMEOUT, or ~2s per MB (slow wifi headroom)
CHUNK_TIMEOUT=$(( CHUNK_MB * 2 + ADB_TIMEOUT ))

for (( i=START_CHUNK; i<TOTAL_CHUNKS; i++ )); do
    SKIP=$(( i * CHUNK_MB ))
    OFFSET_BYTES=$(( i * CHUNK_BYTES ))
    REMAINING=$(( SIZE - OFFSET_BYTES ))
    THIS_CHUNK_MB=$CHUNK_MB
    THIS_CHUNK_BYTES=$CHUNK_BYTES
    if [[ "$REMAINING" -lt "$CHUNK_BYTES" ]]; then
        THIS_CHUNK_MB=$(( (REMAINING + 1048575) / 1048576 ))
        THIS_CHUNK_BYTES=$REMAINING
    fi

    PCT=$(( (i * 100) / TOTAL_CHUNKS ))

    # retry loop per chunk
    CHUNK_OK=0
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        echo "[$PCT%] Chunk $((i+1))/$TOTAL_CHUNKS (offset ${SKIP}M, ${THIS_CHUNK_MB}MB) attempt $attempt"

        rm -f "$TMPCHUNK"

        # Download chunk: pipe through pv for progress if available
        # Note: pv writes progress to stderr, so only suppress adb's stderr, not pv's
        if command -v pv &>/dev/null; then
            if ! timeout "$CHUNK_TIMEOUT" \
                $ADB exec-out "dd if=$REMOTE_Q bs=1M skip=$SKIP count=$THIS_CHUNK_MB 2>/dev/null" 2>/dev/null \
                | pv -s "$THIS_CHUNK_BYTES" -p -t -e -r \
                > "$TMPCHUNK"; then
                echo "  adb/timeout error"
            fi
        else
            if ! timeout "$CHUNK_TIMEOUT" \
                $ADB exec-out "dd if=$REMOTE_Q bs=1M skip=$SKIP count=$THIS_CHUNK_MB 2>/dev/null" \
                > "$TMPCHUNK" 2>/dev/null; then
                echo "  adb/timeout error"
            fi
        fi

        # Verify chunk size
        GOT=$(stat -c%s "$TMPCHUNK" 2>/dev/null || echo 0)
        if [[ "$GOT" -eq "$THIS_CHUNK_BYTES" ]]; then
            cat "$TMPCHUNK" >> "$OUTPUT"
            sync "$OUTPUT"
            echo "  ok"
            CHUNK_OK=1
            break
        else
            echo "  size mismatch (got ${GOT}, expected ${THIS_CHUNK_BYTES})"
        fi

        # Reconnect before retrying
        echo "  [retry] reconnecting in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        adb_wait || { rm -f "$TMPCHUNK"; exit 1; }
    done

    rm -f "$TMPCHUNK"

    if [[ "$CHUNK_OK" -eq 0 ]]; then
        echo "FAILED after $MAX_RETRIES attempts at chunk $((i+1))."
        echo "Re-run to resume: $0 $REMOTE $OUTPUT"
        exit 1
    fi
done

echo ""
echo "Transfer complete. Verifying transport (transport-only -- NOT authenticity)..."
echo ""

echo -n "Remote SHA-256: "
REMOTE_SHA=$(timeout 120 $ADB shell "sha256sum $REMOTE_Q" 2>/dev/null | awk '{print $1}' | tr -d '\r')
echo "$REMOTE_SHA"

echo -n "Local SHA-256:  "
LOCAL_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}')
echo "$LOCAL_SHA"

echo ""
# This is a transport-corruption check, not a peer-authenticity check.
# Both hashes flow through the same ADB connection -- a hostile peer that
# served corrupt bytes could also lie about sha256sum. The output text
# below states this in-line so it can't be skimmed past.
if [[ "$REMOTE_SHA" = "$LOCAL_SHA" ]]; then
    echo "Hashes match -- transport-corruption check PASSED."
    echo ""
    echo "WARNING: this is NOT an authenticity check. Both hashes were"
    echo "produced over the same ADB channel; a hostile or compromised peer"
    echo "could have served corrupt bytes and lied about sha256sum to match."
    echo "Treat the pulled file as no more trustworthy than the device itself."
else
    echo "MISMATCH -- file is corrupted or the peer is misbehaving."
    echo "  Local size:  $(stat -c%s "$OUTPUT")"
    echo "  Remote size: $SIZE"
    exit 1
fi
