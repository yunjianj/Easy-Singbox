#!/usr/bin/env bash
# lib/config.sh — 生成 config.json（多协议按需共存）并保存状态文件

# 生成完整 config.json + .state；参数：
# domain port_any port_hy2 port_tuic pass_any pass_hy2 pass_tuic uuid_tuic [obfs_hy2] [hop_hy2]
#        [protos] [port_socks] [user_socks] [pass_socks]
# hop_hy2: Hysteria2 端口跳跃段（如 50001-51000），留空则不启用跳跃
# protos: 用户选择启用的协议字母串（如 "bc"）；留空=全部协议（兼容旧 .state / 直接调用）
config_gen() {
  local domain=$1 port_any=$2 port_hy2=$3 port_tuic=$4 \
        pass_any=$5 pass_hy2=$6 pass_tuic=$7 uuid_tuic=$8 \
        obfs_hy2=${9:-} hop_hy2=${10:-${HOP_HY2:-}} \
        protos=${11:-} port_socks=${12:-} user_socks=${13:-} pass_socks=${14:-}

  # v1.5.0 起只适配基线大版本（SB_VER_BASE=1.14）：所有启用协议恒按最新语法生成，
  # 不再探测已装内核版本做语法分支/裁剪。安装/升级流程保证内核即为 1.14.x。
  # 实际生成的协议集 = 用户选择（protos）；未指定时默认全部协议。
  local active p
  if [[ -n "$protos" ]]; then
    active=$(core_protos_from_letters "$protos")
  else
    active=$(core_all_protos)
  fi
  [[ -n "$active" ]] || { error "没有要生成的协议（已选: ${protos:-空}）"; return 1; }

  # Hy2 实际监听端口：始终为基础整数端口（sing-box 要求 uint16，核心不支持服务端端口跳跃）。
  # 节点 URI 的 server_port 始终用基础端口 port_hy2（真实监听端口），
  # 范围通过 mport 携带（官方出站字段为 server_ports）。服务端跳跃由 lib/port_hop.sh
  # 的 REDIRECT 把范围转发到该基础端口实现，故“只放行基础端口”也能连，
  # 客户端跳跃需额外在外部防火墙/安全组放行整个范围。
  local hy2_listen="$port_hy2" port_hy2_node="$port_hy2"

  # 端口不可重复：仅校验实际生成协议的非空端口（未启用的协议端口为空，
  # 若参与比较会出现 "" == "" 的误判）。
  local _p _port _seen=" "
  for _p in $active; do
    case "$_p" in
      anytls)    _port=$port_any ;;
      hysteria2) _port=$port_hy2 ;;
      tuic)      _port=$port_tuic ;;
      socks)     _port=$port_socks ;;
    esac
    [[ -z "$_port" ]] && continue
    if [[ "$_seen" == *" $_port "* ]]; then
      error "端口重复：$(core_proto_display "$_p") 使用了已被占用的 $_port"
      return 1
    fi
    _seen="$_seen$_port "
  done
  # Hysteria2 跳跃段即 Hy2 监听端口，故仅检查与其余生效协议的监听端口是否重叠
  if [[ -n "$hop_hy2" ]]; then
    local hlo hhi
    hlo=${hop_hy2%-*}; hhi=${hop_hy2#*-}
    for _p in $active; do
      case "$_p" in
        hysteria2) continue ;;   # 跳跃段归属 Hy2 自身，不算冲突
        anytls)    _port=$port_any ;;
        tuic)      _port=$port_tuic ;;
        socks)     _port=$port_socks ;;
        *) continue ;;
      esac
      [[ -z "$_port" ]] && continue
      if (( _port >= hlo && _port <= hhi )); then
        error "Hysteria2 跳跃段 $hop_hy2 与 $(core_proto_display "$_p") 端口 $_port 重叠，请更换端口或跳跃段"
        return 1
      fi
    done
  fi

  mkdir -p "$SB_DIR_CONF" "$SB_DIR_SSL"

  {
    printf '{\n'
    printf '  "log": { "level": "info", "timestamp": true },\n'
    printf '  "inbounds": [\n'
    # 逐协议输出用户启用的 inbound；用 first 标记控制逗号。
    local first=1
    if [[ " $active " == *" anytls "* ]]; then
      [[ $first -eq 0 ]] && printf ',\n'
      proto_anytls_inbound "$port_any" "$pass_any" "$domain"
      first=0
    fi
    if [[ " $active " == *" hysteria2 "* ]]; then
      [[ $first -eq 0 ]] && printf ',\n'
      proto_hysteria2_inbound "$hy2_listen" "$pass_hy2" "$domain" "$obfs_hy2"
      first=0
    fi
    if [[ " $active " == *" tuic "* ]]; then
      [[ $first -eq 0 ]] && printf ',\n'
      proto_tuic_inbound "$port_tuic" "$uuid_tuic" "$pass_tuic" "$domain"
      first=0
    fi
    if [[ " $active " == *" socks "* ]]; then
      [[ $first -eq 0 ]] && printf ',\n'
      # SOCKS5 明文：sing-box socks inbound 无 tls 字段（唯一非 TLS 协议）
      proto_socks_inbound "$port_socks" "$user_socks" "$pass_socks"
      first=0
    fi
    # 兜底：active 已在函数开头校验非空，此处仅防御性判断
    if [[ $first -eq 1 ]]; then
      error "没有生成任何 inbound（active 为空，逻辑异常）"
      return 1
    fi
    printf '\n  ],\n'
    # 注意：DoH(https) DNS 服务器不能带 "detour": "direct" —— sing-box 运行期会报
    # FATAL "detour to an empty direct outbound makes no sense" 直接崩溃（check 却能通过）。
    # 留空 detour 即走默认出站（此处 route.final=direct），行为一致且不会崩。
    printf '  "dns": { "servers": [ { "tag": "remote", "type": "https", "server": "1.1.1.1" } ], "final": "remote" },\n'
    printf '  "outbounds": [ { "type": "direct", "tag": "direct" } ],\n'
    printf '  "route": { "final": "direct" }\n'
    printf '}\n'
  } > "$SB_CONF"

  chmod 600 "$SB_CONF"; chown root:root "$SB_CONF" 2>/dev/null || true

  # 状态文件（节点 URI 生成依赖，权限 600）
  # PROTOS 保存"用户选择的字母串"（而非生成集）：升级内核大版本或重装后仍保留
  # 用户意图。未显式指定 protos 时回写为全部协议的字母串（兼容旧 .state 与直接调用）。
  local protos_save=$protos
  [[ -n "$protos_save" ]] || protos_save=$(core_all_protos | sed 's/anytls/a/;s/hysteria2/b/;s/tuic/c/;s/socks/d/' | tr -d ' ')
  cat > "$SB_STATE" <<EOF
