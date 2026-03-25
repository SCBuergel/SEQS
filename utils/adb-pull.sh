#!/bin/bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
ADB_DIR=~/platform-tools
ADB="$ADB_DIR/adb"
ADB_ZIP_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
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

if [[ -d "$OUTPUT" ]]; then
    OUTPUT="$OUTPUT/$(basename "$REMOTE")"
fi

# ─── Install dependencies if missing ────────────────────────────────────────

install_adb() {
    echo "ADB not found at $ADB. Installing latest platform-tools..."
    local zip_path
    zip_path=$(mktemp /tmp/platform-tools-XXXXXX.zip)

    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required to download platform-tools."
        exit 1
    fi

    echo "Downloading from $ADB_ZIP_URL ..."
    curl -fL -o "$zip_path" "$ADB_ZIP_URL"

    if ! command -v unzip &>/dev/null; then
        echo "ERROR: unzip is required to extract platform-tools."
        rm -f "$zip_path"
        exit 1
    fi

    echo "Extracting to $HOME ..."
    unzip -o -q "$zip_path" -d "$HOME"
    rm -f "$zip_path"

    if [[ ! -x "$ADB" ]]; then
        echo "ERROR: Installation failed — $ADB not found after extraction."
        exit 1
    fi

    echo "ADB installed: $($ADB --version | head -1)"
    echo ""
}

install_pv() {
    echo "Installing 'pv' (pipe viewer) for progress bars..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y pv
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y pv
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm pv
    else
        echo "WARNING: Could not auto-install pv — unknown package manager."
        echo "         Install it manually for per-chunk progress bars."
        return 1
    fi
}

[[ ! -x "$ADB" ]] && install_adb

if ! command -v pv &>/dev/null; then
    install_pv || true
fi

# ─── Saved device connection ────────────────────────────────────────────────
# Reads saved IP:port from ~/.adb-pull-device so you don't re-enter it each run.

load_saved_device() {
    if [[ -f "$CONNECTION_FILE" ]]; then
        cat "$CONNECTION_FILE"
    fi
}

save_device() {
    echo "$1" > "$CONNECTION_FILE"
}

# ─── Connection helpers ─────────────────────────────────────────────────────

# Prompt for IP:port (pre-filled with saved value) and optionally pair
adb_connect_prompt() {
    local saved ip port target
    saved=$(load_saved_device)

    if [[ -n "$saved" ]]; then
        echo "Last device: $saved"
        read -rp "Device IP:port [$saved]: " target
        target="${target:-$saved}"
    else
        read -rp "Device IP address: " ip
        read -rp "Port [5555]: " port
        port="${port:-5555}"
        target="$ip:$port"
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

# Try reconnecting to saved device silently, return 0 on success
adb_reconnect_saved() {
    local saved
    saved=$(load_saved_device)
    [[ -z "$saved" ]] && return 1
    timeout "$ADB_TIMEOUT" $ADB connect "$saved" &>/dev/null || true
    $ADB devices 2>/dev/null | grep -q 'device$'
}

# Check for connected device; auto-reconnect or prompt as needed
adb_wait() {
    # Already connected?
    if $ADB devices 2>/dev/null | grep -q 'device$'; then
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

# ─── Get remote file size ────────────────────────────────────────────────────
SIZE=$(timeout "$ADB_TIMEOUT" $ADB shell stat -c%s "$REMOTE" 2>/dev/null | tr -d '\r')
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
                $ADB exec-out "dd if='$REMOTE' bs=1M skip=$SKIP count=$THIS_CHUNK_MB 2>/dev/null" 2>/dev/null \
                | pv -s "$THIS_CHUNK_BYTES" -p -t -e -r \
                > "$TMPCHUNK"; then
                echo "  adb/timeout error"
            fi
        else
            if ! timeout "$CHUNK_TIMEOUT" \
                $ADB exec-out "dd if='$REMOTE' bs=1M skip=$SKIP count=$THIS_CHUNK_MB 2>/dev/null" \
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
echo "Transfer complete. Verifying checksums..."
echo ""

echo -n "Remote SHA-256: "
REMOTE_SHA=$(timeout 120 $ADB shell sha256sum "$REMOTE" 2>/dev/null | awk '{print $1}' | tr -d '\r')
echo "$REMOTE_SHA"

echo -n "Local SHA-256:  "
LOCAL_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}')
echo "$LOCAL_SHA"

echo ""
if [[ "$REMOTE_SHA" = "$LOCAL_SHA" ]]; then
    echo "MATCH — transfer verified successfully."
else
    echo "MISMATCH — file may be corrupted."
    echo "  Local size:  $(stat -c%s "$OUTPUT")"
    echo "  Remote size: $SIZE"
    exit 1
fi
