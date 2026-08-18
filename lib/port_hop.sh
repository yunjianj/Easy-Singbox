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
# 失败不致命：Hysteria2 仍可经 base_port 正常连接。
hop_apply() {
  local base=$1 range=$2 lo hi
  [[ -z "$base" || -z "$range" ]] && return 0
  lo=${range%-*}; hi=${range#*-}
  if ! [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ ]]; then
    warn "Hysteria2 跳跃段格式非法（$range），跳过端口跳跃（仍可经基础端口 $base 连接）"
    return 0
  fi
  hop_remove
  local b; b=$(hop_backend)
  case "$b" in
    iptables)
      if iptables -t nat -I PREROUTING -p udp --dport "${lo}:${hi}" \
           -j REDIRECT --to-ports "$base" -m comment --comment "$HOP_TAG" 2>/dev/null; then
        ok "端口跳跃已生效：UDP ${lo}-${hi} -> ${base}（客户端可用 mport 在范围内轮换）"
      else
        warn "iptables REDIRECT 失败（可能缺少 NAT 模块），Hysteria2 仍可经基础端口 ${base} 连接"
      fi
      ;;
    nft)
      nft add table ip easy_singbox 2>/dev/null || true
      nft 'add chain ip easy_singbox prerouting { type nat hook prerouting priority dstnat; }' 2>/dev/null || true
      if nft add rule ip easy_singbox prerouting udp dport "${lo}"-"${hi}" redirect to :"${base}" 2>/dev/null; then
        ok "端口跳跃已生效：UDP ${lo}-${hi} -> ${base}"
      else
        warn "nftables REDIRECT 失败，Hysteria2 仍可经基础端口 ${base} 连接"
      fi
      ;;
    *)
      warn "未找到 iptables/nftables，无法设置端口跳跃；Hysteria2 仅基础端口 ${base} 可用"
      ;;
  esac
}
