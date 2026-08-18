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
# 选 1 安装 → 输入域名 → 选验证方式 → 选端口开放策略
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

- [ ] 安装完成后终端显示 AnyTLS / Hysteria2 / TUIC 三种 URI + 二维码
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
- [ ] 选项 3 变更证书配置（切验证方式/改域名/强制重签）后 reload 成功

## 7. 证书续期演练

- [ ] 临时调短 acme.sh 续期间隔或手动 `acme.sh --renew-all`，确认 reloadcmd 执行 `systemctl reload sing-box` 且服务不中断

## 8. 版本切换与回滚

- [ ] 选项 5 切换到一个其他版本，服务正常
- [ ] 切换失败时可从 `/usr/local/bin/sing-box.bak` 恢复

## 9. 卸载

- [ ] 选项 1（卸载）二次确认后：进程停止、单元删除、`/usr/local/bin/sing-box`、`/usr/local/bin/sb` 清除
- [ ] 可选删除证书目录与 acme.sh 账户
- [ ] 再次执行 `sb` 提示「未安装」

## 10. 防火墙后端

- [ ] 在 ufw / firewalld / iptables 三种环境分别验证「端口开放三选一」按预期放行
- [ ] HTTP-01 模式下即便选「仅节点端口/不开放」，签发阶段临时放行的 80 在完成后被回收
