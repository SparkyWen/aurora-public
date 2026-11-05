export const MAX_LEASE_BYTES = 4096;
export const MAX_VALIDITY_MS = 125 * 60 * 1000;
export const MAX_FUTURE_SKEW_MS = 5 * 60 * 1000;

const LEASE_FIELDS = Object.freeze([
  'expires_at',
  'home_name',
  'ipv4',
  'issued_at',
  'key_id',
  'sequence',
  'signature',
  'version',
]);

const RFC3339_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;
const KEY_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const HOST_LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export function parseLeaseBody(text) {
  if (typeof text !== 'string') throw new Error('lease body must be text');
  if (new TextEncoder().encode(text).byteLength > MAX_LEASE_BYTES) {
    throw new Error('lease body too large');
  }
  const value = JSON.parse(text);
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new Error('lease must be an object');
  }
  return value;
}

export function validateLeaseEnvelope(
  lease,
  { now = new Date(), previousSequence = 0, requireNewer = false } = {},
) {
  if (!lease || Array.isArray(lease) || typeof lease !== 'object') {
    throw new Error('lease must be an object');
  }
  const fields = Object.keys(lease).sort();
  if (fields.length !== LEASE_FIELDS.length ||
      fields.some((field, index) => field !== LEASE_FIELDS[index])) {
    throw new Error('lease fields are invalid');
  }
  if (lease.version !== 1) throw new Error('lease version is unsupported');
  if (typeof lease.key_id !== 'string' || !KEY_ID.test(lease.key_id)) {
    throw new Error('lease key_id is invalid');
  }
  if (!validHomeName(lease.home_name)) {
    throw new Error('lease home_name is invalid');
  }
  if (!validIpv4(lease.ipv4)) throw new Error('lease ipv4 is invalid');
  if (!Number.isSafeInteger(lease.sequence) || lease.sequence <= 0) {
    throw new Error('lease sequence is invalid');
  }
  if (!Number.isSafeInteger(previousSequence) || previousSequence < 0) {
    throw new Error('previous lease sequence is invalid');
  }
  if (requireNewer && lease.sequence <= previousSequence) {
    throw new Error('lease sequence must increase');
  }
  if (!requireNewer && lease.sequence < previousSequence) {
    throw new Error('lease sequence rolled back');
  }
  if (!validSignature(lease.signature)) {
    throw new Error('lease signature is invalid');
  }

  const issuedAt = parseUtcTime(lease.issued_at, 'issued_at');
  const expiresAt = parseUtcTime(lease.expires_at, 'expires_at');
  const nowMs = validDate(now, 'now').getTime();
  // The home agent derives `sequence` from UnixMilli, so a legitimate sequence
  // is always within minutes of now. Reject one implausibly far in the future:
  // a write-token holder could otherwise PUT sequence≈MAX_SAFE_INTEGER and every
  // future millisecond-timestamped PUT would fail requireNewer forever (the
  // clock can't catch up for millennia), silently killing the home path once the
  // last lease expires. The 125-min headroom stays far below any wedge value.
  if (lease.sequence > nowMs + MAX_VALIDITY_MS) {
    throw new Error('lease sequence is implausibly far ahead');
  }
  const validityMs = expiresAt.getTime() - issuedAt.getTime();
  if (validityMs <= 0 || validityMs > MAX_VALIDITY_MS) {
    throw new Error('lease validity window is invalid');
  }
  if (issuedAt.getTime() > nowMs + MAX_FUTURE_SKEW_MS) {
    throw new Error('lease issued_at is too far in the future');
  }
  if (expiresAt.getTime() <= nowMs) throw new Error('lease is expired');

  return { ...lease };
}

export function leaseSequence(lease) {
  if (!lease || !Number.isSafeInteger(lease.sequence) || lease.sequence <= 0) {
    throw new Error('lease sequence is invalid');
  }
  return lease.sequence;
}

function validHomeName(value) {
  if (typeof value !== 'string' || value.length > 253 || value !== value.toLowerCase()) {
    return false;
  }
  const labels = value.split('.');
  return labels.length >= 2 && labels.every((label) => HOST_LABEL.test(label));
}

function validIpv4(value) {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  if (parts.length !== 4) return false;
  return parts.every((part) => {
    if (!/^(?:0|[1-9]\d{0,2})$/.test(part)) return false;
    const number = Number(part);
    return number >= 0 && number <= 255;
  });
}

function validSignature(value) {
  if (typeof value !== 'string' ||
      !/^(?:[A-Za-z0-9+/]{4}){21}[A-Za-z0-9+/]{2}==$/.test(value)) {
    return false;
  }
  try {
    return atob(value).length === 64;
  } catch (_) {
    return false;
  }
}

function parseUtcTime(value, field) {
  if (typeof value !== 'string' || !RFC3339_UTC.test(value)) {
    throw new Error(`lease ${field} is invalid`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error(`lease ${field} is invalid`);
  }
  return parsed;
}

function validDate(value, field) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    throw new Error(`lease ${field} is invalid`);
  }
  return value;
}
