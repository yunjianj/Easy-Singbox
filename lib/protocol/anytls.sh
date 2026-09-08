#!/usr/bin/env bash
# lib/protocol/anytls.sh — AnyTLS inbound 片段生成（TCP）
# 强制 TLS，无证书模式不可用。
# 参数：port pass domain。v1.5.0 起只适配基线大版本（SB_VER_BASE=1.14），
# 恒输出该大版本最新语法字段（如 handshake_timeout），不再有多版本分支。
proto_anytls_inbound() {
  local port=$1 pass=$2 domain=$3
  cat <<EOF
  {
    "type": "anytls",
    "tag": "anytls-in",
    "listen": "::",
    "listen_port": $port,
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
}
