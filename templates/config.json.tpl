{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": __PORT_ANYTLS__,
      "users": [ { "name": "user1", "password": "__PASS_ANYTLS__" } ],
      "tls": {
        "enabled": true,
        "server_name": "__DOMAIN__",
        "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
        "key_path": "/etc/sing-box/ssl/privkey.pem"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": __PORT_HY2__,
      "up_mbps": 100,
      "down_mbps": 100,
      "users": [ { "name": "user1", "password": "__PASS_HY2__" } ],
      "tls": {
        "enabled": true,
        "server_name": "__DOMAIN__",
        "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
        "key_path": "/etc/sing-box/ssl/privkey.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": __PORT_TUIC__,
      "users": [ { "name": "user1", "uuid": "__UUID_TUIC__", "password": "__PASS_TUIC__" } ],
      "tls": {
        "enabled": true,
        "server_name": "__DOMAIN__",
        "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
        "key_path": "/etc/sing-box/ssl/privkey.pem"
      }
    }
  ],
  "dns": {
    "servers": [ { "tag": "remote", "address": "https://1.1.1.1/dns-query", "detour": "direct" } ],
    "final": "remote"
  },
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
