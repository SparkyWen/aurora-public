import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { generateKeyPairSync, verify } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { validatePublishableContract } from '../src/contract-policy.mjs';
import {
  buildDeliveryLink,
  buildPublishedContract,
  normalizeBaseUrl,
  resolveKeyId,
} from '../src/contract-publish.mjs';
import { canonicalJson, rawEd25519PublicKey } from '../src/contract-signing.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const publishScript = join(here, '../scripts/publish-contract.mjs');
const BASE = 'https://cp.example.net';
const NOW = new Date('2026-07-22T00:00:00Z');

// What the app's ContractEditor produces: the output of
// `dart run tool/link_to_contract.dart` for a VPS with CDN fronting, a home node and a
// relay, using placeholder credentials. Family names are arbitrary user labels here,
// and nodes carry `group` and `via`.
const editorContract = () =>
  JSON.parse(readFileSync(join(here, 'fixtures/editor-built-contract.json'), 'utf8'));

const privateKey = () => generateKeyPairSync('ed25519').privateKey;

function publish(input, key, overrides = {}) {
  return buildPublishedContract(input, {
    base: BASE,
    privateKey: key,
    keyId: 'aurora-key-1',
    now: NOW,
    ...overrides,
  });
}

// Mirrors ContractVerifier.verifyRemote in the app: drop the signature, canonicalize
// what is left, and check it against a pinned raw key.
function verifiesAgainst(contract, pinned) {
  const { signature, ...unsigned } = contract;
  assert.equal(signature.algorithm, 'ed25519');
  const rawKey = Buffer.from(pinned, 'base64');
  assert.equal(rawKey.length, 32);
  const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), rawKey]);
  return verify(
    null,
    Buffer.from(canonicalJson(unsigned), 'utf8'),
    { key: spki, format: 'der', type: 'spki' },
    Buffer.from(signature.value, 'base64'),
  );
}

function verifiesAgainstOwnPin(contract) {
  assert.equal(contract.signature.key_id, contract.delivery.signing.key_id);
  return verifiesAgainst(contract, contract.delivery.signing.public_key);
}

test('a contract built by the app passes the publish policy', () => {
  const contract = editorContract();
  assert.ok(contract.nodes.some((node) => node.via === 'tokyo' && node.group === 'tokyo'));
  assert.ok(contract.nodes.some((node) => node.role === 'entry' && node.group === 'edge'));
  assert.doesNotThrow(() => validatePublishableContract(contract));
});

test('a contract built by the app publishes with its nodes untouched', () => {
  const input = editorContract();
  const { contract } = publish(input, privateKey());
  assert.deepEqual(contract.nodes, input.nodes);
  assert.deepEqual(contract.profile, input.profile);
});

test('the published contract carries delivery.signing and verifies against it', () => {
  const key = privateKey();
  const { contract, publicKey } = publish(editorContract(), key, { keyId: 'my-own-key' });

  assert.deepEqual(contract.delivery.signing, { key_id: 'my-own-key', public_key: publicKey });
  assert.equal(publicKey, rawEd25519PublicKey(key));
  assert.equal(contract.signature.key_id, 'my-own-key');
  assert.equal(verifiesAgainstOwnPin(contract), true);
});

test('the pin is covered by the signature', () => {
  const { contract, publicKey } = publish(editorContract(), privateKey());
  const swapped = structuredClone(contract);
  swapped.delivery.signing.public_key = rawEd25519PublicKey(privateKey());

  // An app holding the real key refuses a body whose pin was changed, so nobody
  // between the publisher and the app can swap in a key of their own.
  assert.equal(verifiesAgainst(swapped, publicKey), false);
  assert.equal(verifiesAgainst(contract, publicKey), true);
});

test('the delivery block points at this control plane and keeps only https fallbacks', () => {
  const input = editorContract();
  input.delivery = {
    token: 'kept-token',
    fallbacks: ['https://backup.example.net/v2/contract', 'http://203.0.113.5/c', 'tailscale:x'],
  };
  const { contract, token } = publish(input, privateKey());

  assert.equal(token, 'kept-token');
  assert.equal(contract.delivery.token, 'kept-token');
  assert.equal(contract.delivery.primary, `${BASE}/v2/contract?token=kept-token`);
  assert.equal(contract.delivery.get_domain, `${BASE}/v2/get_domain`);
  assert.deepEqual(contract.delivery.fallbacks, ['https://backup.example.net/v2/contract']);
});

test('a contract with no token gets a fresh one', () => {
  const { token } = publish(editorContract(), privateKey());
  assert.match(token, /^[0-9a-f]{32}$/);
});

