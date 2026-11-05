import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/connection_lease_bootstrap.dart';
import 'package:aurora/core/contract.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final signedContract = AuroraContract.fromJson(
    jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  test('signed lease is prepared before the tunnel starts', () async {
    var calls = 0;

    await ConnectionLeaseBootstrap.prepare(
      signedContract,
      refresh: (policy, delivery) async {
        calls++;
        expect(policy.hasSignedLease, isTrue);
        expect(delivery.token, isNotEmpty);
      },
    );

    expect(calls, 1);
  });

  test('legacy contract does not require a lease bootstrap', () async {
    var called = false;
    final legacy = AuroraContract(
      version: 1,
      defaultMode: 'global',
      nodes: const [],
      outboundGroup: OutboundGroup(
        selectorTag: 'proxy',
        selectorMembers: const [],
        selectorDefault: 'auto',
        urltestTag: 'auto',
        urltestMembers: const [],
        urltestUrl: '',
        urltestInterval: '',
      ),
    );

    await ConnectionLeaseBootstrap.prepare(
      legacy,
      refresh: (_, _) async => called = true,
    );

    expect(called, isFalse);
  });

  test('bootstrap failure is redacted and prevents tunnel startup', () async {
    await expectLater(
      ConnectionLeaseBootstrap.prepare(
        signedContract,
        retryDelays: const [],
        refresh: (_, _) async => throw Exception('private endpoint detail'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'lease_bootstrap_failed',
        ),
      ),
    );
  });

  test(
    'transient refresh failures are retried before the tunnel starts',
    () async {
      var calls = 0;

      await ConnectionLeaseBootstrap.prepare(
        signedContract,
        retryDelays: const [Duration.zero, Duration.zero],
        refresh: (_, _) async {
          calls++;
          if (calls < 3) throw Exception('hotspot still waking');
        },
      );

      expect(calls, 3);
    },
  );

  test('bootstrap gives up after a bounded number of attempts', () async {
    var calls = 0;

    await expectLater(
      ConnectionLeaseBootstrap.prepare(
        signedContract,
        retryDelays: const [Duration.zero, Duration.zero],
        refresh: (_, _) async {
          calls++;
          throw Exception('still unreachable');
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(calls, 3);
  });

  test('an invalid lease policy aborts immediately without retries', () async {
    var calls = 0;

    await expectLater(
      ConnectionLeaseBootstrap.prepare(
        signedContract,
        refresh: (_, _) async {
          calls++;
          throw StateError('lease_policy_invalid');
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'lease_bootstrap_failed',
        ),
      ),
    );

    expect(calls, 1);
  });

  test(
    'authentication rejection is not retried or relabeled as network failure',
    () async {
      var calls = 0;
      await expectLater(
        ConnectionLeaseBootstrap.prepare(
          signedContract,
          retryDelays: const [Duration.zero, Duration.zero],
          refresh: (_, _) async {
            calls++;
            throw StateError('lease_auth_failed');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'lease_auth_failed',
          ),
        ),
      );
      expect(calls, 1);
    },
  );

  test('default schedule keeps probing across the hotspot wake window', () {
    fakeAsync((async) {
      final callTimes = <Duration>[];
      Object? failure;

      ConnectionLeaseBootstrap.prepare(
        signedContract,
        refresh: (_, _) async {
          callTimes.add(async.elapsed);
          throw Exception('link not up yet');
        },
      ).catchError((Object error) {
        failure = error;
      });
      async.elapse(const Duration(seconds: 30));

      expect(callTimes, const [
        Duration.zero,
        Duration(seconds: 2),
        Duration(seconds: 6),
        Duration(seconds: 12),
      ]);
      expect(failure, isA<StateError>());
    });
  });
}
