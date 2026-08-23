#!/usr/bin/env bash
# lib/bbrfq.sh — BBR 拥塞控制 + FQ 队列纪律一键启用/禁用
# 独立于 sing-box 安装，在主页面以单独菜单项提供。
# 仅被 sb source，不单独执行。

# sysctl 持久化文件。
# 必须与 core_ensure_dualstack() 使用的 99-easy-singbox.conf 分离——
# 该函数用 '>' 覆写整个文件（只写 bindv6only=0），若共用会导致 BBR 配置丢失。
BBRFQ_SYSCTL_CONF="/etc/sysctl.d/99-easy-singbox-bbr.conf"

# 检测 BBR 是否在内核可用拥塞控制列表中
bbrfq_bbr_available() {
  local avail
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  [[ "$avail" == *bbr* ]]
}

# 获取当前状态，输出 "cc|qdisc" 两个字段
bbrfq_current() {
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  echo "$cc|$qd"
}

# 格式化状态用于菜单显示（单行）
bbrfq_status_display() {
  local cc qd
  IFS='|' read -r cc qd <<< "$(bbrfq_current)"
  if [[ "$cc" == *bbr* ]]; then
    echo "BBR: 已开启 ($cc) | FQ: $( [[ "$qd" == "fq" ]] && echo "已开启" || echo "未开启" ) ($qd)"
  else
    echo "BBR: 未开启 ($cc) | FQ: $( [[ "$qd" == "fq" ]] && echo "已开启" || echo "未开启" ) ($qd)"
  fi
}

# 启用 BBR + FQ
bbrfq_enable() {
  core_root_check

  # 内核版本检查（BBR 需要 >= 4.9）
  local kver major minor
  kver=$(uname -r)
  major=$(echo "$kver" | cut -d. -f1)
  minor=$(echo "$kver" | cut -d. -f2)
  if [[ "$major" -lt 4 || ( "$major" -eq 4 && "$minor" -lt 9 ) ]]; then
    error "内核版本 $kver 过低，BBR 需要 >= 4.9。请升级内核后重试。"
    return 1
  fi

  # 加载内核模块（内置则无操作，不可用则忽略——后续 sysctl 会报错）
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true

  # 检查 BBR 是否在可用列表
  if ! bbrfq_bbr_available; then
    error "内核不支持 BBR 拥塞控制（tcp_bbr 模块不可用）。"
    info "请确认内核已编译 BBR 支持（CONFIG_TCP_CONG_BBR=y 或可加载 tcp_bbr 模块）。"
    return 1
  fi

  info "正在启用 BBR + FQ ..."

  # 运行时立即生效。
  # 不使用 sysctl --system（会重放 /etc/sysctl.d 全部文件，可能把
  # net.ipv4.ip_forward=0 重放覆盖 Docker 运行时设置的 1，导致容器断网——
  # 见 lib/core.sh 注释）。此处仅 sysctl -w 设置运行时值。
  if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    warn "net.core.default_qdisc 设置失败（内核 < 4.13 无此 sysctl 项）"
    info "FQ 需内核 >= 4.13 才能通过 sysctl 设置默认队列纪律；BBR 仍可单独启用。"
  fi
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    error "设置 tcp_congestion_control=bbr 失败"
    return 1
  fi

  # 持久化（重启后由系统 init 自动加载 /etc/sysctl.d/*.conf）
  cat > "$BBRFQ_SYSCTL_CONF" <<EOF
# Easy-Singbox BBR + FQ 配置
# 由 sb 管理面板生成，可通过对应菜单项一键禁用并移除此文件
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 644 "$BBRFQ_SYSCTL_CONF"

  # 确认生效
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

  if [[ "$cc" == *bbr* ]]; then
    ok "BBR 已启用"
    info "拥塞控制  : $cc"
    if [[ "$qd" == "fq" ]]; then
      ok "FQ 已启用"
      info "队列纪律  : $qd"
    else
      warn "FQ 未生效（内核 < 4.13 或 sch_fq 模块不可用），队列纪律: $qd"
      info "BBR 在非 FQ 队列下仍可工作但性能略降；如需 FQ 请升级内核至 >= 4.13"
    fi
    info "持久化文件: $BBRFQ_SYSCTL_CONF"
  else
    error "BBR 设置未生效，当前拥塞控制: $cc"
    return 1
  fi
}

# 禁用 BBR + FQ（恢复内核默认）
bbrfq_disable() {
  core_root_check

  if ! core_prompt_yn "确认禁用 BBR + FQ 并恢复内核默认（cubic + pfifo_fast）？"; then
    info "已取消"; return 0
  fi

  info "正在禁用 BBR + FQ ..."

  # 运行时恢复内核默认值
  # cubic 是 Linux 默认拥塞控制；pfifo_fast 是默认队列纪律
  sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
  sysctl -w net.core.default_qdisc=pfifo_fast 2>/dev/null || true

  # 移除持久化文件
  if [[ -f "$BBRFQ_SYSCTL_CONF" ]]; then
    rm -f "$BBRFQ_SYSCTL_CONF"
    ok "已移除持久化文件 $BBRFQ_SYSCTL_CONF"
  else
    info "未找到持久化文件（可能此前未启用过）"
  fi

  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

  ok "BBR + FQ 已禁用"
  info "拥塞控制  : $cc"
  info "队列纪律  : $qd"
}

# BBR + FQ 管理子菜单（由主页面对应选项调用）
bbrfq_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo -e "      ${C_BOLD}BBR + FQ 拥塞控制管理${C_RST}"
    echo "--------------------------------------------------------------"
    echo " 当前状态  : $(bbrfq_status_display)"
    echo " 持久化    : $([[ -f "$BBRFQ_SYSCTL_CONF" ]] && echo '已配置（重启后保持）' || echo '未配置')"
    echo "--------------------------------------------------------------"
    echo " [1] 启用 BBR + FQ"
    echo " [2] 禁用 BBR + FQ（恢复内核默认）"
    echo " [0] 返回主菜单"
    echo "=============================================================="
    local choice
    choice=$(core_prompt "请选择 [0-2]")
    case "$choice" in
      1) bbrfq_enable || true ;;
      2) bbrfq_disable || true ;;
      0) break ;;
      *) warn "无效选择" ;;
    esac
    echo ""
    # 注意：read -p 的提示输出到 stderr，绝不能加 2>/dev/null 重定向，
    # 否则用户看不到"按回车继续"提示，误以为脚本卡住（实测踩坑）。
    read -r -p "按回车继续..." _ || true
  done
}