test('the revision outranks both the input and any local edit made before publishing', () => {
  const input = editorContract();
  input.revision = 5;
  assert.equal(publish(input, privateKey()).contract.revision, NOW.getTime());

  input.revision = NOW.getTime() + 1000;
  assert.equal(publish(input, privateKey()).contract.revision, NOW.getTime() + 1001);

  // Republishing an app-built contract: ContractEditor counts in milliseconds, so a
  // publisher counting in seconds would rank below it and never reach the device.
  const appEdit = editorContract();
  appEdit.revision = NOW.getTime() - 60_000;
  assert.ok(publish(appEdit, privateKey()).contract.revision > appEdit.revision);
});

test('the validity window is 30 days from now', () => {
  const { contract } = publish(editorContract(), privateKey());
  assert.equal(contract.issued_at, '2026-07-22T00:00:00.000Z');
  assert.equal(contract.expires_at, '2026-08-21T00:00:00.000Z');
});

test('a contract pinned to another key is refused, because apps would reject it', () => {
  const key = privateKey();
  const { contract } = publish(editorContract(), key);

  assert.doesNotThrow(() => publish(contract, key));
  assert.throws(() => publish(contract, privateKey()), /does not match the key in use/);
  assert.throws(
    () => publish(contract, key, { keyId: 'another-id' }),
    /does not match the key in use/,
  );
});

test('republishing keeps the pinned key id by default', () => {
  const { contract } = publish(editorContract(), privateKey(), { keyId: 'my-own-key' });
  assert.equal(resolveKeyId(contract, undefined), 'my-own-key');
  assert.equal(resolveKeyId(editorContract(), undefined), 'aurora-key-1');
  assert.equal(resolveKeyId(editorContract(), 'chosen'), 'chosen');
  assert.throws(() => resolveKeyId(editorContract(), '../bad'), /invalid characters/);
});

test('an unpinned Hysteria2 node is refused', () => {
  const missing = editorContract();
  delete missing.nodes.find((node) => node.protocol === 'hysteria2').params
    .certificate_public_key_sha256;
  assert.throws(() => publish(missing, privateKey()), /SPKI pin/);

  const insecure = editorContract();
  insecure.nodes.find((node) => node.protocol === 'hysteria2').params.insecure = true;
  assert.throws(() => publish(insecure, privateKey()), /insecure=true/);
});

test('the base URL must be plain https', () => {
  assert.equal(normalizeBaseUrl(`${BASE}//`), BASE);
  for (const bad of ['http://cp.example.net', 'cp.example.net', '', `${BASE}?x=1`, 'https://u:p@cp.example.net']) {
    assert.throws(() => normalizeBaseUrl(bad), /--base/);
  }
});

test('the delivery link has the format the app parses', () => {
  const link = buildDeliveryLink({
    name: 'aurora',
    base: BASE,
    token: 'read-token',
    keyId: 'aurora-key-1',
    publicKey: 'cHVibGljLWtleQ==',
  });
  const match = link.match(/^aurora:\/\/v1\/([A-Za-z0-9_-]+)#aurora$/);
  assert.ok(match, 'no base64 padding or url-unsafe characters');
  assert.equal(
    Buffer.from(match[1], 'base64url').toString('utf8'),
    '{"v":1,"kind":"delivery","name":"aurora","url":"https://cp.example.net/v2/contract",' +
      '"token":"read-token","key_id":"aurora-key-1","public_key":"cHVibGljLWtleQ=="}',
  );
  assert.throws(
    () => buildDeliveryLink({ name: 'Not Valid', base: BASE, token: 't', keyId: 'k', publicKey: 'p' }),
    /--name/,
  );
});

// The script end to end, against a stand-in for npx so nothing touches the network.
function publishFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'aurora-publish-test-'));
  const log = join(dir, 'npx.log');
  const uploaded = join(dir, 'uploaded.json');
  const secret = join(dir, 'secret.txt');
  writeFileSync(
    join(dir, 'npx'),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${log}"
if [[ "$*" == *"secret put"* ]]; then cat >"${secret}"; fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --path ]]; then
    stat -f '%Lp' "$2" >"${uploaded}.mode" 2>/dev/null || stat -c '%a' "$2" >"${uploaded}.mode"
    cp "$2" "${uploaded}"
  fi
  shift
