# Alpine Linux 适配开发指南

> **目标读者**：负责实现 Alpine 支持的 AI 开发者 / 贡献者
> **前提**：已通读项目全部源码，理解 systemd 依赖现状
> **产出标准**：完成后脚本可在 Alpine 3.19+ 上完成与 Debian/Ubuntu 等价的一键安装、管理、诊断全流程

---

## 1. 问题概述

当前项目（easy-singbox v1.1.2）**硬依赖 systemd**，无法在 Alpine Linux 上运行。Alpine 默认使用 **OpenRC** init 系统和 **BusyBox** 用户态工具集，与 systemd 体系完全不兼容。

README 已声明仅支持「Debian 11/12、Ubuntu 20.04/22.04/24.04 等 systemd 发行版」。本指南给出完整的适配方案。

### 1.1 核心冲突点速览

| 功能 | 当前实现（systemd） | Alpine 对应（OpenRC / BusyBox） |
|---|---|---|
| 服务管理 | `systemctl start/stop/restart/enable/disable` | `rc-service` / `rc-update` |
| 服务状态 | `systemctl is-active/is-enabled` | `rc-service status` / `rc-update show` |
| 服务单元文件 | `/etc/systemd/system/sing-box.service` | `/etc/init.d/sing-box` |
| 日志查看 | `journalctl -u sing-box` | `cat /var/log/sing-box.log`（需配置日志输出） |
| 虚拟化探测 | `systemd-detect-virt` | `virt-what`（已有兜底，基本可用） |
| 系统用户创建 | `useradd --system` | `adduser -S -H -s /sbin/nologin` |
| 用户删除 | `userdel` | `deluser` |
| 切换用户测试 | `runuser -u` | `su -s /bin/sh -c`（已有兜底） |
| 包管理器 | `apt` / `yum`（仅提示用） | `apk` |

### 1.2 全部受影响文件清单

```
sb                    # 主入口：journalctl 调用（sb:502）、userdel（sb:314）
lib/core.sh           # systemctl is-active（:96）、systemd-detect-virt（:60）
lib/service.sh        # 整个文件基于 systemd 单元 + systemctl
lib/firewall.sh       # firewalld 分支用 systemctl（:14, :123）
lib/cert.sh           # reloadcmd 写死 systemctl reload（:67, :115）
lib/diag.sh           # systemctl / journalctl 遍布全文
lib/node.sh           # 仅提示文本含 apt/yum（:77），无功能性依赖
lib/port_hop.sh       # iptables/nftables，Alpine 原生支持，无需改动
lib/config.sh         # 间接依赖 service.sh，无直接 systemd 调用
lib/protocol/*.sh     # 纯 config.json 片段生成，无系统依赖
templates/config.json.tpl  # 模板文件，无系统依赖
```

---

## 2. 架构设计：Init 系统抽象层

### 2.1 核心原则

**不修改现有函数签名**，通过在 `lib/core.sh` 新增 init 系统探测，在 `lib/service.sh` 内部做分支适配。调用方（`sb`、`lib/config.sh`、`lib/cert.sh` 等）无需感知底层 init 系统。

### 2.2 新增文件

```
lib/init.sh            # [新增] init 系统抽象层
```

### 2.3 设计示意

```
sb / config.sh / cert.sh / diag.sh
        │
        ├── 调用 service_start() / service_stop() / ...  （签名不变）
        │
lib/service.sh
        │
        ├── source lib/init.sh
        │
        ├── if INIT_SYSTEM == "systemd":
        │       systemctl ...                    （现有逻辑）
        │
        ├── elif INIT_SYSTEM == "openrc":
        │       rc-service ... / rc-update ...   （新增逻辑）
        │
        └── else:
                error "不支持的 init 系统"
```

---

## 3. 逐文件改造指南

### 3.1 新增 `lib/init.sh` — Init 系统探测

