#!/usr/bin/env bash
# lib/diag.sh — 一键诊断（sb debug / 主页面选项 7）
# 目的：把定位“节点不通”所需的全部信息一次性收集齐，输出到终端并写入文件，
#       方便用户直接复制/上传给维护者。
# 约定：全程 best-effort，任何单项失败都不得中断整体（脚本处于 set -euo pipefail 下），
#       因此所有外部命令一律以 `|| true` 兜底；密码/UUID 一律脱敏后再输出。

DIAG_OUT="/etc/sing-box/diag.log"

# 小节标题
_d_sec() { printf '\n===== %s =====\n' "$*"; }

# 脱敏：把形如 "password": "xxx" / "uuid": "xxx" 的值替换为 ***
_d_mask() {
  sed -E 's/("(password|uuid)"[[:space:]]*:[[:space:]]*")[^"]*"/\1***"/g' 2>/dev/null || true
}

# 判断某端口是否处于监听状态。参数：tcp|udp port；返回 0=在监听
# 复用 core_listening_ports，避免依赖 ss 过滤器语法（不支持时会返回全部条目造成误判）
diag_port_listening() {
  local proto=$1 port=$2
  core_port_in_use "$port" "$proto"
}

# 以 singbox 用户身份测试文件可读性（服务以该用户运行，root 可读不代表服务可读）
diag_readable_as_singbox() {
  local f=$1
  id singbox >/dev/null 2>&1 || return 1
  if command -v runuser >/dev/null 2>&1; then
    runuser -u singbox -- test -r "$f" 2>/dev/null
  else
    su -s /bin/sh singbox -c "test -r '$f'" 2>/dev/null
  fi
}

