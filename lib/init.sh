#!/usr/bin/env bash
# lib/init.sh — init 系统探测与抽象
# 在 lib/core.sh 之后 source（见 sb 模块载入区），提供 INIT_SYSTEM 全局变量，
# 并按 init 系统覆盖 SB_SERVICE 服务单元路径与日志文件路径。

# 探测当前系统的 init 系统；返回: "systemd" | "openrc" | "unknown"
init_detect() {
  # 方法1: 检查 PID 1（Alpine 上 openrc-init 是 OpenRC 0.43+ 的专用 PID1）
  local pid1
  pid1=$(cat /proc/1/comm 2>/dev/null || true)
  case "$pid1" in
    systemd)
      echo "systemd"; return 0 ;;
    init|openrc-init)
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

# 按 init 系统设置服务单元路径（覆盖 lib/core.sh 中的 systemd 默认值）
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  SB_SERVICE="/etc/init.d/sing-box"
fi

# OpenRC 下 sing-box 日志落文件（systemd 走 journald）
SB_LOG_FILE="/var/log/sing-box/sing-box.log"
