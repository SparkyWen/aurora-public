// Aurora control plane: a Cloudflare Worker.
//
// Why it exists: a new install has to fetch its node list from somewhere that needs no
// tunnel, and mesh VPNs such as Tailscale are often blocked or throttled on the networks
// where Aurora matters most. A Worker is one bootstrap entry worth trying. Reachability
// differs by carrier and time of day and has to be measured, so clients also keep
// several entries and a last known good contract.
//
// Routes:
//   GET /v2/get_domain        -> { ok, domains: [...] } the delivery entries that are
//                                currently alive (the bootstrap layer that survives a
//                                blocked domain)
//   GET /v2/contract?token=   -> the contract JSON (token auth, stored in KV, never in git)
//   GET/PUT /v2/egress-lease  -> the signed home exit lease (separate read and write tokens)
//   GET /health               -> liveness probe
//
// Security: the real contract, with its node credentials, lives only in KV
// (key=`contract`), and the token is the env secret `AURORA_TOKEN`. No real key, IP or
// token appears in this repository. Publish with scripts/publish-contract.mjs.

import {
  leaseSequence,
  MAX_LEASE_BYTES,
  parseLeaseBody,
  validateLeaseEnvelope,
} from './egress-lease.js';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'access-control-allow-origin': '*',
};

function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extra },
  });
}

function tokenFrom(request, url) {
  const bearer = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  return (
    url.searchParams.get('token') ||
    request.headers.get('x-aurora-token') ||
    bearer ||
    ''
  );
}

// Constant-time comparison, to avoid a token timing side channel.
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// A previous token is accepted only as an explicit, temporary migration aid.
// Keeping the primary mandatory prevents a stale secret from becoming the sole
// credential if a deployment is only partially configured. An optional
// AURORA_TOKEN_PREVIOUS_UNTIL (epoch ms) forces the migration to actually end:
// once past it, the previous token stops being a valid credential so a
// forgotten secret can't silently defeat the rotation forever.
function validReadToken(token, env, now = Date.now()) {
  if (!env.AURORA_TOKEN) return false;
  if (safeEqual(token, env.AURORA_TOKEN)) return true;
  if (!env.AURORA_TOKEN_PREVIOUS) return false;
  const until = Number(env.AURORA_TOKEN_PREVIOUS_UNTIL);
  if (Number.isFinite(until) && now > until) return false;
  return safeEqual(token, env.AURORA_TOKEN_PREVIOUS);
}

class BodyTooLargeError extends Error {}

