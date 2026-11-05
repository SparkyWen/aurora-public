import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/path_health_coordinator.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/egress_lease.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/data/connection_probe.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeBridge bridge;
  late AuroraContract contract;
  late DateTime now;
  late List<(String, String)> probes;
  late int leaseRefreshes;

  setUp(() {
    bridge = FakeBridge();
    contract = AuroraContract.fromJson(
      jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    now = DateTime.utc(2026, 7, 22);
    probes = [];
    leaseRefreshes = 0;
  });

  PathHealthCoordinator coordinator({
    PathEgressProbe? probe,
    Duration healthInterval = Duration.zero,
    Duration fastRetestDelay = Duration.zero,
  }) => PathHealthCoordinator(
    bridge: bridge,
    now: () => now,
    probe:
        probe ??
        (group, policy) async {
          probes.add((group, policy.expectedIpv4));
          return verified;
        },
    refreshLease: (_, _) async {
      leaseRefreshes++;
      return lease;
    },
    healthInterval: healthInterval,
    fastRetestDelay: fastRetestDelay,
    startupGracePeriod: Duration.zero,
  );

  test(
    'requests all three path urltests and refreshes the signed lease',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);

      expect(bridge.urlTests, [
        'relay-public-auto',
        'relay-tailnet-auto',
        'home-auto',
      ]);
      expect(leaseRefreshes, 1);
      expect(probes, [('relay-public-auto', lease.ipv4)]);
      await health.dispose();
    },
  );

  test('uses selected member delay and temporal six-round p50/p95', () async {
    final health = coordinator();
    await health.start(contract, PathPreference.auto);
    for (final delay in [900, 100, 300, 500, 700, 1100]) {
      await health.onGroups(
        groups(publicDelays: [50, delay, 60], publicSelected: 'public-2'),
      );
      now = now.add(const Duration(seconds: 30));
    }

    expect(health.current.activeNode, 'public-2');
    expect(health.current.delayMs, 1100);
    expect(health.current.p50Ms, 500);
    expect(health.current.p95Ms, 1100);
    expect(health.current.jitterMs, 600);
    await health.dispose();
  });

  test(
    'uses fastest successful member only when selected item is absent',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);
      await health.onGroups(
        groups(publicDelays: [420, 180, 310], publicSelected: 'missing'),
      );

      expect(health.current.activeNode, 'public-2');
      expect(health.current.delayMs, 180);
      await health.dispose();
    },
  );

  test(
    'first current-path transport failure schedules one fast retest',
    () async {
      final health = coordinator(
        fastRetestDelay: const Duration(milliseconds: 5),
      );
      await health.start(contract, PathPreference.auto);
      await health.onGroups(groups(publicDelays: [0, 0, 0]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bridge.urlTests.where((tag) => tag == 'relay-public-auto').length, 2);
      expect(bridge.urlTests.length, 6);
      await health.dispose();
    },
  );

  test('mismatch forces one lease refresh and second egress probe', () async {
    var calls = 0;
    final health = coordinator(
      probe: (group, policy) async {
        calls++;
        probes.add((group, policy.expectedIpv4));
        return calls == 1 ? mismatch : verified;
      },
    );
    await health.start(contract, PathPreference.auto);

    expect(calls, 2);
    expect(leaseRefreshes, 2);
    await health.onGroups(groups(publicDelays: [220, 230, 240]));
    expect(bridge.selections, [('proxy', 'relay-public-auto')]);
    expect(health.current.egressVerified, isTrue);
    await health.dispose();
  });

  test('startup never remains on an unverified preferred path', () async {
    final health = coordinator(
      probe: (group, _) async =>
          group == 'relay-tailnet-auto' ? verified : mismatch,
    );
    await health.start(contract, PathPreference.auto);

    expect(bridge.selections, [
      ('proxy', 'relay-public-auto'),
      ('proxy', 'relay-tailnet-auto'),
    ]);
    expect(health.current.state, AuroraPathState.relayTailnet);
    expect(health.current.egressVerified, isTrue);
    await health.dispose();
  });

  test('startup selects fail-closed when no household path verifies', () async {
    final health = coordinator(probe: (_, _) async => mismatch);
    await health.start(contract, PathPreference.auto);

    expect(bridge.selections.last, ('proxy', 'fail-closed'));
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(bridge.stopCalls, 0);
    await health.dispose();
  });

  test(
    'two hard failures switch once and preserve the failure reason',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);
      bridge.selections.clear();
      await health.onGroups(groups(publicDelays: [0, 0, 0]));
      now = now.add(const Duration(seconds: 5));
      await health.onGroups(groups(publicDelays: [0, 0, 0]));

      expect(bridge.selections, [('proxy', 'relay-tailnet-auto')]);
      expect(health.current.state, AuroraPathState.relayTailnet);
      expect(health.current.reasonCode, PathReason.pathHardFailure);
      expect(health.current.egressVerified, isTrue);
      await health.dispose();
    },
  );

  test(
    'failed switched path is isolated until a verified household path',
    () async {
      final health = coordinator(
        probe: (group, _) async => switch (group) {
          'relay-tailnet-auto' => mismatch,
          _ => verified,
        },
      );
      await health.start(contract, PathPreference.auto);
      bridge.selections.clear();
      await health.onGroups(groups(publicDelays: [0, 0, 0]));
      now = now.add(const Duration(seconds: 5));
      await health.onGroups(groups(publicDelays: [0, 0, 0]));

      expect(bridge.selections, [
        ('proxy', 'relay-tailnet-auto'),
        ('proxy', 'home-auto'),
      ]);
      expect(health.current.state, AuroraPathState.homeDirect);
      expect(health.current.egressVerified, isTrue);
      await health.dispose();
    },
  );

  test(
    'all unverifiable paths select fail-closed without stopping TUN',
    () async {
      final health = coordinator(probe: (_, _) async => mismatch);
      await health.start(contract, PathPreference.auto);
      await health.onGroups(groups(publicDelays: [200, 210, 220]));

      expect(bridge.selections.last, ('proxy', 'fail-closed'));
      expect(bridge.stopCalls, 0);
      expect(health.current.state, AuroraPathState.homeBlocked);
      await health.dispose();
    },
  );

  test('network epoch clears samples and retests every path', () async {
    final health = coordinator();
    await health.start(contract, PathPreference.auto);
    await health.onNetworkChanged();

    expect(health.networkEpoch, 1);
    expect(bridge.urlTests.length, 6);
    expect(leaseRefreshes, 2);
    await health.dispose();
  });

  test(
    'network recheck isolates a confirmed egress mismatch without groups',
    () async {
      var mismatchNow = false;
      final health = coordinator(
        probe: (_, _) async => mismatchNow ? mismatch : verified,
      );
      await health.start(contract, PathPreference.auto);
      bridge.selections.clear();
      mismatchNow = true;

      await health.onNetworkChanged();

      expect(bridge.selections, [('proxy', 'fail-closed')]);
      expect(health.current.state, AuroraPathState.homeBlocked);
      await health.dispose();
    },
  );

  test(
    'steady recheck isolates a confirmed egress mismatch without groups',
    () {
      fakeAsync((clock) {
        var mismatchNow = false;
        var started = false;
        final health = coordinator(
          healthInterval: const Duration(milliseconds: 5),
          probe: (_, _) async => mismatchNow ? mismatch : verified,
        );
        try {
          unawaited(
            health.start(contract, PathPreference.auto).then((_) {
              started = true;
            }),
          );
          clock.flushMicrotasks();
          expect(started, isTrue);
          expect(clock.periodicTimerCount, 1);
          bridge.selections.clear();
          mismatchNow = true;

          // Advance the production Timer and its async lease/probe/selector
          // chain explicitly. Wall-clock sleeping cannot prove a round ended.
          clock.elapse(const Duration(milliseconds: 4));
          expect(bridge.selections, isEmpty);
          clock.elapse(const Duration(milliseconds: 1));
          clock.flushMicrotasks();

          expect(bridge.selections, [('proxy', 'fail-closed')]);
          expect(health.current.state, AuroraPathState.homeBlocked);
          expect(health.current.reasonCode, PathReason.egressMismatch);
          expect(bridge.stopCalls, 0);
        } finally {
          unawaited(health.dispose());
          clock.flushMicrotasks();
        }
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'an established session blocks immediately when its lease expires',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);
      expect(health.current.egressVerified, isTrue);

      now = lease.expiresAt.add(const Duration(seconds: 1));
      await health.onNetworkChanged();

      expect(bridge.selections, [
        ('proxy', 'relay-public-auto'),
        ('proxy', 'fail-closed'),
      ]);
      expect(health.current.state, AuroraPathState.homeBlocked);
      expect(health.current.leaseHealth, LeaseHealth.invalid);
      expect(health.current.egressVerified, isFalse);
      await health.dispose();
    },
  );

  test('an expired startup lease never releases a candidate path', () async {
    now = lease.expiresAt.add(const Duration(seconds: 1));
    final health = coordinator();

    await health.start(contract, PathPreference.auto);

    expect(bridge.selections, isEmpty);
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(health.current.leaseHealth, LeaseHealth.invalid);
    await health.dispose();
  });

  test(
    'lease expiry blocks before validating an incomplete group snapshot',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);

      now = lease.expiresAt.add(const Duration(seconds: 1));
      await health.onGroups(const []);

      expect(bridge.selections.last, ('proxy', 'fail-closed'));
      expect(health.current.state, AuroraPathState.homeBlocked);
      await health.dispose();
    },
  );

  test(
    'a failed block selection is retried and never falsely acknowledged',
    () async {
      final health = coordinator();
      await health.start(contract, PathPreference.auto);
      bridge.failSelectionTag = 'fail-closed';
      now = lease.expiresAt.add(const Duration(seconds: 1));

      await expectLater(health.onNetworkChanged(), throwsStateError);
      expect(health.current.state, AuroraPathState.relayPublic);
      await health.onNetworkChanged();

      expect(
        bridge.selections.where((selection) => selection.$2 == 'fail-closed'),
        hasLength(2),
      );
      expect(health.current.state, AuroraPathState.homeBlocked);
      await health.dispose();
    },
  );

  test(
    'a renewed lease re-verifies before recovering the preferred path',
    () async {
      var candidate = lease;
      final health = PathHealthCoordinator(
        bridge: bridge,
        now: () => now,
        probe: (group, policy) async {
          probes.add((group, policy.expectedIpv4));
          return verified;
        },
        refreshLease: (_, _) async => candidate,
        healthInterval: Duration.zero,
        fastRetestDelay: Duration.zero,
        startupGracePeriod: Duration.zero,
      );
      await health.start(contract, PathPreference.auto);

      now = lease.expiresAt.add(const Duration(seconds: 1));
      await health.onNetworkChanged();
      candidate = EgressLease(
        keyId: lease.keyId,
        homeName: lease.homeName,
        ipv4: lease.ipv4,
        sequence: lease.sequence + 1,
        issuedAt: now.subtract(const Duration(seconds: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        signature: lease.signature,
      );
      await health.onNetworkChanged();

      expect(bridge.selections, [
        ('proxy', 'relay-public-auto'),
        ('proxy', 'fail-closed'),
        ('proxy', 'relay-public-auto'),
      ]);
      expect(health.current.state, AuroraPathState.relayPublic);
      expect(health.current.leaseHealth, LeaseHealth.valid);
      expect(health.current.egressVerified, isTrue);
      await health.dispose();
    },
  );

  test('HTTP challenge is compatibility data, not path failure', () async {
    var firstProbe = true;
    final health = coordinator(
      probe: (_, _) async {
        if (firstProbe) {
          firstProbe = false;
          return verified;
        }
        return compatibility;
      },
    );
    await health.start(contract, PathPreference.auto);
    await health.onNetworkChanged();
    for (var round = 0; round < 4; round++) {
      await health.onGroups(groups(publicDelays: [200, 210, 220]));
      now = now.add(const Duration(seconds: 30));
    }

    expect(bridge.selections, [('proxy', 'relay-public-auto')]);
    expect(health.current.state, AuroraPathState.relayPublic);
    await health.dispose();
  });

  test('HTTP challenge cannot establish startup egress identity', () async {
    final health = coordinator(probe: (_, _) async => compatibility);

    await health.start(contract, PathPreference.auto);

    expect(bridge.selections.last, ('proxy', 'fail-closed'));
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(health.current.egressVerified, isFalse);
    await health.dispose();
  });

  test('failed manual preference change returns to fail-closed', () async {
    var homeFails = false;
    final health = coordinator(
      probe: (group, _) async =>
          group == 'home-auto' && homeFails ? mismatch : verified,
    );
    await health.start(contract, PathPreference.auto);
    homeFails = true;

    await health.setPreference(PathPreference.homeDirect);

    expect(bridge.selections, [
      ('proxy', 'relay-public-auto'),
      ('proxy', 'home-auto'),
      ('proxy', 'fail-closed'),
    ]);
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(health.current.egressVerified, isFalse);
    await health.dispose();
  });

  test('groups during the initial lease fetch never fail-close', () async {
    final gate = Completer<void>();
    final health = PathHealthCoordinator(
      bridge: bridge,
      now: () => now,
      probe: (_, _) async => verified,
      refreshLease: (_, _) async {
        leaseRefreshes++;
        if (leaseRefreshes == 1) await gate.future;
        return lease;
      },
      healthInterval: Duration.zero,
      fastRetestDelay: Duration.zero,
      startupGracePeriod: Duration.zero,
    );
    final emitted = <PathHealthSnapshot>[];
    final subscription = health.snapshots.listen(emitted.add);
    final starting = health.start(contract, PathPreference.auto);
    await Future<void>.delayed(Duration.zero);

    // libbox pushes group snapshots immediately after connect, while the very
    // first lease fetch is still on the wire. That must never be read as an
    // invalid lease.
    await health.onGroups(groups(publicDelays: [200, 210, 220]));
    expect(
      bridge.selections.where((selection) => selection.$2 == 'fail-closed'),
      isEmpty,
    );
    expect(
      emitted.where(
        (snapshot) => snapshot.state == AuroraPathState.homeBlocked,
      ),
      isEmpty,
    );
    await subscription.cancel();

    gate.complete();
    await starting;
    expect(bridge.selections, [('proxy', 'relay-public-auto')]);
    expect(health.current.state, AuroraPathState.relayPublic);
    await health.dispose();
  });

  test('groups during a steady lease refresh keep the verified path', () async {
    Completer<void>? refreshGate;
    final health = PathHealthCoordinator(
      bridge: bridge,
      now: () => now,
      probe: (_, _) async => verified,
      refreshLease: (_, _) async {
        final gate = refreshGate;
        if (gate != null) await gate.future;
        return lease;
      },
      healthInterval: Duration.zero,
      fastRetestDelay: Duration.zero,
      startupGracePeriod: Duration.zero,
    );
    await health.start(contract, PathPreference.auto);
    bridge.selections.clear();

    final gate = refreshGate = Completer<void>();
    final refreshing = health.onNetworkChanged();
    await Future<void>.delayed(Duration.zero);
    final evaluating = health.onGroups(groups(publicDelays: [200, 210, 220]));
    await Future<void>.delayed(Duration.zero);

    expect(
      bridge.selections.where((selection) => selection.$2 == 'fail-closed'),
      isEmpty,
    );
    gate.complete();
    refreshGate = null;
    await refreshing;
    await evaluating;
    expect(health.current.state, AuroraPathState.relayPublic);
    await health.dispose();
  });

  test('egress probe outage never degrades a healthy transport', () async {
    var probeDown = false;
    final health = coordinator(
      probe: (_, _) async => probeDown ? probeOutage : verified,
    );
    await health.start(contract, PathPreference.auto);
    bridge.selections.clear();
    probeDown = true;

    await health.onNetworkChanged();
    for (var round = 0; round < 4; round++) {
      await health.onGroups(groups(publicDelays: [200, 210, 220]));
      now = now.add(const Duration(seconds: 30));
    }

    expect(
      bridge.selections.where((selection) => selection.$2 == 'fail-closed'),
      isEmpty,
    );
    expect(health.current.state, AuroraPathState.relayPublic);
    await health.dispose();
  });

  test(
    'latency switch with a probe outage holds the verified current path',
    () async {
      var probeDown = false;
      final health = coordinator(
        probe: (_, _) async => probeDown ? probeOutage : verified,
      );
      await health.start(contract, PathPreference.auto);
      bridge.selections.clear();
      probeDown = true;

      for (var round = 0; round < 5; round++) {
        await health.onGroups(groups(publicDelays: [4000, 4000, 4000]));
        now = now.add(const Duration(seconds: 30));
      }

      expect(bridge.selections, [
        ('proxy', 'relay-tailnet-auto'),
        ('proxy', 'relay-public-auto'),
      ]);
      expect(health.current.state, AuroraPathState.relayPublic);
      expect(health.current.reasonCode, PathReason.egressUnverified);
      await health.dispose();
    },
  );

  test('a dead current path with a probe outage still fails closed', () async {
    var probeDown = false;
    final health = coordinator(
      probe: (_, _) async => probeDown ? probeOutage : verified,
    );
    await health.start(contract, PathPreference.auto);
    bridge.selections.clear();
    probeDown = true;

    await health.onGroups(groups(publicDelays: [0, 0, 0]));
    now = now.add(const Duration(seconds: 5));
    await health.onGroups(groups(publicDelays: [0, 0, 0]));

    expect(bridge.selections.last, ('proxy', 'fail-closed'));
    expect(health.current.state, AuroraPathState.homeBlocked);
    await health.dispose();
  });

  test('steady timer refreshes lease and probes current path', () async {
    final health = coordinator(healthInterval: const Duration(milliseconds: 8));
    await health.start(contract, PathPreference.auto);
    await Future<void>.delayed(const Duration(milliseconds: 28));

    expect(leaseRefreshes, greaterThanOrEqualTo(2));
    expect(probes.length, greaterThanOrEqualTo(2));
    await health.dispose();
  });

  test('groups cannot switch the selector during a health probe', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var probeCalls = 0;
    final health = coordinator(
      fastRetestDelay: const Duration(milliseconds: 1),
      probe: (_, _) async {
        if (++probeCalls == 2) {
          probeStarted.complete();
          return probeResult.future;
        }
        return verified;
      },
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    await health.onGroups(groups(publicDelays: [0, 0, 0]));
    await probeStarted.future;

    now = now.add(const Duration(seconds: 5));
    final evaluating = health.onGroups(groups(publicDelays: [0, 0, 0]));
    await Future<void>.delayed(Duration.zero);
    final selectionsDuringProbe = [...bridge.selections];
    probeResult.complete(verified);
    await evaluating;

    expect(selectionsDuringProbe, [('proxy', 'relay-public-auto')]);
    expect(bridge.selections.last, ('proxy', 'relay-tailnet-auto'));
    expect(health.current.state, AuroraPathState.relayTailnet);
  });

  test('an old network probe cannot verify the new network epoch', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var probeCalls = 0;
    final health = coordinator(
      fastRetestDelay: const Duration(milliseconds: 1),
      probe: (_, _) async {
        if (++probeCalls == 1) return verified;
        if (probeCalls == 2) {
          probeStarted.complete();
          return probeResult.future;
        }
        return probeOutage;
      },
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    await health.onGroups(groups(publicDelays: [0, 0, 0]));
    await probeStarted.future;

    final changingNetwork = health.onNetworkChanged();
    await Future<void>.delayed(Duration.zero);
    probeResult.complete(verified);
    await changingNetwork;
    await Future<void>.delayed(Duration.zero);
    await health.onGroups(groups(publicDelays: [200, 210, 220]));

    expect(health.networkEpoch, 1);
    expect(health.current.egressVerified, isFalse);
    // A later verification outage must not use the old epoch's success as
    // permission to restore the public path after trying another candidate.
    for (var round = 0; round < 8; round++) {
      now = now.add(const Duration(seconds: 30));
      await health.onGroups(groups(publicDelays: [4000, 4000, 4000]));
    }
    expect(health.current.state, AuroraPathState.homeBlocked);
  });

  test('a network change during startup retries with fresh egress evidence', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var calls = 0;
    var recovered = false;
    final health = coordinator(
      probe: (_, _) {
        if (++calls == 1) {
          probeStarted.complete();
          return probeResult.future;
        }
        return Future.value(recovered ? verified : probeOutage);
      },
    );
    addTearDown(health.dispose);
    final starting = health.start(contract, PathPreference.auto);
    await probeStarted.future;
    await health.onNetworkChanged();
    probeResult.complete(verified);
    await starting;

    expect(health.networkEpoch, 1);
    expect(health.current.egressVerified, isFalse);
    expect(health.current.state, AuroraPathState.homeBlocked);
    recovered = true;
    await health.onNetworkChanged();
    expect(health.current.egressVerified, isTrue);
    expect(health.current.state, AuroraPathState.relayPublic);
  });

  test('lease expiry preempts startup after its lease has been fetched', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    final health = coordinator(
      probe: (_, _) {
        probeStarted.complete();
        return probeResult.future;
      },
    );
    addTearDown(health.dispose);
    final starting = health.start(contract, PathPreference.auto);
    await probeStarted.future;
    now = lease.expiresAt.add(const Duration(seconds: 1));
    await health.onGroups([]);
    final selectedWhilePending = bridge.selections.last.$2;
    probeResult.complete(verified);
    await starting;

    expect(selectedWhilePending, 'fail-closed');
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(health.current.egressVerified, isFalse);
    expect(bridge.urlTests, isNotEmpty);
  });

  test('already blocked telemetry does not cancel a recovery lease refresh', () async {
    final refreshStarted = Completer<void>();
    final refreshResult = Completer<EgressLease>();
    var calls = 0;
    final health = PathHealthCoordinator(
      bridge: bridge,
      now: () => now,
      probe: (_, _) async => verified,
      refreshLease: (_, _) {
        if (++calls == 1) return Future.value(lease);
        refreshStarted.complete();
        return refreshResult.future;
      },
      healthInterval: Duration.zero,
      fastRetestDelay: Duration.zero,
      startupGracePeriod: Duration.zero,
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    now = lease.expiresAt.add(const Duration(seconds: 1));
    await health.onGroups([]);
    final recovering = health.onNetworkChanged();
    await refreshStarted.future;
    await health.onGroups([]);
    refreshResult.complete(EgressLease(
      keyId: lease.keyId,
      homeName: lease.homeName,
      ipv4: lease.ipv4,
      sequence: 13,
      issuedAt: now,
      expiresAt: now.add(const Duration(hours: 2)),
      signature: lease.signature,
    ));
    await recovering;

    expect(health.current.state, AuroraPathState.relayPublic);
    expect(health.current.egressVerified, isTrue);
  });

  test('network change during initial urltests keeps periodic health checks', () async {
    final testStarted = Completer<void>();
    final testResult = Completer<void>();
    final periodicProbe = Completer<void>();
    var firstTest = true;
    bridge.onUrlTest = (_) {
      if (firstTest) {
        firstTest = false;
        testStarted.complete();
        return testResult.future;
      }
      return Future.value();
    };
    final health = coordinator(
      healthInterval: const Duration(milliseconds: 5),
      probe: (group, policy) async {
        probes.add((group, policy.expectedIpv4));
        if (probes.length >= 3 && !periodicProbe.isCompleted) {
          periodicProbe.complete();
        }
        return verified;
      },
    );
    addTearDown(health.dispose);
    final starting = health.start(contract, PathPreference.auto);
    await testStarted.future;
    final changingNetwork = health.onNetworkChanged();
    testResult.complete();
    await Future.wait([starting, changingNetwork]);
    await periodicProbe.future.timeout(const Duration(seconds: 2));

    expect(probes.length, greaterThanOrEqualTo(3));
  });

  test(
    'dispose during startup lease fetch prevents further bridge work',
    () async {
      final leaseStarted = Completer<void>();
      final leaseResult = Completer<EgressLease>();
      final health = PathHealthCoordinator(
        bridge: bridge,
        now: () => now,
        probe: (group, policy) async {
          probes.add((group, policy.expectedIpv4));
          return verified;
        },
        refreshLease: (_, _) {
          leaseStarted.complete();
          return leaseResult.future;
        },
        healthInterval: Duration.zero,
        fastRetestDelay: Duration.zero,
        startupGracePeriod: Duration.zero,
      );
      final starting = health.start(contract, PathPreference.auto);
      await leaseStarted.future;
      await health.dispose();
      leaseResult.complete(lease);
      await starting;

      expect(bridge.selections, isEmpty);
      expect(bridge.urlTests, isEmpty);
      expect(probes, isEmpty);
      expect(health.current.egressVerified, isFalse);
    },
  );

  test('manual preference waits for the current health probe', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var probeCalls = 0;
    final health = coordinator(
      probe: (_, _) async {
        if (++probeCalls == 2) {
          probeStarted.complete();
          return probeResult.future;
        }
        return verified;
      },
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    final changingNetwork = health.onNetworkChanged();
    await probeStarted.future;

    final changingPreference = health.setPreference(PathPreference.homeDirect);
    await Future<void>.delayed(Duration.zero);
    final selectionsDuringProbe = [...bridge.selections];
    probeResult.complete(verified);
    await Future.wait([changingNetwork, changingPreference]);

    expect(selectionsDuringProbe, [('proxy', 'relay-public-auto')]);
    expect(bridge.selections.last, ('proxy', 'home-auto'));
    expect(health.current.state, AuroraPathState.homeDirect);
  });

  test('pending telemetry keeps only the newest health sample', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var probeCalls = 0;
    final health = coordinator(
      fastRetestDelay: const Duration(milliseconds: 1),
      probe: (_, _) async {
        if (++probeCalls == 2) {
          probeStarted.complete();
          return probeResult.future;
        }
        return verified;
      },
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    await health.onGroups(groups(publicDelays: [0, 0, 0]));
    await probeStarted.future;

    final updates = <Future<void>>[];
    for (var update = 0; update < 20; update++) {
      now = now.add(const Duration(seconds: 1));
      updates.add(health.onGroups(groups(publicDelays: [0, 0, 0])));
    }
    updates.add(health.onGroups(groups(publicDelays: [200, 210, 220])));
    probeResult.complete(verified);
    await Future.wait(updates);

    expect(bridge.selections, [('proxy', 'relay-public-auto')]);
    expect(health.current.state, AuroraPathState.relayPublic);
    expect(health.current.delayMs, 200);
  });

  test('the latest preference wins while a probe is pending', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    var probeCalls = 0;
    final health = coordinator(
      probe: (_, _) async {
        if (++probeCalls == 2) {
          probeStarted.complete();
          return probeResult.future;
        }
        return verified;
      },
    );
    addTearDown(health.dispose);
    await health.start(contract, PathPreference.auto);
    final changingNetwork = health.onNetworkChanged();
    await probeStarted.future;
    final home = health.setPreference(PathPreference.homeDirect);
    final automatic = health.setPreference(PathPreference.auto);
    probeResult.complete(verified);
    await Future.wait([changingNetwork, home, automatic]);

    expect(health.current.preference, PathPreference.auto);
    expect(bridge.selections, [('proxy', 'relay-public-auto')]);
  });

  test('a lease expiring during startup probe cannot verify a path', () async {
    final probeStarted = Completer<void>();
    final probeResult = Completer<EgressProbeReport>();
    final health = coordinator(
      probe: (_, _) {
        probeStarted.complete();
        return probeResult.future;
      },
    );
    addTearDown(health.dispose);
    final starting = health.start(contract, PathPreference.auto);
    await probeStarted.future;
    now = lease.expiresAt.add(const Duration(seconds: 1));
    probeResult.complete(verified);
    await starting;

    expect(bridge.selections, [
      ('proxy', 'relay-public-auto'),
      ('proxy', 'fail-closed'),
    ]);
    expect(health.current.state, AuroraPathState.homeBlocked);
    expect(health.current.egressVerified, isFalse);
  });

  test(
    'lease expiry waits for an issued selector command before blocking',
    () async {
      final selectionStarted = Completer<void>();
      final selectionResult = Completer<void>();
      final health = coordinator();
      addTearDown(health.dispose);
      await health.start(contract, PathPreference.auto);
      bridge.onSelect = (_, tag) async {
        if (tag == 'relay-tailnet-auto') {
          selectionStarted.complete();
          await selectionResult.future;
        }
      };
      await health.onGroups(groups(publicDelays: [0, 0, 0]));
      now = now.add(const Duration(seconds: 5));
      final switching = health.onGroups(groups(publicDelays: [0, 0, 0]));
      await selectionStarted.future;

      now = lease.expiresAt.add(const Duration(seconds: 1));
      final blocking = health.onGroups([]);
      await Future<void>.delayed(Duration.zero);
      final beforeAcknowledgement = [...bridge.selections];
      selectionResult.complete();
      await Future.wait([switching, blocking]);

      expect(beforeAcknowledgement, [
        ('proxy', 'relay-public-auto'),
        ('proxy', 'relay-tailnet-auto'),
      ]);
      expect(bridge.selections.last, ('proxy', 'fail-closed'));
      expect(health.current.state, AuroraPathState.homeBlocked);
      expect(health.current.egressVerified, isFalse);
      expect(probes, [('relay-public-auto', lease.ipv4)]);
    },
  );

  test(
    'lease expiry preempts an in-flight probe despite missing groups',
    () async {
      final probeStarted = Completer<void>();
      final probeResult = Completer<EgressProbeReport>();
      var probeCalls = 0;
      final health = coordinator(
        probe: (_, _) async {
          if (++probeCalls == 2) {
            probeStarted.complete();
            return probeResult.future;
          }
          return verified;
        },
      );
      addTearDown(health.dispose);
      await health.start(contract, PathPreference.auto);
      final changingNetwork = health.onNetworkChanged();
      await probeStarted.future;

      now = lease.expiresAt.add(const Duration(seconds: 1));
      await health.onGroups([]);
      expect(bridge.selections.last, ('proxy', 'fail-closed'));
      expect(health.current.state, AuroraPathState.homeBlocked);
      expect(probeResult.isCompleted, isFalse);

      probeResult.complete(verified);
      await changingNetwork;
      expect(health.current.state, AuroraPathState.homeBlocked);
      expect(health.current.egressVerified, isFalse);
      expect(bridge.selections, [
        ('proxy', 'relay-public-auto'),
        ('proxy', 'fail-closed'),
      ]);
    },
  );
}