diag_collect() {
  local now; now=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)
  echo "easy-singbox 诊断报告"
  echo "生成时间: $now"
  echo "脚本版本: v${SB_SCRIPT_VERSION:-?}"

  _d_sec "1. 系统与内核环境"
  core_detect_os 2>/dev/null || true
  echo "架构: $(uname -m 2>/dev/null || true)"
  echo "内核: $(uname -r 2>/dev/null || true)"
  echo "虚拟化: $(core_detect_virt 2>/dev/null || true)"
  # bindv6only=1 时 listen "::" 只监听 IPv6，IPv4 客户端会被“主动拒绝”
  echo "net.ipv6.bindv6only: $(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo '读取失败')"
  echo "sing-box 二进制: $([[ -x "$SB_BIN" ]] && "$SB_BIN" version 2>/dev/null | head -1 || echo '未安装')"

  _d_sec "2. 服务状态"
  echo "is-active : $(systemctl is-active sing-box 2>/dev/null || true)"
  echo "is-enabled: $(systemctl is-enabled sing-box 2>/dev/null || true)"
  systemctl status sing-box --no-pager -n 0 2>/dev/null | head -12 || true

  _d_sec "3. 服务日志（最近 80 行，含崩溃原因）"
  journalctl -u sing-box -n 80 --no-pager 2>/dev/null || echo "journalctl 不可用"

  _d_sec "4. 配置校验（sing-box check）"
  if [[ -x "$SB_BIN" && -f "$SB_CONF" ]]; then
    "$SB_BIN" check -c "$SB_CONF" 2>&1 && echo "check 通过" || echo "check 失败（见上方输出）"
  else
    echo "二进制或配置缺失：SB_BIN=$SB_BIN SB_CONF=$SB_CONF"
  fi

  _d_sec "5. 状态文件端口（凭证已脱敏）"
  if [[ -f "$SB_STATE" ]]; then
    sed -E 's/^(PASS_[A-Z0-9_]+|UUID_[A-Z0-9_]+|OBS_[A-Z0-9_]+)=.*/\1=***/' "$SB_STATE" 2>/dev/null || true
  else
    echo "状态文件不存在: $SB_STATE"
  fi

  _d_sec "6. 端口监听实况（关键：TCP 被“主动拒绝”通常=此处无监听）"
  echo "--- 全部监听套接字 ---"
  ss -lntup 2>/dev/null | grep -E 'sing-box|Netid|LISTEN|UNCONN' | head -40 || true
  if [[ -f "$SB_STATE" ]]; then
    # 子 shell 读取，避免污染当前环境变量
    (
      set +u
      . "$SB_STATE" 2>/dev/null || true
      echo "--- 按协议逐个核对 ---"
      # 缺少 ss 时监听集合为空，会把所有端口误报为“未监听”，必须显式区分，避免误导排查
      if ! command -v ss >/dev/null 2>&1; then
        echo "未安装 ss(iproute2)，无法核对监听状态；请先安装：apt install iproute2 / yum install iproute"
        exit 0
      fi
      if diag_port_listening tcp "${PORT_ANYTLS:-0}"; then
        echo "AnyTLS    tcp/${PORT_ANYTLS:-?} : 监听中"
      else
        echo "AnyTLS    tcp/${PORT_ANYTLS:-?} : [异常] 未监听 → 客户端必然报 connection refused"
      fi
      if diag_port_listening udp "${PORT_HY2_LISTEN:-${PORT_HY2:-0}}"; then
        echo "Hysteria2 udp/${PORT_HY2_LISTEN:-${PORT_HY2:-?}} : 监听中"
      else
        echo "Hysteria2 udp/${PORT_HY2_LISTEN:-${PORT_HY2:-?}} : [异常] 未监听"
      fi
      if diag_port_listening udp "${PORT_TUIC:-0}"; then
        echo "TUIC      udp/${PORT_TUIC:-?} : 监听中"
      else
        echo "TUIC      udp/${PORT_TUIC:-?} : [异常] 未监听"
      fi
    ) || true
  fi

  _d_sec "7. 本机自连测试（排除防火墙，仅验证进程是否在收）"
  if [[ -f "$SB_STATE" ]]; then
    (
      set +u
      . "$SB_STATE" 2>/dev/null || true
      local p="${PORT_ANYTLS:-}"
      if [[ -n "$p" ]]; then
        if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
          echo "127.0.0.1:$p (AnyTLS/tcp) 可连接 → 进程在收，问题在防火墙/安全组"
        else
          echo "127.0.0.1:$p (AnyTLS/tcp) 不可连接 → 进程没在收，问题在服务本身"
        fi
        # 显式测 IPv4 外部地址，验证 listen "::" 是否覆盖 IPv4
        local myip; myip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' || true)
        if [[ -n "$myip" ]]; then
          if timeout 3 bash -c "exec 3<>/dev/tcp/$myip/$p" 2>/dev/null; then
            echo "$myip:$p (本机 IPv4 地址) 可连接 → IPv4 栈正常"
          else
            echo "$myip:$p (本机 IPv4 地址) 不可连接 → 可能仅监听 IPv6（检查 bindv6only）或本机防火墙拦截"
          fi
        fi
      fi
    ) || true
  fi

  _d_sec "8. 防火墙规则"
  echo "--- 后端探测 ---"
  fw_detect 2>/dev/null || true
  echo "--- ufw ---"
  if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>/dev/null || true; else echo "未安装 ufw"; fi
  echo "--- firewalld ---"
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --state 2>/dev/null || true
    firewall-cmd --list-all 2>/dev/null || true
  else echo "未安装 firewalld"; fi
  echo "--- iptables INPUT 策略与规则 ---"
  iptables -S INPUT 2>/dev/null | head -40 || echo "iptables 不可用"
  echo "--- nftables ---"
  nft list ruleset 2>/dev/null | head -40 || echo "未安装 nft 或无规则"

  _d_sec "9. 端口跳跃 REDIRECT 规则"
  iptables -t nat -S PREROUTING 2>/dev/null | grep -i 'easy-singbox\|REDIRECT' || echo "iptables nat 无相关规则"
  nft list table ip easy_singbox 2>/dev/null || echo "nft 无 easy_singbox 表"

  _d_sec "10. 证书"
  ls -l "$SB_DIR_SSL" 2>/dev/null || echo "证书目录不存在: $SB_DIR_SSL"
  local fc="$SB_DIR_SSL/fullchain.pem" pk="$SB_DIR_SSL/privkey.pem"
  if [[ -f "$fc" ]]; then
    openssl x509 -in "$fc" -noout -subject -dates 2>/dev/null || true
    echo "SAN: $(openssl x509 -in "$fc" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ' || true)"
  else
    echo "缺少 fullchain.pem"
  fi
  # 服务以 singbox 用户运行，必须确认该用户可读证书与私钥
  for f in "$fc" "$pk" "$SB_CONF"; do
    if [[ -f "$f" ]]; then
      if diag_readable_as_singbox "$f"; then
        echo "singbox 用户可读: $f"
      else
        echo "[异常] singbox 用户不可读: $f → 服务会启动失败"
      fi
    fi
  done

  _d_sec "11. 域名解析与出口 IP"
  if [[ -f "$SB_STATE" ]]; then
    local d; d=$(grep -m1 '^DOMAIN=' "$SB_STATE" 2>/dev/null | cut -d= -f2 || true)
    echo "DOMAIN=$d"
    if [[ -n "$d" ]]; then
      echo "解析结果: $(getent hosts "$d" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
    fi
  fi
  echo "出口 IPv4: $(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || echo '获取失败')"
  echo "本机 IPv4: $(ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | tr '\n' ' ' || true)"

  _d_sec "12. config.json（凭证已脱敏）"
  if [[ -f "$SB_CONF" ]]; then
    _d_mask < "$SB_CONF" || true
  else
    echo "配置文件不存在: $SB_CONF"
  fi

  _d_sec "诊断结束"
  echo "如需更详细的运行日志，可执行 sb 选项 7 中的“切换 debug 日志级别”后复现问题再次诊断。"
}