async function boundedBody(request, maximumBytes) {
  const declaredLength = Number(request.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new BodyTooLargeError('request body too large');
  }
  if (!request.body) return '';

  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumBytes) {
      await reader.cancel();
      throw new BodyTooLargeError('request body too large');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

function storedLeaseSequence(raw) {
  if (raw == null) return 0;
  return leaseSequence(parseLeaseBody(raw));
}

class LeaseReplayError extends Error {}
class LeaseStoreInvalidError extends Error {}
class LeaseInvalidError extends Error {}

// The lease is deliberately separate from KV. A single named Durable Object
// serializes compare-and-store transactions, so two concurrent publishers can
// never both win with the same or a rolled-back sequence.
export class EgressLeaseStore {
  constructor(ctx, _env) {
    this.ctx = ctx;
  }

  async fetch(request) {
    if (request.method === 'GET') {
      let lease;
      try {
        lease = await this.ctx.storage.get('lease');
      } catch (_) {
        return json({ ok: 0, error: 'lease_store_failed' }, 500);
      }
      if (lease == null) return json({ ok: 0, error: 'no_egress_lease' }, 404);
      if (typeof lease !== 'string') {
        return json({ ok: 0, error: 'lease_store_invalid' }, 500);
      }
      return new Response(lease, { status: 200, headers: { ...JSON_HEADERS } });
    }

    if (request.method !== 'PUT') {
      return json({ ok: 0, error: 'method_not_allowed' }, 405);
    }

    let raw;
    try {
      raw = await request.text();
      parseLeaseBody(raw);
    } catch (_) {
      return json({ ok: 0, error: 'invalid_lease' }, 400);
    }

    try {
      await this.ctx.storage.transaction(async (transaction) => {
        let previousSequence;
        try {
          previousSequence = storedLeaseSequence(await transaction.get('lease'));
        } catch (_) {
          throw new LeaseStoreInvalidError();
        }
        try {
          validateLeaseEnvelope(parseLeaseBody(raw), {
            now: new Date(),
            previousSequence,
            requireNewer: true,
          });
        } catch (error) {
          if (error instanceof Error &&
              (error.message === 'lease sequence must increase' ||
               error.message === 'lease sequence rolled back')) {
            throw new LeaseReplayError();
          }
          throw new LeaseInvalidError();
        }
        await transaction.put('lease', raw);
      });
    } catch (error) {
      if (error instanceof LeaseReplayError) {
        return json({ ok: 0, error: 'lease_replay' }, 409);
      }
      if (error instanceof LeaseStoreInvalidError) {
        return json({ ok: 0, error: 'lease_store_invalid' }, 500);
      }
      if (error instanceof LeaseInvalidError) {
        return json({ ok: 0, error: 'invalid_lease' }, 400);
      }
      return json({ ok: 0, error: 'lease_store_failed' }, 500);
    }
    return new Response(null, { status: 204 });
  }
}

function egressLeaseStub(env) {
  const namespace = env.EGRESS_LEASE_STORE;
  if (!namespace || typeof namespace.idFromName !== 'function' ||
      typeof namespace.get !== 'function') {
    return null;
  }
  return namespace.get(namespace.idFromName('primary'));
}

async function callEgressLeaseStore(env, method, raw) {
  const stub = egressLeaseStub(env);
  if (!stub || typeof stub.fetch !== 'function') {
    return json({ ok: 0, error: 'lease_store_unbound' }, 500);
  }
  try {
    return await stub.fetch(new Request('https://aurora.internal/lease', {
      method,
      ...(raw == null ? {} : { body: raw }),
    }));
  } catch (_) {
    return json({ ok: 0, error: 'lease_store_failed' }, 500);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-headers': '*',
          'access-control-allow-methods': 'GET,PUT,OPTIONS',
        },
      });
    }

    if (path === '/v2/egress-lease' && request.method === 'GET') {
      const token = tokenFrom(request, url);
      if (!validReadToken(token, env)) {
        return json({ ok: 0, error: 'unauthorized' }, 401);
      }
      return callEgressLeaseStore(env, 'GET');
    }

    if (path === '/v2/egress-lease' && request.method === 'PUT') {
      const token = request.headers.get('x-aurora-lease-token') || '';
      if (!env.AURORA_LEASE_WRITE_TOKEN ||
          !safeEqual(token, env.AURORA_LEASE_WRITE_TOKEN)) {
        return json({ ok: 0, error: 'unauthorized' }, 401);
      }
      let raw;
      try {
        raw = await boundedBody(request, MAX_LEASE_BYTES);
      } catch (error) {
        if (error instanceof BodyTooLargeError) {
          return json({ ok: 0, error: 'lease_too_large' }, 413);
        }
        return json({ ok: 0, error: 'invalid_lease' }, 400);
      }

      return callEgressLeaseStore(env, 'PUT', raw);
    }

    if (request.method !== 'GET') return json({ ok: 0, error: 'method_not_allowed' }, 405);

    if (path === '/' || path === '/health') {
      return json({ ok: 1, service: 'aurora-control-plane' });
    }

    // Bootstrap layer: clients ask which delivery entries are alive right now, so a
    // domain can be rotated without shipping a new app.
    if (path === '/v2/get_domain') {
      let domains = [];
      try {
        domains = JSON.parse(env.DELIVERY_DOMAINS || '[]');
      } catch (_) {
        domains = [];
      }
      return json({ ok: 1, domains });
    }

    // Contract delivery (token auth). The body in KV is already valid JSON, so it is
    // passed through verbatim.
    if (path === '/v2/contract') {
      const token = tokenFrom(request, url);
      if (!validReadToken(token, env)) {
        return json({ ok: 0, error: 'unauthorized' }, 401);
      }
      if (!env.AURORA_KV) return json({ ok: 0, error: 'kv_unbound' }, 500);
      const contract = await env.AURORA_KV.get('contract');
      if (!contract) return json({ ok: 0, error: 'no_contract_published' }, 404);
      return new Response(contract, { status: 200, headers: { ...JSON_HEADERS } });
    }

    return json({ ok: 0, error: 'not_found' }, 404);
  },
};
