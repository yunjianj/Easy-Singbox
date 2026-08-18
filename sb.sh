#!/usr/bin/env bash
# sb.sh — 一键引导脚本（可独立运行）
#   bash <(wget -qO- https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)
# 若自身已位于仓库目录（含 install.sh），直接运行；否则下载仓库后运行 install.sh。
set -euo pipefail

REPO="yunjianj/Easy-Singbox"
BRANCH="main"
SELF="${BASH_SOURCE[0]:-$0}"

# 通过进程替换/管道运行（如 bash <(wget ...)）时，SELF 为伪路径
# （/dev/fd/63、/proc/PID/fd/63、/dev/stdin），无法据此定位仓库目录，
# 直接走下载分支，避免 readlink/cd 解析伪路径失败。
case "$SELF" in
  /dev/fd/*|/proc/*|/dev/stdin|-) SELF_DIR="" ;;
  *) SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || SELF_DIR="" ;;
esac

# 自身位于真实仓库目录（含 install.sh）：直接运行，避免重复下载
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/install.sh" ]]; then
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
