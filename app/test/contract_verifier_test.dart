import 'dart:convert';

import 'package:aurora/data/contract_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Ed25519 algorithm;
  late SimpleKeyPair keyPair;
  late String publicKey;

  setUp(() async {
    algorithm = Ed25519();
    keyPair = await algorithm.newKeyPair();
    publicKey = base64.encode((await keyPair.extractPublicKey()).bytes);
  });

  Future<String> signedContract({
    DateTime? issuedAt,
    DateTime? expiresAt,
    String minimumVersion = '0.1.0',
  }) async {
    final now = DateTime.utc(2026, 7, 19, 12);
    final contract = <String, dynamic>{
      'version': 1,
      'revision': 42,
      'issued_at': (issuedAt ?? now.subtract(const Duration(minutes: 1)))
          .toIso8601String(),
      'expires_at': (expiresAt ?? now.add(const Duration(days: 7)))
          .toIso8601String(),
      'min_client_version': minimumVersion,
      'profile': {'default_mode': 'global', 'name': '\u6d4b\u8bd5'}, // non-ASCII profile name (CJK)
      'nodes': [
        {
          'id': 'ss',
          'protocol': 'shadowsocks-2022',
          'server': '203.0.113.1',
          'port': 8443,
          'params': {
            'method': '2022-blake3-aes-128-gcm',
            'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
          },
        },
      ],
      'outbound_group': {
        'selector': {
          'tag': 'proxy',
          'members': ['auto', 'ss'],
          'default': 'auto',
        },
        'urltest': {
          'tag': 'auto',
          'members': ['ss'],
        },
      },
    };
    final signature = await algorithm.sign(
      utf8.encode(ContractVerifier.canonicalJson(contract)),
      keyPair: keyPair,
    );
    contract['signature'] = {
      'algorithm': 'ed25519',
      'key_id': 'aurora-key-1',
      'value': base64.encode(signature.bytes),
    };
    return json.encode(contract);
  }

  test('accepts a valid Ed25519 contract', () async {
    await ContractVerifier.verifyRemote(
      await signedContract(),
      clientVersion: '0.1.3',
      now: DateTime.utc(2026, 7, 19, 12),
      publicKey: publicKey,
    );
  });

  test('rejects payload tampering', () async {
    final body = json.decode(await signedContract()) as Map<String, dynamic>;
    body['revision'] = 43;
    await expectLater(
      ContractVerifier.verifyRemote(
        json.encode(body),
        clientVersion: '0.1.3',
        now: DateTime.utc(2026, 7, 19, 12),
        publicKey: publicKey,
      ),
      throwsFormatException,
    );
  });

  test('rejects unsigned and expired contracts', () async {
    final unsigned = json.decode(await signedContract()) as Map<String, dynamic>
      ..remove('signature');
    await expectLater(
      ContractVerifier.verifyRemote(
        json.encode(unsigned),
        clientVersion: '0.1.3',
        now: DateTime.utc(2026, 7, 19, 12),
        publicKey: publicKey,
      ),
      throwsFormatException,
    );
    await expectLater(
      ContractVerifier.verifyRemote(
        await signedContract(
          issuedAt: DateTime.utc(2026, 7, 1),
          expiresAt: DateTime.utc(2026, 7, 18),
        ),
        clientVersion: '0.1.3',
        now: DateTime.utc(2026, 7, 19, 12),
        publicKey: publicKey,
      ),
      throwsFormatException,
    );
  });

  test('rejects future and incompatible contracts', () async {
    await expectLater(
      ContractVerifier.verifyRemote(
        await signedContract(issuedAt: DateTime.utc(2026, 7, 20)),
        clientVersion: '0.1.3',
        now: DateTime.utc(2026, 7, 19, 12),
        publicKey: publicKey,
      ),
      throwsFormatException,
    );
    await expectLater(
      ContractVerifier.verifyRemote(
        await signedContract(minimumVersion: '0.2.0'),
        clientVersion: '0.1.3',
        now: DateTime.utc(2026, 7, 19, 12),
        publicKey: publicKey,
      ),
      throwsFormatException,
    );
  });

  test('canonical JSON recursively sorts keys without changing arrays', () {
    expect(
      ContractVerifier.canonicalJson({
        'z': 1,
        'a': {
          'd': 2,
          'b': ['\u540e', '\u5148'], // non-ASCII data: must survive canonical JSON/signing
        },
      }),
      '{"a":{"b":["\u540e","\u5148"],"d":2},"z":1}',
    );
  });
}