```bash
#!/usr/bin/env bash
# lib/init.sh — init 系统探测与抽象
# 在 lib/core.sh 之后 source，提供 INIT_SYSTEM 全局变量。

# 探测当前系统的 init 系统
# 返回: "systemd" | "openrc" | "unknown"
init_detect() {
  # 方法1: 检查 PID 1
  local pid1
  pid1=$(cat /proc/1/comm 2>/dev/null || true)
  case "$pid1" in
    systemd)  echo "systemd"; return 0 ;;
    init|openrc-init) 
      # openrc-init 是 OpenRC 0.43+ 的专用 PID1
      if command -v rc-service >/dev/null 2>&1; then
        echo "openrc"; return 0
      fi
      ;;
  esac

  # 方法2: 检查命令是否存在
  if command -v systemctl >/dev/null 2>&1; then
    echo "systemd"; return 0
  fi
  if command -v rc-service >/dev/null 2>&1; then
    echo "openrc"; return 0
  fi

  echo "unknown"
}

# 缓存探测结果，避免重复调用
if [[ -z "${INIT_SYSTEM:-}" ]]; then
  INIT_SYSTEM=$(init_detect)
fi
```

**source 顺序**：在 `sb` 文件的模块载入区，`core.sh` 之后、`service.sh` 之前插入：

```bash
# sb 文件第 24 行之后
source "$SB_DIR/lib/core.sh"
source "$SB_DIR/lib/init.sh"      # ← 新增
source "$SB_DIR/lib/service.sh"
```

### 3.2 改造 `lib/service.sh` — 服务管理

这是改动量最大的文件。**保留所有函数名和调用签名不变**，内部按 `INIT_SYSTEM` 分支。

#### 3.2.1 服务单元路径

```bash
# 在 lib/core.sh 或 lib/service.sh 顶部，按 init 系统选择路径
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  SB_SERVICE="/etc/init.d/sing-box"        # OpenRC init 脚本
else
  SB_SERVICE="/etc/systemd/system/sing-box.service"  # 原有值
fi
```

> **注意**：`SB_SERVICE` 当前在 `lib/core.sh:27` 定义为硬编码值。需改为条件赋值，或移到 `lib/init.sh` 中在探测后赋值。

#### 3.2.2 `service_write_unit()` — 写入服务单元

在现有函数中增加 OpenRC 分支：

```bash
service_write_unit() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    service_write_openrc_unit
    return
  fi
  # === 以下为现有 systemd 逻辑，保持不变 ===
  cat > "$SB_SERVICE" <<'EOF'
[Unit]
...
EOF
}

# 新增：生成 OpenRC init 脚本
service_write_openrc_unit() {
  cat > "$SB_SERVICE" <<'OPENRC_EOF'
#!/sbin/openrc-run
# OpenRC init script for sing-box
# Managed by easy-singbox — do not edit manually

description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"

# 降权运行
user="singbox"
group="singbox"

# 启动前校验配置
start_pre() {
  checkpath -d -m 0755 -o singbox:singbox /var/log/sing-box
  "$command" check -c /etc/sing-box/config.json || return 1
}

# 依赖
depend() {
  need net
  after firewall
}
OPENRC_EOF
  chmod 755 "$SB_SERVICE"
}
```

#### 3.2.3 `service_ensure_user()` — 创建用户

```bash
service_ensure_user() {
  if ! id singbox >/dev/null 2>&1; then
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      # BusyBox adduser: -S=system, -H=no-home, -s=shell
      adduser -S -H -s /sbin/nologin singbox 2>/dev/null || \
      adduser -S -H singbox 2>/dev/null || true
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin singbox 2>/dev/null || \
      useradd --system --no-create-home singbox 2>/dev/null || true
    fi
  fi
}
```

#### 3.2.4 `service_install()` — 安装服务

```bash
service_install() {
  service_ensure_user
  service_write_unit
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add sing-box default 2>/dev/null || true
  else
    systemctl daemon-reload
    systemctl enable sing-box
  fi
}
```

#### 3.2.5 `service_start()` — 启动服务

