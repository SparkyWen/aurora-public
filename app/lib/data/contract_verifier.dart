import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'canonical_json.dart';

/// Verifies control-plane contracts independently of HTTPS.
///
/// Explicit local imports are the user's own trust root. Every remotely fetched
/// contract must pass this verifier before it can become a last-known-good
/// contract, against the key pinned by the contract the user already trusts
/// ([DeliveryInfo.signingPublicKey]). No key is compiled into the app.
class ContractVerifier {
  static Future<void> verifyRemote(
    String contractJson, {
    required String clientVersion,
    required String publicKey,
    String? keyId,
    DateTime? now,
  }) async {
    final decoded = json.decode(contractJson);
    if (decoded is! Map) {
      throw const FormatException('contract is not an object');
    }
    final contract = Map<String, dynamic>.from(decoded);
    final signatureValue = contract.remove('signature');
    if (signatureValue is! Map) {
      throw const FormatException('remote contract is unsigned');
    }
    final signature = Map<String, dynamic>.from(signatureValue);
    if (signature['algorithm'] != 'ed25519' ||
        (keyId != null && signature['key_id'] != keyId)) {
      throw const FormatException('unsupported contract signing key');
    }

    final revision = (contract['revision'] as num?)?.toInt() ?? 0;
    if (revision <= 0) {
      throw const FormatException('remote contract has no revision');
    }
    final issuedAt = DateTime.tryParse(contract['issued_at'] as String? ?? '');
    final expiresAt = DateTime.tryParse(
      contract['expires_at'] as String? ?? '',
    );
    if (issuedAt == null || expiresAt == null || !expiresAt.isAfter(issuedAt)) {
      throw const FormatException('remote contract validity window is invalid');
    }
    final clock = (now ?? DateTime.now()).toUtc();
    if (issuedAt.toUtc().isAfter(clock.add(const Duration(minutes: 5)))) {
      throw const FormatException('remote contract is not valid yet');
    }
    if (!expiresAt.toUtc().isAfter(clock)) {
      throw const FormatException('remote contract has expired');
    }
    final minimum = contract['min_client_version'] as String? ?? '0.0.0';
    if (_compareVersions(clientVersion, minimum) < 0) {
      throw FormatException(
        'remote contract requires Aurora $minimum (installed $clientVersion)',
      );
    }

    final signatureBytes = _decodeExact(
      signature['value'] as String? ?? '',
      64,
      'signature',
    );
    final publicKeyBytes = _decodeExact(publicKey, 32, 'public key');
    final valid = await Ed25519().verify(
      utf8.encode(canonicalJson(contract)),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException('remote contract signature is invalid');
    }
  }

  /// RFC-8785-like canonical form for Aurora's integer/string/list/object
  /// contract subset. The Node publisher uses the identical recursive key sort.
  static String canonicalJson(Object? value) => CanonicalJson.encode(value);

  static List<int> _decodeExact(String value, int length, String label) {
    try {
      final bytes = base64.decode(value);
      if (bytes.length == length) return bytes;
    } catch (_) {
      // Fall through to one consistent error.
    }
    throw FormatException('invalid Ed25519 $label');
  }

  static int _compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var i = 0; i < 3; i++) {
      final compared = a[i].compareTo(b[i]);
      if (compared != 0) return compared;
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final core = value.split(RegExp(r'[+-]')).first;
    final parts = core.split('.');
    return List.generate(
      3,
      (index) => index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0,
    );
  }
}
