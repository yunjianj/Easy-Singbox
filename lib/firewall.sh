#!/usr/bin/env bash
# lib/firewall.sh — 防火墙：**只读探测 + 临时放行 80 + 显式关闭**，不做自动端口放行
#
# v1.6.0 起的边界（重要，勿回退）：
# 本脚本**不再自动开放任何节点端口**，防火墙完全交由用户自行配置。
# 原因：自动改防火墙在 1Panel / Docker / firewalld 等同机环境下极易与用户自己的
# 管理冲突（对方的规则被 flush、或本脚本的规则被对方冲掉），且"自动放行"给的
# 是虚假的安全感——云安全组/上游防火墙仍需手动配置。
# 因此这里只保留三件事：
#   1) fw_detect      —— 只读探测后端，供诊断报告展示现状
#   2) fw_open_http_temp / fw_close_http_temp —— HTTP-01 签发期临时放行 80 并收回
#      （这是签发必需且会自动回收的最小动作，与"长期开放节点端口"性质不同）
#   3) fw_disable     —— 供主菜单「一键关闭防火墙」显式调用（用户主动要求）

FW_BACKEND=""

# 探测可用后端，结果存入 FW_BACKEND
# 重要：仅当 ufw 处于 active 时才选 ufw 后端。若 ufw 已安装但 inactive，
# 一律回退到 iptables（只影响 fw_disable 的收尾动作；探测本身不改任何规则）。
fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    FW_BACKEND="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && service_is_active firewalld 2>/dev/null; then
    FW_BACKEND="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    FW_BACKEND="iptables"
  else
    FW_BACKEND="none"
  fi
  echo "$FW_BACKEND"
}

# ---------- HTTP-01 签发期的 80 临时放行（唯一保留的改规则路径）----------
# acme.sh --standalone 需要 80 端口可达；签发完成（含失败路径）后立即收回。
# ufw 没有临时规则概念，两种情况都退回 iptables 追加式 ACCEPT —— 该规则不带
# --permanent，ufw disable 或重启后自然消失，不会污染用户的永久策略。
fw_open_http_temp() {
  iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
}

fw_close_http_temp() {
  iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
}

# ---------- 显式关闭防火墙（仅主菜单「一键关闭防火墙」调用）----------
# 注意 iptables 分支会 `iptables -F INPUT`：**清空整条 INPUT 链**，
# 其中可能包含用户自己写的规则（不只是本脚本的）。调用方必须先明确警告。
fw_disable() {
  case "$FW_BACKEND" in
    ufw)       ufw disable >/dev/null 2>&1 || true ;;
    firewalld)
      if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service firewalld stop 2>/dev/null || true
        rc-update del firewalld default 2>/dev/null || true
      else
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
      fi
      ;;
    iptables)  iptables -P INPUT ACCEPT 2>/dev/null || true; iptables -F INPUT 2>/dev/null || true ;;
    none)      : ;;
  esac
}

# ---------- 端口清单（只读打印，不改任何规则）----------
# v1.6.0 起安装/变更时替代原来的「端口开放三选一」：脚本不再动防火墙，
# 改为把用户需要自行放行的端口明确列出来（含云安全组与跳跃段）。
# 参数：p_any p_hy2 p_tuic p_socks [hop_hy2]；未启用协议的端口传空串自动跳过。
fw_print_port_checklist() {
  local p_any=$1 p_hy2=$2 p_tuic=$3 p_socks=${4:-} hop=${5:-}
  # 端口列宽固定 12，跳跃段（50001-51000 共 11 字符）也能对齐
  local items=""
  [[ -n "$p_any" ]]   && items="${items}  TCP  $(printf '%-12s' "$p_any")AnyTLS\n"
  [[ -n "$p_hy2" ]]   && items="${items}  UDP  $(printf '%-12s' "$p_hy2")Hysteria2\n"
  [[ -n "$p_tuic" ]]  && items="${items}  UDP  $(printf '%-12s' "$p_tuic")TUIC v5\n"
  # SOCKS5 只列 TCP：其 UDP ASSOCIATE 走内核随机分配的临时高位端口（非本端口），
  # 放行本端口的 udp 是空规则。需要 UDP 的流量请走 Hysteria2 / TUIC。
  [[ -n "$p_socks" ]] && items="${items}  TCP  $(printf '%-12s' "$p_socks")SOCKS5（明文，仅 TCP）\n"
  echo ""
  info "本脚本不再自动修改防火墙。请自行在【云安全组 / 上游防火墙】放行以下端口："
  printf "%b" "$items"
  [[ -n "$hop" ]] && echo "  UDP  $(printf '%-12s' "$hop")Hysteria2 端口跳跃段（客户端 mport 在此段内跳变，必须整段放行）"
  echo "  TCP  $(printf '%-12s' 22)SSH（若你启用防火墙，务必先放行 22，否则会把自己锁在门外）"
  echo ""
  warn "本机防火墙（ufw/firewalld/iptables）与云安全组是两套独立机制，都需放行才生效；"
  warn "若不确定如何配置，可在主菜单执行 [11] 一键关闭防火墙（会暴露所有端口，含 SSH）。"
  if [[ -n "$hop" ]]; then
    warn "已启用 Hysteria2 端口跳跃（$hop）：本机只需放行基础端口 $p_hy2（跳跃段由 REDIRECT 自动转发），"
    warn "  但客户端向整个 UDP $hop 范围随机发包，云安全组/上游防火墙必须放行该整段，否则 Hy2 报超时。"
  fi
}