```bash
service_start() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    service_start_openrc
    return
  fi
  # === 现有 systemd 逻辑保持不变 ===
  systemctl daemon-reload
  systemctl start sing-box 2>/dev/null || true
  # ... 端口跳跃 + 健康检查 ...
}

service_start_openrc() {
  rc-service sing-box start 2>/dev/null || true
  # 重新应用端口跳跃（复用现有逻辑）
  if [[ -f "$SB_STATE" ]]; then
    set -a; . "$SB_STATE"; set +a
    [[ -n "$HOP_HY2" && -n "$PORT_HY2_LISTEN" ]] && hop_apply "$PORT_HY2_LISTEN" "$HOP_HY2"
  fi
  # 健康检查：等待进程起来（最多 15s）
  local i
  for i in $(seq 1 15); do
    rc-service sing-box status 2>/dev/null | grep -qw started && break
    sleep 1
  done
  if ! rc-service sing-box status 2>/dev/null | grep -qw started; then
    error "sing-box 服务未能启动，节点将无法连接。最近日志："
    tail -30 /var/log/sing-box/sing-box.log >&2 2>/dev/null || true
    return 1
  fi
  ok "sing-box 服务已启动并运行"
}
```

#### 3.2.6 其余服务控制函数

```bash
service_stop() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box stop 2>/dev/null || true
  else
    systemctl stop sing-box 2>/dev/null || true
  fi
}

service_restart() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box restart 2>/dev/null || true
  else
    systemctl daemon-reload
    systemctl restart sing-box
  fi
}

service_reload() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    # OpenRC 无 reload 语义，restart 等价
    rc-service sing-box restart 2>/dev/null || true
  else
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
  fi
}

service_disable() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update del sing-box default 2>/dev/null || true
  else
    systemctl disable sing-box 2>/dev/null || true
  fi
}

service_is_active() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box status 2>/dev/null | grep -qw started
  else
    systemctl is-active --quiet sing-box 2>/dev/null
  fi
}

service_remove_unit() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box stop 2>/dev/null || true
    rc-update del sing-box default 2>/dev/null || true
    rm -f "$SB_SERVICE"
  else
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f "$SB_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
  fi
}
```

#### 3.2.7 `service_verify_ports()` — 端口监听校验

此函数仅依赖 `ss` 命令和 `core_listening_ports()`，与 init 系统无关。**唯一需要改的是日志查看部分**：

```bash
service_verify_ports() {
  # ... 前半段不变（ss 命令检查端口） ...
  if (( bad )); then
    error "存在未监听的端口，客户端会报 connection refused。最近日志："
    # 改为按 init 系统查看日志
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      tail -40 /var/log/sing-box/sing-box.log >&2 2>/dev/null || true
    else
      journalctl -u sing-box -n 40 --no-pager >&2 || true
    fi
    warn "可执行 sb → 选项 9 生成完整诊断报告"
    return 1
  fi
  return 0
}
```

### 3.3 改造 `lib/core.sh`

#### 3.3.1 `SB_SERVICE` 路径条件化

将 `lib/core.sh:27` 的硬编码：

```bash
# 原代码
SB_SERVICE="/etc/systemd/system/sing-box.service"
```

改为在 `lib/init.sh` source 之后动态赋值（因为 `INIT_SYSTEM` 在 `init.sh` 中确定）：

```bash
# lib/core.sh 中保持占位，实际在 init.sh 中覆盖
SB_SERVICE="/etc/systemd/system/sing-box.service"  # 默认值，init.sh 会按系统覆盖
```

然后在 `lib/init.sh` 末尾追加：

```bash
# 按 init 系统设置服务单元路径
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  SB_SERVICE="/etc/init.d/sing-box"
fi
```

#### 3.3.2 `core_sb_status()` — 服务状态探测

```bash
core_sb_status() {
  local installed running version proto
  if [[ -x "$SB_BIN" ]]; then installed="已安装"; else installed="未安装"; fi
  # 改为调用 service_is_active（已做 init 系统适配）
  if service_is_active; then running="已运行"; else running="未运行"; fi
  # ... 其余不变 ...
}
```

#### 3.3.3 `core_detect_virt()` — 已有兜底，无需改动

```bash
# 现有代码已正确处理：systemd-detect-virt 优先，virt-what 兜底，再失败显示 unknown
# Alpine 上 systemd-detect-virt 不存在，自动走 virt-what（apk add virt-what）
# 若 virt-what 也不存在则显示 unknown — 行为可接受
```

#### 3.3.4 `core_detect_os()` — 已兼容

Alpine 有 `/etc/os-release`，现有代码可直接读取 `PRETTY_NAME`。无需改动。

### 3.4 改造 `lib/cert.sh`

#### 3.4.1 `cert_install_files()` — reloadcmd 动态化

