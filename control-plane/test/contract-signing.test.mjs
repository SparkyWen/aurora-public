import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import test from 'node:test';

import {
  attachContractSignature,
  canonicalJson,
  DEFAULT_CONTRACT_KEY_ID,
  rawEd25519PublicKey,
} from '../src/contract-signing.mjs';
import {
  normalizeContractCompatibility,
  validatePublishableContract,
} from '../src/contract-policy.mjs';

test('canonical JSON recursively sorts objects and preserves arrays', () => {
  // Non-ASCII on purpose: the canonical form must keep these as UTF-8, not escape them.
  assert.equal(
    canonicalJson({ z: 1, a: { d: 2, b: ['\u540e', '\u5148'] } }),
    '{"a":{"b":["\u540e","\u5148"],"d":2},"z":1}',
  );
});

test('publisher creates a verifiable Ed25519 signature', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const signed = attachContractSignature(
    { version: 1, revision: 42, nodes: [{ id: 'home' }] },
    privateKey,
  );
  const signature = signed.signature;
  delete signed.signature;
  assert.equal(signature.algorithm, 'ed25519');
  assert.equal(signature.key_id, DEFAULT_CONTRACT_KEY_ID);
  assert.equal(
    verify(
      null,
      Buffer.from(canonicalJson(signed), 'utf8'),
      publicKey,
      Buffer.from(signature.value, 'base64'),
    ),
    true,
  );
});

test('the signature names the key id it was asked to use', () => {
  const { privateKey } = generateKeyPairSync('ed25519');
  const signed = attachContractSignature({ revision: 1 }, privateKey, 'my-own-key');
  assert.equal(signed.signature.key_id, 'my-own-key');
});

test('the raw public key is the 32-byte form the app pins', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const raw = Buffer.from(rawEd25519PublicKey(privateKey), 'base64');
  assert.equal(raw.length, 32);
  // SPKI is a fixed 12-byte Ed25519 prefix followed by the raw key.
  assert.deepEqual(raw, publicKey.export({ format: 'der', type: 'spki' }).subarray(12));
  assert.equal(
    rawEd25519PublicKey(privateKey.export({ type: 'pkcs8', format: 'pem' })),
    raw.toString('base64'),
  );
});

test('a key that is not Ed25519 is refused', () => {
  const { privateKey } = generateKeyPairSync('x25519');
  assert.throws(() => rawEd25519PublicKey(privateKey), /Ed25519/);
});

test('dual-path publish policy accepts home-only topology', () => {
  assert.doesNotThrow(() => validatePublishableContract(dualContract()));
});

test('three-path publish policy accepts public, Tailnet, then home topology', () => {
  assert.doesNotThrow(() => validatePublishableContract(threePathContract()));
});

test('publisher keeps the legacy expected_ipv4 alias for installed clients', () => {
  const contract = threePathContract();
  assert.equal(contract.egress.expected_ipv4, undefined);

  normalizeContractCompatibility(contract);

  assert.equal(contract.egress.expected_ipv4, contract.egress.bootstrap_ipv4);
});

test('publish policy rejects mismatched egress IPv4 compatibility fields', () => {
  const contract = threePathContract();
  contract.egress.expected_ipv4 = '203.0.113.10';

  assert.throws(
    () => validatePublishableContract(contract),
    /compatibility fields must match/,
  );
});

test('three-path publish policy rejects a public path without signed home DNS', () => {
  const contract = threePathContract();
  contract.nodes.find((node) => node.id === 'home-via-relay-public-a').server =
    'other.example.net';
  assert.throws(() => validatePublishableContract(contract), /public household target/);
});

test('three-path publish policy requires public and Tailnet paths to share entries', () => {
  const contract = threePathContract();
  contract.nodes.push({ id: 'relay-entry-c', role: 'entry', server: '198.51.100.8' });
  contract.nodes.find((node) => node.id === 'home-via-relay-tailnet-b').detour =
    'relay-entry-c';
  assert.throws(() => validatePublishableContract(contract), /share entries/);
});

