#!/usr/bin/env bash
# lib/firewall.sh — 防火墙后端适配（ufw → firewalld → iptables）
# 端口开放三选一：1 全部(80+节点) / 2 仅节点端口 / 3 不开放
# HTTP-01 模式下即使选 2/3 也需临时放行 80，完成后回收。

FW_BACKEND=""

# 探测可用后端，结果存入 FW_BACKEND
fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
    FW_BACKEND="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    FW_BACKEND="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    FW_BACKEND="iptables"
  else
    FW_BACKEND="none"
  fi
  echo "$FW_BACKEND"
}

# 开放端口（临时或永久）。proto: tcp|udp；port: 数字
fw_open_port() {
  local proto=$1 port=$2 perm=${3:-permanent}
  case "$FW_BACKEND" in
    ufw)
      if [[ "$perm" == "temp" ]]; then
        # ufw 无临时规则概念，用 iptables 兜底
        iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
      else
        ufw allow "$port/$proto" >/dev/null 2>&1 || true
      fi
      ;;
    firewalld)
      if [[ "$perm" == "temp" ]]; then
        firewall-cmd --add-port="$port/$proto" 2>/dev/null || true
      else
        firewall-cmd --permanent --add-port="$port/$proto" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
      fi
      ;;
    iptables)
      iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
      ;;
    none)
      : # 无防火墙后端，跳过
      ;;
  esac
}

# 关闭临时端口（仅对 iptables/firewalld temp 生效）
fw_close_temp_port() {
  local proto=$1 port=$2
  case "$FW_BACKEND" in
    ufw)       iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true ;;
    firewalld) firewall-cmd --remove-port="$port/$proto" 2>/dev/null || true ;;
    iptables)  iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true ;;
  esac
}

# 开放端口段（如 50001-51000），用于 Hysteria2 端口跳跃。proto: tcp|udp；range: lo-hi
fw_open_range() {
  local proto=$1 range=$2 perm=${3:-permanent}
  case "$FW_BACKEND" in
    ufw)
      if [[ "$perm" == "temp" ]]; then
        iptables -I INPUT -p "$proto" --dport "$range" -j ACCEPT 2>/dev/null || true
      else
        ufw allow "$range/$proto" >/dev/null 2>&1 || true
      fi
      ;;
    firewalld)
      if [[ "$perm" == "temp" ]]; then
        firewall-cmd --add-port="$range/$proto" 2>/dev/null || true
      else
        firewall-cmd --permanent --add-port="$range/$proto" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
      fi
      ;;
    iptables)
      iptables -I INPUT -p "$proto" --dport "$range" -j ACCEPT 2>/dev/null || true
      ;;
    none)
      : # 无防火墙后端，跳过
      ;;
  esac
}

# 临时放行 80（HTTP-01 签发用），回显一个 token 供回收
fw_open_http_temp() {
  fw_open_port tcp 80 temp
}

fw_close_http_temp() {
  fw_close_temp_port tcp 80
}

# 按用户选择开放端口。参数：choice p_any p_hy2 p_tuic [hy2_hop_range]
# choice: 1=全部 2=仅节点 3=不开放
fw_apply_choice() {
  local choice=$1 p_any=$2 p_hy2=$3 p_tuic=$4 hop=${5:-}
  fw_detect
  case "$choice" in
    1)
      fw_open_port tcp 80 permanent
      fw_open_port tcp "$p_any" permanent
      fw_open_port udp "$p_hy2" permanent
      fw_open_port udp "$p_tuic" permanent
      [[ -n "$hop" ]] && fw_open_range udp "$hop" permanent
      ok "已通过 $FW_BACKEND 开放 80 + 三协议端口 + Hy2 跳跃段"
      ;;
    2)
      fw_open_port tcp "$p_any" permanent
      fw_open_port udp "$p_hy2" permanent
      fw_open_port udp "$p_tuic" permanent
      [[ -n "$hop" ]] && fw_open_range udp "$hop" permanent
      warn "仅开放了三协议端口 + Hy2 跳跃段；HTTP-01 签发阶段将临时放行 80 并回收"
      ;;
    3)
      warn "未开放任何端口，请自行在防火墙/安全组中放行 80（仅 HTTP-01 需要）、三协议端口及 Hy2 跳跃段 $hop"
      ;;
  esac
}