```bash
cert_install_files() {
  local domain=$1
  mkdir -p "$SB_DIR_SSL"
  # 根据 init 系统选择 reloadcmd
  local reload_cmd
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    reload_cmd="rc-service sing-box restart 2>/dev/null || true"
  else
    reload_cmd="systemctl is-enabled sing-box >/dev/null 2>&1 && systemctl reload sing-box || true"
  fi
  "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
    --key-file      "$SB_DIR_SSL/privkey.pem" \
    --fullchain-file "$SB_DIR_SSL/fullchain.pem" \
    --reloadcmd "$reload_cmd" --ecc
  # ... 权限设置不变 ...
}
```

#### 3.4.2 `cert_renew()` — 提示文本修正

```bash
cert_renew() {
  [[ -r "$SB_CF_ENV" ]] && set -a && . "$SB_CF_ENV" && set +a
  "$ACME_HOME/acme.sh" --renew-all --ecc || "$ACME_HOME/acme.sh" --cron
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    ok "续期检查完成（acme.sh cron 会自动续期，reloadcmd 指向 rc-service sing-box restart）"
  else
    ok "续期检查完成（acme.sh cron 会自动续期，reloadcmd 指向 systemctl reload sing-box）"
  fi
}
```

### 3.5 改造 `lib/diag.sh`

诊断模块需要全面适配，因为大量调用 `systemctl` / `journalctl`。

#### 3.5.1 新增日志查看辅助函数

在 `lib/diag.sh` 顶部新增：

```bash
# 统一日志查看入口，按 init 系统选择数据源
# 参数: 行数
diag_print_logs() {
  local lines=${1:-80}
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    echo "--- OpenRC 日志 /var/log/sing-box/sing-box.log (最近 $lines 行) ---"
    tail -n "$lines" /var/log/sing-box/sing-box.log 2>/dev/null || echo "日志文件不可用"
  else
    echo "--- journald 日志 (最近 $lines 行) ---"
    journalctl -u sing-box -n "$lines" --no-pager 2>/dev/null || echo "journalctl 不可用"
  fi
}

# 获取服务状态摘要行
diag_service_status_line() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    local status
    status=$(rc-service sing-box status 2>/dev/null || true)
    echo "status    : $status"
    echo "enabled   : $(rc-update show default 2>/dev/null | grep -w sing-box || echo 'disabled')"
  else
    echo "is-active : $(systemctl is-active sing-box 2>/dev/null || true)"
    echo "is-enabled: $(systemctl is-enabled sing-box 2>/dev/null || true)"
    systemctl status sing-box --no-pager -n 0 2>/dev/null | head -12 || true
  fi
}
```

#### 3.5.2 替换各诊断小节

**第 2 节（服务状态）**：

```bash
_d_sec "2. 服务状态"
diag_service_status_line
```

**第 3 节（服务日志）**：

```bash
_d_sec "3. 服务日志（最近 80 行，含崩溃原因）"
diag_print_logs 80
```

**第 6 节**中 `diag.sh:84` 的安装提示：

```bash
# 原代码
echo "未安装 ss(iproute2)，无法核对监听状态；请先安装：apt install iproute2 / yum install iproute"
# 改为按系统提示
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  echo "未安装 ss(iproute2)，无法核对监听状态；请先安装：apk add iproute2"
else
  echo "未安装 ss(iproute2)，无法核对监听状态；请先安装：apt install iproute2 / yum install iproute"
fi
```

**第 13 节 `diag_verdict()`**：

```bash
# 原 diag.sh:203
systemctl is-active --quiet sing-box 2>/dev/null && svc_up=1 || svc_up=0
# 改为
service_is_active && svc_up=1 || svc_up=0
```

#### 3.5.3 诊断子菜单 `diag_menu()`

```bash
diag_menu() {
  echo "诊断与日志："
  echo "  [1] 生成完整诊断报告（推荐，一次性收集所有排查信息）"
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    echo "  [2] 查看实时日志（tail -f /var/log/sing-box/sing-box.log，Ctrl+C 退出）"
  else
    echo "  [2] 查看实时日志（journalctl -f，Ctrl+C 退出）"
  fi
  echo "  [3] 切换 sing-box 日志级别（info <-> debug）"
  local c; c=$(core_prompt "选择" "1")
  case "$c" in
    2)
      if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        tail -f /var/log/sing-box/sing-box.log 2>/dev/null || true
      else
        journalctl -u sing-box -f --no-pager 2>/dev/null || true
      fi
      ;;
    3) diag_toggle_log_level || true ;;
    *) diag_run || true ;;
  esac
}
```