# 主入口：收集 → 落盘 → 提示
diag_run() {
  core_root_check
  mkdir -p "$(dirname "$DIAG_OUT")" 2>/dev/null || true
  # 同时输出到终端与文件；诊断本身不得因单项失败而中断
  diag_collect 2>&1 | tee "$DIAG_OUT" || true
  chmod 600 "$DIAG_OUT" 2>/dev/null || true
  echo ""
  ok "诊断报告已保存到 $DIAG_OUT（凭证已脱敏，可直接复制发送）"
  info "查看：cat $DIAG_OUT    上传前请再次确认无敏感信息"
}

# 切换 sing-box 日志级别（info <-> debug），便于抓取更详细的运行日志
diag_toggle_log_level() {
  core_root_check
  [[ -f "$SB_CONF" ]] || { error "配置文件不存在: $SB_CONF"; return 1; }
  local cur target
  cur=$(grep -oE '"level"[[:space:]]*:[[:space:]]*"[a-z]+"' "$SB_CONF" 2>/dev/null | head -1 \
        | sed -E 's/.*"([a-z]+)"$/\1/' || true)
  [[ -z "$cur" ]] && cur="info"
  if [[ "$cur" == "debug" ]]; then target="info"; else target="debug"; fi
  sed -i -E "s/(\"level\"[[:space:]]*:[[:space:]]*\")[a-z]+(\")/\1${target}\2/" "$SB_CONF" 2>/dev/null || true
  if ! "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1; then
    error "修改后配置校验失败，请手动检查 $SB_CONF"
    return 1
  fi
  service_restart 2>/dev/null || true
  ok "日志级别已从 $cur 切换为 $target 并重启服务"
  info "复现问题后执行 sb → 选项 7 → 生成诊断报告，即可拿到详细日志"
}

# 诊断子菜单
diag_menu() {
  echo "诊断与日志："
  echo "  [1] 生成完整诊断报告（推荐，一次性收集所有排查信息）"
  echo "  [2] 查看实时日志（journalctl -f，Ctrl+C 退出）"
  echo "  [3] 切换 sing-box 日志级别（info <-> debug）"
  local c; c=$(core_prompt "选择" "1")
  case "$c" in
    2) journalctl -u sing-box -f --no-pager 2>/dev/null || true ;;
    3) diag_toggle_log_level || true ;;
    *) diag_run || true ;;
  esac
}
