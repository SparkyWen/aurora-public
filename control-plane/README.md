# Aurora control plane

An optional Cloudflare Worker that delivers contract updates to your devices. You do not need it to
use Aurora: `install.sh` prints a link, you add it in the app, and that is a complete setup. Deploy a
Worker when you would rather change servers in one place than re-import links on every device.

It hands out a signed contract and, if you use the [signed egress](../docs/advanced-signed-egress.md)
option, the home node's signed lease. It never carries VPN traffic.

The Worker is not a trust anchor. The app checks every download against the Ed25519 key pinned in the
contract it already trusts (`delivery.signing`), and no key is compiled into the app. Whoever controls
the Cloudflare account can withhold updates, but cannot forge one without your signing key. They can,
however, read the contract, node credentials included, because it is stored unencrypted in KV.

## Routes

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness probe |
| `GET /v2/get_domain` | The delivery entries that are currently alive (`DELIVERY_DOMAINS`), so a domain can be rotated without a new app |
| `GET /v2/contract?token=...` | The contract JSON from KV (read token required) |
| `GET /v2/egress-lease` | The home node's signed lease (read token required) |
| `PUT /v2/egress-lease` | Stores a lease with a strictly higher sequence (separate write token required) |

The contract lives in KV. The lease lives in a single Durable Object, whose storage transaction
serializes the sequence comparison and the write. Do not move it to KV: KV's read-then-write would let
two concurrent writers both win.

## Deploy your own

You need a free Cloudflare account and a current Node.js. Run everything from `control-plane/`.

```bash
npx wrangler login      # or set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN

# 1. Create the KV namespace, and paste the id it prints into wrangler.toml.
npx wrangler kv namespace create AURORA_KV

# 2. Deploy once to learn your URL: https://aurora-cp.YOUR-SUBDOMAIN.workers.dev
npx wrangler deploy

# 3. Put that URL in DELIVERY_DOMAINS in wrangler.toml, then deploy again.
npx wrangler deploy
```

### Build a contract

Skip this if you already have a contract file. Otherwise expand the links `install.sh` printed, using
the same code the app runs (`app/` needs Flutter's Dart SDK; `secrets/` is gitignored):

```bash
mkdir -m 700 -p ../secrets
cd ../app && dart run tool/link_to_contract.dart ../secrets/contract.json \
  'aurora://v1/...' 'aurora://v1/...'
cd ../control-plane
```

Each server becomes its own route family, named after the server. The publisher has no `--link` input
on purpose: expanding links lives in one place, in Dart.

### Publish

```bash
node scripts/publish-contract.mjs \
  --contract ../secrets/contract.json \
  --base https://aurora-cp.YOUR-SUBDOMAIN.workers.dev \
  --output ../secrets/contract.json \
  --link-output ../secrets/delivery-link.txt
```

The first run generates the signing key at `secrets/aurora-contract-signing.pem` (repository root,
gitignored, mode 0600). **Back it up offline.** Then:

1. The contract's delivery block is pointed at your Worker, and the public key is pinned in
   `delivery.signing`. Both are covered by the signature.
2. The signed contract goes to KV, and the read token to the Worker secret `AURORA_TOKEN`.
3. An import link is written to `--link-output` (0600). The path is printed, the token never is.

Add the contents of that file in the app, the same way you add a server. The app downloads the contract,
checks it against the key in the link, and from then on accepts only contracts signed by that key. The
link holds the read token, so treat it like a password.

To check the Worker itself:

```bash
curl https://aurora-cp.YOUR-SUBDOMAIN.workers.dev/health
curl https://aurora-cp.YOUR-SUBDOMAIN.workers.dev/v2/get_domain
```

### Publishing an update

Edit the contract and run the same command. Devices pick it up the next time they connect.

- **Point `--output` at the `--contract` file**, as above. It keeps the token, the key pin and a rising
  revision. A contract with no `delivery.token` gets a new token, which replaces `AURORA_TOKEN` and
  locks out every device still using the old one. The publisher warns when this happens.
- **Publish at least every 30 days.** A published contract expires after 30 days. An expired download
  is refused and the device stays on its last known good contract, so nothing breaks at once, but a
  device can no longer receive changes.
- A device only accepts a higher `revision`, and every publish raises it.

## Losing or changing the signing key

The publisher refuses to sign a contract that pins a different key, because installed apps would
reject the update while the publish looked successful. It has no rotation command. If the key is lost,
or you want to change it:

1. Remove `delivery.signing` from your contract file.
2. Publish with the new key (`--signing-key`, or delete the old file to generate one).
3. Re-import the new link on every device.

## Changing the read token

A device has to hold the current token to refresh, so a new token alone locks out every device that has
not updated yet. To replace it without that, keep the old token valid for a while:

```bash
npx wrangler secret put AURORA_TOKEN_PREVIOUS         # the old token
npx wrangler secret put AURORA_TOKEN_PREVIOUS_UNTIL   # epoch milliseconds when it stops working
```

Publish the new token in `delivery.token`. Devices pick it up on their next refresh. Past the deadline the old
token stops working, so a forgotten secret cannot quietly undo the change. Without a deadline it stays valid until
you delete the secret.

## Security

- The contract's node credentials are only in KV and in your local files. Nothing in this directory
  holds a real one, and `.gitignore` blocks local contract copies and `.dev.vars`.
- `AURORA_TOKEN` can only read the contract and the lease. `AURORA_LEASE_WRITE_TOKEN` can only write the
  lease. Never reuse one for the other.
- The Worker checks a lease's envelope, time and sequence. It does not hold the home agent's private
  key and never signs anything on its behalf.
- A remote contract with an invalid signature, an expired or not-yet-valid window, an older revision or a
  too-high `min_client_version` is refused, and the device keeps its last known good contract.

## Limits

- This delivers configuration, not connectivity. If a node's IP is blocked, the contract still arrives
  but the node stays unreachable: use it to publish a replacement.
- `workers.dev` domains are unreliable on some networks. A custom domain (see the end of
  `wrangler.toml`) is steadier, and you can list several backups in `DELIVERY_DOMAINS`.
- Reachability differs by carrier and time of day. Measure it on the networks you care about.

## Tests

```bash
node --test     # pure Node: no wrangler and no network
```

The publisher always passes `--remote` to `wrangler kv key put`. Without it, recent versions of Wrangler
write only to the local development KV.