### 3.6 改造 `sb`（主入口）

#### 3.6.1 `sb log` 子命令

```bash
# 原 sb:502
log|logs)       journalctl -u sing-box -n 200 --no-pager ;;
# 改为
log|logs)
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    tail -n 200 /var/log/sing-box/sing-box.log 2>/dev/null || echo "日志文件不可用"
  else
    journalctl -u sing-box -n 200 --no-pager
  fi
  ;;
```

#### 3.6.2 `sb_uninstall()` 中的 `userdel`

```bash
# 原 sb:314
userdel singbox 2>/dev/null || true
# 改为
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  deluser singbox 2>/dev/null || true
else
  userdel singbox 2>/dev/null || true
fi
```

### 3.7 改造 `lib/firewall.sh`

#### 3.7.1 `fw_detect()` — firewalld 分支

```bash
fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    FW_BACKEND="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && service_is_active firewalld 2>/dev/null; then
    FW_BACKEND="firewalld"
  # ... 其余不变 ...
```

> **注意**：`systemctl is-active --quiet firewalld` 改为 `service_is_active firewalld`。但 `service_is_active` 当前硬编码检查 `sing-box`。需要**通用化**该函数，接受服务名参数。

修正 `lib/service.sh` 中的 `service_is_active`：

```bash
# 原代码
service_is_active() { systemctl is-active --quiet sing-box 2>/dev/null; }
# 改为通用版（参数可选，默认 sing-box）
service_is_active() {
  local svc=${1:-sing-box}
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service "$svc" status 2>/dev/null | grep -qw started
  else
    systemctl is-active --quiet "$svc" 2>/dev/null
  fi
}
```

#### 3.7.2 `fw_disable()` — firewalld 分支

```bash
fw_disable() {
  case "$FW_BACKEND" in
    ufw)       ufw disable >/dev/null 2>&1 || true ;;
    firewalld)
      if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service firewalld stop 2>/dev/null || true
        rc-update del firewalld default 2>/dev/null || true
      else
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
      fi
      ;;
    iptables)  iptables -P INPUT ACCEPT 2>/dev/null || true; iptables -F INPUT 2>/dev/null || true ;;
    none)      : ;;
  esac
}
```

### 3.8 改造 `lib/node.sh`（仅提示文本）

```bash
# 原 node.sh:77
warn "未安装 qrencode，已跳过二维码。可安装后执行 sb 选"查看节点"重新生成（apt install qrencode / yum install qrencode）"
# 改为
local pkg_hint
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  pkg_hint="apk add qrencode"
else
  pkg_hint="apt install qrencode / yum install qrencode"
fi
warn "未安装 qrencode，已跳过二维码。可安装后执行 sb 选"查看节点"重新生成（$pkg_hint）"
```

### 3.9 `lib/port_hop.sh` — 无需改动

Alpine 原生支持 `iptables`（`apk add iptables`）和 `nft`（`apk add nftables`）。现有 `hop_backend()` 的探测逻辑 `command -v iptables` / `command -v nft` 在 Alpine 上直接可用。

### 3.10 `templates/config.json.tpl` — 无需改动

模板是纯 JSON 配置，与 init 系统无关。

---

## 4. Alpine 特有注意事项

### 4.1 sing-box 日志输出

systemd 下 sing-box 日志走 stdout → journald。OpenRC 下需**显式配置日志文件**，否则日志丢失。

**方案**：OpenRC init 脚本中已配置 `output_log` / `error_log` 指向 `/var/log/sing-box/sing-box.log`。但还需在 `service_write_openrc_unit()` 中确保目录存在（`start_pre` 里的 `checkpath` 已处理）。

### 4.2 OpenRC 无 `daemon-reload`

systemd 修改 unit 文件后需 `systemctl daemon-reload`。OpenRC 直接读取 `/etc/init.d/` 脚本，无需等价操作。`service_install()` 的 OpenRC 分支中不要调用 daemon-reload。

