#!/usr/bin/env bash
# lib/port_hop.sh — Hysteria2 端口跳跃（服务端实现）
# 重要：sing-box 核心的 inbound listen_port 为 uint16，不支持服务端端口跳跃
# （既无 hop_ports，也不接受字符串范围）。因此服务端跳跃通过 iptables/nftables
# REDIRECT 实现：将跳跃段 UDP 流量重定向到 Hysteria2 实际监听的整数端口。
# 规则带固定标记，便于安装/变更/卸载时精确清理。

HOP_TAG="easy-singbox-hop"

# 探测可用的重定向后端：优先 iptables（nft 系统上通常为 iptables-nft 包装，命令兼容）
hop_backend() {
  if command -v iptables >/dev/null 2>&1; then
    echo "iptables"
  elif command -v nft >/dev/null 2>&1; then
    echo "nft"
  else
    echo "none"
  fi
}

# 校验跳跃规则是否真实存在于内核（静默，只用返回码表达）。
# 为什么需要：REDIRECT 规则是**非持久的内核状态**——重启必丢，且 1Panel / Docker
# / firewalld 等会重写 iptables-nft 表。.state 里的 HOP_HY2 只记录"当初配过"，
# 并不代表规则还在。没有这个校验，规则悄悄消失时节点 URI 仍带 mport，
# 客户端向整段端口发包却无人接收 → Hy2 超时，而诊断还会误判成"客户端问题"。
# 返回 0=规则存在 / 1=不存在或无法确认
hop_verify() {
  local b; b=$(hop_backend)
  case "$b" in
    iptables)
      # IPv4 规则存在即可（客户端绝大多数走 v4；纯 v6 站点另由 IPv6 规则兜底）
      iptables -t nat -S PREROUTING 2>/dev/null | grep -q "$HOP_TAG"
      ;;
    nft)
      nft list table ip easy_singbox 2>/dev/null | grep -q "redirect to"
      ;;
    *) return 1 ;;
  esac
}

# 按 .state 重建跳跃规则（幂等；未配置跳跃则 no-op）。
# 与 hop_apply 的区别：本函数**只重建规则，绝不改动 .state**——
# HOP_HY2 键的增删是 config_gen 的职责（规则建立失败时它才删键，避免 URI 带
# 无效 mport）。这里若跟着删键，重启后一次失败就会永久抹掉用户的跳跃配置。
# 调用时机：service_start / service_restart / service_reload（选项 4/6/3/7）。
hop_reapply() {
  [[ -f "$SB_STATE" ]] || return 0
  # .state 可能由旧版本写出，键未必齐全，一律用 ${VAR:-}（sb 顶层 set -u，
  # 裸引用缺失键会抛 unbound variable 直接终止脚本）
  local hop="" base=""
  if [[ -r "$SB_STATE" ]]; then
    hop=$(grep -m1 '^HOP_HY2=' "$SB_STATE" 2>/dev/null | cut -d= -f2- || true)
    base=$(grep -m1 '^PORT_HY2_LISTEN=' "$SB_STATE" 2>/dev/null | cut -d= -f2- || true)
    [[ -n "$base" ]] || base=$(grep -m1 '^PORT_HY2=' "$SB_STATE" 2>/dev/null | cut -d= -f2- || true)
  fi
  [[ -n "$hop" && -n "$base" ]] || return 0
  hop_apply "$base" "$hop"
}

# 清除本脚本设置的所有重定向规则（幂等，无规则也可安全调用）
hop_remove() {
  local b; b=$(hop_backend)
  case "$b" in
    iptables)
      local rules="" line
      # 用命令替换捕获（grep 无匹配会返回 1，故追加 || true 避免触发 set -e）
      rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "$HOP_TAG" 2>/dev/null) || true
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # -S 输出形如 “-A PREROUTING ...”，去掉 “-A ” 即可转为 -D 参数
        iptables -t nat -D ${line#-A } 2>/dev/null || true
      done <<< "$rules"
      # IPv6 规则（若配置了 IPv6 跳跃）同样按标记清理
      if command -v ip6tables >/dev/null 2>&1; then
        rules=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep "$HOP_TAG" 2>/dev/null) || true
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          ip6tables -t nat -D ${line#-A } 2>/dev/null || true
        done <<< "$rules"
      fi
      ;;
    nft)
      nft delete table ip easy_singbox 2>/dev/null || true
      nft delete table ip6 easy_singbox 2>/dev/null || true
      ;;
    *)
      : # 无后端，跳过
      ;;
  esac
}

# 应用重定向：hop_apply <base_port> <range lo-hi>
# 将 UDP lo-hi 重定向到 base_port（Hysteria2 实际监听端口）。
# 成功返回 0；规则未建立（无后端 / REDIRECT 失败）返回 1，
# 调用方可据此决定是否保留跳跃配置（避免 URI 带 mport 却无规则导致节点不通）。
hop_ensure_backend() {
  # Alpine 等最小化系统默认无 iptables/nftables，先尝试按发行版安装。
  # IPv6 跳跃（域名纯 AAAA/客户端走 v6 时必需）还需要 ip6tables。
  if command -v iptables >/dev/null 2>&1 || command -v nft >/dev/null 2>&1; then
    return 0
  fi
  info "系统缺少 iptables/nftables（端口跳跃需要），尝试安装..."
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache iptables ip6tables >/dev/null 2>&1 || apk add --no-cache iptables >/dev/null 2>&1 || apk add --no-cache nftables >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables ip6tables >/dev/null 2>&1 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q iptables ip6tables >/dev/null 2>&1 || yum install -y -q iptables >/dev/null 2>&1 || true
  fi
  command -v iptables >/dev/null 2>&1 || command -v nft >/dev/null 2>&1
}

