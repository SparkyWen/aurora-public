# Self-hosting guide

Everything here runs from one script, `install.sh`. It is safe to re-run at any time: it keeps your keys, so
connected clients keep working, and only changes what you ask it to.

- [VPS](#vps)
- [Home node](#home-node)
- [Relay: a VPS in front of your home node](#relay-a-vps-in-front-of-your-home-node)
- [CDN fronting](#cdn-fronting)
- [Several servers](#several-servers)
- [Managing a node](#managing-a-node)
- [What the installer changes on your system](#what-the-installer-changes-on-your-system)
- [Troubleshooting](#troubleshooting)

## VPS

Any Linux VPS with systemd and a public IPv4 address works (x86-64, ARM64 or ARMv7).

```bash
curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh | sudo bash
```

Give it a name, which is what the app shows:

```bash
curl -fsSL .../install.sh | sudo bash -s -- --vps --name tokyo
```

**Then open the ports in your cloud provider's firewall.** The script opens the local firewall (ufw, firewalld or
iptables), but it cannot touch a provider's security group or cloud firewall. By default:

| Port | Protocol |
| --- | --- |
| TCP 443 | REALITY |
| UDP 443 | Hysteria2 |
| TCP 8443 | Shadowsocks |

If a default port is taken (say, by nginx on 443) the script picks a free alternative and tells you. A port you
set explicitly with `--reality-port`, `--hy2-port` or `--ss-port` is never silently changed.

## Home node

A home node lets your traffic exit from your home connection. That is useful for services that treat datacenter
IPs differently. It runs on Linux or macOS.

```bash
curl -fsSL .../install.sh | sudo bash -s -- --home
```

Home mode differs from a VPS in three ways:

1. **Different default ports**: TCP 8443, UDP 8443, TCP 2053, because home ISPs commonly block inbound 80 and 443.
2. **UPnP**: it asks your router to forward those ports, and re-asserts this every five minutes, following your
   machine if its LAN address changes.
3. **A check for carrier-grade NAT**, described below.

Give the machine a stable LAN address or a DHCP reservation if you can.

### If UPnP fails

The summary at the end says so and lists the forwards to create by hand, on your router's port forwarding page. To
skip UPnP entirely, pass `--no-upnp`.

### Carrier-grade NAT

Many ISPs share one public IPv4 across customers. No port forward can work then, because your router has no public
address to forward from. The script detects this when UPnP is available, by comparing your router's WAN address with
the address the internet sees. Your options:

- **Ask your ISP for a public IPv4.** Often a free request or a small fee.
- **Use a relay over Tailscale.** Join the home machine and a cheap VPS to the same tailnet, then:

  ```bash
  # At home: listen as usual, and advertise the Tailscale address.
  curl -fsSL .../install.sh | sudo bash -s -- --home --no-upnp --host "$(tailscale ip -4)"

  # On the VPS, with the link the home node printed:
  curl -fsSL .../install.sh | sudo bash -s -- relay '<link>'
  ```

  Import the relay's link in the app. Clients reach the VPS, and the VPS reaches your home over the tailnet.

### Dynamic DNS

Home IPs change. Without a DNS name, every change breaks your link until you re-import it. To keep the link valid
indefinitely, give the node a name and let it update the record:

```bash
# Cloudflare, with an API token scoped to Zone.DNS edit:
curl -fsSL .../install.sh | sudo bash -s -- --home --host home.example.com --cf-token "$TOKEN"

# DuckDNS, which is free:
curl -fsSL .../install.sh | sudo bash -s -- --home --host myname.duckdns.org --duckdns-token "$TOKEN"
```

To keep a token out of your shell history and process list, read it into the environment instead:

```bash
read -rs AURORA_CF_TOKEN && export AURORA_CF_TOKEN   # paste the token, then press Enter
curl -fsSL .../install.sh | sudo --preserve-env=AURORA_CF_TOKEN bash -s -- --home --host home.example.com
```

Tokens are stored in the node's `0600` state file. A timer checks every five minutes. The Cloudflare record is never
proxied, because clients need your real address for REALITY and QUIC.

Before the tunnel exists, the app looks server names up directly at `223.5.5.5`, a public resolver that also answers
reliably from inside China. If your network blocks it, a server known only by name cannot be reached. Use its IP
address with `--host` instead.

### Testing a home node

**Test from outside your home**, for example from a phone on mobile data. Testing your own public IP from inside the
LAN is unreliable: routers can answer for ports that are closed from the outside (hairpin NAT), so both success and
failure can be false.

## Relay: a VPS in front of your home node

Your home IP might be slow or blocked from where you are. A relay is a VPS that gets you in, while your traffic still
exits from home:

```bash
# 1. At home:
curl -fsSL .../install.sh | sudo bash -s -- --home --host home.example.com

# 2. On the VPS, with the link printed in step 1:
curl -fsSL .../install.sh | sudo bash -s -- relay '<link from step 1>' --name edge

# 3. In the app, add the link printed in step 2.
```

The relay's link holds everything the app needs, including the route to your home node. If you also add the home link
directly, you get both routes and can switch between them. For example, go direct when you are nearby and use the relay
when you travel.

How it is built, and why it is safe:

- **Your traffic is encrypted end to end to your home node.** The client wraps an inner Shadowsocks tunnel to your
  home inside the outer connection to the relay, so the relay only forwards ciphertext. It does hold the Shadowsocks
  password needed to print its link, so treat a relay as part of your trusted infrastructure.
- **The relay can only reach your home node.** It has no general internet outbound. Leaked relay credentials cannot be
  used as an open proxy, and a misconfiguration fails closed rather than quietly moving your exit. The self-test checks
  this property: it fails if the relay can reach the open internet.
- **In the app, entries are never selectable.** Only the chained routes appear, so your exit stays your home IP.

Use a DNS name for your home node (`--host`, see [Dynamic DNS](#dynamic-dns)). A literal IP is written into the relay's
allowlist, so an IP change means re-running the relay install with the new link.

## CDN fronting

If your server's IP gets blocked, every protocol on it dies together, since they share the address. Fronting through a
CDN moves the visible endpoint to Cloudflare's address space:

1. Add a DNS record at Cloudflare pointing at your server, with the **proxy enabled** (orange cloud).
2. Set the zone's SSL/TLS mode to **Full** (not Strict: the origin certificate is self-signed).
3. Add the domain:

   ```bash
   curl -fsSL .../install.sh | sudo bash -s -- --cdn-domain cdn.example.com
   ```

4. Re-import the link in the app, and open the CDN port (default TCP 2083) in your cloud firewall.

The port must be one Cloudflare proxies over HTTPS: 443, 2053, 2083, 2087, 2096 or 8443. This works for a VPS, a home
node or a relay, and it appears in the app as another protocol in that server's route.

## Several servers

Each link you add becomes its own route in the app, named after the server. With more than one, the main screen shows
a route picker:

- **Auto** picks the fastest across everything. Your public IP may change as it does.
- **A named route** locks onto that server. If it goes down, Aurora says so rather than silently moving you somewhere
  else. That is deliberate: when you pick where your traffic exits, it must not change behind your back.

The first server you add is the default, so adding a second never moves your exit on its own. A relay becomes the
default when you add it, since you set it up to be used.

Adding a link with a name you already have replaces that server, which is how you update after `aurora-node rotate`.

## Managing a node

```bash
sudo aurora-node link        # the link and QR code again
sudo aurora-node status      # service state, address and ports
sudo aurora-node verify      # end-to-end traffic test
sudo aurora-node rotate      # new keys; clients must re-import
sudo aurora-node uninstall   # remove it, keeping keys so a re-install keeps the same link
sudo aurora-node uninstall --purge   # also delete the keys
```

Change a setting by re-running the installer with it:

```bash
curl -fsSL .../install.sh | sudo bash -s -- --ss-port 2053
```

### Full option list

Run `install.sh --help`, or see the top of [`install.sh`](../install.sh). Notable ones:

| Option | Meaning |
| --- | --- |
| `--host <addr>` | The address clients dial (IPv4 or DNS name) |
| `--reality-sni <name>` | The real TLS site REALITY borrows. By default it is chosen by a live test |
| `--allow-lan` | Let tunnel traffic reach this machine's LAN (blocked by default) |
| `--rotate` | Generate new keys during this install |
| `--no-self-test` | Skip the traffic test |
| `--no-firewall` | Leave the local firewall alone |

### Port hopping

By default Hysteria2 hops its **source** port every 10 seconds, on the one known port. Some carriers throttle UDP per
flow, and a new source port is a new flow. It needs no server change.

Hopping across a range of server ports is possible but riskier: the client hops blindly, so a single blocked port in the
range causes periodic outages. See [`deploy/extras/hy2-port-hopping.sh`](../deploy/extras/hy2-port-hopping.sh) and verify
from outside before advertising a range.

## What the installer changes on your system

So you can audit or undo it by hand:

| What | Linux | macOS |
| --- | --- | --- |
| sing-box binary (pinned, checksum verified) | `/usr/local/lib/aurora-node/sing-box` | same |
| Management command | `/usr/local/bin/aurora-node` | same |
| Config, keys, link | `/etc/aurora-node/` | `/usr/local/etc/aurora-node/` |
| Service | `aurora-node.service` (unprivileged user, `CAP_NET_BIND_SERVICE` only, sandboxed) | `org.aurora.node` LaunchDaemon |
| Upkeep timer (home or DDNS only) | `aurora-node-maintain.timer` | `org.aurora.node.maintain` LaunchDaemon |
| Local firewall | Allows the node's ports in ufw, firewalld or iptables | Allows sing-box in the application firewall |
| UDP buffers | `/etc/sysctl.d/99-aurora-node.conf` | not needed |
| Packages | `curl`, `tar`, `openssl` if missing; `qrencode` if available | none |
| Router (home only) | UPnP forwards for the node's ports | same |

Nothing is sent anywhere except to look up your public IP (ipify and similar services), to download sing-box, and to
update your DNS provider if you asked for it. `aurora-node uninstall` removes all of this except firewall rules, which
you may be using for something else.

## Troubleshooting

### The self-test fails

The script tests over loopback with real requests, so a failure here is on this machine, not your network path.

- **Only REALITY fails.** The camouflage site may have stopped working as a REALITY target. Remove `S_REALITY_SNI` from
  `/etc/aurora-node/node.env` and re-run, which picks a new one by test, or set one with `--reality-sni`. All protocols
  will pick up the change, and clients must re-import.
- **Everything fails.** Check this machine's own internet access: `curl https://api.ipify.org`. Then
  `journalctl -u aurora-node -n 50`.

### The app says connected but nothing loads, or it cannot connect at all

1. Run `sudo aurora-node verify`. If that passes, the server is healthy, and the problem is the network path to it.
2. Check your cloud firewall allows the ports, **including UDP** (the most commonly forgotten one).
3. Test from outside with `nc -vz <host> <tcp-port>`. For a home node, use a phone on mobile data.
4. Try each protocol: the Nodes screen in the app shows which ones respond.

### It worked, and then stopped

Open **Settings → Diagnostics** in the app. Common causes:

- **Your home IP changed**, and you have no dynamic DNS. Run `sudo aurora-node link` on the node and re-import.
- **Your server's IP was blocked.** All protocols on one IP fail together. Add a [relay](#relay-a-vps-in-front-of-your-home-node)
  or [CDN fronting](#cdn-fronting), which reach you over independent addresses.
- **UDP is throttled or blocked on your current network.** Aurora fails over to TCP on its own. Slow speeds may mean
  Hysteria2 is being throttled while still answering health checks; the app's throughput check demotes such a leg.

See [`reliability-notes.md`](reliability-notes.md) for the failure modes in depth, and how to read the logs.

### Connecting a third-party client

`/etc/aurora-node/share-links.txt` holds standard `vless://`, `hysteria2://` and `ss://` links for v2rayN, NekoBox and
similar clients.
