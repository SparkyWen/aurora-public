// Tests the Worker's request handling in pure Node (no wrangler, no network).
// Run `node --test` from control-plane/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { EgressLeaseStore } from '../src/worker.js';

function durableNamespace(initial = []) {
  const values = new Map(initial);
  let transactionTail = Promise.resolve();
  const storage = {
    async get(key) {
      await transactionTail;
      return values.has(key) ? values.get(key) : undefined;
    },
    async transaction(callback) {
      const previous = transactionTail;
      let release;
      transactionTail = new Promise((resolve) => { release = resolve; });
      await previous;
      try {
        return await callback({
          async get(key) { return values.has(key) ? values.get(key) : undefined; },
          async put(key, value) { values.set(key, value); },
        });
      } finally {
        release();
      }
    },
  };
  const object = new EgressLeaseStore({ storage }, {});
  const stub = { fetch: (request) => object.fetch(request) };
  return {
    idFromName(name) {
      assert.equal(name, 'primary');
      return 'primary-id';
    },
    get(id) {
      assert.equal(id, 'primary-id');
      return stub;
    },
  };
}

// In-memory KV stub standing in for env.AURORA_KV.get.
function makeEnv(overrides = {}) {
  const store = new Map(overrides.kv || []);
  return {
    AURORA_TOKEN: 'test-token-abc',
    AURORA_LEASE_WRITE_TOKEN: 'lease-write-test-token',
    DELIVERY_DOMAINS: JSON.stringify(['https://aurora-cp.example.workers.dev']),
    AURORA_KV: {
      async get(k) { return store.has(k) ? store.get(k) : null; },
      async put(k, value) { store.set(k, value); },
    },
    EGRESS_LEASE_STORE: durableNamespace(overrides.leaseStore || []),
    ...overrides.env,
  };
}

const call = (path, env, init = {}) =>
  worker.fetch(new Request('https://cp.example' + path, init), env);

const leaseSignature = Buffer.alloc(64, 11).toString('base64');

function lease(sequence = 10, overrides = {}) {
  const issuedAt = new Date(Date.now() - 60_000);
  const expiresAt = new Date(issuedAt.getTime() + 120 * 60_000);
  return {
    version: 1,
    key_id: 'home-egress-1',
    home_name: 'home.example.invalid',
    ipv4: '203.0.113.9',
    sequence,
    issued_at: issuedAt.toISOString(),
    expires_at: expiresAt.toISOString(),
    signature: leaseSignature,
    ...overrides,
  };
}

test('GET /health -> ok', async () => {
  const res = await call('/health', makeEnv());
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, 1);
});

test('GET /v2/get_domain returns the configured delivery domains', async () => {
  const res = await call('/v2/get_domain', makeEnv());
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body.domains, ['https://aurora-cp.example.workers.dev']);
});

test('GET /v2/contract without token -> 401', async () => {
  const res = await call('/v2/contract', makeEnv({ kv: [['contract', '{"version":1}']] }));
  assert.equal(res.status, 401);
});

test('GET /v2/contract with wrong token -> 401', async () => {
  const res = await call('/v2/contract?token=nope', makeEnv({ kv: [['contract', '{"version":1}']] }));
  assert.equal(res.status, 401);
});

test('GET /v2/contract with correct token (query) -> contract verbatim', async () => {
  const contract = '{"version":1,"nodes":[]}';
  const res = await call('/v2/contract?token=test-token-abc', makeEnv({ kv: [['contract', contract]] }));
  assert.equal(res.status, 200);
  assert.equal(await res.text(), contract);
  assert.match(res.headers.get('content-type'), /application\/json/);
});

test('GET /v2/contract with correct token (header) -> 200', async () => {
  const res = await call('/v2/contract', makeEnv({ kv: [['contract', '{"v":1}']] }), {
    headers: { 'x-aurora-token': 'test-token-abc' },
  });
  assert.equal(res.status, 200);
});

test('GET endpoints accept a previous read token during bounded rotation', async () => {
  const env = makeEnv({
    kv: [['contract', '{"v":1}']],
    leaseStore: [['lease', JSON.stringify(lease())]],
    env: { AURORA_TOKEN_PREVIOUS: 'previous-test-token' },
  });

  const contract = await call('/v2/contract', env, {
    headers: { 'x-aurora-token': 'previous-test-token' },
  });
  const egressLease = await call('/v2/egress-lease', env, {
    headers: { 'x-aurora-token': 'previous-test-token' },
  });

  assert.equal(contract.status, 200);
  assert.equal(egressLease.status, 200);
});

test('a previous read token stops working past AURORA_TOKEN_PREVIOUS_UNTIL', async () => {
  const expired = makeEnv({
    kv: [['contract', '{"v":1}']],
    env: {
      AURORA_TOKEN_PREVIOUS: 'previous-test-token',
      AURORA_TOKEN_PREVIOUS_UNTIL: '1000', // epoch ms in the distant past
    },
  });
  const res = await call('/v2/contract', expired, {
    headers: { 'x-aurora-token': 'previous-test-token' },
  });
  assert.equal(res.status, 401);

  // The primary token is unaffected by the previous-token expiry.
  const primary = await call('/v2/contract?token=test-token-abc', expired);
  assert.equal(primary.status, 200);
});

