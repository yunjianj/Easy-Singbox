# easy-singbox 端口检查竞态条件修复指导

> 目标脚本：`easy-singbox`（管理面板，版本 v1.2.11，含 `sb` 命令入口）
> 目标环境：Debian 13 (trixie)，sing-box v1.13.19，systemd 管理服务
> 文档用途：供其他 AI / 开发者按此指导修改脚本源码，修复端口检查误报问题

---

## 一、问题现象

在 `systemctl restart sing-box` 之后，脚本**立即**检查端口监听状态，出现误报：

```
[ OK ] sing-box 服务已启动并运行
[ERR ] AnyTLS 未监听 tcp/57585
[ OK ] Hysteria2 监听正常 udp/60857
[ERR ] TUIC 未监听 udp/53813
[ERR ] 存在未监听的端口，客户端会报 connection refused。最近日志：
[ERR ] 端口未正常监听，安装中止。请执行 sb → 选项 9 生成诊断报告后排查。
```

而 36 秒后执行的诊断（`sb → 选项 9 → 生成完整诊断报告`）显示：

```
AnyTLS    tcp/57585 : 监听中
Hysteria2 udp/60857 : 监听中
TUIC      udp/53813 : 监听中
本机自连 127.0.0.1:57585 : 通
公网自连 35.212.195.191:57585 : 通
```

**服务本身从未失败，节点实际可用。** 脚本因为误报中止了安装流程，这是必须修复的。

### 证据时间线（摘自现场诊断报告）

| 时间 (UTC) | 事件 |
|---|---|
| 06:42:20 | sing-box (PID 368507) 启动，日志输出 `inbound/anytls-in: tcp server started at [::]:57585`、`hy2-in: udp server started at [::]:60857`、`tuic-in: udp server started at [::]:53813`、`sing-box started (0.02s)` |
| 06:42:20 | 脚本立即做端口检查 → AnyTLS / TUIC 误报未监听 |
| 06:42:56 | 诊断报告复查 → 三个端口全部监听正常 |

---

## 二、根因分析

**竞态条件（race condition）。**

脚本的执行顺序是：

1. `systemctl start / restart sing-box` → systemd 返回"已启动"
2. **立即**执行端口检查（`ss` / `netstat`）

问题在于：`systemctl` 返回成功只代表**主进程已拉起**，并不代表 **socket 已全部完成 bind**。sing-box 从进程 spawn 到完成 TCP/UDP socket 绑定 + TLS 证书读取需要几十毫秒。检查恰好落在这个时间窗口内，就产生误报。

- Hy2 (udp/60857) 恰好先完成 bind，通过检查；
- AnyTLS (tcp/57585)、TUIC (udp/53813) 稍晚完成，被误判为未监听。

补充说明：`listen: "::"` 在 `ss` 中显示为 `*:57585`（IPv6 通配 + `bindv6only=0` 覆盖 IPv4），不是导致误报的原因，但修改匹配规则时需兼容该格式。

---

## 三、修改要求（核心）

### 总体思路

把**"启动后一次性即时检查"**改为**"带超时的轮询等待"**：启动服务后循环检查端口，直到全部就绪（或超时），再判定成败。

### 需要修改的位置

在脚本源码中定位以下特征片段（用 grep 定位，任选一个锚点即可）：

```
锚点 1：systemctl start sing-box      （或 systemctl restart sing-box）
锚点 2：存在未监听的端口
锚点 3：监听正常 / 未监听
锚点 4：PORT_ANYTLS / PORT_HY2_LISTEN / PORT_TUIC
```

找到"启动服务 → 检查端口"这一连续代码块（可能是独立函数，如 `check_ports()`、`start_singbox()` 或 `install` 主流程内联代码），将其中**服务启动后紧跟的端口检查部分**整体替换为下面的实现。

### 参考实现（可直接采用的代码）

