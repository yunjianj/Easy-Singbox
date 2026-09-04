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
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  if [[ "$cc" == *bbr* && "$qd" == "fq" ]]; then
    echo "已开启 (bbr + fq)"
  elif [[ "$cc" == *bbr* ]]; then
    echo "已开启 (bbr, qdisc=$qd)"
  else
    echo "未开启 (${cc:-?})"
  fi
}

# 内部：查询 ipwho.is（HTTPS）并解析为 "国家/城市 / ISP"，失败返回 "未知/未知 / 未知"
_core_ipwho_query() {
  local ip=$1 geo region city isp url
  # IPv6 地址含冒号，部分 curl 版本/HTTP 代理会把 URL 路径中的裸冒号误当 port
  # 分隔符导致请求失败（实测 IPv6 全返回"未知"），故统一 percent-encode（RFC 3986
  # 保留字符应编码；IPv4 无冒号，编码后与原 URL 等价）。
  url="https://ipwho.is/${ip//:/%3A}"
  geo=$(curl -s --max-time 6 "$url" || true)
  # ipwho.is 对部分来源返回 pretty-printed JSON（"country": "值" 冒号后有空格、字段换行），
  # 解析必须兼容紧凑与美化两种格式，故冒号两侧允许空白。
  region=$(printf '%s' "$geo" | grep -oE '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  city=$(printf '%s' "$geo"    | grep -oE '"city"[[:space:]]*:[[:space:]]*"[^"]*"'     | head -1 | sed -E 's/.*"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  isp=$(printf '%s' "$geo"     | grep -oE '"isp"[[:space:]]*:[[:space:]]*"[^"]*"'      | head -1 | sed -E 's/.*"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  [[ -z "$region" ]] && region="未知"
  [[ -z "$city" ]]   && city="未知"
  [[ -z "$isp" ]]    && isp="未知"
  echo "$region/$city / $isp"
}

# 内部：判断本机是否有 IPv6 出网能力（IPv6 默认路由，或全局作用域 IPv6 地址含 ULA）。
# 注意：ULA（fd00::/7，如 LXC 容器默认的 fd66:...）也算"有 IPv6"，因为它说明 IPv6
# 栈已启用、且宿主可能通过 NAT66 提供出网——不能仅凭"无 2000::/3 地址"就判不支持。
_core_has_ipv6() {
  ip -6 route show default 2>/dev/null | grep -q default || \
  ip -6 addr show scope global 2>/dev/null | grep -q inet6
}

# 内部：多服务探测公网 IPv6 地址（curl -6 强制 IPv6 栈）。
# 依次尝试 api6.ipify.org / v6.ident.me（均为纯 IPv6 HTTPS 端点），单服务失败或超时
# 自动降级下一个；全部失败返回 1。IPv4 机器 _core_has_ipv6 为假时不进入本函数。
_core_probe_v6() {
  local url ip
  for url in "https://api6.ipify.org" "https://v6.ident.me"; do
    ip=$(curl -6 -s --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
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
  if [[ -n "$v4" ]]; then
    echo "IPv4 $v4 | $(_core_ipwho_query "$v4")"
  else
    echo "IPv4 不支持（本机无公网 IPv4）"
  fi
  # 本机完全没有 IPv6（无地址/无路由）时直接判不支持，零网络开销；
  # 有 IPv6 但公网探测失败时给出区分文案（可能宿主缺 NAT66/路由，而非"不支持"）。
  if _core_has_ipv6; then
    v6=$(_core_probe_v6)
    if [[ -n "$v6" ]]; then
      echo "IPv6 $v6 | $(_core_ipwho_query "$v6")"
    else
      echo "IPv6 探测失败（本机存在 IPv6 地址，但无法访问公网 IPv6——检查宿主/上游 IPv6 路由、NAT66 或安全组）"
    fi
  else
    echo "IPv6 不支持（本机无公网 IPv6）"
  fi
}

# 返回 sing-box 版本号（如 1.14.0）。未安装或无法探测时输出空并返回 1。
# 用纯 shell 取第 3 字段（sing-box version 首行形如 "sing-box version 1.14.0"，
# 版本号是第 3 个词，源码见 cmd/sing-box/cmd_version.go），不依赖 awk——部分环境
# （Windows Git Bash 的 MSYS gawk 等）下 "子进程输出 | awk" 管道可能取不到数据。
core_sb_ver() {
  [[ -x "$SB_BIN" ]] || return 1
  local line v
  line=$("$SB_BIN" version 2>/dev/null | head -1) || return 1
  # 有意的未加引号分词（IFS 空白）
  # shellcheck disable=SC2086
  set -- $line
  v=${3:-}
  [[ -n "$v" ]] && echo "$v" || return 1
}

# 语义化版本比较：cur >= target 返回 0，否则返回 1；空/非法版本按 0.0.0 处理。
# 兼容 Alpine busybox（无 sort -V），纯数字分段比较。
core_ver_ge() {
  local cur=${1:-0} tgt=${2:-0} i a b
  local -a ca ta
  IFS='.' read -r -a ca <<< "${cur//[^0-9.]/}"
  IFS='.' read -r -a ta <<< "${tgt//[^0-9.]/}"
  for i in 0 1 2; do
    a=${ca[$i]:-0}; b=${ta[$i]:-0}
    (( a > b )) && return 0
    (( a < b )) && return 1
  done
  return 0
}

# 输出大版本族（major.minor，如 1.14），用于判断"大版本切换"（1.13 -> 1.14 等）。
# 纯 shell 实现（兼容 busybox），去掉 -beta1/+build 与非法字符；
# 空或无法解析的版本输出空并返回 1。
core_ver_family() {
  local v=$1 maj minor
  [[ -n "$v" ]] || return 1
  v=${v%%[-+]*}                    # 去掉 -beta1 / +build 后缀
  v=${v//[^0-9.]/}                 # 只保留数字与点
  maj=${v%%.*}; [[ -n "$maj" ]] || return 1
  minor=${v#*.}; minor=${minor%%.*}
  [[ -n "$minor" ]] || return 1
  echo "$maj.$minor"
}

# 返回 "installed|running|version|proto_count"
core_sb_status() {
  local installed running version proto
  if [[ -x "$SB_BIN" ]]; then installed="已安装"; else installed="未安装"; fi
  if service_is_active; then running="已运行"; else running="未运行"; fi
  version=$(core_sb_ver) || version="-"; [[ -n "$version" ]] || version="?"
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
    # 只应用本脚本自己的配置文件。`sysctl --system` 会按序重放 /run/sysctl.d/、
    # /etc/sysctl.d/、/usr/lib/sysctl.d/、/etc/sysctl.conf 全部配置，可能把其中
    # 的 net.ipv4.ip_forward=0 重新应用，覆盖 Docker 守护进程运行时设置的 1，
    # 导致同一宿主机上所有容器出站流量超时（重启后才恢复）。sysctl -p 指定文件
    # 只应用该文件，行为等价满足持久化 bindv6only=0，且不触碰任何其他内核参数。
    sysctl -p /etc/sysctl.d/99-easy-singbox.conf >/dev/null 2>&1 || true
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

# ---------- ss 不可用时的回退 ----------
# 直读 /proc/net/{tcp,tcp6,udp,udp6} 提取监听端口。
# 存在意义：Alpine / 精简容器常无 iproute2（ss），且 apk 安装也可能失败；
# 若此时直接放弃端口校验，就无法区分"服务根本没监听"与"只是防火墙/安全组拦截"，
# 而这两种故障的排查方向完全相反。只要有 procfs 就能得到结论，零依赖。
#
# 判定规则：
#   TCP —— 仅取 state=0A(LISTEN) 的行；
#   UDP —— 无 LISTEN 状态，socket 存在即视为在监听（含未连接的 UDP 套接字）。
# 端口在 /proc 中是 4 位十六进制（如 1F90=8080），用 bash 内建 $((16#..)) 转换：
# busybox awk 没有 strtonum()，不能靠 awk 做十六进制转换。
_core_ports_from_proc() {
  local proto=${1:-} f files is_udp out="" la st hex port
  case "$proto" in
    tcp) files="/proc/net/tcp /proc/net/tcp6" ;;
    udp) files="/proc/net/udp /proc/net/udp6" ;;
    *)   files="/proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6" ;;
  esac
  for f in $files; do
    [[ -r "$f" ]] || continue
    is_udp=0; [[ "$f" == *udp* ]] && is_udp=1
    # 列序：sl local_address rem_address st ...
    while read -r _ la _ st _; do
      [[ "$la" == *:* ]] || continue
      if (( ! is_udp )); then
        # 状态列大小写都按大写比对（内核输出为大写 0A）
        [[ "${st^^}" == "0A" ]] || continue
      fi
      hex=${la##*:}
      [[ "$hex" =~ ^[0-9A-Fa-f]+$ ]] || continue
      port=$((16#$hex)) 2>/dev/null || continue
      out="$out$port "
    done < <(tail -n +2 "$f" 2>/dev/null)
  done
  echo " $out "
}

core_listening_ports() {
  local proto=${1:-}
  if command -v ss >/dev/null 2>&1; then
    local list
    list=$(ss -lnHtu 2>/dev/null \
           | awk -v w="$proto" 'w=="" || $1==w {print $5}' \
           | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)
    echo " ${list} "
    return
  fi
  # 无 ss 时不再返回空集（空集会让所有端口被误判为"未监听"），改用 /proc 回退
  _core_ports_from_proc "$proto"
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

# 检测并按发行版自动安装基础依赖（安装 sing-box 前调用，幂等）：
#
#   【必需】curl    —— 下载，缺失则无法获取 sing-box
#   【必需】openssl —— acme.sh 生成密钥的硬依赖
#   【可选】ss（包名 iproute2 / iproute2-ss / iproute）—— 端口监听校验。
#            缺失时有 /proc/net 回退方案，不阻断安装。
#   【可选】iptables/nftables —— 端口跳跃 REDIRECT 后端。
#            缺失时端口跳跃降级（config_gen 会自动移除 HOP_HY2），不阻断安装。
#
# 返回 0=必需依赖就绪（可选依赖缺失只警告）；1=必需依赖安装后仍不可用。
# 注意：本函数被 sb_install 以 "core_ensure_deps || return 1" 调用，
# 因此绝不能因可选依赖缺失就返回 1——那会在精简系统上直接中止安装。
core_ensure_deps() {
  local missing=() apk_pkgs="" apt_pkgs="" yum_pkgs="" n
  command -v curl >/dev/null 2>&1 || { missing+=(curl);      apk_pkgs="$apk_pkgs curl";      apt_pkgs="$apt_pkgs curl";      yum_pkgs="$yum_pkgs curl"; }
  command -v openssl >/dev/null 2>&1 || { missing+=(openssl); apk_pkgs="$apk_pkgs openssl"; apt_pkgs="$apt_pkgs openssl"; yum_pkgs="$yum_pkgs openssl"; }
  # ss —— 端口监听校验的必需工具，单独判断，不能与 ip 合并成"两者皆缺"：
  # Alpine 的 busybox 自带 ip，但默认没有 ss，且 Alpine 3.21+ 把 ss 拆到独立
  # 子包 iproute2-ss。旧逻辑（ss 与 ip 皆缺才算缺失）导致 Alpine 上永远跳过安装，
  # 端口监听校验随之被整体跳过，无法区分"服务没监听"与"防火墙拦截"。
  if ! command -v ss >/dev/null 2>&1; then
    missing+=(ss); apk_pkgs="$apk_pkgs iproute2"; apt_pkgs="$apt_pkgs iproute2"; yum_pkgs="$yum_pkgs iproute"
  fi
  # 端口跳跃后端（iptables 或 nftables 任一即可）
  if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
    missing+=(iptables); apk_pkgs="$apk_pkgs iptables"; apt_pkgs="$apt_pkgs iptables"; yum_pkgs="$yum_pkgs iptables"
  fi
  [[ ${#missing[@]} -eq 0 ]] && return 0

  info "检测到缺失依赖: ${missing[*]}，正在安装..."
  if command -v apk >/dev/null 2>&1; then
    # 逐个安装而非整批：apk 是原子操作，一批包里只要有一个不存在（Alpine 各
    # 分支包名差异大，如 iptables / iproute2-ss）就会导致整批失败，连能装的
    # 包也一起装不上——这正是 Alpine 上"依赖安装失败"的常见根因。
    local p
    for p in $apk_pkgs; do
      apk add --no-cache "$p" >/dev/null 2>&1 || true
    done
    # Alpine 3.21+ 将 ss 拆为独立子包 iproute2-ss（provides cmd:ss），
    # 主包不含时单独补装，否则 ss 仍会缺失。
    if [[ " $apk_pkgs " == *" iproute2 "* ]] && ! command -v ss >/dev/null 2>&1; then
      apk add --no-cache iproute2-ss >/dev/null 2>&1 || true
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $apt_pkgs >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q $yum_pkgs >/dev/null 2>&1 || true
  else
    warn "无法识别的包管理器，请手动安装: ${missing[*]}"
    return 1
  fi
  # 复查：区分必需（curl/openssl）与可选（ss/iptables），可选缺失只警告
  local still=() opt_still=()
  for n in "${missing[@]}"; do
    case "$n" in
      ss) command -v ss >/dev/null 2>&1 || opt_still+=("$n") ;;
      iptables) command -v iptables >/dev/null 2>&1 || command -v nft >/dev/null 2>&1 || opt_still+=("$n") ;;
      *) command -v "$n" >/dev/null 2>&1 || still+=("$n") ;;
    esac
  done
  if [[ ${#opt_still[@]} -gt 0 ]]; then
    warn "以下可选依赖不可用: ${opt_still[*]}（不影响安装，相关功能会自动降级）"
    if command -v apk >/dev/null 2>&1; then
      warn "Alpine 可尝试: apk add iproute2 iproute2-ss iptables"
    fi
    warn "ss 缺失时端口监听校验改用 /proc/net 回退；iptables 缺失时端口跳跃不启用"
  fi
  if [[ ${#still[@]} -gt 0 ]]; then
    error "以下必需依赖安装后仍不可用: ${still[*]}（请手动安装）"
    return 1
  fi
  if [[ ${#opt_still[@]} -eq 0 ]]; then
    ok "依赖已就绪: ${missing[*]}"
  else
    ok "必需依赖已就绪（${opt_still[*]} 缺失，相关功能已降级）"
  fi
}

# 内部：计算文件的 git blob SHA1——与 GitHub API 返回的 blob sha 同算法：
#   sha1("blob <字节数>\0" + 文件内容)
# 用于把本地文件与 GitHub 官方记录逐字节比对（供应链完整性校验）。
# 失败（缺 sha1sum/shasum）返回 1；成功打印 40 位十六进制摘要。
_core_blob_sha1() {
  local f=$1 len tool
  [[ -f "$f" ]] || return 1
  if command -v sha1sum >/dev/null 2>&1; then
    tool="sha1sum"
  elif command -v shasum >/dev/null 2>&1; then
    tool="shasum -a 1"
  else
    return 1
  fi
  len=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$len" ]] || return 1
  { printf 'blob %s\0' "$len"; cat "$f"; } | $tool 2>/dev/null | awk '{print $1}'
}

# 校验仓库源码内容完整性（供应链防护，对应安全审计 1.1）：
# 此前只校验"文件在不在"（齐套检查），无法发现"结构相同、内容被整体替换"的投毒。
# 现以 GitHub git trees API 返回的各文件官方 blob SHA1 为锚点，逐文件比对本地内容，
# 实现真正的内容级完整性校验。
#
# 用法：core_verify_repo_files <解压目录> <相对路径1> [相对路径2 ...]
# 返回：0=全部校验通过；1=发现内容不一致（疑似投毒，调用方必须中止）；
#       2=无法获取/解析官方校验值（API 不可达、数据不全或缺 sha1 工具）——
#         属"无法校验"而非"校验失败"，由调用方决定是否降级继续，绝不静默通过。
core_verify_repo_files() {
  local dir=$1; shift
  local tree_json map f want got cnt=0
  tree_json=$(curl -fsSL --retry 2 --max-time 25 \
    "https://api.github.com/repos/yunjianj/Easy-Singbox/git/trees/main?recursive=1" 2>/dev/null || true)
  # 以下用显式 if 而非 `[[ ]] && return`：set -e 下后者在条件不成立时整条语句
  # 返回非零会触发退出（除非调用方用 || 包裹），显式 if 无此风险。
  if [[ -z "$tree_json" ]]; then return 2; fi
  # GitHub API 返回美化 JSON（字段分行），按 path → type → sha 顺序解析出 blob 映射；
  # 首个 sha 是树对象自身的摘要（此时 p 为空），会被 p != "" 条件自然跳过。
  map=$(printf '%s' "$tree_json" | awk '
    /"path":/ { p=$0; gsub(/.*"path": *"|",?$/,"",p); next }
    /"type":/ { t=$0; gsub(/.*"type": *"|",?$/,"",t); next }
    /"sha":/ && p != "" { s=$0; gsub(/.*"sha": *"|",?$/,"",s)
                          if (t=="blob" && s ~ /^[0-9a-f]{40}$/) print p" "s; p=""; t=""; next }
  ' || true)
  if [[ -z "$map" ]]; then return 2; fi
  for f in "$@"; do
    want=$(printf '%s\n' "$map" | grep -m1 "^${f} " | awk '{print $2}' || true)
    if [[ -z "$want" ]]; then return 2; fi
    got=$(_core_blob_sha1 "$dir/$f" || true)
    if [[ -z "$got" ]]; then return 2; fi
    if [[ "$got" != "$want" ]]; then
      warn "内容校验不符: $f（官方 ${want:0:12}… 实际 ${got:0:12}…）"
      return 1
    fi
    cnt=$((cnt+1))
  done
  if [[ $cnt -eq 0 ]]; then return 2; fi
  return 0
}
