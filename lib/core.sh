#!/usr/bin/env bash
# lib/core.sh — 工具函数、系统探测、日志、颜色
# 仅被 sb / install.sh source，不单独执行。

# ---------- 颜色（仅当输出到终端且 tput 可用时启用）----------
# 必须同时检测 tput：Alpine/BusyBox 默认无 ncurses（apk add ncurses 提供 tput），
# 缺失时静默降级为无色，绝不因颜色问题中断脚本（v1.2.1 修复）。
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RED=$(tput setaf 1 2>/dev/null || true); C_GRN=$(tput setaf 2 2>/dev/null || true)
  C_YEL=$(tput setaf 3 2>/dev/null || true); C_BLU=$(tput setaf 4 2>/dev/null || true)
  C_CYN=$(tput setaf 6 2>/dev/null || true); C_BOLD=$(tput bold 2>/dev/null || true)
  C_RST=$(tput sgr0 2>/dev/null || true)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BOLD=""; C_RST=""
fi

# ---------- 日志 ----------
info()  { printf '%s[INFO]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_YEL" "$C_RST" "$*"; }
error() { printf '%s[ERR ]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }

# ---------- 全局路径 ----------
SB_BIN="/usr/local/bin/sing-box"
SB_DIR_CONF="/etc/sing-box"
SB_CONF="$SB_DIR_CONF/config.json"
SB_DIR_SSL="$SB_DIR_CONF/ssl"
SB_STATE="$SB_DIR_CONF/.state"
SB_NODES="$SB_DIR_CONF/nodes.txt"
SB_CF_ENV="$SB_DIR_CONF/.cf.env"
SB_SERVICE="/etc/systemd/system/sing-box.service"
SB_SYMLINK="/usr/local/bin/sb"
ACME_HOME="$HOME/.acme.sh"

# ---------- 运行环境 ----------
core_root_check() {
  if [[ $EUID -ne 0 ]]; then
    error "本脚本必须以 root 身份运行（当前 EUID=$EUID）。请使用 sudo 或切换至 root 后重试。"
    exit 1
  fi
}

# ---------- 系统探测 ----------
core_detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${PRETTY_NAME:-$NAME $VERSION_ID}"
  else
    echo "unknown"
  fi
}

core_detect_arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) error "不支持的 CPU 架构: $m（仅支持 x86_64 / aarch64）"; exit 1 ;;
  esac
}

core_detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v; v=$(systemd-detect-virt 2>/dev/null) || v="none"
    [[ "$v" == "none" ]] && echo "物理机" || echo "$v"
  elif command -v virt-what >/dev/null 2>&1; then
    virt-what 2>/dev/null | head -1 || echo "unknown"
  else
    echo "unknown"
  fi
}

core_detect_bbr() {
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$cc" == *bbr* ]]; then
    echo "已开启 (bbr)"
  else
    echo "未开启 (${cc:-?})"
  fi
}

# 内部：查询 ipwho.is（HTTPS）并解析为 "国家/城市 / ISP"，失败返回 "未知/未知 / 未知"
_core_ipwho_query() {
  local ip=$1 geo region city isp
  geo=$(curl -s --max-time 6 "https://ipwho.is/$ip" || true)
  region=$(printf '%s' "$geo" | grep -o '"country":"[^"]*"'   | head -1 | sed 's/"country":"//;s/"$//' || true)
  city=$(printf '%s' "$geo"    | grep -o '"city":"[^"]*"'     | head -1 | sed 's/"city":"//;s/"$//' || true)
  isp=$(printf '%s' "$geo"     | grep -o '"isp":"[^"]*"'      | head -1 | sed 's/"isp":"//;s/"$//' || true)
  [[ -z "$region" ]] && region="未知"
  [[ -z "$city" ]]   && city="未知"
  [[ -z "$isp" ]]    && isp="未知"
  echo "$region/$city / $isp"
}

