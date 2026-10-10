# TESTING — 自测清单

在干净 Linux 服务器上逐步验证。所有命令需 root 执行。

## 0. 前置

- 一台干净的 Debian 12 / Ubuntu 22.04（x86_64 或 aarch64）
- 一个已解析到本机公网 IP 的域名（HTTP-01 需要）
- 或 Cloudflare 托管域名 + API Token（DNS-01 需要）
- 能访问 GitHub（`api.github.com` / `github.com`）、Let's Encrypt

## 1. 安装主链路

```bash
bash install.sh
# 选 1 安装 → 输入域名 → 选验证方式 → （v1.6.0 起不再询问端口开放策略）
```

检查项：

- [ ] `sing-box` 进程运行：`systemctl is-active sing-box` == `active`
- [ ] `sb` 命令可用：`which sb` 指向 `/usr/local/bin/sb`
- [ ] 再次执行 `sb` 进入主页面，状态显示「已运行 / 3 协议在线」
- [ ] `/etc/sing-box/config.json` 存在且 `sing-box check` 通过
- [ ] `/etc/sing-box/ssl/{fullchain.pem,privkey.pem}` 存在，权限 600

## 2. HTTP-01 证书模式

- [ ] 域名 A 记录指向本机 IP
- [ ] 防火墙/安全组放行 80（或选端口策略 1）
- [ ] 安装时选 HTTP-01，签发成功
- [ ] `openssl x509 -in /etc/sing-box/ssl/fullchain.pem -noout -dates` 正常

## 3. DNS-01(Cloudflare) 证书模式

- [ ] 准备 Cloudflare API Token（Zone:DNS:Edit）
- [ ] 安装时选 DNS-01，填入 Token，无需 80 端口即可签发
- [ ] `/etc/sing-box/.cf.env` 存在，权限 600，含 `CF_Token=...`

## 4. 节点 URI 与导入

- [ ] 安装完成后终端显示 AnyTLS / Hysteria2 / TUIC 三种 URI
- [ ] `/etc/sing-box/nodes.txt` 存在，权限 600，**无订阅链接**
- [ ] 将 Hysteria2 / TUIC URI 导入客户端，可成功连接
- [ ] AnyTLS 在不识别的客户端中用 outbound JSON 兜底导入成功

## 5. 证书握手验证

```bash
openssl s_client -connect <DOMAIN>:<PORT_HY2> -servername <DOMAIN> </dev/null 2>/dev/null | openssl x509 -noout -subject
```

- [ ] 三协议端口均能完成 TLS 握手并返回真实证书

## 6. 变更操作

- [ ] 选项 2 变更端口/凭证后，`sing-box` reload 成功，节点 URI 更新
- [ ] 选项 2 可关闭项能真正关闭：在跳跃段 / obfs / SOCKS5 用户名密码提示中输入 `-`，对应配置被清除（`HOP_HY2` 为空且节点无 `mport` / `OBS_HY2` 为空 / socks inbound 无 `users` 块）；全回车则保持旧值不变
- [ ] 选项 3 变更证书配置（切验证方式/改域名/强制重签）后 reload 成功

## 7. 证书续期演练

- [ ] 临时调短 acme.sh 续期间隔或手动 `acme.sh --renew-all`，确认 reloadcmd 执行 `systemctl reload sing-box` 且服务不中断

## 8. 内核升级与版本支持检测

- [ ] 主面板 Sing-Box 行显示已装内核版本，且为 1.14.x（基线达标无红字）
- [ ] 选项 7 显示"已是最新版本，无需升级"（当前为 1.14.x 最新时）
- [ ] 手动把 `/usr/local/bin/sing-box` 换成旧内核（如 1.13.x）后进入面板，出现红色「内核版本过低…请执行选项 7 升级」提示
- [ ] 选项 7 一键升级：自动下载 1.14 大版本最新补丁（不可手动输入版本），服务正常，`sing-box check` 通过
- [ ] 主面板启动检测（v1.6.2 起）：有新补丁时 Sing-Box 行下方绿色提示 `[发现新内核 vX.Y.Z，可执行选项 7 升级]`；已是最新时无提示行；断网时无提示（静默，不误报）；`cat /usr/local/share/easy-singbox/.kernel_ver` 缓存格式为 `版本|时间戳`
- [ ] 选项 7 与选项 8 的确认默认为 y（直接回车即继续）；卸载 / 关防火墙 / 无校验安装的确认仍默认为 n
- [ ] 升级失败时可从 `/usr/local/bin/sing-box.bak` 恢复
- [ ] 升级后 `systemctl is-active sing-box` 为 `active`（脚本会轮询确认；起不来会自动回滚内核，不留半成品）

