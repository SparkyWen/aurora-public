import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../data/canonical_json.dart';
import 'contract.dart';

class EgressLease {
  const EgressLease({
    required this.keyId,
    required this.homeName,
    required this.ipv4,
    required this.sequence,
    required this.issuedAt,
    required this.expiresAt,
    required this.signature,
  });

  final String keyId;
  final String homeName;
  final String ipv4;
  final int sequence;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String signature;

  bool isValidAt(DateTime clock) => expiresAt.isAfter(clock.toUtc());
}

abstract final class EgressLeaseVerifier {
  static const _maximumBytes = 4096;
  static const _maximumSequence = 9007199254740991;
  static const _maximumValidity = Duration(minutes: 125);
  static const _futureSkew = Duration(minutes: 5);
  static const _fields = {
    'version',
    'key_id',
    'home_name',
    'ipv4',
    'sequence',
    'issued_at',
    'expires_at',
    'signature',
  };

  static Future<EgressLease> verify(
    String raw, {
    required EgressPolicy policy,
    required int minimumSequence,
    DateTime? now,
  }) async {
    if (!policy.hasSignedLease) {
      throw const FormatException('lease_policy_missing');
    }
    if (raw.isEmpty || utf8.encode(raw).length > _maximumBytes) {
      throw const FormatException('lease_size_invalid');
    }
    Object? decoded;
    try {
      decoded = json.decode(raw);
    } catch (_) {
      throw const FormatException('lease_json_invalid');
    }
    if (decoded is! Map) {
      throw const FormatException('lease_fields_invalid');
    }
    final document = Map<String, dynamic>.from(decoded);
    if (document.keys.toSet().length != _fields.length ||
        !document.keys.toSet().containsAll(_fields)) {
      throw const FormatException('lease_fields_invalid');
    }
    if (document['version'] != 1 ||
        document['key_id'] is! String ||
        document['home_name'] is! String ||
        document['ipv4'] is! String ||
        document['sequence'] is! int ||
        document['issued_at'] is! String ||
        document['expires_at'] is! String ||
        document['signature'] is! String) {
      throw const FormatException('lease_fields_invalid');
    }
    if (document['key_id'] != policy.leaseKeyId) {
      throw const FormatException('lease_key_mismatch');
    }
    if (document['home_name'] != policy.homeName) {
      throw const FormatException('lease_home_mismatch');
    }
    final ipv4 = document['ipv4'] as String;
    if (!_isStrictIPv4(ipv4)) {
      throw const FormatException('lease_ipv4_invalid');
    }
    final sequence = document['sequence'] as int;
    if (sequence <= 0 ||
        sequence > _maximumSequence ||
        minimumSequence < 0 ||
        sequence < minimumSequence) {
      throw const FormatException('lease_sequence_rollback');
    }
    final issuedAt = _parseUTC(document['issued_at'] as String, 'issued');
    final expiresAt = _parseUTC(document['expires_at'] as String, 'expires');
    final validity = expiresAt.difference(issuedAt);
    if (validity <= Duration.zero || validity > _maximumValidity) {
      throw const FormatException('lease_validity_invalid');
    }
    final clock = (now ?? DateTime.now()).toUtc();
    if (issuedAt.isAfter(clock.add(_futureSkew))) {
      throw const FormatException('lease_future');
    }
    if (!expiresAt.isAfter(clock)) {
      throw const FormatException('lease_expired');
    }
    final signature = _decodeExact(
      document['signature'] as String,
      64,
      'lease_signature_invalid',
    );
    final publicKey = _decodeExact(
      policy.leasePublicKey!,
      32,
      'lease_public_key_invalid',
    );
    final unsigned = Map<String, dynamic>.from(document)..remove('signature');
    final verified = await Ed25519().verify(
      utf8.encode(CanonicalJson.encode(unsigned)),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) {
      throw const FormatException('lease_signature_invalid');
    }
    return EgressLease(
      keyId: document['key_id'] as String,
      homeName: document['home_name'] as String,
      ipv4: ipv4,
      sequence: sequence,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      signature: document['signature'] as String,
    );
  }

  static DateTime _parseUTC(String value, String field) {
    if (!value.endsWith('Z')) {
      throw FormatException('lease_${field}_at_invalid');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !parsed.isUtc) {
      throw FormatException('lease_${field}_at_invalid');
    }
    return parsed;
  }

  static List<int> _decodeExact(String value, int length, String category) {
    try {
      final bytes = base64.decode(value);
      if (bytes.length == length) return bytes;
    } catch (_) {
      // Return one stable redacted category below.
    }
    throw FormatException(category);
  }

  static bool _isStrictIPv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
        return false;
      }
      final number = int.tryParse(part);
      return number != null && number >= 0 && number <= 255;
    });
  }
}
