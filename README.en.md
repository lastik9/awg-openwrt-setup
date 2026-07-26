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

**1. Download the script and template** (into `/root`):

```sh
cd /root && for f in setup-awg.sh awg.env.example; do curl -fsSLO "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/$f"; done
```

**2. Prepare `awg.env`** — one of two ways:

### Option A: you have a ready `.conf` (recommended)

This is the plain-text config from your provider / the Amnezia app, shaped like
`[Interface] … [Peer] …`. The script parses it and extracts every parameter for you —
nothing to type by hand.

```sh
# 2.1 save the config to a file on the router
vi /root/my.conf
#     press i, paste the whole config, then Esc and :wq

# 2.2 generate awg.env from it
sh setup-awg.sh --from-conf /root/my.conf

# 2.3 set keepalive (Amnezia .conf usually omits it; needed behind NAT)
sed -i "s/^KEEPALIVE=.*/KEEPALIVE='25'/" /root/awg.env

# 2.4 (optional) check the key fields
grep -E "ENDPOINT_HOST|KEEPALIVE|MAKE_ZONE" /root/awg.env
```

### Option B: fill it manually

If you don't have a ready `.conf`, copy the template and fill in the values:

```sh
cp awg.env.example awg.env
vi awg.env
```

**3. Run install + setup:**

```sh
sh setup-awg.sh
```

**4. Attach to podkop:** **LuCI → Services → Podkop**, connection type **VPN**,
network interface `awg0` → Save & Apply.

## Command-line options

| Flag | Action |
|------|--------|
| (none) | install packages + configure from `awg.env` |
| `--from-conf FILE` | generate `awg.env` from a `.conf` and exit |
| `--no-install` | skip package installation, configure only |
| `--env PATH` | use an env file at a different path |
| `-h`, `--help` | help |

Extra options live in `awg.env`:

| Variable | Action |
|----------|--------|
| `MAKE_ZONE='1'` | create the `awg` firewall zone (0 — leave firewall alone) |
| `KEEPALIVE='25'` | persistent keepalive; required behind NAT |
| `INSTALL_RU_LANG='1'` | install the Russian LuCI locale for AmneziaWG |

## Multiple servers

One interface = one server. For a second server, create a **separate interface**
(`awg1`, `awg2`, …) with its own env file and its own zone. Packages are already
installed, so run with `--no-install`.

```sh
# 1. generate a separate env from the second config (--env sets the output path)
sh setup-awg.sh --from-conf /root/server2.conf --env /root/awg1.env

# 2. open awg1.env and edit three lines:
#      IFACE='awg1'         (unique interface name)
#      ZONE_NAME='awg1'     (own zone; or keep 'awg' to share one)
#      KEEPALIVE='25'
vi /root/awg1.env

# 3. bring the second interface up (do not reinstall packages)
sh setup-awg.sh --env /root/awg1.env --no-install
```

Now the router has two independent tunnels — `awg0` and `awg1`. In podkop each is
attached as a separate configuration: add a second profile and point it at interface
`awg1`. Which traffic goes through which server is decided by podkop's lists.

A note on zones: you can give each interface its own zone (`awg`, `awg1`) for easier
separate management, or put both interfaces into one zone by editing
`firewall.awg.network` manually. By default the script creates a separate zone per
`ZONE_NAME`.

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
