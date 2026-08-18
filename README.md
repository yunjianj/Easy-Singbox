# easy-singbox

面向 Linux 服务器的 **sing-box 一键部署脚本**。

## 一键安装

以 root 在目标服务器执行以下任一命令，自动下载并进入安装主页面：

```bash
bash <(wget -qO- https://cdn.jsdelivr.net/gh/yunjianj/Easy-Singbox@main/sb.sh)
```

或（使用 curl）：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/yunjianj/Easy-Singbox@main/sb.sh)
```

> 若 jsDelivr 拉取缓慢，可改用 GitHub 源（偶尔有 CDN 缓存延迟）：
> `bash <(wget -qO- https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)`

也可先克隆再安装（已装 git 时）：

```bash
git clone https://github.com/yunjianj/Easy-Singbox.git && cd Easy-Singbox && bash install.sh
```

> 安装后管理命令为 `sb`（已软链到 `/usr/local/bin/sb`）。卸载请另执行仓库内 `uninstall.sh`。


- **强制 TLS**：AnyTLS + Hysteria2 + TUIC v5 三协议共存于同一份 `config.json`，各自独立端口、共享同一份真实证书，`tls.enabled` 均为 `true`，**不支持无证书模式、不支持手动上传证书**。
- **不生成订阅链接**：安装完成后直接在终端打印三种协议的节点 URI + 二维码，并写入 `/etc/sing-box/nodes.txt`（权限 600）。
- **证书自动申请**：通过 acme.sh 向 Let's Encrypt 自动签发，支持 HTTP-01 与 DNS-01(Cloudflare) 两种验证方式。

## 支持系统

- Debian 11/12、Ubuntu 20.04/22.04/24.04 等 systemd 发行版（x86_64 / aarch64）
- 防火墙后端自动适配：`ufw → firewalld → iptables`，均无则跳过并提示

## 依赖

脚本仅依赖 `curl` + `bash` + 常见 coreutils。其余工具在安装时自动安装：

- `sing-box`（从 GitHub Releases 下载最新 stable，要求 ≥ 1.13）
- `acme.sh`（证书申请）
- `qrencode`（二维码，缺失时仅跳过二维码不中断）

## 三种协议

| 协议 | 传输 | 凭证 | 说明 |
| --- | --- | --- | --- |
| AnyTLS (TCP) | TCP | password | 抗探测，需服务端默认 padding |
| Hysteria2 (QUIC) | UDP | password | 可选 salamander obfs |
| TUIC v5 (QUIC) | UDP | uuid + password | 双字段 |

三者均使用同一份 TLS 证书，由证书模块统一签发到 `/etc/sing-box/ssl/`。

## 两种证书模式

1. **HTTP-01**：域名 A 记录指向本机 IP，签发阶段需 80 端口空闲。脚本在签发前临时放行 80、完成后回收。
2. **DNS-01 (Cloudflare)**：填入 Cloudflare API Token（需 `Zone:DNS:Edit` 权限），无需 80 端口。Token 持久化于 `/etc/sing-box/.cf.env`（权限 600）以便续期。

证书续期由 acme.sh 自带 cron 负责，续期后执行 `systemctl reload sing-box`。

## 端口开放三选一

安装时会询问端口开放策略（直接回车默认选 1）：

1. 全部开放（80 + 三协议端口 + Hy2 跳跃段）
2. 开放所有端口（直接关闭防火墙，存在安全风险，仅建议可信网络使用）
3. 不开放（自行在防火墙/安全组配置）

默认随机高位端口（49152–65535，避让 Hy2 跳跃段），可在「变更代理配置」中逐个自定义。

## 使用

```bash
# 首次运行（进入统一主页面）
bash install.sh

# 安装后，任意位置输入管理命令
sb
```

主页面菜单：

```
==============================================================
      easy-singbox  管理面板  v1.0.0
--------------------------------------------------------------
 系统      : Debian 12 (Bookworm) x86_64
 指令集    : amd64 (AES-NI: 支持)
 虚拟化    : KVM
 BBR       : 已开启 (bbr)
 IP / 地区 : 1.2.3.4  |  Hong Kong / CN
 Sing-Box  : 已运行  v1.13.0  (3 协议在线)
 脚本版本  : v1.0.0  [已是最新]
--------------------------------------------------------------
 [1] 一键安装 / 卸载 Sing-Box
 [2] 变更代理配置      (协议 / 端口 / 凭证)
 [3] 变更证书配置      (HTTP-01 / DNS-01 / 重签)
 [4] 重启 / 查看节点
 [5] 更新 / 切换内核版本
 [6] 更新脚本            (当前 v1.0.0)
 [0] 退出
==============================================================
```

## 节点导入方式

安装完成（或选「查看节点」）后，终端显示三种协议 URI 与二维码，并写入 `/etc/sing-box/nodes.txt`。

- **Hysteria2 / TUIC**：直接复制 URI 导入客户端。
- **AnyTLS**：部分 GUI 客户端尚不识别 `anytls://`，此时终端会额外输出该节点的 sing-box outbound JSON 片段，可手动粘贴导入。
- **严禁订阅链接**：脚本不会输出任何 `http(s)://.../sub` 形式的订阅地址。

## 卸载与更新

- **卸载**：主页面选项 1（已安装时变为卸载），或独立执行 `bash uninstall.sh`。会二次确认是否一并删除证书目录与 acme.sh 账户。
- **切换版本**：选项 5，下载指定版本前备份当前二进制（`/usr/local/bin/sing-box.bak`），失败可手动恢复。
- **更新脚本**：选项 6，从配置源（`sb` 顶部 `SB_UPDATE_BASE`）拉取最新代码，保留本机 `/etc/sing-box/config.json` 与证书。
- **版本自检**：主面板标题与「脚本版本」行显示当前版本（`sb` 内 `SB_SCRIPT_VERSION` 常量），并自动对比仓库根 `VERSION` 文件——已最新显示绿色 `[已是最新]`，有新版本显示红色 `[发现新版本 vX，可执行选项 6 更新]`，检测失败（网络受限）显示黄色 `[远程版本未知]`。检测结果本地缓存 10 分钟，不会拖慢菜单。发布新版本时请同步修改 `SB_SCRIPT_VERSION` 与 `VERSION` 文件。

## 已知限制

- **AnyTLS 客户端兼容性**：部分客户端不识别 `anytls://` URI，需使用 outbound JSON 兜底导入（见上）。
- 降权运行以 `singbox` 系统用户执行；本期端口均为高位随机，无需 `CAP_NET_BIND_SERVICE`（已预留）。
- DNS-01 仅支持 Cloudflare，其他 DNS 服务商本期未实现。

## 目录结构

```
easy-singbox/
├── install.sh          # 主入口
├── sb                  # 管理命令本体（软链到 /usr/local/bin/sb）
├── uninstall.sh        # 独立卸载入口
├── lib/
│   ├── core.sh         # 工具/系统探测/日志/颜色
│   ├── service.sh      # systemd 管理 + 降权
│   ├── firewall.sh     # 防火墙后端适配
│   ├── cert.sh         # 证书管理（acme.sh）
│   ├── config.sh       # 生成 config.json
│   ├── node.sh         # 节点 URI 生成 + 二维码
│   └── protocol/       # anytls / hysteria2 / tuic 片段
├── templates/config.json.tpl
├── README.md
└── TESTING.md
```
