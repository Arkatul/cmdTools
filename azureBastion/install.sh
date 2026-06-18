#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${INSTALL_DIR}/azureBastionSsh"

install -D -m 755 "${SCRIPT_DIR}/azureBastionSsh.sh" "${TARGET}"
printf "Installed: %s\n" "${TARGET}"

if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
    printf "Note: '%s' is not in your PATH.\n" "${INSTALL_DIR}"
    printf "Add this to your shell config:  export PATH=\"%s:\$PATH\"\n" "${INSTALL_DIR}"
fi