test('dual-path publish policy rejects unknown and direct path members', () => {
  const unknown = dualContract();
  unknown.paths.items.relay.members.push('missing');
  assert.throws(() => validatePublishableContract(unknown), /unknown path member/);

  const direct = dualContract();
  direct.paths.items.home.members.push('direct');
  assert.throws(() => validatePublishableContract(direct), /direct/);
});

test('dual-path publish policy rejects relay members in the legacy group', () => {
  const contract = dualContract();
  contract.outbound_group.urltest.members = ['home-via-relay'];
  assert.throws(() => validatePublishableContract(contract), /legacy/);
});

test('dual-path publish policy rejects partial additive fields', () => {
  const contract = dualContract();
  delete contract.egress;
  assert.throws(() => validatePublishableContract(contract), /present together/);
});

function dualContract() {
  return {
    version: 1,
    nodes: [
      { id: 'relay-entry', role: 'entry', server: '198.51.100.8' },
      { id: 'home-via-relay', role: 'exit', protocol: 'shadowsocks-2022', server: '100.64.0.9', port: 8388, detour: 'relay-entry' },
      { id: 'home', role: 'primary', server: '203.0.113.9' },
    ],
    outbound_group: {
      selector: { tag: 'proxy', members: ['auto', 'home'], default: 'auto' },
      urltest: { tag: 'auto', members: ['home'] },
    },
    paths: {
      preferred: 'relay',
      items: {
        relay: { group_tag: 'relay-auto', members: ['home-via-relay'] },
        home: { group_tag: 'home-auto', members: ['home'] },
      },
    },
    path_policy: { mode: 'prefer_relay', fallback: 'home', health: {} },
    egress: { expected_ipv4: '203.0.113.9', expected_country: 'ZZ', expected_asn: 'AS64500' },
  };
}

function threePathContract() {
  const contract = dualContract();
  contract.nodes = [
    { id: 'relay-entry-a', role: 'entry', server: '198.51.100.8' },
    { id: 'relay-entry-b', role: 'entry', server: '198.51.100.8' },
    { id: 'home-via-relay-public-a', role: 'exit', protocol: 'shadowsocks-2022', server: 'home.example.net', port: 2053, detour: 'relay-entry-a' },
    { id: 'home-via-relay-public-b', role: 'exit', protocol: 'shadowsocks-2022', server: 'home.example.net', port: 2053, detour: 'relay-entry-b' },
    { id: 'home-via-relay-tailnet-a', role: 'exit', protocol: 'shadowsocks-2022', server: '100.64.0.9', port: 8388, detour: 'relay-entry-a' },
    { id: 'home-via-relay-tailnet-b', role: 'exit', protocol: 'shadowsocks-2022', server: '100.64.0.9', port: 8388, detour: 'relay-entry-b' },
    { id: 'home', role: 'primary', server: '203.0.113.9' },
  ];
  contract.paths = {
    preferred: 'relay_public',
    items: {
      relay_public: { group_tag: 'relay-public-auto', members: ['home-via-relay-public-a', 'home-via-relay-public-b'] },
      relay_tailnet: { group_tag: 'relay-tailnet-auto', members: ['home-via-relay-tailnet-a', 'home-via-relay-tailnet-b'] },
      home: { group_tag: 'home-auto', members: ['home'] },
    },
  };
  contract.path_policy = {
    mode: 'prefer_relay', fallback: 'home', fallback_order: ['relay_tailnet', 'home'], health: {},
  };
  contract.egress = {
    bootstrap_ipv4: '203.0.113.9',
    expected_country: 'ZZ',
    expected_asn: 'AS64500',
    lease_url: 'https://control.example.net/v2/egress-lease',
    lease_key_id: 'home-egress-1',
    lease_public_key: Buffer.alloc(32, 7).toString('base64'),
    home_name: 'home.example.net',
  };
  return contract;
}
