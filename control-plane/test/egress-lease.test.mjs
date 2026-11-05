import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  MAX_LEASE_BYTES,
  leaseSequence,
  parseLeaseBody,
  validateLeaseEnvelope,
} from '../src/egress-lease.js';

const signature = Buffer.alloc(64, 7).toString('base64');
const now = new Date('2026-07-22T00:30:00Z');

function lease(overrides = {}) {
  return {
    version: 1,
    key_id: 'home-egress-1',
    home_name: 'home.example.invalid',
    ipv4: '203.0.113.9',
    sequence: 10,
    issued_at: '2026-07-22T00:00:00Z',
    expires_at: '2026-07-22T02:00:00Z',
    signature,
    ...overrides,
  };
}

const options = {
  now,
  previousSequence: 9,
  requireNewer: true,
};

test('parses a bounded JSON object without changing its values', () => {
  const raw = JSON.stringify(lease());

  assert.deepEqual(parseLeaseBody(raw), lease());
});

test('rejects a non-object or oversized lease body', () => {
  assert.throws(() => parseLeaseBody('[]'), /object/);
  assert.throws(
    () => parseLeaseBody(JSON.stringify({ padding: 'x'.repeat(MAX_LEASE_BYTES) })),
    /too large/,
  );
});

test('accepts a bounded signed lease with a newer sequence', () => {
  const validated = validateLeaseEnvelope(lease(), options);

  assert.equal(validated.sequence, 10);
  assert.equal(validated.ipv4, '203.0.113.9');
  assert.equal(leaseSequence(validated), 10);
});

test('rejects a sequence implausibly far ahead of now (wedge guard)', () => {
  const wedge = lease({ sequence: Number.MAX_SAFE_INTEGER });
  assert.throws(
    () => validateLeaseEnvelope(wedge, { ...options, previousSequence: 9 }),
    /implausibly far ahead/,
  );
  // A millisecond-timestamp sequence at "now" is still accepted.
  const live = lease({ sequence: now.getTime() });
  assert.equal(
    validateLeaseEnvelope(live, { ...options, previousSequence: 9 }).sequence,
    now.getTime(),
  );
});

test('rejects missing and unknown envelope fields', () => {
  const missing = lease();
  delete missing.home_name;

  assert.throws(() => validateLeaseEnvelope(missing, options), /fields/);
  assert.throws(
    () => validateLeaseEnvelope(lease({ unexpected: true }), options),
    /fields/,
  );
});

test('rejects unsupported versions, key ids, and home names', () => {
  assert.throws(
    () => validateLeaseEnvelope(lease({ version: 2 }), options),
    /version/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ key_id: '../key' }), options),
    /key_id/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ home_name: 'not a host' }), options),
    /home_name/,
  );
});

test('rejects malformed IPv4 including shorthand and leading zero forms', () => {
  for (const ipv4 of ['999.1.1.1', '127.1', '01.2.3.4', '2001:db8::1']) {
    assert.throws(
      () => validateLeaseEnvelope(lease({ ipv4 }), options),
      /ipv4/,
    );
  }
});

test('rejects non-base64 and non-64-byte signatures', () => {
  assert.throws(
    () => validateLeaseEnvelope(lease({ signature: 'bad' }), options),
    /signature/,
  );
  assert.throws(
    () => validateLeaseEnvelope(
      lease({ signature: Buffer.alloc(63).toString('base64') }),
      options,
    ),
    /signature/,
  );
});

test('rejects expired, future, reversed, and oversized validity windows', () => {
  assert.throws(
    () => validateLeaseEnvelope(lease({ expires_at: '2026-07-22T00:30:00Z' }), options),
    /expired/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ issued_at: '2026-07-22T00:36:00Z' }), options),
    /future/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ expires_at: '2026-07-21T23:59:59Z' }), options),
    /validity/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ expires_at: '2026-07-22T02:05:01Z' }), options),
    /validity/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ issued_at: '22 July 2026' }), options),
    /issued_at/,
  );
});

test('rejects replay and non-safe sequence numbers', () => {
  assert.throws(
    () => validateLeaseEnvelope(lease({ sequence: 9 }), options),
    /sequence/,
  );
  assert.throws(
    () => validateLeaseEnvelope(lease({ sequence: Number.MAX_SAFE_INTEGER + 1 }), options),
    /sequence/,
  );
});

test('allows the current sequence for read-time validation', () => {
  const validated = validateLeaseEnvelope(lease({ sequence: 9 }), {
    ...options,
    requireNewer: false,
  });

  assert.equal(validated.sequence, 9);
});