hop_apply() {
  local base=$1 range=$2 lo hi
  [[ -z "$base" || -z "$range" ]] && return 0
  lo=${range%-*}; hi=${range#*-}
  if ! [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ ]]; then
    warn "Hysteria2 跳跃段格式非法（$range），跳过端口跳跃（仍可经基础端口 $base 连接）"
    return 0
  fi
  # 无后端时自动安装；仍装不上则明确失败（调用方应移除跳跃配置，URI 不带 mport）
  if ! hop_ensure_backend; then
    warn "未找到 iptables/nftables 且自动安装失败，端口跳跃不可用；Hysteria2 仅基础端口 ${base} 可用"
    return 1
  fi
  hop_remove
  local b; b=$(hop_backend)
  # 限定规则仅匹配默认路由出口网卡（WAN），避免劫持 docker0/br-xxx 网桥上
  # 容器发出的出站 UDP 流量（否则容器访问外部 UDP 50001-51000 段会被静默
  # REDIRECT 到本机 sing-box 端口）。取不到出口网卡时回退为不限定并提示。
  local wan_if wan6
  wan_if=$(ip -4 route show default 2>/dev/null | \
           awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
  # IPv6 跳跃需单独取 IPv6 默认路由出口网卡（可能与 IPv4 不同，如 HE 隧道接口 he-ipv6）
  wan6=$(ip -6 route show default 2>/dev/null | \
         awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
  case "$b" in
    iptables)
      if [[ -n "$wan_if" ]]; then
        # $ifarg 有意不加引号做分词（值为 "-i <iface>" 或空串，内容由本脚本构造）
        local ifarg="-i $wan_if"
      else
        warn "未识别到默认出口网卡，跳跃规则不限定入接口（可能影响同机 Docker 容器出站 UDP）"
        local ifarg=""
      fi
      if iptables -t nat -I PREROUTING $ifarg -p udp --dport "${lo}:${hi}" \
           -j REDIRECT --to-ports "$base" -m comment --comment "$HOP_TAG" 2>/dev/null; then
        ok "端口跳跃已生效：UDP ${lo}-${hi} -> ${base}（客户端可用 mport 在范围内轮换）"
      else
        warn "iptables REDIRECT 失败（可能缺少 NAT 模块），Hysteria2 仅基础端口 ${base} 可用"
        return 1
      fi
      # IPv6 跳跃：域名若只有 AAAA 记录（或客户端走 v6），IPv4 nat 表不处理 IPv6
      # 流量，必须为 IPv6 单独建 REDIRECT 规则。失败仅降级为"IPv6 跳跃不可用"。
      if command -v ip6tables >/dev/null 2>&1; then
        local ifarg6=""
        if [[ -n "$wan6" ]]; then
          ifarg6="-i $wan6"
        else
          warn "未识别到 IPv6 默认出口网卡，IPv6 跳跃规则不限定入接口"
        fi
        if ip6tables -t nat -I PREROUTING $ifarg6 -p udp --dport "${lo}:${hi}" \
             -j REDIRECT --to-ports "$base" -m comment --comment "$HOP_TAG" 2>/dev/null; then
          ok "IPv6 端口跳跃已生效：UDP ${lo}-${hi} -> ${base}"
        else
          warn "ip6tables REDIRECT 失败（内核可能不支持 IPv6 NAT），IPv6 客户端跳跃不可用；IPv4 跳跃不受影响"
        fi
      fi
      ;;
    nft)
      nft add table ip easy_singbox 2>/dev/null || true
      nft 'add chain ip easy_singbox prerouting { type nat hook prerouting priority dstnat; }' 2>/dev/null || true
      local rc
      if [[ -n "$wan_if" ]]; then
        nft add rule ip easy_singbox prerouting iifname "$wan_if" udp dport "${lo}"-"${hi}" redirect to :"${base}" 2>/dev/null
        rc=$?
      else
        nft add rule ip easy_singbox prerouting udp dport "${lo}"-"${hi}" redirect to :"${base}" 2>/dev/null
        rc=$?
      fi
      if (( rc == 0 )); then
        ok "端口跳跃已生效：UDP ${lo}-${hi} -> ${base}"
      else
        warn "nftables REDIRECT 失败，Hysteria2 仅基础端口 ${base} 可用"
        return 1
      fi
      # IPv6 跳跃（IPv4 表不处理 IPv6 流量）
      nft add table ip6 easy_singbox 2>/dev/null || true
      nft 'add chain ip6 easy_singbox prerouting { type nat hook prerouting priority dstnat; }' 2>/dev/null || true
      if [[ -n "$wan6" ]]; then
        nft add rule ip6 easy_singbox prerouting iifname "$wan6" udp dport "${lo}"-"${hi}" redirect to :"${base}" 2>/dev/null \
          && ok "IPv6 端口跳跃已生效：UDP ${lo}-${hi} -> ${base}" \
          || warn "IPv6 nftables REDIRECT 失败，IPv6 客户端跳跃不可用；IPv4 跳跃不受影响"
      else
        nft add rule ip6 easy_singbox prerouting udp dport "${lo}"-"${hi}" redirect to :"${base}" 2>/dev/null \
          && ok "IPv6 端口跳跃已生效：UDP ${lo}-${hi} -> ${base}" \
          || warn "IPv6 nftables REDIRECT 失败，IPv6 客户端跳跃不可用；IPv4 跳跃不受影响"
      fi
      ;;
    *)
      warn "未找到 iptables/nftables，端口跳跃不可用；Hysteria2 仅基础端口 ${base} 可用"
      return 1
      ;;
  esac
}
