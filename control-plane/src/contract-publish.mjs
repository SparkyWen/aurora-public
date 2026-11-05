// The publishing logic, free of file and network access so it can be tested.
// `scripts/publish-contract.mjs` wraps it with arguments, key files and wrangler.
import { randomBytes } from 'node:crypto';

import {
  attachContractSignature,
  DEFAULT_CONTRACT_KEY_ID,
  rawEd25519PublicKey,
} from './contract-signing.mjs';
import {
  normalizeContractCompatibility,
  validatePublishableContract,
} from './contract-policy.mjs';

const VALIDITY_MS = 30 * 24 * 60 * 60 * 1000;
const KEY_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// Matches `_labelPattern` in app/lib/core/server_bundle.dart.
const LINK_NAME = /^[a-z][a-z0-9-]{0,15}$/;

export function normalizeBaseUrl(value) {
  const base = String(value ?? '').replace(/\/+$/, '');
  let url;
  try {
    url = new URL(base);
  } catch (_) {
    throw new Error('--base must be a URL');
  }
  // The app refuses a delivery link that is not https, and a read token sent in
  // clear text could be replayed to download every node credential.
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('--base must be a plain https:// URL');
  }
  return base;
}

// Apps already holding this contract only accept what is signed by the key it
// pins, under the key id it pins. Publishing with any other key would look
// successful while every installed app silently stayed on its old contract.
export function assertPinUnchanged(contract, publicKey, keyId) {
  const pinned = contract?.delivery?.signing;
  if (!pinned) return;
  if (pinned.public_key !== publicKey || pinned.key_id !== keyId) {
    throw new Error(
      `this contract pins signing key "${pinned.key_id}", which does not match the key in use. ` +
        'Installed apps would reject the update. Use the original key file. If it is lost, ' +
        'remove delivery.signing from the input and re-import the new link on every device.',
    );
  }
}

export function resolveKeyId(contract, requested) {
  const keyId = requested ?? contract?.delivery?.signing?.key_id ?? DEFAULT_CONTRACT_KEY_ID;
  if (!KEY_ID.test(keyId)) throw new Error('--key-id has invalid characters');
  return keyId;
}

export function buildPublishedContract(
  input,
  { base, privateKey, keyId, token, minClientVersion = '0.1.3', now = new Date() },
) {
  const contract = structuredClone(input);
  normalizeContractCompatibility(contract);
  const publicKey = rawEd25519PublicKey(privateKey);
  assertPinUnchanged(contract, publicKey, keyId);

  const readToken = token || contract?.delivery?.token || randomBytes(16).toString('hex');
  // Milliseconds, the unit ContractEditor uses for local edits. In seconds a publish
  // would rank below any local edit on the device and never count as an upgrade.
  contract.revision = Number.isInteger(contract.revision)
    ? Math.max(contract.revision + 1, now.getTime())
    : now.getTime();
  contract.updated = now.toISOString();
  contract.issued_at = now.toISOString();
  contract.expires_at = new Date(now.getTime() + VALIDITY_MS).toISOString();
  contract.min_client_version = minClientVersion;
  contract.network = {
    mtu: 1400,
    ipv6_mode: 'block',
    suppress_https_rr: false,
    ...(contract.network || {}),
  };
  if (Array.isArray(contract?.outbound_group?.selector?.members)) {
    contract.outbound_group.selector.members =
      contract.outbound_group.selector.members.filter((tag) => tag !== 'direct');
  }
  if (Array.isArray(contract?.outbound_group?.urltest?.members)) {
    contract.outbound_group.urltest.members =
      contract.outbound_group.urltest.members.filter((tag) => tag !== 'direct');
  }
  for (const node of contract.nodes || []) {
    if (node.protocol !== 'hysteria2') continue;
    const params = node.params || {};
    const hasPin = params.certificate_public_key_sha256 != null;
    const hasPem = params.certificate != null;
    if (!hasPin && !hasPem) {
      throw new Error(
        `refusing to publish Hysteria2 node "${node.id}": add an SPKI pin or PEM certificate`,
      );
    }
    if (params.insecure === true) {
      throw new Error(
        `refusing to publish Hysteria2 node "${node.id}" with insecure=true`,
      );
    }
  }
  validatePublishableContract(contract);

  // Rewrite the delivery block: the control plane is primary. Plain http: fallbacks
  // are dropped because the read token would travel in clear text, and anyone on
  // the path could replay it against the Worker to fetch the full contract with its
  // node credentials (see the client's _withToken constraint). So are non-fetchable
  // schemes such as tailscale:, which the app cannot use before the tunnel is up.
  const oldFallbacks = Array.isArray(contract?.delivery?.fallbacks)
    ? contract.delivery.fallbacks
    : [];
  contract.delivery = {
    primary: `${base}/v2/contract?token=${readToken}`,
    get_domain: `${base}/v2/get_domain`,
    fallbacks: oldFallbacks.filter((url) => String(url).startsWith('https://')),
    token: readToken,
    note: 'Control plane entry point. Reachability depends on the network: on failure ' +
      'the client tries its other entries, then keeps its last known good contract.',
    // Inside the signed body on purpose: this is what carries the pin forward, so
    // it has to be covered by the signature it pins.
    signing: { key_id: keyId, public_key: publicKey },
  };
  return {
    contract: attachContractSignature(contract, privateKey, keyId),
    token: readToken,
    publicKey,
  };
}

// The format `DeliveryLink` in app/lib/core/server_bundle.dart parses.
export function buildDeliveryLink({ name, base, token, keyId, publicKey }) {
  if (!LINK_NAME.test(name)) {
    throw new Error('--name must be lowercase letters, digits and dashes (max 16)');
  }
  const payload = {
    v: 1,
    kind: 'delivery',
    name,
    url: `${base}/v2/contract`,
    token,
    key_id: keyId,
    public_key: publicKey,
  };
  const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  return `aurora://v1/${encoded}#${name}`;
}
