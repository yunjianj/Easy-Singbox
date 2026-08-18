#!/usr/bin/env bash
# lib/node.sh — 节点 URI 生成 + 二维码输出
# 严禁生成订阅链接。安装完成或选“查看节点”后打印三种协议 URI + 二维码，写入 nodes.txt(600)。

node_gen() {
  if [[ ! -f "$SB_STATE" ]]; then
    error "未找到配置状态文件，请先完成安装/配置（选项 1 / 2）"
    return 1
  fi
  set -a; . "$SB_STATE"; set +a

  local name="$DOMAIN"
  local anytls_uri="anytls://${PASS_ANYTLS}@${DOMAIN}:${PORT_ANYTLS}?sni=${DOMAIN}&insecure=0#${name}"
  local hy2_uri="hysteria2://${PASS_HY2}@${DOMAIN}:${PORT_HY2}?alpn=h3&sni=${DOMAIN}&insecure=0#${name}"
  if [[ -n "$OBS_HY2" ]]; then
    hy2_uri="${hy2_uri%#${name}}&obfs=salamander:${OBS_HY2}#${name}"
  fi
  # 注意：sing-box 核心 inbound 不支持服务端端口跳跃（无 listen_port 范围、无 hop_ports），
  # 脚本用 iptables/nftables REDIRECT 做入口重定向，但单监听无法实现客户端 mport 跳变的回包匹配，
  # 故 URI 不写入 mport（否则客户端跳变必断）。客户端固定连接基础端口 PORT_HY2 即可稳定可用。
  local tuic_uri="tuic://${UUID_TUIC}:${PASS_TUIC}@${DOMAIN}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&sni=${DOMAIN}&alpn=h3&insecure=0#${name}"

  {
    echo "# easy-singbox 节点信息（无订阅链接，请勿分享订阅地址）"
    echo ""
    echo "## AnyTLS"
    echo "$anytls_uri"
    echo ""
    echo "## Hysteria2"
    echo "$hy2_uri"
    echo ""
    echo "## TUIC v5"
    echo "$tuic_uri"
    echo ""
    echo "## AnyTLS sing-box outbound JSON 兜底（部分客户端不识别 anytls:// 时使用）"
    cat <<JSON
{
  "type": "anytls",
  "tag": "anytls",
  "server": "$DOMAIN",
  "server_port": $PORT_ANYTLS,
  "password": "$PASS_ANYTLS",
  "tls": { "enabled": true, "server_name": "$DOMAIN", "insecure": false }
}
JSON
  } | tee "$SB_NODES" >/dev/null

  chmod 600 "$SB_NODES"; chown root:root "$SB_NODES"

  # 终端展示
  echo ""
  info "===== 节点信息（已写入 $SB_NODES，权限 600）====="
  echo ""
  echo -e "${C_CYN}## AnyTLS${C_RST}"
  echo "$anytls_uri"
  echo ""
  echo -e "${C_CYN}## Hysteria2${C_RST}"
  echo "$hy2_uri"
  echo ""
  echo -e "${C_CYN}## TUIC v5${C_RST}"
  echo "$tuic_uri"
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    for u in "$anytls_uri" "$hy2_uri" "$tuic_uri"; do
      echo -e "${C_YEL}--- QR ---${C_RST}"
      qrencode -t ANSIUTF8 "$u"
      echo ""
    done
  else
    warn "未安装 qrencode，已跳过二维码。可安装后执行 sb 选“查看节点”重新生成（apt install qrencode / yum install qrencode）"
  fi
}
