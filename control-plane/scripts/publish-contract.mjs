#!/usr/bin/env node
// Publish an Aurora contract to your Cloudflare control plane.
//
// Run it from anywhere, after `npx wrangler login` or with CLOUDFLARE_API_TOKEN set:
//
//   node control-plane/scripts/publish-contract.mjs \
//     --contract secrets/contract.json \
//     --base https://aurora-cp.YOUR-SUBDOMAIN.workers.dev \
//     --output secrets/contract.json \
//     --link-output secrets/delivery-link.txt
//
// Starting from `aurora://` links rather than a contract? Expand them first, with the
// same code the app uses, so the logic exists in one place:
//
//   cd app && dart run tool/link_to_contract.dart ../secrets/contract.json '<aurora://...>'
//
// What it does:
//   1. Loads the Ed25519 signing key, or generates one on first run (0600).
//   2. Points delivery.primary at this control plane and pins the key in
//      delivery.signing, then signs the result.
//   3. Uploads the signed contract to KV (key=contract) and the read token to the
//      Worker secret AURORA_TOKEN.
//   4. Optionally writes the signed contract (--output) and an import link for your
//      devices (--link-output), both 0600. Paths are printed, the token never is.
//
// Point --output at the --contract file. The next run then keeps the same token and
// a rising revision. Without a token in the input a new one is generated, which locks
// out every device still using the old one.
//
// Nothing here writes a secret to git: the default key path is gitignored, and the
// temporary upload file lives in a private directory that is removed afterwards.
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import {
  buildDeliveryLink,
  buildPublishedContract,
  normalizeBaseUrl,
  resolveKeyId,
} from '../src/contract-publish.mjs';

const USAGE = `usage: node scripts/publish-contract.mjs --contract <file> --base <https://...>
  --contract <file>             Contract to publish. To start from aurora:// links, run
                                app/tool/link_to_contract.dart first.
  --base <url>                  Your Worker, e.g. https://aurora-cp.NAME.workers.dev
  --signing-key <pem>           Ed25519 key, generated if missing
                                (default: secrets/aurora-contract-signing.pem)
  --key-id <id>                 Key id (default: the contract's pinned id, or aurora-key-1)
  --output <file>               Also write the signed contract (0600)
  --link-output <file>          Write the delivery import link for your devices (0600)
  --name <label>                Name in the import link (default: aurora)
  --min-client-version <x.y.z>  Oldest app allowed to accept this contract`;

function die(message) {
  console.error(`error: ${message}`);
  process.exit(2);
}

function parseOptions() {
  try {
    return parseArgs({
      options: {
        contract: { type: 'string' },
        base: { type: 'string' },
        'signing-key': { type: 'string' },
        'key-id': { type: 'string' },
        output: { type: 'string' },
        'link-output': { type: 'string' },
        name: { type: 'string', default: 'aurora' },
        'min-client-version': { type: 'string', default: '0.1.3' },
      },
    }).values;
  } catch (error) {
    die(`${error.message}\n${USAGE}`);
  }
}