```bash
# =============================================================
# 端口轮询等待：修复 systemd 返回后 socket 尚未绑定导致的误报
# =============================================================
# 从状态文件读取期望端口（若无状态文件则按实际配置硬编码）
EXPECT_TCP=( "${PORT_ANYTLS:-57585}" )                      # AnyTLS → TCP
EXPECT_UDP=( "${PORT_HY2_LISTEN:-${PORT_HY2:-60857}}" "${PORT_TUIC:-53813}" )  # Hy2、TUIC → UDP

wait_for_ports() {
    local timeout="${1:-10}"        # 最长等待秒数
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        local all_ok=1 p
        for p in "${EXPECT_TCP[@]}"; do
            ss -tln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" || all_ok=0
        done
        for p in "${EXPECT_UDP[@]}"; do
            ss -uln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" || all_ok=0
        done
        [ "$all_ok" -eq 1 ] && return 0
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

# 使用方式（替换原检查代码）：
# systemctl restart sing-box
# if wait_for_ports 10; then
#     echo "[ OK ] 全部端口监听正常"
# else
#     echo "[ERR ] 端口未在 10s 内全部就绪，最近 3 条监听输出："
#     ss -tlnp 2>/dev/null | tail -n 3
#     ss -ulnp 2>/dev/null | tail -n 3
# fi
```

### 关键实现细节（务必遵守）

1. **必须轮询，不能只加固定 `sleep 2`**
   固定 sleep 在慢速机器 / 证书重新签发时仍可能不够。轮询自适应启动耗时，最快收敛，超时才判定失败。

2. **端口匹配规则**
   - 用 `ss -tln`（TCP）、`ss -uln`（UDP）输出做匹配；
   - 匹配串 `[:.]${p}[[:space:]]` 可同时兼容 `*:57585`、`0.0.0.0:57585`、`[::]:57585` 三种显示格式；
   - 不要用精确行匹配（`grep -w` 或 `awk '== '$p` 在 `*:PORT` 格式下会误判）。

3. **端口来源**
   优先从脚本自己的状态文件读取（字段名参考：`PORT_ANYTLS`、`PORT_HY2`、`PORT_HY2_LISTEN`、`PORT_TUIC`）。注意 Hy2 使用 **`PORT_HY2_LISTEN`**（端口跳跃 REDIRECT 的目标端口）而不是对外公布的 `PORT_HY2`。若脚本无状态文件机制，则按实际生成配置时的变量直接引用。

4. **超时失败分支要保留诊断输出**
   超时后打印当时的 `ss -tlnp` / `ss -ulnp`，便于继续排查真正的监听故障（如端口被占用、证书权限等）。

5. **不要改动诊断报告逻辑**
   诊断功能（`sb` 选项 9）的端口复核逻辑是正常的，本次只修"启动后即时检查"这一处，避免影响诊断报告输出格式。

---

## 四、修改后的预期行为

| 场景 | 修改前 | 修改后 |
|---|---|---|
| 正常启动（socket 绑定慢于 systemd 返回） | ❌ 误报未监听，安装中止 | ✅ 轮询等到全部就绪，安装继续 |
| 端口被占用 / 证书失败（真故障） | ⚠️ 即时报错但信息少 | ✅ 超时后报错并附带 ss 输出 |
| 服务快速启动（0.02s 完成绑定） | ⚠️ 碰运气 | ✅ 首轮即通过，无额外等待 |

---

## 五、验证方法（修改后请在 Debian 13 上回归）

1. `systemctl restart sing-box && bash 脚本` → 应输出 `[ OK ] 全部端口监听正常`，不再中止。
2. 连续执行 5 次 `systemctl restart sing-box`，每次紧接着跑端口检查，确认**不再出现** `[ERR] 未监听` 误报。
3. 人为制造一次真故障（如临时 `systemctl stop sing-box` 后再跑检查）→ 应在超时后正确报错并给出 `ss` 输出。
4. 修改前后分别执行 `sb → 选项 9` 生成诊断报告，确认诊断报告格式、内容未受影响。

---

## 六、附：现场无关问题备忘（不要修改）

日志中 `connection refused` 到 `127.0.0.1:853`（Aug 18 23:40 附近）是**客户端侧** DNS 配置问题：客户端把 DoT 请求发到服务器本机 853 端口，而服务器上无 DoT 监听。与本次端口检查竞态**无关**，服务端脚本无需处理。

---

*文档生成时间：2026-08-19*