## 8b. 旧 `.state` 升级回归（v1.5.10 修复项，必测）

模拟 v1.4.0 之前脚本写出的 `.state`（缺 `PROTOS`/`PORT_SOCKS`/`USER_SOCKS`/`PASS_SOCKS`），
验证选项 7 不再 `PROTOS: unbound variable` 中断。

```bash
cp /etc/sing-box/.state /root/state.bak
cp /etc/sing-box/config.json /root/config.bak
# 删掉新版本才有的键，模拟旧机器
sed -i -e '/^PROTOS=/d' -e '/^PORT_SOCKS=/d' -e '/^USER_SOCKS=/d' -e '/^PASS_SOCKS=/d' /etc/sing-box/.state
# 把内核换成 1.13.x，再走选项 7
```

- [ ] 选项 7 全程跑完，**无 `unbound variable`**，提示「检测到旧版状态文件（无 PROTOS 键），已按现有配置推断启用协议: ...」
- [ ] `sing-box check -c /etc/sing-box/config.json` 通过；`python3 -m json.tool /etc/sing-box/config.json` 无报错
- [ ] 推断的协议集与升级前一致（**不会凭空多出 SOCKS5**）；`grep '^PROTOS=' /etc/sing-box/.state` 已被回写
- [ ] `nodes.txt` 每个 URI 的端口与 `config.json` 对应 inbound 的 `listen_port` 一致
- [ ] 还原：`cp /root/state.bak /etc/sing-box/.state && cp /root/config.bak /etc/sing-box/config.json && sb`（选项 6 重载）

## 9. 卸载

- [ ] 选项 1（卸载）二次确认后：进程停止、单元删除、`/usr/local/bin/sing-box`、`/usr/local/bin/sb` 清除
- [ ] 可选删除证书目录与 acme.sh 账户
- [ ] 再次执行 `sb` 提示「未安装」

## 10. 防火墙（v1.6.0 起脚本不自动配置）

- [ ] 安装/选项 2 变更配置后，终端打印「需自行放行」的端口清单，且内容与实际启用协议一致（未启用的协议不出现）
- [ ] 清单包含 `TCP 22 SSH` 与跳跃段整段提示（启用跳跃时）
- [ ] 安装全程 `iptables -S INPUT` / `ufw status` **不含**本脚本新增的节点端口规则（除 HTTP-01 临时 80）
- [ ] HTTP-01 签发阶段临时放行的 80 在签发结束（含失败路径）后被回收：`iptables -S INPUT | grep -- '--dport 80'` 无输出
- [ ] 选项 11「一键关闭防火墙」：ufw 环境显示 `ufw status: inactive`；iptables 环境 INPUT 策略为 ACCEPT 且无 `-A INPUT` 规则
- [ ] 选项 11 输入 `n` 取消时，防火墙规则无任何变化
- [ ] 选项 11 确认前有明确警告（会 `iptables -F INPUT` / 停用 firewalld，暴露含 22 SSH 的所有端口）

## 11. 端口跳跃规则丢失回归（v1.6.0 修复项，必测）

REDIRECT 规则是非持久的内核状态，重启或被 1Panel/Docker/firewalld 改写 iptables 后即失效，
而 `.state` 的 `HOP_HY2` 与节点 URI 的 `mport` 仍在 → Hy2 必然超时。

```bash
# 模拟规则丢失（保留 .state，只删内核规则）
iptables -t nat -S PREROUTING | grep easy-singbox | awk '{print $1,$2,$3}' \
  | xargs -r -n3 iptables -t nat -D
iptables -t nat -S PREROUTING | grep -c easy-singbox-hop   # 应为 0
```

- [ ] 规则丢失后执行选项 9：§6 Hy2 行下方标注「[异常] 端口跳跃 … REDIRECT 规则不存在」，§9 显示「规则状态: [异常]」
- [ ] §13 自动结论**指向服务端跳跃规则缺失**，明确说明「不是客户端问题」，并给出「执行选项 4 或 6 重建」的修复步骤
- [ ] 执行选项 6（重启/查看节点）后 `iptables -t nat -S PREROUTING | grep -c easy-singbox-hop` 恢复为 1，客户端 mport 恢复可用
- [ ] 执行选项 4（启动）同样能重建（服务已在运行时也生效）
- [ ] 执行选项 3（变更证书）与选项 7（升级内核）后规则仍在（这两条路径经 `service_reload`）
- [ ] `.state` 的 `HOP_HY2` 在上述过程中**不被删除**（只有 `config_gen` 有权因规则建立失败而删键）
- [ ] 未配置跳跃的机器：§9 显示「未配置端口跳跃」，不出现任何 `[异常]` 误报