// A temporary file plus rename, so the mode holds even when the target already
// exists with looser permissions, and a crash cannot leave half a credential.
function writePrivateFile(path, content) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomBytes(4).toString('hex')}.tmp`;
  writeFileSync(temporary, content, { mode: 0o600, flag: 'wx' });
  renameSync(temporary, path);
}

function loadOrCreateSigningKey(path, pinned) {
  if (existsSync(path)) {
    if (process.platform !== 'win32' && (statSync(path).mode & 0o077) !== 0) {
      console.warn(`[!] ${path} was readable by others; tightening it to 0600`);
      chmodSync(path, 0o600);
    }
    return readFileSync(path, 'utf8');
  }
  // A fresh key cannot satisfy a pin, so generating one here would only leave an
  // unusable file behind and hide that the real key has gone missing.
  if (pinned) {
    die(
      `the contract pins signing key "${pinned.key_id}" but ${path} does not exist. ` +
        'Point --signing-key at the original key. If it is lost, remove delivery.signing ' +
        'from the input and re-import the new link on every device.',
    );
  }
  const { privateKey } = generateKeyPairSync('ed25519');
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  writePrivateFile(path, pem);
  console.log(`[*] Generated a new signing key: ${path} (0600)`);
  console.log('    Back it up offline. Without it, every device has to re-import a new link.');
  return pem;
}

const options = parseOptions();
if (!options.contract || !options.base) die(USAGE);

const scriptDir = dirname(fileURLToPath(import.meta.url));
const controlPlaneDir = dirname(scriptDir);
const signingKeyPath = resolve(
  options['signing-key'] ||
    process.env.AURORA_SIGNING_KEY_PATH ||
    join(controlPlaneDir, '../secrets/aurora-contract-signing.pem'),
);

let signedContract;
let token;
let publicKey;
let keyId;
let link;
let base;
try {
  base = normalizeBaseUrl(options.base);
  const input = JSON.parse(readFileSync(options.contract, 'utf8'));
  keyId = resolveKeyId(input, options['key-id']);
  const privateKey = loadOrCreateSigningKey(signingKeyPath, input?.delivery?.signing);
  if (!input?.delivery?.token) {
    console.warn(
      '[!] The input has no delivery.token, so a new read token will replace AURORA_TOKEN. ' +
        'Devices using an older token must re-import the link.',
    );
  }
  ({ contract: signedContract, token, publicKey } = buildPublishedContract(input, {
    base,
    privateKey,
    keyId,
    minClientVersion: options['min-client-version'],
  }));
  link = buildDeliveryLink({ name: options.name, base, token, keyId, publicKey });
} catch (error) {
  die(error.message);
}

const uploadDir = mkdtempSync(join(tmpdir(), 'aurora-publish-'));
const uploadPath = join(uploadDir, 'contract.json');
const wrangler = (args, execOptions = {}) =>
  execFileSync(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['wrangler', ...args], {
    cwd: controlPlaneDir,
    stdio: 'inherit',
    ...execOptions,
  });

try {
  writeFileSync(uploadPath, JSON.stringify(signedContract), { mode: 0o600 });
  console.log('[*] Uploading the contract to KV (key=contract) ...');
  wrangler(['kv', 'key', 'put', '--binding', 'AURORA_KV', 'contract', '--path', uploadPath, '--remote']);
  console.log('[*] Writing the Worker secret AURORA_TOKEN ...');
  wrangler(['secret', 'put', 'AURORA_TOKEN'], {
    input: token,
    stdio: ['pipe', 'inherit', 'inherit'],
  });
  if (options.output) {
    writePrivateFile(resolve(options.output), `${JSON.stringify(signedContract, null, 2)}\n`);
  }
  if (options['link-output']) {
    writePrivateFile(resolve(options['link-output']), `${link}\n`);
  }
  console.log('\n========================================================');
  console.log(' Published:');
  console.log(`   contract:    ${base}/v2/contract (token hidden)`);
  console.log(`   revision:    ${signedContract.revision}`);
  console.log(`   signing key: ${signingKeyPath} (${keyId})`);
  if (options.output) console.log(`   contract copy: ${resolve(options.output)} (0600)`);
  if (options['link-output']) {
    console.log(`   import link: ${resolve(options['link-output'])} (0600)`);
    console.log(' Add that link in the app. It holds the read token: treat it like a password.');
  } else {
    console.log(' Pass --link-output <file> to write the link your devices import.');
  }
  console.log(' DELIVERY_DOMAINS in wrangler.toml must list this Worker: redeploy if it changed.');
  console.log('========================================================');
} catch (error) {
  // Not die(): exiting here would skip the cleanup below, and the upload file holds
  // node credentials. Wrangler has already printed the details.
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
} finally {
  rmSync(uploadDir, { recursive: true, force: true });
}