DOMAIN=$domain
PROTOS=$protos_save
PORT_ANYTLS=$port_any
PORT_HY2=$port_hy2_node
PORT_HY2_LISTEN=$port_hy2
PORT_TUIC=$port_tuic
PORT_SOCKS=$port_socks
PASS_ANYTLS=$pass_any
PASS_HY2=$pass_hy2
PASS_TUIC=$pass_tuic
USER_SOCKS=$user_socks
PASS_SOCKS=$pass_socks
UUID_TUIC=$uuid_tuic
OBS_HY2=$obfs_hy2
HOP_HY2=$hop_hy2
EOF
  chmod 600 "$SB_STATE"; chown root:root "$SB_STATE" 2>/dev/null || true

  # 清空旧的端口跳跃重定向规则（幂等）
  hop_remove

  # 校验配置
  if ! "$SB_BIN" check -c "$SB_CONF"; then
    error "config.json 校验失败，请检查配置"
    return 1
  fi
  # 降权运行：让 singbox 用户可读配置/证书
  service_chown_conf
  # 应用 Hysteria2 端口跳跃（服务端 REDIRECT；无跳跃则仅清理旧规则）
  # 注意：hop_apply 返回非零表示规则未建立（无 iptables/nftables 且安装失败，或
  # REDIRECT 失败），此时必须从 state 移除 HOP_HY2——否则 URI 携带 mport 但服务器
  # 没有重定向规则，客户端跳变必连不上（单端口仍可用）。
  if [[ -n "$hop_hy2" ]]; then
    if hop_apply "$port_hy2" "$hop_hy2"; then
      :
    else
      warn "端口跳跃未能生效（无 iptables/nftables 或 REDIRECT 失败），已从状态移除 HOP_HY2；节点将仅用基础端口 ${port_hy2}"
      sed -i '/^HOP_HY2=/d' "$SB_STATE" 2>/dev/null || true
    fi
  fi
  ok "config.json 已生成并通过 sing-box check（已启用: $(core_protos_human "$protos_save")）"
}

