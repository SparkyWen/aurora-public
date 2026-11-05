import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/contract.dart';
import 'package:aurora/core/egress_lease.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> fixture;
  late EgressPolicy policy;
  final now = DateTime.utc(2026, 7, 22, 1);

  setUp(() {
    fixture =
        json.decode(
              File(
                'test/fixtures/go-signed-egress-lease.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    policy = EgressPolicy(
      expectedIpv4: '203.0.113.9',
      expectedCountry: 'US',
      expectedAsn: 'AS64496',
      leaseUrl: Uri.parse('https://control.example.net/v2/egress-lease'),
      leaseKeyId: 'home-egress-1',
      leasePublicKey: fixture['public_key'] as String,
      homeName: 'home.example.invalid',
    );
  });

  test('verifies a Go-signed lease with canonical JSON parity', () async {
    final value = await EgressLeaseVerifier.verify(
      json.encode(fixture['lease']),
      policy: policy,
      minimumSequence: 9,
      now: now,
    );
    expect(value.sequence, 10);
    expect(value.ipv4, '203.0.113.9');
    expect(value.isValidAt(now), isTrue);
  });

  test(
    'rejects signature, identity, time, address, and replay failures',
    () async {
      Future<void> rejects(
        String category,
        void Function(Map<String, dynamic>) mutate, {
        EgressPolicy? overridePolicy,
        int minimum = 9,
        DateTime? clock,
      }) async {
        final body = Map<String, dynamic>.from(fixture['lease'] as Map);
        mutate(body);
        await expectLater(
          EgressLeaseVerifier.verify(
            json.encode(body),
            policy: overridePolicy ?? policy,
            minimumSequence: minimum,
            now: clock ?? now,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'category',
              category,
            ),
          ),
        );
      }

      await rejects('lease_signature_invalid', (body) {
        body['signature'] =
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==';
      });
      await rejects(
        'lease_key_mismatch',
        (_) {},
        overridePolicy: policy.copyWith(leaseKeyId: 'other-key'),
      );
      await rejects(
        'lease_home_mismatch',
        (_) {},
        overridePolicy: policy.copyWith(homeName: 'other.example.invalid'),
      );
      await rejects(
        'lease_expired',
        (_) {},
        clock: now.add(const Duration(hours: 2)),
      );
      await rejects('lease_future', (body) {
        body['issued_at'] = '2026-07-22T01:06:00Z';
      });
      await rejects('lease_validity_invalid', (body) {
        body['expires_at'] = '2026-07-22T02:06:00Z';
      });
      await rejects('lease_ipv4_invalid', (body) {
        body['ipv4'] = '01.2.3.4';
      });
      await rejects('lease_sequence_rollback', (_) {}, minimum: 11);
      await rejects('lease_fields_invalid', (body) {
        body['unknown'] = true;
      });
    },
  );

  test('errors never include raw IP or signature', () async {
    final raw = json.encode(fixture['lease']);
    try {
      await EgressLeaseVerifier.verify(
        raw,
        policy: policy.copyWith(leaseKeyId: 'wrong'),
        minimumSequence: 0,
        now: now,
      );
      fail('verification unexpectedly succeeded');
    } catch (error) {
      expect(error.toString(), isNot(contains('203.0.113.9')));
      expect(
        error.toString(),
        isNot(contains((fixture['lease'] as Map)['signature'])),
      );
    }
  });
}