final lease = EgressLease(
  keyId: 'home-egress-1',
  homeName: 'home.example.net',
  ipv4: '203.0.113.10',
  sequence: 12,
  issuedAt: DateTime.utc(2026, 7, 22).subtract(const Duration(minutes: 5)),
  expiresAt: DateTime.utc(2026, 7, 22).add(const Duration(hours: 2)),
  signature: 'redacted-test-signature',
);

const verified = EgressProbeReport(
  egress: EgressStatus.verified,
  category: ProbeCategory.ok,
);
const mismatch = EgressProbeReport(
  egress: EgressStatus.mismatch,
  category: ProbeCategory.ok,
);
const compatibility = EgressProbeReport(
  egress: EgressStatus.unknown,
  category: ProbeCategory.http,
  compatibilityOnly: true,
);
const probeOutage = EgressProbeReport(
  egress: EgressStatus.unknown,
  category: ProbeCategory.timeout,
  transportFailure: true,
);

List<OutboundGroupInfo> groups({
  required List<int> publicDelays,
  String publicSelected = 'public-1',
  List<int> tailnetDelays = const [260, 270, 280],
  List<int> homeDelays = const [140, 150, 160],
}) => [
  OutboundGroupInfo(
    tag: 'proxy',
    type: 'selector',
    selected: 'relay-public-auto',
    selectable: true,
    items: const [],
  ),
  pathGroup('relay-public-auto', 'public', publicDelays, publicSelected),
  pathGroup('relay-tailnet-auto', 'tailnet', tailnetDelays, 'tailnet-1'),
  pathGroup('home-auto', 'home', homeDelays, 'home-1'),
];