test('GET /v2/contract when nothing published -> 404', async () => {
  const res = await call('/v2/contract?token=test-token-abc', makeEnv());
  assert.equal(res.status, 404);
});

test('GET /v2/egress-lease requires the contract read token', async () => {
  const env = makeEnv({ leaseStore: [['lease', JSON.stringify(lease())]] });

  assert.equal((await call('/v2/egress-lease', env)).status, 401);
  assert.equal((await call('/v2/egress-lease?token=nope', env)).status, 401);
});

test('GET /v2/egress-lease returns 404 before first publication', async () => {
  const res = await call('/v2/egress-lease?token=test-token-abc', makeEnv());

  assert.equal(res.status, 404);
});

test('PUT /v2/egress-lease accepts only the separate write token', async () => {
  const env = makeEnv();
  const body = JSON.stringify(lease());

  const missing = await call('/v2/egress-lease', env, { method: 'PUT', body });
  const readToken = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-token': 'test-token-abc' },
    body,
  });

  assert.equal(missing.status, 401);
  assert.equal(readToken.status, 401);
});

test('valid PUT is stored verbatim and returned by authenticated GET', async () => {
  const env = makeEnv();
  const raw = JSON.stringify(lease(), null, 2);

  const put = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: raw,
  });
  const get = await call('/v2/egress-lease', env, {
    headers: { 'x-aurora-token': 'test-token-abc' },
  });

  assert.equal(put.status, 204);
  assert.equal(get.status, 200);
  assert.equal(await get.text(), raw);
  assert.match(get.headers.get('content-type'), /application\/json/);
});

test('PUT rejects equal or older sequences without replacing the current lease', async () => {
  const current = JSON.stringify(lease(10));
  const env = makeEnv({ leaseStore: [['lease', current]] });

  for (const sequence of [10, 9]) {
    const res = await call('/v2/egress-lease', env, {
      method: 'PUT',
      headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
      body: JSON.stringify(lease(sequence)),
    });
    assert.equal(res.status, 409);
  }
  const get = await call('/v2/egress-lease?token=test-token-abc', env);
  assert.equal(await get.text(), current);
});

test('PUT maps invalid and oversized bodies without echoing them', async () => {
  const env = makeEnv();
  const invalidMarker = 'do-not-echo-this-body';
  const invalid = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify(lease(10, { signature: invalidMarker })),
  });
  const oversized = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify({ padding: 'x'.repeat(5000) }),
  });

  assert.equal(invalid.status, 400);
  assert.doesNotMatch(await invalid.text(), new RegExp(invalidMarker));
  assert.equal(oversized.status, 413);
});

test('PUT treats a corrupt stored lease as server state failure', async () => {
  const env = makeEnv({ leaseStore: [['lease', 'corrupt-stored-lease']] });
  const res = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify(lease()),
  });

  assert.equal(res.status, 500);
  assert.doesNotMatch(await res.text(), /corrupt-stored-lease/);
});

test('lease endpoint fails closed when the Durable Object binding is absent', async () => {
  const env = makeEnv({ env: { EGRESS_LEASE_STORE: undefined } });
  const get = await call('/v2/egress-lease?token=test-token-abc', env);
  const put = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify(lease()),
  });

  assert.equal(get.status, 500);
  assert.equal(put.status, 500);
  assert.match(await get.text(), /lease_store_unbound/);
});

test('PUT maps Durable Object failure to a redacted server error', async () => {
  const internalMarker = 'private-provider-failure';
  const env = makeEnv({
    env: {
      EGRESS_LEASE_STORE: {
        idFromName() { return 'id'; },
        get() {
          return { async fetch() { throw new Error(internalMarker); } };
        },
      },
    },
  });
  const res = await call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify(lease()),
  });

  assert.equal(res.status, 500);
  assert.doesNotMatch(await res.text(), new RegExp(internalMarker));
});

test('concurrent duplicate publications accept exactly one sequence', async () => {
  const current = JSON.stringify(lease(10));
  const env = makeEnv({ leaseStore: [['lease', current]] });
  const publish = () => call('/v2/egress-lease', env, {
    method: 'PUT',
    headers: { 'x-aurora-lease-token': 'lease-write-test-token' },
    body: JSON.stringify(lease(11)),
  });

  const responses = await Promise.all([publish(), publish()]);

  assert.deepEqual(responses.map((response) => response.status).sort(), [204, 409]);
  const get = await call('/v2/egress-lease?token=test-token-abc', env);
  assert.equal(JSON.parse(await get.text()).sequence, 11);
});

test('OPTIONS advertises the lease PUT method', async () => {
  const res = await call('/v2/egress-lease', makeEnv(), { method: 'OPTIONS' });

  assert.equal(res.status, 204);
  assert.match(res.headers.get('access-control-allow-methods'), /PUT/);
});

test('POST is rejected', async () => {
  const res = await call('/health', makeEnv(), { method: 'POST' });
  assert.equal(res.status, 405);
});

test('unknown path -> 404', async () => {
  const res = await call('/nope', makeEnv());
  assert.equal(res.status, 404);
});
