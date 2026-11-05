import 'dart:convert';
import 'dart:io';

import 'package:aurora/data/contract_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cross-language signing interop guard.
///
/// `test/fixtures/node-signed-contract.json` was produced by the real Node
/// publisher path (`control-plane/src/contract-signing.mjs`
/// `attachContractSignature`) over a realistic contract (large-integer
/// `revision`, nested arrays/objects, unsorted keys). If the Dart and Node
/// canonical-JSON forms ever diverge (number formatting, key ordering, escaping),
/// this test fails — which is exactly the silent failure we must catch, because
/// a mismatch would make every remotely fetched contract fail verification and
/// leave clients pinned to the embedded LKG forever.
///
/// Only the TEST public key is committed (below); the throwaway private key that
/// signed the fixture is not in the repo.
void main() {
  // Raw 32-byte Ed25519 public key (base64) of the throwaway key that signed
  // the fixture. Test-only — unrelated to the production signing key.
  const testPublicKey = 'kNwTfTFY4EVpz/Ci5dwPe9+3KtnLAS7hZqNbqBTra0g=';

  // The fixture's validity window is 2026-07-19 .. 2026-08-18; pin a clock
  // inside it so the test is deterministic and never expires.
  final clock = DateTime.parse('2026-07-20T00:00:00Z');

  String fixture() =>
      File('test/fixtures/node-signed-contract.json').readAsStringSync();

  test('Dart verifies a Node-signed contract (canonical JSON parity)', () async {
    await ContractVerifier.verifyRemote(
      fixture(),
      clientVersion: '9.9.9',
      now: clock,
      publicKey: testPublicKey,
    );
    // Reaching here without throwing == cross-language interop holds.
  });

  test('a tampered node port breaks the signature', () async {
    final tampered = fixture().replaceFirst('"port":443', '"port":444');
    expect(tampered == fixture(), isFalse);
    await expectLater(
      ContractVerifier.verifyRemote(
        tampered,
        clientVersion: '9.9.9',
        now: clock,
        publicKey: testPublicKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('the wrong public key is rejected', () async {
    // Flip the last byte of the key — a valid base64 32-byte key that did not
    // sign this contract.
    final bytes = base64.decode(testPublicKey);
    bytes[31] ^= 0x01;
    await expectLater(
      ContractVerifier.verifyRemote(
        fixture(),
        clientVersion: '9.9.9',
        now: clock,
        publicKey: base64.encode(bytes),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
