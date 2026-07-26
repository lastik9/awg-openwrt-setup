# awg-openwrt-setup

[Русский](README.md) · [English](README.en.md) · **中文**

在 **OpenWrt 25 (apk)** 上安装 **AmneziaWG** 的脚本，配合
[podkop](https://podkop.net/) 实现分流（策略路由）。

一次运行即可：安装 AmneziaWG 软件包、创建网络接口和带 NAT 与 MSS clamping 的防火墙区域、
启动隧道并检查握手。**不会改动 podkop** —— 需在 LuCI 中手动把接口挂到 podkop 上。
另附独立的卸载脚本。

## 为什么需要它

[AmneziaWG](https://docs.amnezia.org/) 是带混淆的 WireGuard，可抵抗基于 DPI 的封锁。
在 OpenWrt 上手动配置需要多个步骤：装包、在网页界面建接口、手动导入 `.conf`、建防火墙区域。
配合 podkop 时还有一个坑：接口**不能**路由全部 `AllowedIPs`，否则所有流量都会进入隧道，
绕过 podkop 的分流规则。

本脚本免去这些琐事：从简单的 `awg.env` 构建接口和 peer（或从现有 `.conf` 生成），
立即设置 `route_allowed_ips=0`，并创建正确的防火墙区域。

## 环境要求

- 使用 **apk** 包管理器的 OpenWrt 25.x（已在 25.12.x 上测试）。
- 已安装并正常运行的 **podkop**。
- SSH 访问及 **root** 权限。
- 运行时路由器需联网 —— 需下载 AmneziaWG 软件包。

## 脚本做了什么

1. 通过官方安装器
   ([Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt))
   非交互式安装 AmneziaWG 软件包。
2. 从 `awg.env` 读取隧道参数。
3. 创建 UCI 接口和 peer —— **仅当接口尚不存在时**（幂等）。
   设置 `route_allowed_ips=0`，交由 podkop 管理路由。
4. 创建防火墙区域（`input`/`forward` REJECT，`output` ACCEPT，masquerade，
   MSS clamping）。**不**添加 `lan → awg` 转发 —— 由 podkop 处理。
5. 启动接口并检查握手。

脚本**不会**配置 podkop —— 安装后请自行在 **Services → Podkop** 中挂载接口。

## 安装

以下命令在**路由器**上通过 SSH 执行，位于 `/root` 目录。

**首次安装 —— 一条命令**（下载并直接启动向导）：

```sh
cd /root && wget -O setup-awg.sh "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh" && sh setup-awg.sh
```

> ⚠️ **首次安装 = 一次 reboot。** 首次安装 AmneziaWG 软件包时，`netifd` 只有在重启后
> 才会识别这个新协议。脚本会自动检测这一情况，并在结束时给出 **15 秒**倒计时重启提示：
> 什么都不按，路由器会自动重启，重启后接口会自动启动；若要取消，输入 `n` 并回车（之后
> 自行手动执行 `reboot`）。再次运行时（协议已注册）不会触发重启 —— 隧道会立即启动。

向导会逐步引导：
- 询问**接口名称** —— 按服务器所在国家/位置起个易记的名字（`awg_nl`、`awg_de`、
  `awg_us`），以免混淆。连字符会自动替换为下划线（`awg-nl` → `awg_nl`）；
- 打开**编辑器** —— 把整个 `.conf` 粘贴进去（从 `[Interface]` 到 `[Peer]` 结尾），
  保存并退出（在 `vi` 中：`Esc`，然后 `:wq`）；
- 询问 **keepalive** —— 按回车使用 25（位于 NAT 之后时需要）。

随后脚本会自动安装软件包、以所选名称创建接口、将其加入共享防火墙区域 `awg`，并启动隧道。

**3. 挂载到 podkop：** **LuCI → Services → Podkop**，连接类型选 **VPN**，
网络接口选你设定的名字（如 `awg_nl`）→ Save & Apply。

### 备选：不使用向导

如需非交互方式（自动化、脚本）—— 从 `.conf` 生成 `awg.env` 再运行：

```sh
wget -O awg.env.example "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/awg.env.example"
sh setup-awg.sh --from-conf /root/my.conf          # 生成 awg.env
sed -i "s/^KEEPALIVE=.*/KEEPALIVE='25'/" /root/awg.env
sh setup-awg.sh                                     # 从 awg.env 启动
```

或从 `awg.env.example` 模板手动填写 `awg.env`。

## 命令行参数

| 参数 | 作用 |
|------|------|
| （无） | 无 `awg.env` 时运行向导；否则从 `awg.env` 配置 |
| `-i`, `--wizard` | 强制运行交互式向导 |
| `--from-conf FILE` | 从 `.conf` 生成 `awg.env` 后退出 |
| `--no-install` | 跳过软件包安装，仅配置 |
| `--reboot` | 静默模式：立即重启，跳过 15 秒倒计时（用于自动化；= `AUTO_REBOOT=1`） |
| `--env PATH` | 使用指定路径的 env 文件 |
| `-h`, `--help` | 帮助 |

其他选项在 `awg.env` 中设置：

| 变量 | 作用 |
|------|------|
| `MAKE_ZONE='1'` | 创建 `awg` 防火墙区域（0 —— 不改动防火墙） |
| `KEEPALIVE='25'` | persistent keepalive；位于 NAT 之后时必填 |

## 多个服务器

一个接口 = 一个服务器。要添加另一个，只需**再次运行向导**并给接口起个不同的名字：

```sh
sh setup-awg.sh -i
# 名称：awg_de，粘贴第二个 .conf —— 即可
```

每个服务器拥有各自的接口（`awg_nl`、`awg_de`……），但它们都归入**同一个共享防火墙
区域** `awg` —— 所有接口的防火墙行为（masq + MSS）一致，无需增设多个区域。脚本会自动
把新接口加入现有区域。

在 podkop 中，每条隧道作为独立配置挂载：新增第二个配置并指向所需接口。哪些流量走哪个
服务器，由 podkop 的列表决定。

## 关于 keepalive

Amnezia 的 `.conf` 通常没有 `PersistentKeepalive` 行。如果路由器位于 NAT 之后
（包括位于另一台路由器之后），务必在 `awg.env` 中设置 `KEEPALIVE='25'` ——
否则 NAT 会话会关闭，握手随之断开。没有 keepalive 的接口在没有流量进入隧道之前，
也不会主动发起握手。

## 卸载

```sh
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/uninstall-awg.sh
sh uninstall-awg.sh
```

脚本会查找**所有** `proto=amneziawg` 的接口（向导会在共享区域中创建任意名称），
列出后经确认将它们连同 peer 段和防火墙区域一并删除。若只想删除某一个接口，
使用 `--iface awg_nl`。最后会**单独询问**是否卸载 AmneziaWG 系统软件包。
这些软件包（`kmod-amneziawg`、`amneziawg-tools`、`luci-proto-amneziawg`）是**共享**的：
若路由器上还有其他 AWG 隧道，建议保留。podkop 不受影响。

> **请先在 podkop 中移除该接口。** 如果被删除的接口仍挂在 podkop/forkop 上，singbox
> 会继续劫持 DNS 并把它转发到已失效的隧道：按 IP 能 ping 通，但域名无法解析（"断网"）。
> 卸载前请在 **Services → Podkop → Save & Apply** 中移除该接口。

若删除后接口在 LuCI 中仍显示"待删除"（内核设备会一直保留，直到 netifd 重启 —— 尤其是
AWG 软件包已被卸载时），脚本会检测到并提示 **带 15 秒倒计时的重启**（与安装时相同）。
直接回车/超时即重启；输入 `n` 再回车则取消。`--reboot` 参数则静默重启、跳过倒计时（用于自动化）。

## 安全

- **切勿**提交真实的 `awg.env` —— 其中含有私钥。`.gitignore` 已将其排除。
- 仓库中仅包含 `awg.env.example`（无实际值的模板）。
- 若密钥曾泄露 —— 请重新签发配置并在服务器上吊销旧密钥。

## 致谢

本项目仅为安装器。核心工作均在上游完成：

- [amnezia-vpn/amneziawg](https://docs.amnezia.org/) —— AmneziaWG 协议；
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) ——
  面向 OpenWrt 的 AmneziaWG 软件包构建；
- [podkop](https://podkop.net/) —— 分流路由。

所安装的组件归其各自作者所有，并按其各自的许可证分发。本许可证（MIT）仅涵盖本脚本的代码。

## 免责声明

按现状提供。首次运行前请确保能物理访问路由器，以便在需要时回滚。应用前请人工核对
生成的 `awg.env`。

## 许可证

[MIT](LICENSE) © 2026 lastik9
