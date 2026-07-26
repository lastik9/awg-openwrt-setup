# awg-openwrt-setup

[Русский](README.md) · **English** · [中文](README.zh-CN.md)

Installer script for **AmneziaWG** on **OpenWrt 25 (apk)**, made to work alongside
[podkop](https://podkop.net/) for selective (policy) routing.

One run: installs AmneziaWG packages, creates the network interface and a firewall
zone with NAT and MSS clamping, brings the tunnel up and checks the handshake.
**Podkop is left untouched** — you attach the interface to it manually in LuCI.
A separate uninstaller is included.

## Why

[AmneziaWG](https://docs.amnezia.org/) is WireGuard with obfuscation, resistant to
DPI-based blocking. Setting it up on OpenWrt by hand takes several steps: packages,
the interface via the web UI, manual `.conf` import, a firewall zone. With podkop
there is an extra catch: the interface must **not** route all its `AllowedIPs`,
otherwise every packet goes into the tunnel and bypasses podkop's selective rules.

This script removes the busywork: it builds the interface and peer from a simple
`awg.env` (or generates one from an existing `.conf`), sets `route_allowed_ips=0`
right away, and creates a correct firewall zone.

## Requirements

- OpenWrt 25.x with the **apk** package manager (tested on 25.12.x).
- **podkop** already installed and working.
- SSH access and **root** privileges.
- Internet on the router at run time — AmneziaWG packages are downloaded.

## What the script does

1. Installs AmneziaWG packages via the official installer
   ([Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)),
   non-interactively.
2. Reads tunnel parameters from `awg.env`.
3. Creates the UCI interface and peer — **only if the interface does not exist yet**
   (idempotent). Sets `route_allowed_ips=0` so that podkop manages routing.
4. Creates a firewall zone (`input`/`forward` REJECT, `output` ACCEPT, masquerade,
   MSS clamping). It does **not** add `lan → awg` forwarding — podkop handles that.
5. Brings the interface up and checks for a handshake.

The script does **not** configure podkop — after installation, attach the interface
in **Services → Podkop** yourself.

## Installation

Run these commands **on the router** over SSH.

```sh
# copy the files to the router (e.g. into /root) or fetch them one by one:
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/awg.env.example

# option A: you have a provider .conf — generate the env from it
sh setup-awg.sh --from-conf /root/my.conf
# then open awg.env, set KEEPALIVE='25' and review the values

# option B: fill the env manually
cp awg.env.example awg.env
vi awg.env

# run install + setup
sh setup-awg.sh
```

After installation: **LuCI → Services → Podkop**, connection type **VPN**, network
interface `awg0` → Save & Apply.

## Command-line options

| Flag | Action |
|------|--------|
| (none) | install packages + configure from `awg.env` |
| `--from-conf FILE` | generate `awg.env` from a `.conf` and exit |
| `--no-install` | skip package installation, configure only |
| `--env PATH` | use an env file at a different path |
| `-h`, `--help` | help |

## Note on keepalive

Amnezia `.conf` files usually have no `PersistentKeepalive` line. If the router sits
behind NAT (including behind another router), you must set `KEEPALIVE='25'` in
`awg.env` — otherwise the NAT session closes and the handshake drops. An interface
without keepalive also won't initiate a handshake on its own until traffic enters the
tunnel.

## Uninstall

```sh
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/uninstall-awg.sh
sh uninstall-awg.sh
```

The script removes the interface and the firewall zone, then **asks separately**
whether to remove the AmneziaWG system packages. Those packages
(`kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg`) are **shared**: if you
run other AWG tunnels on the router, keep them. Podkop is left untouched.

## Security

- **Never** commit a real `awg.env` — it holds the private key. `.gitignore` blocks it.
- Only `awg.env.example` (a template with no values) goes into the repo.
- If keys were ever exposed — reissue the config and revoke the old one on the server.

## Credits

This project is just an installer. The real work lives upstream:

- [amnezia-vpn/amneziawg](https://docs.amnezia.org/) — the AmneziaWG protocol;
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) —
  AmneziaWG package builds for OpenWrt;
- [podkop](https://podkop.net/) — selective routing.

Installed components belong to their authors and are distributed under their own
licenses. This license (MIT) covers only the code of this script.

## Disclaimer

Provided as is. Before the first run make sure you have physical access to the router
in case a rollback is needed. Review the generated `awg.env` by eye before applying it.

## License

[MIT](LICENSE) © 2026 lastik9
