#!/usr/bin/env bash
# uninstall.sh — 独立卸载入口
set -euo pipefail
SB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec bash "$SB_DIR/sb" uninstall
