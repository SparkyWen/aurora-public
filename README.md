# Aurora

**Your own multi-protocol VPN. One command on your server, one scan on your phone.**

Aurora connects your devices to servers **you** own: a cheap VPS or a machine at home. There is no account, no
subscription and no telemetry.

## Quick start

**1. Set up a server.** On a Linux or macOS machine you control:

```bash
curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh | sudo bash
```

It detects a VPS or a home network, generates keys, opens the firewall, proves real traffic flows through every
protocol, and prints a link and QR code. On a VPS, also allow the ports it lists in your provider's firewall.

**2. Install the app.** [Download it](https://github.com/SparkyWen/aurora-public/releases) for Android, Windows or
Linux, or [build from source](docs/building.md). iOS and macOS must be built with your own Apple developer account.

**3. Add your server.**

- **Phone:** scan the QR code with your camera, confirm, then tap **Connect**.
- **Desktop:** click **Add a server**, then **Paste** and **Add server**. Desktop apps connect as soon as they have a
  server, and again each time they open.
- **Headless Linux:** `aurora import '<link>' && aurora connect`

## Choose your setup

| You have | Run | Traffic exits from |
| --- | --- | --- |
| A VPS | `install.sh` | The VPS |
| A machine at home | `install.sh` (or `--home` to force it) | Your home IP |
| A home machine, and a VPS for reachability | `install.sh` at home, then `install.sh relay '<link>'` on the VPS | Your home IP, reached through the VPS |
| A server whose IP gets blocked | Add `--cdn-domain cdn.example.com` | Your server, reached through Cloudflare |

At home it asks your router to forward the ports over UPnP, and tells you what to do if it can't, or if your ISP uses
carrier-grade NAT. Add as many servers as you like; each is its own route in the app. See the
[self-hosting guide](docs/self-hosting.md).

## Managing a node

```bash
sudo aurora-node link        # print the link and QR code again
sudo aurora-node status      # service state, address, ports
sudo aurora-node verify      # re-run the traffic test
sudo aurora-node rotate      # replace all keys (clients re-import the new link)
sudo aurora-node uninstall   # remove it (--purge also deletes the keys)
```

Re-running the installer is safe: it keeps your keys, so connected clients keep working.

## How it works

A single tunnel is easy to identify and block. Aurora runs several behind one address and moves between them when one
stops working:

| Protocol | Port (VPS / home) | Good at |
| --- | --- | --- |
| VLESS + Vision + REALITY | TCP 443 / 8443 | Looks like real TLS to a real website |
| Hysteria2 | UDP 443 / 8443 | Fast on lossy links |
| Shadowsocks 2022 | TCP 8443 / 2053 | Lightweight fallback |

Smart mode sends mainland China traffic directly and proxies the rest; Global mode proxies nearly everything. IPv6 is
blocked by default to prevent leaks. See the [architecture](docs/architecture.md).

## Platforms

| Platform | Get it |
| --- | --- |
| Android 7+ | APK from Releases |
| Windows 10+ | Installer from Releases |
| Linux with systemd | `.deb` or `.tar.gz` from Releases; includes the `aurora` command line |
| iOS 15+, macOS 12+ | [Build from source](docs/building.md) with your own Apple developer account |

The node installer runs on Linux with systemd (x86-64, ARM64, ARMv7) and macOS.

## Documentation

[Self-hosting](docs/self-hosting.md) · [Architecture](docs/architecture.md) · [Link and contract format](docs/contract.md) ·
[Building](docs/building.md) · [Reliability notes](docs/reliability-notes.md) · [Control plane](control-plane/README.md) ·
[Signed egress](docs/advanced-signed-egress.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Responsible use

Aurora is for reaching your own servers and protecting your own traffic. You are responsible for following the laws
where you are and the terms of your hosting provider and ISP. It does not make you anonymous; see
[SECURITY.md](SECURITY.md).

## License

[GPL-3.0-or-later](LICENSE). Aurora links [sing-box](https://github.com/SagerNet/sing-box) and is an independent project,
not affiliated with or endorsed by it.
