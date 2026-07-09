#!/bin/bash
# Installs genPassphrase.sh system-wide as `genpassphrase`, alongside its wordlist.
#
#   /usr/local/bin/genpassphrase              - the executable
#   /usr/local/share/genpassphrase/wordlist.txt - the word dictionary
#
# Must be run as root (sudo ./install.sh) since it writes under /usr/local.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SOURCE_SCRIPT="$SCRIPT_DIR/genPassphrase.sh"
SOURCE_WORDLIST="$SCRIPT_DIR/wordlist.txt"

BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/genpassphrase"
BIN_NAME="genpassphrase"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this installer writes to $BIN_DIR and $SHARE_DIR, which require root." >&2
    echo "Re-run with: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    echo "Error: $SOURCE_SCRIPT not found" >&2
    exit 1
fi

if [[ ! -f "$SOURCE_WORDLIST" ]]; then
    echo "Error: $SOURCE_WORDLIST not found" >&2
    exit 1
fi

install -d -m 755 "$SHARE_DIR"
install -d -m 755 "$BIN_DIR"
install -m 644 "$SOURCE_WORDLIST" "$SHARE_DIR/wordlist.txt"
install -m 755 "$SOURCE_SCRIPT" "$BIN_DIR/$BIN_NAME"

echo "Installed:"
echo "  $BIN_DIR/$BIN_NAME"
echo "  $SHARE_DIR/wordlist.txt"
echo
echo "Run '$BIN_NAME --help' to get started (make sure $BIN_DIR is in your PATH)."
