#!/usr/bin/env bash
# lib/protocol/anytls.sh — AnyTLS inbound 片段生成（TCP）
# 强制 TLS，无证书模式不可用。
# 参数：port pass domain [ge114]；ge114=1 表示 sing-box >= 1.14（启用 1.14 新增 TLS 字段）。
proto_anytls_inbound() {
  local port=$1 pass=$2 domain=$3 ge114=${4:-0}
  local tls_hs=""
  [[ "$ge114" == 1 ]] && tls_hs=$'      "handshake_timeout": "8s",\n'
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
${tls_hs}      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
}