# 双栈公网 IP 与地理位置检测（精确到城市），返回两行：
#   IPv4 <ip> | <国家>/<城市> / <ISP>
#   IPv6 <ip> | <国家>/<城市> / <ISP>
# 某协议无公网出口时对应行显示"不支持（本机无公网 IPv4/IPv6）"。
# IPv4/IPv6 分别探测：api.ipify.org 仅返回 IPv4，api6.ipify.org 仅返回 IPv6。
# 安全要求：全部走 HTTPS（明文会泄露服务器公网 IP 且可被中间人篡改）。
core_detect_ip_region() {
  local v4 v6
  v4=$(curl -s --max-time 6 https://api.ipify.org || true)
  # v6 探测失败通常意味着本机无公网 IPv6，用短超时避免拖慢菜单
  v6=$(curl -s --max-time 4 --connect-timeout 2 https://api6.ipify.org || true)
  if [[ -n "$v4" ]]; then
    echo "IPv4 $v4 | $(_core_ipwho_query "$v4")"
  else
    echo "IPv4 不支持（本机无公网 IPv4）"
  fi
  if [[ -n "$v6" ]]; then
    echo "IPv6 $v6 | $(_core_ipwho_query "$v6")"
  else
    echo "IPv6 不支持（本机无公网 IPv6）"
  fi
}

# 返回 "installed|running|version|proto_count"
core_sb_status() {
  local installed running version proto
  if [[ -x "$SB_BIN" ]]; then installed="已安装"; else installed="未安装"; fi
  if service_is_active; then running="已运行"; else running="未运行"; fi
  if [[ -x "$SB_BIN" ]]; then
    version=$("$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}') || version="?"
  else
    version="-"
  fi
  if [[ -f "$SB_CONF" ]]; then
    proto=$(grep -o '"type": *"\(anytls\|hysteria2\|tuic\)"' "$SB_CONF" 2>/dev/null | wc -l)
  else
    proto=0
  fi
  echo "$installed|$running|$version|$proto"
}

# 确保 IPv6 双栈监听：“::” 在 net.ipv6.bindv6only=1 时只监听 IPv6，
# 导致 IPv4 客户端连接被“主动拒绝”(RST)，症状与“端口没监听”完全一致，
# 极难排查。Linux 默认该值为 0（双栈），但部分 VPS/容器镜像会设为 1。
# 此处强制置 0 并持久化，避免任何 TLS 入站无法被 IPv4 客户端访问。
core_ensure_dualstack() {
  local v; v=$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 0)
  if [[ "$v" != "0" ]]; then
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
  fi
  if [[ -d /etc/sysctl.d ]]; then
    printf 'net.ipv6.bindv6only=0\n' > /etc/sysctl.d/99-easy-singbox.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
  fi
}

# ---------- 随机工具 ----------
# 随机高位端口：动态私有端口段 49152-65535，避让 Hysteria2 跳跃段 50001-51000
# Hysteria2 端口跳跃默认保留段（随机端口不占用，避免冲突）
PORT_HOP_LO=50001
PORT_HOP_HI=51000

# 取监听端口集合，输出形如 " 22 80 443 " 的空格包裹串，便于纯 bash 子串精确匹配。
# 参数：proto 可选，tcp|udp，留空=两者都要。
#
# 实现要点（踩过的坑）：
# 1) 一次性取出全部监听端口，而非每个候选端口 fork 一次 ss，避免循环内进程风暴；
# 2) 绝不依赖 ss 的 `sport = :N` 过滤器语法——若该语法不被支持，ss 会返回全部条目，
#    导致“每个端口都判为占用”的静默失效（旧实现即因此完全失效）；
# 3) 固定使用 `-tu` 组合调用：此时 ss 输出带 Netid 列，本地地址恒为第 5 列。
#    若只传 -t，输出无 Netid 列、本地地址在第 4 列，按固定列取会错位。
core_listening_ports() {
  local proto=${1:-}
  command -v ss >/dev/null 2>&1 || { echo " "; return; }
  local list
  list=$(ss -lnHtu 2>/dev/null \
         | awk -v w="$proto" 'w=="" || $1==w {print $5}' \
         | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)
  echo " ${list} "
}

core_rand_port() {
  # 注：span 必须在 lo/hi 赋值后再计算，避免 bash 同条 local 内 RHS 提前展开导致 span 异常
  local lo=49152 hi=65535 span p tries=0 used
  span=$((hi - lo + 1))
  used=$(core_listening_ports)
  while (( ++tries <= 100 )); do
    p=$((RANDOM % span + lo))
    # 避让 Hysteria2 跳跃段
    (( p >= PORT_HOP_LO && p <= PORT_HOP_HI )) && continue
    # 纯 bash 子串匹配，循环内不再 fork
    [[ "$used" == *" $p "* ]] && continue
    echo "$p"; return 0
  done
  # 兜底：探测异常时直接返回一个高位随机端口，避免死循环卡死
  p=$((RANDOM % span + lo))
  echo "$p"
  return 0
}

core_rand_pass() {
  local len=${1:-16}
  # 注意：head -c 会提前关闭管道导致 tr 收到 SIGPIPE(141)；在 set -o pipefail 下
  # 整个管道返回非零，会触发 set -e 静默中止。末尾 || true 屏蔽 SIGPIPE。
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || true
}

core_rand_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z' || true
  else
    LC_ALL=C tr -dc '0-9a-f' </dev/urandom 2>/dev/null | head -c 32 | \
      sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/' || true
  fi
}

# ---------- 交互输入 ----------
# core_prompt <提示语> [默认值]，echo 出结果
# 提示必须用 read -e -p 交给 readline 管理（否则退格会越过输入删掉提示）；
# 同时把提示重定向到 stderr(1>&2)，避免被 $(core_prompt ...) 捕获进返回值。
# 颜色用 \001/\002 包裹，告知 readline 这些 ANSI 转义为不可见字符（zero-width）。
core_prompt() {
  local ans B N p
  B=$'\001\e[1m\002'; N=$'\001\e[0m\002'
  if [[ -n "${2:-}" ]]; then
    p="${B}${1}${N} [$2]: "
  else
    p="${B}${1}${N}: "
  fi
  read -e -r -p "$p" ans 1>&2 || ans=""
  if [[ -z "$ans" && -n "${2:-}" ]]; then ans="$2"; fi
  echo "$ans"
}

# core_prompt_yn <提示语>，返回 0=yes / 1=no（默认 no）
core_prompt_yn() {
  local ans B N
  B=$'\001\e[1m\002'; N=$'\001\e[0m\002'
  read -e -r -p "${B}${1}${N} [y/N]: " ans 1>&2 || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# 检测端口是否已被监听占用；参数：port [tcp|udp]；返回 0=占用，1=空闲/无法探测
# 复用 core_listening_ports 做精确匹配，不依赖 ss 过滤器语法。
core_port_in_use() {
  local p=$1 proto=${2:-} used
  used=$(core_listening_ports "$proto")
  [[ "$used" == *" $p "* ]]
}
