import { createPublicKey, sign } from 'node:crypto';

export const DEFAULT_CONTRACT_KEY_ID = 'aurora-key-1';

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, sorted(value[key])]),
    );
  }
  return value;
}

export function canonicalJson(value) {
  return JSON.stringify(sorted(value));
}

// The form the app pins in `delivery.signing.public_key`: the raw 32-byte
// Ed25519 key in standard base64, not the SPKI or PEM wrapper.
export function rawEd25519PublicKey(privateKey) {
  const publicKey = createPublicKey(privateKey);
  if (publicKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('the contract signing key must be Ed25519');
  }
  return Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
}

export function attachContractSignature(
  contract,
  privateKey,
  keyId = DEFAULT_CONTRACT_KEY_ID,
) {
  const unsigned = structuredClone(contract);
  delete unsigned.signature;
  const signature = sign(
    null,
    Buffer.from(canonicalJson(unsigned), 'utf8'),
    privateKey,
  );
  return {
    ...unsigned,
    signature: {
      algorithm: 'ed25519',
      key_id: keyId,
      value: signature.toString('base64'),
    },
  };
}
