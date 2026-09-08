#!/usr/bin/env bash
# lib/node.sh — 节点 URI 生成
# 严禁生成订阅链接。安装完成或选“查看节点”后打印已启用协议的 URI，写入 nodes.txt(600)。
# 生效集 = 用户选择(PROTOS) ∩ 内核支持，与 config_gen 严格一致。

node_gen() {
  if [[ ! -f "$SB_STATE" ]]; then
    error "未找到配置状态文件，请先完成安装/配置（选项 1 / 2）"
    return 1
  fi
  set -a; . "$SB_STATE"; set +a

  local name="$DOMAIN"
  # 生效集 = 用户选择(PROTOS) ∩ 内核支持，与 config_gen 的裁剪严格一致。
  # 未选择或当前内核未适配的协议不生成 URI，其配置仍保留在 .state，
  # 切回支持的高版本内核（或重新选上）后由 config_rebuild_from_state 恢复。
  local sb_ver supported chosen active="" p
  sb_ver=$(core_sb_ver 2>/dev/null) || sb_ver=""
  supported=$(core_supported_protos "$sb_ver")
  if [[ -n "${PROTOS:-}" ]]; then
    chosen=$(core_protos_from_letters "$PROTOS")
  else
    chosen="$supported"   # 旧 .state 无 PROTOS：沿用内核支持的全部
  fi
  for p in $chosen; do
    if core_proto_supported "$p" "$sb_ver"; then active="$active $p"; fi
  done
  active="${active# }"

  local anytls_uri="" hy2_uri="" tuic_uri="" socks_uri=""
  if [[ " $active " == *" anytls "* ]]; then
    anytls_uri="anytls://${PASS_ANYTLS}@${DOMAIN}:${PORT_ANYTLS}?sni=${DOMAIN}&insecure=0#${name}"
  fi
  if [[ " $active " == *" socks "* ]]; then
    # SOCKS5 无强制 TLS；带认证时写入 user:pass@，任一留空则不认证
    if [[ -n "${USER_SOCKS:-}" && -n "${PASS_SOCKS:-}" ]]; then
      socks_uri="socks5://${USER_SOCKS}:${PASS_SOCKS}@${DOMAIN}:${PORT_SOCKS}#${name}"
    else
      socks_uri="socks5://${DOMAIN}:${PORT_SOCKS}#${name}"
    fi
  fi
  if [[ " $active " == *" hysteria2 "* ]]; then
    hy2_uri="hysteria2://${PASS_HY2}@${DOMAIN}:${PORT_HY2}?alpn=h3&sni=${DOMAIN}&insecure=0"
    if [[ -n "$OBS_HY2" ]]; then
      hy2_uri="${hy2_uri}&obfs=salamander:${OBS_HY2}"
    fi
    # Hysteria2 端口跳跃（mport）：sing-box 核心 inbound 不支持服务端端口跳跃（无 listen_port 范围），
    # 脚本用 nftables/iptables REDIRECT 把整个跳跃段重定向到基础监听端口，回包由 conntrack 自动还原
    # 源端口，客户端 mport 跳变完全可用（v1.0.7 曾据此移除 mport，实为误判——真正导致节点不通的
    # 是 DNS detour 崩溃，已于 v1.1.0 修复）。启用跳跃后需在云安全组放行整个 UDP 范围。
    if [[ -n "$HOP_HY2" ]]; then
      hy2_uri="${hy2_uri}&mport=${HOP_HY2}"
    fi
    hy2_uri="${hy2_uri}#${name}"
  fi
  if [[ " $active " == *" tuic "* ]]; then
    tuic_uri="tuic://${UUID_TUIC}:${PASS_TUIC}@${DOMAIN}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&sni=${DOMAIN}&alpn=h3&insecure=0#${name}"
  fi

  {
    echo "# easy-singbox 节点信息（无订阅链接，请勿分享订阅地址）"
    echo ""
    if [[ -n "$anytls_uri" ]]; then
      echo "## AnyTLS"
      echo "$anytls_uri"
      echo ""
    fi
    if [[ -n "$hy2_uri" ]]; then
      echo "## Hysteria2"
      echo "$hy2_uri"
      echo ""
    fi
    if [[ -n "$tuic_uri" ]]; then
      echo "## TUIC v5"
      echo "$tuic_uri"
      echo ""
    fi
    if [[ -n "$socks_uri" ]]; then
      echo "## SOCKS5（明文，无 TLS）"
      echo "$socks_uri"
      echo ""
    fi
    if [[ -n "$anytls_uri" ]]; then
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
      echo ""
    fi
    if [[ -n "$socks_uri" ]]; then
      echo "## SOCKS5 sing-box outbound JSON 兜底（部分客户端不识别 socks5:// 时使用）"
      cat <<JSON
{
  "type": "socks",
  "tag": "socks",
  "server": "$DOMAIN",
  "server_port": $PORT_SOCKS,
  "version": "5",
  "username": "${USER_SOCKS:-}",
  "password": "${PASS_SOCKS:-}",
  "udp_over_tcp": false
}
JSON
      echo ""
    fi
  } > "$SB_NODES"

  # umask 077 下重定向创建即为 600，保险起见显式收紧
  chmod 600 "$SB_NODES"; chown root:root "$SB_NODES"

  # 终端展示
  echo ""
  info "===== 节点信息（已写入 $SB_NODES，权限 600）====="
  echo ""
  if [[ -n "$anytls_uri" ]]; then
    echo -e "${C_CYN}## AnyTLS${C_RST}"
    echo "$anytls_uri"
    echo ""
  fi
  if [[ -n "$hy2_uri" ]]; then
    echo -e "${C_CYN}## Hysteria2${C_RST}"
    echo "$hy2_uri"
    echo ""
  fi
  if [[ -n "$tuic_uri" ]]; then
    echo -e "${C_CYN}## TUIC v5${C_RST}"
    echo "$tuic_uri"
    echo ""
  fi
  if [[ -n "$socks_uri" ]]; then
    echo -e "${C_CYN}## SOCKS5${C_RST} ${C_YEL}(明文，无 TLS)${C_RST}"
    echo "$socks_uri"
    echo ""
  fi
  if [[ -z "$anytls_uri" && -z "$hy2_uri" && -z "$tuic_uri" && -z "$socks_uri" ]]; then
    warn "当前未启用任何协议（已选: ${PROTOS:-未指定}，内核 v${sb_ver:-?}），未生成节点"
    warn "可执行选项 2 重新选择协议，或选项 7 升级内核以启用未适配协议"
  fi
}
