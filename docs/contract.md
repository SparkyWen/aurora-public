# Contract and link format

Two documents describe a user's servers:

- The **link** (`aurora://v1/...`) is what `install.sh` prints. It describes one server, and it is compact so it fits a
  QR code.
- The **contract** is what the app stores and compiles. It describes every server the user has added, plus delivery and
  network policy.

The app expands links into contract nodes in `app/lib/core/server_bundle.dart` and merges them in
`app/lib/core/contract_editor.dart`. The compiler (`app/lib/core/config_compiler.dart`) only ever sees contracts.

## The link

```
aurora://v1/<base64url without padding, of gzip-compressed compact JSON>#<name>
```

The `#name` fragment is cosmetic, so a link is recognizable at a glance. The name inside the payload is authoritative.
Compression is what lets the QR code of a VPS or home link fit an 80-column terminal. The app and `install.sh relay` also
accept uncompressed JSON, which is convenient when writing a link by hand.

### Server link

```json
{
  "v": 1,
  "kind": "vps",
  "name": "tokyo",
  "host": "203.0.113.10",
  "reality": { "port": 443, "uuid": "...", "pbk": "...", "sid": "...", "sni": "www.apple.com" },
  "hy2": { "port": 443, "password": "...", "sni": "www.bing.com", "spki": "<base64 SHA-256 of the certificate's SPKI>" },
  "ss": { "port": 8443, "password": "<base64, 16 random bytes>" },
  "cdn": { "host": "cdn.example.com", "port": 2083, "uuid": "...", "path": "/abc" },
  "exit": { "name": "house", "host": "home.example.com", "port": 2053, "password": "..." }
}
```

| Field | Notes |
| --- | --- |
| `v` | Format version. The app refuses versions it does not know, and asks the user to upgrade |
| `kind` | `vps` or `home` (terminal exits), or `relay` (entries chained to `exit`) |
| `name` | `^[a-z][a-z0-9-]{0,15}$`. Identifies the server: re-importing a name replaces that server |
| `host` | The IPv4 address or DNS name clients dial |
| `cdn` | Optional CDN-fronted VLESS+WebSocket+TLS entry |
| `exit` | Relay only: the home node's Shadowsocks endpoint |

### Delivery link

Points the app at a [control plane](../control-plane/README.md) and pins its signing key. Importing it is the trust
decision.

```json
{
  "v": 1,
  "kind": "delivery",
  "name": "my-control-plane",
  "url": "https://aurora-cp.example.workers.dev/v2/contract",
  "token": "...",
  "key_id": "aurora-key-1",
  "public_key": "<base64 raw 32-byte Ed25519>"
}
```

### Deep links

On phones, `aurora://` is a registered URL scheme, so scanning the QR code with the system camera opens the app. The
Flutter engine delivers `aurora://v1/<data>#<name>` as the route `/<data>#<name>`, and `main.dart` routes it to the Add
Server page, which **always asks for confirmation**. A link on a web page must not be able to reconfigure a VPN without a
tap.

There is deliberately no in-app QR scanner: Flutter scanning plugins generally bring Google ML Kit, which reports usage
metrics, and Aurora has no telemetry.

## The contract

```json
{
  "version": 1,
  "revision": 1793000000000,
  "updated": "2026-11-05T12:00:00.000Z",
  "profile": { "name": "Aurora", "default_mode": "global", "default_family": "tokyo" },
  "network": { "mtu": 1400, "ipv6_mode": "block", "suppress_https_rr": false },
  "delivery": { "primary": "https://.../v2/contract", "token": "...", "signing": { "key_id": "...", "public_key": "..." } },
  "nodes": [ ],
  "outbound_group": {
    "selector": { "tag": "proxy", "members": ["auto", "tokyo-reality", "..."], "default": "auto" },
    "urltest": { "tag": "auto", "members": ["tokyo-reality", "..."], "url": "https://www.gstatic.com/generate_204", "interval": "3m" }
  }
}
```

| Field | Notes |
| --- | --- |
| `revision` | Monotonic; a remote contract must be strictly newer (rollback protection) |
| `profile.default_family` | The route to use before the user picks one |
| `network.ipv6_mode` | `block` (default; on desktop this means the TUN gets no IPv6 address at all) or `native` |
| `delivery` | Optional. Without `delivery.signing`, the app never fetches anything |

### Nodes

```json
{
  "id": "tokyo-hy2",
  "name": "tokyo Hysteria2",
  "role": "fast",
  "via": "tokyo",
  "group": "tokyo",
  "protocol": "hysteria2",
  "server": "203.0.113.10",
  "port": 443,
  "params": { }
}
```

| Field | Notes |
| --- | --- |
| `role` | `primary`, `fast`, `backup` or `exit` are selectable. `entry` is only reachable through a `detour` |
| `via` | The route family: how traffic reaches this exit. Becomes a `via-<family>` group |
| `group` | Which imported server this node belongs to; used to replace or remove it |
| `detour` | Dial this node's server through another node, which must have `role: entry` |
| `protocol` | `vless-reality`, `hysteria2`, `shadowsocks-2022` or `vless-ws-tls` |

### Route families

A family answers "how does traffic get to this exit?". Each `install.sh` server is its own family, named after it, so
locking a family pins your exit.

If `via` is missing, the app derives only what the structure can prove: a node with a `detour` becomes `relay`, and any
other becomes `unspecified`. It **never** assumes `direct`. A node with no detour has no relay hop, but that says nothing
about where it exits, and a label that promises more than it knows is how a route can stay green while your exit moves.

### Parameters by protocol

**`vless-reality`**: `uuid`, `flow` (`xtls-rprx-vision`), `sni`, `public_key`, `short_id`, `fingerprint` (`chrome`).

**`hysteria2`**: `password`, `sni`, `alpn`, and `certificate_public_key_sha256` (SPKI pin) or `certificate`.
`server_ports` (a list of `"start:end"`) and `hop_interval` enable hopping. List only ports verified from outside.
`insecure: true` exists for plain share links; `install.sh` always pins.

**`shadowsocks-2022`**: `method` (`2022-blake3-aes-128-gcm`), `password`. A `multiplex` field is ignored; see the hard
constraints in [`CONTRIBUTING.md`](../CONTRIBUTING.md).

**`vless-ws-tls`**: `uuid`, `sni`, `path`, `fingerprint`, and optional `host`.

### Multi-path contracts

`paths`, `path_policy` and `egress` must appear together. They describe explicit paths with a health policy and signed
egress leases. `install.sh` does not produce these; see
[`advanced-signed-egress.md`](advanced-signed-egress.md). A contract with `paths` cannot be merged with links.

### Trying it yourself

```bash
cd app
dart run tool/link_to_contract.dart contract.json 'aurora://v1/...'
dart run tool/compile_check.dart contract.json global out.json
sing-box check -c out.json
```

A complete fixture is at [`app/test/fixtures/contract.sample.json`](../app/test/fixtures/contract.sample.json), with its
compiled forms alongside it.