OutboundGroupInfo pathGroup(
  String tag,
  String prefix,
  List<int> delays,
  String selected,
) => OutboundGroupInfo(
  tag: tag,
  type: 'urltest',
  selected: selected,
  selectable: false,
  items: [
    for (var i = 0; i < delays.length; i++)
      OutboundItem(tag: '$prefix-${i + 1}', type: 'proxy', delayMs: delays[i]),
  ],
);

class FakeBridge implements AuroraBridge {
  final urlTests = <String>[];
  final selections = <(String, String)>[];
  int stopCalls = 0;
  int startCalls = 0;
  String? failSelectionTag;
  Future<void> Function(String group, String tag)? onSelect;
  Future<void> Function(String group)? onUrlTest;

  @override
  Future<void> selectOutbound(String group, String tag) async {
    selections.add((group, tag));
    await onSelect?.call(group, tag);
    if (tag == failSelectionTag) {
      failSelectionTag = null;
      throw StateError('selection_failed');
    }
  }

  @override
  Future<void> urlTest(String group) async {
    urlTests.add(group);
    await onUrlTest?.call(group);
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> start(String configJson) async => startCalls++;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> openVpnSettings() async {}

  @override
  Future<TrafficStat> queryStats() async => const TrafficStat();

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() => const Stream.empty();

  @override
  Stream<String> logStream() => const Stream.empty();

  @override
  Stream<TrafficStat> statsStream() => const Stream.empty();

  @override
  Future<AuroraStatus> status() async => AuroraStatus.connected;

  @override
  Stream<AuroraStatus> statusStream() => const Stream.empty();
}