### 4.3 OpenRC reload 语义

OpenRC 的 `rc-service reload` 发送 SIGHUP，而 sing-box 不支持 SIGHUP 热重载。因此 `service_reload()` 在 OpenRC 下改为 `restart`。这在证书续期场景下会短暂中断（约 1-2 秒），可接受。

### 4.4 cron 服务

acme.sh 续期依赖 cron。Alpine 需确保 cron 服务安装并启动：

```bash
# 建议在 service_install() 的 OpenRC 分支中追加检测
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  if ! rc-service crond status 2>/dev/null | grep -qw started; then
    warn "cron 服务未运行，acme.sh 证书将无法自动续期。请安装并启动：apk add dcron && rc-update add crond default && rc-service crond start"
  fi
fi
```

### 4.5 依赖包安装提示

Alpine 上缺失的工具对应的安装命令：

| 工具 | Alpine 安装命令 |
|---|---|
| `ss` (iproute2) | `apk add iproute2` |
| `qrencode` | `apk add qrencode` |
| `iptables` | `apk add iptables` |
| `nftables` | `apk add nftables` |
| `curl` | `apk add curl` |
| `git` | `apk add git` |
| `sha256sum` | `apk add coreutils`（BusyBox 自带，但功能有限） |
| `uuidgen` | `apk add util-linux` |
| `openssl` | `apk add openssl` |
| `virt-what` | `apk add virt-what` |
| `cron` | `apk add dcron` |

### 4.6 BusyBox `adduser` 语法差异

BusyBox `adduser` 不支持 `--system` / `--no-create-home` 长选项，需用短选项：

```bash
# BusyBox adduser
adduser -S -H -s /sbin/nologin -D singbox
# -S: system user
# -H: no home directory
# -s: shell
# -D: don't ask for password
```

### 4.7 `readlink -f` 兼容性

`sb.sh:4` 和 `install.sh:4` 使用 `readlink -f`。BusyBox 的 `readlink` 默认不支持 `-f`（需 `readlink -f` 或 `realpath`）。Alpine 3.13+ 的 BusyBox 已支持，但建议在文档中标注最低版本要求为 **Alpine 3.19+**。

### 4.8 `tput` 颜色

`lib/core.sh` 使用 `tput setaf` 初始化颜色变量。Alpine 需 `apk add ncurses`（注意：Alpine 上没有名为 `tput` 的软件包，tput 由 `ncurses` 提供）。
v1.2.1 起颜色初始化同时检测 `command -v tput`，缺失时（无论是否终端）一律静默降级为无色，不影响功能——**绝不允许因颜色问题中断脚本**。

---

## 5. 改造检查清单

### 5.1 代码改造

- [ ] 新增 `lib/init.sh`，实现 `init_detect()` 和 `INIT_SYSTEM` 赋值
- [ ] 在 `sb` 模块载入区（:24 之后）插入 `source lib/init.sh`
- [ ] `lib/service.sh`：全部函数增加 OpenRC 分支
- [ ] `lib/core.sh:27`：`SB_SERVICE` 改为条件赋值
- [ ] `lib/core.sh:96`：`core_sb_status()` 改用 `service_is_active()`
- [ ] `lib/firewall.sh:14`：firewalld 探测改用 `service_is_active firewalld`
- [ ] `lib/firewall.sh:123`：firewalld 停止改用 OpenRC 命令
- [ ] `lib/cert.sh:67`：`reloadcmd` 按 init 系统动态生成
- [ ] `lib/cert.sh:115`：续期提示文本适配
- [ ] `lib/diag.sh`：新增 `diag_print_logs()` / `diag_service_status_line()`
- [ ] `lib/diag.sh`：第 2/3/6/13 节替换为通用函数
- [ ] `lib/diag.sh:268-272`：诊断子菜单实时日志适配
- [ ] `lib/node.sh:77`：安装提示增加 `apk` 命令
- [ ] `sb:502`：`sb log` 子命令适配
- [ ] `sb:314`：`userdel` 改为 `deluser`
- [ ] `sb.sh:46-49`：完整性校验文件列表增加 `lib/init.sh`

