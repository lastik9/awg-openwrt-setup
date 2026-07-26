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

以下命令在**路由器**上通过 SSH 执行。

**1. 下载脚本和模板**（到 `/root`）：

```sh
cd /root && for f in setup-awg.sh awg.env.example; do curl -fsSLO "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/$f"; done
```

**2. 准备 `awg.env`** —— 任选其一：

```sh
# 方式 A：已有服务商的 .conf —— 从中生成 env
sh setup-awg.sh --from-conf /root/my.conf
# 然后打开 awg.env，若 KEEPALIVE 为空则填入 '25'，并核对各项值

# 方式 B：手动填写 env
cp awg.env.example awg.env
vi awg.env
```

**3. 执行安装与配置：**

```sh
sh setup-awg.sh
```

**4. 挂载到 podkop：** **LuCI → Services → Podkop**，连接类型选 **VPN**，
网络接口选 `awg0` → Save & Apply。

## 命令行参数

| 参数 | 作用 |
|------|------|
| （无） | 安装软件包 + 从 `awg.env` 配置 |
| `--from-conf FILE` | 从 `.conf` 生成 `awg.env` 后退出 |
| `--no-install` | 跳过软件包安装，仅配置 |
| `--env PATH` | 使用指定路径的 env 文件 |
| `-h`, `--help` | 帮助 |

其他选项在 `awg.env` 中设置：

| 变量 | 作用 |
|------|------|
| `MAKE_ZONE='1'` | 创建 `awg` 防火墙区域（0 —— 不改动防火墙） |
| `KEEPALIVE='25'` | persistent keepalive；位于 NAT 之后时必填 |
| `INSTALL_RU_LANG='1'` | 安装 AmneziaWG 的 LuCI 俄语语言包 |

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

脚本会删除接口和防火墙区域，最后**单独询问**是否卸载 AmneziaWG 系统软件包。
这些软件包（`kmod-amneziawg`、`amneziawg-tools`、`luci-proto-amneziawg`）是**共享**的：
若路由器上还有其他 AWG 隧道，建议保留。podkop 不受影响。

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
