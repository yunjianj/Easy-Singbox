#!/usr/bin/env bash
# sb.sh — 一键引导脚本（可独立运行）
#   bash <(wget -qO- https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)
# 若自身已位于仓库目录（含 install.sh），直接运行；否则下载仓库后运行 install.sh。
set -euo pipefail

REPO="yunjianj/Easy-Singbox"
BRANCH="main"
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$(readlink -f "$SELF")")" && pwd)"

# 已在仓库目录内：直接运行本地 install.sh，避免重复下载
if [[ -f "$SELF_DIR/install.sh" ]]; then
  cd "$SELF_DIR"
  exec bash ./install.sh "$@"
fi

echo "==> 下载 Easy-Singbox ($BRANCH) ..."
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP/esb.tar.gz"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP/esb.tar.gz" "$URL"
else
  echo "需要 curl 或 wget 才能下载，请先安装其一" >&2
  exit 1
fi

echo "==> 解压 ..."
tar -xzf "$TMP/esb.tar.gz" -C "$TMP"
DIR="$(find "$TMP" -maxdepth 1 -type d -name 'Easy-Singbox-*' | head -1)"
if [[ -z "$DIR" || ! -f "$DIR/install.sh" ]]; then
  echo "解压失败或未找到 install.sh" >&2
  exit 1
fi

cd "$DIR"
exec bash ./install.sh "$@"