### 5.2 测试验证

- [ ] **Alpine 3.19 x86_64**：完整安装流程（HTTP-01 证书 + 三协议 + 端口跳跃）
- [ ] **Alpine 3.19 x86_64**：完整安装流程（DNS-01 Cloudflare 证书）
- [ ] **Alpine 3.20 aarch64**：完整安装流程
- [ ] **Debian 12**：回归测试，确认 systemd 路径无退化
- [ ] **Ubuntu 24.04**：回归测试
- [ ] `sb` 主面板显示正确（系统名、架构、虚拟化、BBR、IP、服务状态）
- [ ] `sb` 选项 2（变更代理配置）：端口/凭证变更后 reload 生效
- [ ] `sb` 选项 3（变更证书）：重签后 reload 生效
- [ ] `sb` 选项 4/5/6：启停/重启正常
- [ ] `sb` 选项 7：版本切换（下载 + 校验 + 重启）
- [ ] `sb` 选项 8：脚本自更新（拉取 + 对比 + 覆盖）
- [ ] `sb` 选项 9：诊断报告 13 节全部输出正常，无 `command not found`
- [ ] `sb debug`：命令行入口等效主页面选项 9
- [ ] `sb log`：日志查看正常
- [ ] `sb uninstall`：服务停止、单元删除、用户删除、文件清理
- [ ] 证书续期：acme.sh cron 执行后 reloadcmd 正常触发服务重启
- [ ] 端口跳跃：iptables REDIRECT 规则生效，客户端 mport 可用
- [ ] 降权运行：singbox 用户可读 config.json 与证书，不可读 .state/.cf.env/nodes.txt
- [ ] 重启服务器后服务自启动

### 5.3 边界场景

- [ ] Alpine 上未安装 `virt-what` → 主面板虚拟化显示 `unknown`（可接受）
- [ ] Alpine 上无 `tput` → 颜色降级为空（v1.2.1 起 `command -v tput` 守卫，脚本正常跑）
- [ ] Alpine 上无 `uuidgen` → `core_rand_uuid()` 走 `/dev/urandom` + `sed` 兜底（已有）
- [ ] Alpine 上无 `sha256sum` → `core_rand_pass()` 不受影响；但 `sb_download()` 的二进制校验会走警告分支
- [ ] Alpine 容器环境（LXC/Docker）→ OpenRC 可能无法正常运行 PID1，需在文档中标注「仅支持非容器 Alpine」

---

## 6. 文件依赖关系图

```
sb (主入口)
├── source lib/core.sh          ← 改: SB_SERVICE 条件化, core_sb_status
├── source lib/init.sh          ← 新增
├── source lib/service.sh       ← 改: 全函数 OpenRC 分支
├── source lib/firewall.sh      ← 改: firewalld 分支
├── source lib/port_hop.sh      ← 不改
├── source lib/cert.sh          ← 改: reloadcmd 动态化
├── source lib/protocol/*.sh   ← 不改
├── source lib/config.sh        ← 不改（间接依赖 service.sh）
├── source lib/node.sh          ← 改: 仅提示文本
└── source lib/diag.sh          ← 改: 日志/状态函数通用化
```

---

## 7. 实施顺序建议

1. **先写 `lib/init.sh`** + 在 `sb` 中 source — 建立探测基础
2. **改 `lib/service.sh`** — 这是核心，所有服务管理经过此处
3. **改 `lib/core.sh`** — `SB_SERVICE` 条件化 + `core_sb_status`
4. **改 `lib/firewall.sh`** — firewalld 分支
5. **改 `lib/cert.sh`** — reloadcmd 动态化
6. **改 `lib/diag.sh`** — 日志/状态通用化
7. **改 `sb`** — `log` 子命令 + `userdel`
8. **改 `lib/node.sh`** — 提示文本
9. **改 `sb.sh`** — 完整性校验列表加 `lib/init.sh`
10. **Alpine 环境测试** — 按 5.2 清单逐项验证
11. **回归测试** — Debian/Ubuntu 上确认无退化

---

## 8. 附录：OpenRC init 脚本完整参考

以下是需要生成到 `/etc/init.d/sing-box` 的完整 OpenRC 脚本：

