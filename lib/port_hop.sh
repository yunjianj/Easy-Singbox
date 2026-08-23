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
      ;;
    nft)
      nft delete table ip easy_singbox 2>/dev/null || true
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
  # Alpine 等最小化系统默认无 iptables/nftables，先尝试按发行版安装
  if command -v iptables >/dev/null 2>&1 || command -v nft >/dev/null 2>&1; then
    return 0
  fi
  info "系统缺少 iptables/nftables（端口跳跃需要），尝试安装..."
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache iptables >/dev/null 2>&1 || apk add --no-cache nftables >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q iptables >/dev/null 2>&1 || true
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
  local wan_if
  wan_if=$(ip -4 route show default 2>/dev/null | \
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
      ;;
    *)
      warn "未找到 iptables/nftables，端口跳跃不可用；Hysteria2 仅基础端口 ${base} 可用"
      return 1
      ;;
  esac
}
