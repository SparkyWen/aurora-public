import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/contract.dart';
import 'package:aurora/data/egress_lease_repository.dart';
import 'package:aurora/data/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String rawLease;
  late EgressPolicy policy;
  final now = DateTime.utc(2026, 7, 22, 1);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture =
        json.decode(
              File(
                'test/fixtures/go-signed-egress-lease.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    rawLease = json.encode(fixture['lease']);
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

  test(
    'fetches with the existing read token and persists verified LKG',
    () async {
      http.Request? seen;
      final repository = EgressLeaseRepository(
        client: MockClient((request) async {
          seen = request;
          return http.Response(rawLease, 200);
        }),
        now: () => now,
      );
      final emitted = expectLater(repository.leases, emits(isA<dynamic>()));
      final lease = await repository.refresh(
        policy,
        const DeliveryInfo(token: 'read-secret'),
      );
      expect(lease.sequence, 10);
      expect(
        seen!.url.toString(),
        'https://control.example.net/v2/egress-lease',
      );
      expect(seen!.headers['x-aurora-token'], 'read-secret');
      expect(await SecureStore.loadEgressLease(), rawLease);
      await emitted;
      await repository.close();
    },
  );

  test('uses valid encrypted LKG on network failure', () async {
    await SecureStore.saveEgressLease(rawLease);
    final repository = EgressLeaseRepository(
      client: MockClient((_) async => throw http.ClientException('offline')),
      now: () => now,
    );
    final lease = await repository.refresh(
      policy,
      const DeliveryInfo(token: 'read-secret'),
    );
    expect(lease.sequence, 10);
    await repository.close();
  });

  test(
    'invalid response returns and preserves the still-valid verified LKG',
    () async {
      await SecureStore.saveEgressLease(rawLease);
      final invalid = json.decode(rawLease) as Map<String, dynamic>
        ..['ipv4'] = '8.8.8.8';
      final repository = EgressLeaseRepository(
        client: MockClient(
          (_) async => http.Response(json.encode(invalid), 200),
        ),
        now: () => now,
      );
      final lease = await repository.refresh(
        policy,
        const DeliveryInfo(token: 'read-secret'),
      );
      expect(lease.sequence, 10);
      expect(lease.ipv4, '203.0.113.9');
      expect(await SecureStore.loadEgressLease(), rawLease);
      await repository.close();
    },
  );

  test('invalid response fails redacted when no valid LKG exists', () async {
    final invalid = json.decode(rawLease) as Map<String, dynamic>
      ..['ipv4'] = '8.8.8.8';
    final repository = EgressLeaseRepository(
      client: MockClient((_) async => http.Response(json.encode(invalid), 200)),
      now: () => now,
    );

    await expectLater(
      repository.refresh(policy, const DeliveryInfo(token: 'read-secret')),
      throwsA(
        predicate(
          (error) =>
              error.toString() == 'Bad state: lease_refresh_failed' &&
              !error.toString().contains('8.8.8.8'),
        ),
      ),
    );
    expect(await SecureStore.loadEgressLease(), isNull);
    await repository.close();
  });

  for (final failure in ['network', 'http', 'signature']) {
    test(
      'does not return a cached lease that expires during $failure wait',
      () async {
        await SecureStore.saveEgressLease(rawLease);
        var clock = DateTime.utc(2026, 7, 22, 1, 59, 59);
        final repository = EgressLeaseRepository(
          client: MockClient((_) async {
            clock = DateTime.utc(2026, 7, 22, 2);
            if (failure == 'network') throw http.ClientException('offline');
            return http.Response(
              failure == 'signature' ? rawLease : '',
              failure == 'http' ? 503 : 200,
            );
          }),
          now: () => clock,
        );
        addTearDown(repository.close);
        await expectLater(
          repository.refresh(policy, const DeliveryInfo(token: 'test')),
          throwsA(isA<StateError>()),
        );
        expect(await SecureStore.loadEgressLease(), rawLease);
      },
    );
  }

  test(
    'authorization failure is distinct from network failure without credentials',
    () async {
      final repository = EgressLeaseRepository(
        client: MockClient((_) async => http.Response('private details', 401)),
        now: () => now,
      );
      addTearDown(repository.close);
      await expectLater(
        repository.refresh(policy, const DeliveryInfo(token: 'read-secret')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'lease_auth_failed',
          ),
        ),
      );
    },
  );

  test(
    'lease expiry during secure-store write cannot publish a valid result',
    () async {
      var clock = now;
      final values = _ExpiringStorageValues(
        () => clock = DateTime.utc(2026, 7, 22, 2),
      );
      FlutterSecureStorage.setMockInitialValues(values);
      final repository = EgressLeaseRepository(
        client: MockClient((_) async => http.Response(rawLease, 200)),
        now: () => clock,
      );
      final emitted = <Object>[];
      final subscription = repository.leases.listen(emitted.add);
      addTearDown(() async {
        await subscription.cancel();
        await repository.close();
      });
      await expectLater(
        repository.refresh(policy, const DeliveryInfo(token: 'test')),
        throwsA(isA<StateError>()),
      );
      expect(emitted, isEmpty);
    },
  );

  test('rejects non-HTTPS lease endpoint before network access', () async {
    var called = false;
    final repository = EgressLeaseRepository(
      client: MockClient((_) async {
        called = true;
        return http.Response(rawLease, 200);
      }),
      now: () => now,
    );
    await expectLater(
      repository.refresh(
        policy.copyWith(
          leaseUrl: Uri.parse('http://control.example.net/v2/egress-lease'),
        ),
        const DeliveryInfo(token: 'read-secret'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(called, isFalse);
    await repository.close();
  });
}

// Model the keychain write finishing only after the validity window elapsed.
class _ExpiringStorageValues extends MapBase<String, String> {
  _ExpiringStorageValues(this.onWrite);
  final void Function() onWrite;
  final _values = <String, String>{};
  @override
  String? operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, String value) {
    _values[key] = value;
    onWrite();
  }

  @override
  Iterable<String> get keys => _values.keys;
  @override
  void clear() => _values.clear();
  @override
  String? remove(Object? key) => _values.remove(key);
}