```bash
#!/sbin/openrc-run
# OpenRC init script for sing-box
# Managed by easy-singbox — do not edit manually

description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"
user="singbox"
group="singbox"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -m 0755 -o singbox:singbox /var/log/sing-box
  "$command" check -c /etc/sing-box/config.json || return 1
}
```

**与 systemd unit 的对照**：

| systemd unit 指令 | OpenRC 对应 | 说明 |
|---|---|---|
| `ExecStartPre=...check` | `start_pre()` | 启动前校验配置 |
| `ExecStart=...run` | `command` + `command_args` | 启动命令 |
| `Restart=always` | OpenRC 需额外配置 supervise | 见下方说明 |
| `User=singbox` | `user="singbox"` | 降权运行 |
| `Group=singbox` | `group="singbox"` | 降权运行 |
| `LimitNOFILE=100000` | `rc_ulimit="-n 100000"` | 文件描述符限制 |
| `NoNewPrivileges=true` | （无直接对应） | 由 OpenRC 运行环境保证 |
| `ProtectSystem=strict` | （无直接对应） | 需依赖文件权限 |
| `ReadOnlyPaths=/etc/sing-box` | （无直接对应） | 需依赖文件权限 |
| `ProtectHome=true` | （无直接对应） | singbox 用户无 home |
| `PrivateTmp=true` | （无直接对应） | OpenRC 无 namespace 支持 |

### 关于 `Restart=always`

OpenRC 默认不会自动重启崩溃的进程。如需自动重启，有两种方案：

**方案 A（推荐）**：使用 `supervise-daemon`（OpenRC 内置）

```bash
# 在 init 脚本中替换 command_background
supervise_daemon_args="--user singbox --group singbox"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"
```

将 `command_background=true` 替换为使用 `supervise-daemon`，它会自动重启进程。

**方案 B**：安装 `s6` 或 `runit` 作为监督进程（过度复杂，不推荐）

**建议在实现时采用方案 A**，完整 init 脚本如下：

```bash
#!/sbin/openrc-run
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervise_daemon_args="--user singbox --group singbox --stdout /var/log/sing-box/sing-box.log --stderr /var/log/sing-box/sing-box.log"
pidfile="/run/sing-box.pid"
respawn_delay=5
respawn_max=0

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -m 0755 -o singbox:singbox /var/log/sing-box
  "$command" check -c /etc/sing-box/config.json || return 1
}
```

- `respawn_delay=5`：等价于 `RestartSec=5`
- `respawn_max=0`：无限重启（等价于 `Restart=always`）

---

## 9. 常见问题

**Q: 为什么不直接在 Alpine 上安装 systemd？**
A: 虽然 `apk add systemd` 技术上可行，但 Alpine 设计上不使用 systemd，强制安装会破坏系统结构（PID1 仍为 OpenRC），且 systemd 依赖大量 glibc 特性，与 Alpine 的 musl libc 存在兼容性问题。

**Q: Alpine 上 sing-box 二进制是否兼容？**
A: 是的。sing-box 官方发布的 `sing-box-*-linux-amd64.tar.gz` 使用静态编译，不依赖 glibc/musl，在 Alpine 上直接可用。本项目下载逻辑（`sb_download()`）无需改动。

**Q: acme.sh 在 Alpine 上是否兼容？**
A: 是的。acme.sh 是纯 bash 脚本，依赖 `curl` 和 `openssl`（或 `wget`），Alpine 上安装 `apk add curl openssl` 即可。

**Q: 是否需要处理 musl libc 与 glibc 的差异？**
A: 不需要。本项目的全部代码是 bash 脚本，不涉及 C 编译。sing-box 二进制是静态编译，acme.sh 是纯 bash。唯一可能遇到的是 BusyBox 工具（`tr`、`sed`、`grep`）的 GNU 扩展差异，但现有代码已避免使用 GNU 专有语法。

**Q: Docker 容器中的 Alpine 支持吗？**
A: 不支持。容器环境通常不运行 init 系统（PID1 为容器运行时），OpenRC 无法正常工作。本项目的服务管理依赖 init 系统可用，建议仅在 Alpine 虚拟机/物理机上使用。

---

## 10. 变更记录

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-08-18 | v1.0 | 初版，基于 v1.1.2 代码分析生成 |
