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

**1. Download the script** (into `/root`):

```sh
cd /root && curl -fsSLO "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh"
```

**2. Run the wizard:**

```sh
sh setup-awg.sh
```

The wizard walks you through:
- it asks for an **interface name** — pick a meaningful one per server country/location
  (`awg_nl`, `awg_de`, `awg_us`) so you don't get confused. Dashes are replaced with
  underscores automatically (`awg-nl` → `awg_nl`);
- it opens an **editor** — paste your whole `.conf` there (from `[Interface]` to the
  end of `[Peer]`), save and quit (in `vi`: `Esc`, then `:wq`);
- it asks for **keepalive** — press Enter for 25 (needed behind NAT).

Then the script installs the packages, creates the interface with your chosen name,
adds it to the shared firewall zone `awg`, and brings the tunnel up.

**3. Attach to podkop:** **LuCI → Services → Podkop**, connection type **VPN**,
network interface (the name you chose, e.g. `awg_nl`) → Save & Apply.

### Alternative: without the wizard

For a non-interactive path (automation, scripts) — generate `awg.env` from a `.conf`
and run:

```sh
curl -fsSLO "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/awg.env.example"
sh setup-awg.sh --from-conf /root/my.conf          # creates awg.env
sed -i "s/^KEEPALIVE=.*/KEEPALIVE='25'/" /root/awg.env
sh setup-awg.sh                                     # brings it up from awg.env
```

Or fill `awg.env` manually from the `awg.env.example` template.

## Command-line options

| Flag | Action |
|------|--------|
| (none) | wizard if no `awg.env`; otherwise configure from `awg.env` |
| `-i`, `--wizard` | force the interactive wizard |
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

One interface = one server. To add another, just **run the wizard again** and give the
interface a different name:

```sh
sh setup-awg.sh -i
# name: awg_de, paste the second .conf — that's it
```

Each server gets its own interface (`awg_nl`, `awg_de`, …), but they all go into
**one shared firewall zone** `awg` — the firewall behaviour (masq + MSS) is identical
for all, no need to multiply zones. The script adds each new interface to the existing
zone automatically.

In podkop each tunnel is attached as a separate configuration: add a second profile and
point it at the interface you want. Which traffic goes through which server is decided
by podkop's lists.

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