# 内部：凭证类输入（密码 / obfs）合法性校验。
# 采用白名单：仅允许字母数字与常见安全符号，拒绝引号、反斜杠、$、反引号、空白、
# 控制字符与其它 shell / JSON 元字符——这些字符会破坏 .state（被 source 的 shell
# 文件）与 config.json 的结构。空值视为合法（obfs 允许留空关闭）。
_config_credential_ok() {
  local v=$1
  [[ -z "$v" ]] && return 0
  [[ "$v" =~ ^[A-Za-z0-9!@#%^*_+=~.,:-]+$ ]]
}

# 交互选择要启用的协议（字母编号，可组合），输出字母串（如 "bc"）。
# 参数：默认已选的字母串（可为空）。至少选择一个，空输入会要求重输。
# 供 sb_install 与 config_change 共用，保证两处交互一致。
# 注意：本函数常被命令替换调用（protos=$(config_pick_protos ...)），stdout 会被捕获，
# 因此所有面向用户的菜单/提示/告警一律输出到 stderr（同 core_prompt 约定），
# stdout 仅用于回显最终选择的字母串——否则菜单会被 $( ) 吞掉、用户看不到。
config_pick_protos() {
  local def=${1:-} in picked=""
  echo "选择要启用的协议（输入字母组合，如 bc = Hysteria2 + TUIC）：" >&2
  local l p name
  for p in anytls hysteria2 tuic socks; do
    l=$(core_proto_letter "$p"); name=$(core_proto_display "$p")
    case "$p" in
      anytls)    printf '  [%s] %-10s %s  %s\n' "$l" "$name" "TCP" "加密(强制 TLS)" >&2 ;;
      hysteria2) printf '  [%s] %-10s %s  %s\n' "$l" "$name" "UDP" "加密(强制 TLS)" >&2 ;;
      tuic)      printf '  [%s] %-10s %s  %s\n' "$l" "$name" "UDP" "加密(强制 TLS)" >&2 ;;
      socks)     printf '  [%s] %-10s %s  %s\n' "$l" "$name" "TCP" "明文(sing-box socks 无 tls 字段)" >&2 ;;
    esac
  done
  while [[ -z "$picked" ]]; do
    in=$(core_prompt "启用哪些协议(abcd 可组合)" "$def")
    picked=$(core_protos_from_letters "$in")
    [[ -n "$picked" ]] || warn "请至少输入一个有效字母（a/b/c/d），例如 bc" >&2
  done
  info "已选择: $(core_protos_human "$in")" >&2
  # 选择 SOCKS5 时明确告警（唯一非 TLS 协议）
  if [[ " $picked " == *" socks "* ]]; then
    warn "SOCKS5 为明文协议（sing-box socks inbound 不支持 TLS），握手与目标地址可被链路识别。" >&2
    warn "已默认生成随机用户名与密码；若留空将关闭认证，等同开放代理，极易被扫描滥用。" >&2
  fi
  # 回显字母串（规范化：仅保留有效字母并按 abcd 排序）
  core_protos_from_letters "$in" | sed 's/anytls/a/;s/hysteria2/b/;s/tuic/c/;s/socks/d/' | tr -d ' '
}

