#!/usr/bin/env bash
# lib/protocol/hysteria2.sh — Hysteria2 inbound 片段生成（UDP/QUIC）
# 强制 TLS，无证书模式不可用。可选 salamander obfs（第4参数为 obfs 密码）。
# v1.5.0 起只适配基线大版本（SB_VER_BASE=1.14），恒输出该大版本最新语法字段。
# 参数：port pass domain [obfs]
proto_hysteria2_inbound() {
  local port=$1 pass=$2 domain=$3 obfs=${4:-}
  # 端口跳跃由 lib/port_hop.sh 通过 iptables/nftables REDIRECT 实现，
  # 此处 listen_port 必须是 sing-box 要求的 uint16 整数（基础监听端口）。
  local lp_line="\"listen_port\": $port"
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
      "handshake_timeout": "8s",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
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
      "handshake_timeout": "8s",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
  fi
}