done
exit "\${STUB_EXIT:-0}"
`,
  );
  chmodSync(join(dir, 'npx'), 0o755);
  const run = (args, env = {}) =>
    spawnSync(process.execPath, [publishScript, ...args], {
      encoding: 'utf8',
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, ...env },
    });
  return { dir, log, uploaded, secret, run };
}

const mode = (path) => (statSync(path).mode & 0o777).toString(8);

test('first publish generates a key, uploads, and writes private output files', {
  skip: process.platform === 'win32',
}, (t) => {
  const { dir, log, uploaded, secret, run } = publishFixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const contractPath = join(dir, 'contract.json');
  const keyPath = join(dir, 'private/signing.pem');
  const linkPath = join(dir, 'link.txt');
  writeFileSync(contractPath, readFileSync(join(here, 'fixtures/editor-built-contract.json')));

  const result = run([
    '--contract', contractPath,
    '--base', BASE,
    '--signing-key', keyPath,
    '--output', contractPath,
    '--link-output', linkPath,
  ]);
  assert.equal(result.status, 0, result.stderr);

  assert.equal(mode(keyPath), '600');
  assert.equal(mode(linkPath), '600');
  assert.equal(mode(contractPath), '600');
  assert.equal(readFileSync(`${uploaded}.mode`, 'utf8').trim(), '600');

  const published = JSON.parse(readFileSync(uploaded, 'utf8'));
  assert.equal(verifiesAgainstOwnPin(published), true);
  assert.equal(published.delivery.signing.key_id, 'aurora-key-1');
  assert.equal(
    published.delivery.signing.public_key,
    rawEd25519PublicKey(readFileSync(keyPath, 'utf8')),
  );

  const { token } = published.delivery;
  assert.equal(readFileSync(secret, 'utf8'), token, 'token goes to wrangler over stdin');
  assert.ok(!readFileSync(log, 'utf8').includes(token), 'token is never a process argument');
  assert.ok(!result.stdout.includes(token) && !result.stderr.includes(token), 'token is not printed');
  assert.ok(result.stdout.includes(linkPath), 'the link path is printed');

  const link = readFileSync(linkPath, 'utf8').trim();
  assert.ok(!result.stdout.includes(link), 'the link is not printed');
  const decoded = JSON.parse(
    Buffer.from(link.slice('aurora://v1/'.length).split('#')[0], 'base64url').toString('utf8'),
  );
  assert.deepEqual(decoded, {
    v: 1,
    kind: 'delivery',
    name: 'aurora',
    url: `${BASE}/v2/contract`,
    token,
    key_id: published.delivery.signing.key_id,
    public_key: published.delivery.signing.public_key,
  });

  // Publishing again from --output keeps the key, the token and a rising revision.
  const keyBefore = readFileSync(keyPath, 'utf8');
  const again = run(['--contract', contractPath, '--base', BASE, '--signing-key', keyPath]);
  assert.equal(again.status, 0, again.stderr);
  assert.equal(readFileSync(keyPath, 'utf8'), keyBefore);
  const second = JSON.parse(readFileSync(uploaded, 'utf8'));
  assert.equal(second.delivery.token, token);
  assert.ok(second.revision > published.revision);
  assert.ok(!again.stderr.includes('new read token'));
});

test('a pinned contract is refused when its key file is missing, leaving no new key', {
  skip: process.platform === 'win32',
}, (t) => {
  const { dir, run } = publishFixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const contractPath = join(dir, 'contract.json');
  const { contract } = publish(editorContract(), privateKey());
  writeFileSync(contractPath, JSON.stringify(contract));
  const keyPath = join(dir, 'missing.pem');

  const result = run(['--contract', contractPath, '--base', BASE, '--signing-key', keyPath]);

  assert.equal(result.status, 2);
  assert.match(result.stderr, /pins signing key/);
  assert.equal(existsSync(keyPath), false);
});

test('a lax key file is tightened, and a failed upload leaves nothing behind', {
  skip: process.platform === 'win32',
}, (t) => {
  const { dir, run } = publishFixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const contractPath = join(dir, 'contract.json');
  const keyPath = join(dir, 'key.pem');
  const linkPath = join(dir, 'link.txt');
  const scratch = join(dir, 'tmp');
  execFileSync('mkdir', [scratch]);
  writeFileSync(contractPath, readFileSync(join(here, 'fixtures/editor-built-contract.json')));
  writeFileSync(keyPath, privateKey().export({ type: 'pkcs8', format: 'pem' }), { mode: 0o644 });

  const result = run(
    ['--contract', contractPath, '--base', BASE, '--signing-key', keyPath, '--link-output', linkPath],
    { STUB_EXIT: '1', TMPDIR: scratch },
  );

  assert.equal(result.status, 1);
  assert.equal(mode(keyPath), '600');
  assert.equal(existsSync(linkPath), false, 'no link for a contract that was not published');
  assert.equal(execFileSync('ls', ['-A', scratch], { encoding: 'utf8' }), '', 'upload file removed');
});

test('an unknown option is an error, so a typo cannot silently drop the link', () => {
  const result = spawnSync(process.execPath, [publishScript, '--link-ouput', 'x'], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /--link-ouput/);
});