# 变更代理配置（主页面选项 2）
config_change() {
  if [[ ! -f "$SB_CONF" ]]; then
    error "尚未安装，请先执行安装（选项 1）"
    return 1
  fi
  [[ -f "$SB_STATE" ]] && set -a && . "$SB_STATE" && set +a

  # 先让用户选择启用哪些协议（字母编号，如 bc = Hysteria2 + TUIC）
  local protos; protos=$(config_pick_protos "${PROTOS:-}")
  [[ -n "$protos" ]] || return 1
  local chosen; chosen=$(core_protos_from_letters "$protos")

  local domain port_any="" port_hy2="" port_tuic="" port_socks="" \
        pass_any pass_hy2 pass_tuic uuid_tuic user_socks="" pass_socks="" obfs hop
  domain=$(core_prompt "节点域名" "${DOMAIN:-}")
  # 仅询问已选协议的参数；未选中的端口留空（config_gen 会跳过其 inbound 与校验）
  if [[ " $chosen " == *" anytls "* ]]; then
    port_any=$(core_prompt "AnyTLS 端口" "${PORT_ANYTLS:-$(core_rand_port)}")
    pass_any=$(core_prompt "AnyTLS 密码" "${PASS_ANYTLS:-$(core_rand_pass)}")
  else
    pass_any="${PASS_ANYTLS:-$(core_rand_pass)}"
  fi
  if [[ " $chosen " == *" hysteria2 "* ]]; then
    port_hy2=$(core_prompt "Hysteria2 端口" "${PORT_HY2:-$(core_rand_port)}")
    pass_hy2=$(core_prompt "Hysteria2 密码" "${PASS_HY2:-$(core_rand_pass)}")
  else
    pass_hy2="${PASS_HY2:-$(core_rand_pass)}"
  fi
  if [[ " $chosen " == *" tuic "* ]]; then
    port_tuic=$(core_prompt "TUIC 端口" "${PORT_TUIC:-$(core_rand_port)}")
    pass_tuic=$(core_prompt "TUIC 密码" "${PASS_TUIC:-$(core_rand_pass)}")
    uuid_tuic=$(core_prompt "TUIC UUID" "${UUID_TUIC:-$(core_rand_uuid)}")
  else
    pass_tuic="${PASS_TUIC:-$(core_rand_pass)}"
    uuid_tuic="${UUID_TUIC:-$(core_rand_uuid)}"
  fi
  if [[ " $chosen " == *" socks "* ]]; then
    port_socks=$(core_prompt "SOCKS5 端口" "${PORT_SOCKS:-$(core_rand_port)}")
    # 默认随机用户名/密码；两者任一留空 = 关闭认证（不推荐，等同开放代理）
    user_socks=$(core_prompt "SOCKS5 用户名(留空=关闭认证，不推荐)" "${USER_SOCKS:-$(core_rand_user)}")
    pass_socks=$(core_prompt "SOCKS5 密码(留空=关闭认证)" "${PASS_SOCKS:-$(core_rand_pass)}")
  else
    # 未选 SOCKS5：保留原认证配置（下次启用时恢复），端口留空跳过 inbound
    user_socks="${USER_SOCKS:-}"
    pass_socks="${PASS_SOCKS:-}"
  fi
  obfs=$(core_prompt "Hysteria2 obfs 密码(留空关闭)" "${OBS_HY2:-}")
  hop=$(core_prompt "Hysteria2 端口跳跃段(如 50001-51000，留空关闭)" "${HOP_HY2:-}")

  # 输入校验（安全）：凭证类手动输入此前允许任意字符，含引号/反斜杠/$/反引号/空白
  # 的输入会破坏 .state（被 source 的 shell 文件）与 config.json 结构。
  # 此处统一用白名单拦截；空值合法（obfs 可留空关闭）。
  local _item _name _val
  for _item in "AnyTLS 密码:$pass_any" \
               "Hysteria2 密码:$pass_hy2" \
               "TUIC 密码:$pass_tuic" \
               "Hysteria2 obfs:$obfs" \
               "SOCKS5 用户名:$user_socks" \
               "SOCKS5 密码:$pass_socks"; do
    _name=${_item%%:*}; _val=${_item#*:}
    if ! _config_credential_ok "$_val"; then
      error "$_name 含非法字符（仅允许字母、数字与 !@#%^*_+=~.,:- ，不能含空格/引号/反斜杠/\$/反引号）"
      return 1
    fi
  done
  # TUIC UUID 必须是标准 8-4-4-4-12 十六进制格式（写进 .state 与 JSON 前拦截）
  if [[ -n "$uuid_tuic" ]] \
     && [[ ! "$uuid_tuic" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    error "TUIC UUID 格式不合法（应为 8-4-4-4-12 的十六进制格式）"
    return 1
  fi

  config_gen "$domain" "$port_any" "$port_hy2" "$port_tuic" \
             "$pass_any" "$pass_hy2" "$pass_tuic" "$uuid_tuic" "$obfs" "$hop" \
             "$protos" "$port_socks" "$user_socks" "$pass_socks"
  service_reload
  ok "代理配置已变更并 reload"
  node_gen
}

# 从 .state 恢复既有参数并按基线语法重新生成 config.json。
# 供内核升级（选项 7）后调用：把旧脚本版本（v1.3.x 及更早的 1.13 语法/无 socks 字段）
# 生成的存量 config.json 平滑重建为本脚本基线大版本的最新语法，代理参数保持不变。
# 重建失败会回滚旧配置；新装/基线内补丁升级时配置文件本就正确，重建是幂等安全操作。
# 返回 0=已重建 / 1=重建失败（已回滚原配置）/ 2=无 state 或未安装，跳过。
config_rebuild_from_state() {
  [[ -f "$SB_STATE" ]] || { warn "未找到状态文件 $SB_STATE，跳过配置重建"; return 2; }
  [[ -x "$SB_BIN" ]]  || { warn "未安装 sing-box，跳过配置重建"; return 2; }
  set -a; . "$SB_STATE"; set +a
  local bak="${SB_CONF}.pre-ver.$$"
  [[ -f "$SB_CONF" ]] && cp -f "$SB_CONF" "$bak" 2>/dev/null || true
  if config_gen "$DOMAIN" "$PORT_ANYTLS" "$PORT_HY2" "$PORT_TUIC" \
                "$PASS_ANYTLS" "$PASS_HY2" "$PASS_TUIC" "$UUID_TUIC" \
                "$OBS_HY2" "$HOP_HY2" "$PROTOS" "$PORT_SOCKS" \
                "$USER_SOCKS" "$PASS_SOCKS"; then
    rm -f "$bak" 2>/dev/null || true
    return 0
  fi
  # 生成或校验失败：回滚旧配置，避免带病 reload
  [[ -f "$bak" ]] && mv -f "$bak" "$SB_CONF" 2>/dev/null || true
  warn "config.json 重建失败，已回滚原配置"
  return 1
}
