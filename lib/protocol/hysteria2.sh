#!/usr/bin/env bash
# lib/protocol/hysteria2.sh — Hysteria2 inbound 片段生成（UDP/QUIC）
# 强制 TLS，无证书模式不可用。可选 salamander obfs（第4参数为 obfs 密码）。
# 第5参数 ge114=1 表示 sing-box >= 1.14（启用 1.14 新增 TLS 字段）。
proto_hysteria2_inbound() {
  local port=$1 pass=$2 domain=$3 obfs=${4:-} ge114=${5:-0}
  # 端口跳跃由 lib/port_hop.sh 通过 iptables/nftables REDIRECT 实现，
  # 此处 listen_port 必须是 sing-box 要求的 uint16 整数（基础监听端口）。
  local lp_line="\"listen_port\": $port"
  local tls_hs=""
  [[ "$ge114" == 1 ]] && tls_hs=$'      "handshake_timeout": "8s",\n'
  if [[ -n "$obfs" ]]; then
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    $lp_line,
    "obfs": { "type": "salamander", "password": "$obfs" },
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
${tls_hs}      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
  else
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    $lp_line,
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
${tls_hs}      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
  fi
}
