# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
[security advisory form](https://github.com/SparkyWen/aurora-public/security/advisories/new), not in a
public issue. Include what you found and how to reproduce it.

## What Aurora does and does not protect

Aurora moves your traffic through a server **you** control. It hides your traffic from your local
network and makes the connection hard to identify and block. Understand its limits:

- **It does not make you anonymous.** Your server's provider and ISP can see its traffic, and websites
  see your server's IP. For a home node, that IP is your home connection.
- **Whoever runs the exit sees your destinations.** That is why links must only come from servers you
  set up yourself. The app asks for confirmation when a link arrives from outside it, for this reason.
- **Your link is a password.** It holds the server's credentials. Anyone with it can use your server.
  Run `aurora-node rotate` if one leaks.

## How secrets are handled

- `install.sh` generates all credentials on your machine. They are stored in `/etc/aurora-node/node.env`
  (`0600`, root only) and never sent anywhere. The service runs as an unprivileged user that can read its
  config but not that file.
- The app stores links and contracts only in the platform's encrypted storage (Keychain, Android
  Keystore-backed storage, libsecret, DPAPI). The headless CLI uses a `0600` file in your user state
  directory.
- Support bundles contain a hash of the active config, never the config itself.
- There is no telemetry, no analytics and no account. Nothing reports to the project.

## Trust model

- **Local imports are the trust root.** Pasting a link or a contract is your decision to trust it.
- **Remote updates must be signed.** A contract fetched from a control plane must carry a valid Ed25519
  signature from the key pinned by the contract you already trust, and a higher revision. No signing key
  is compiled into the app, so everyone self-hosting uses their own, and without a pinned key the app
  never fetches anything.
- **A refreshed contract only becomes last-known-good after it connects successfully**, so a signed but
  broken update cannot strand you.

## Exit node defaults

Exit nodes refuse private, loopback and link-local destinations, so a leaked credential cannot reach your
LAN or a cloud metadata service, and they refuse outbound SMTP (port 25). Relay nodes have no general
internet outbound at all: they can only reach the one home node they were set up for.

## Installing with `curl | bash`

If you prefer to read first, which is reasonable:

```bash
curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

The installer downloads a pinned sing-box release from its official GitHub releases and verifies a SHA-256
checksum embedded in the script before running it.
