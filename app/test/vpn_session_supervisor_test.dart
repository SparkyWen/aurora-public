import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/path_health_coordinator.dart';
import 'package:aurora/app/path_event_log.dart';
import 'package:aurora/app/vpn_session_supervisor.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/egress_lease.dart';
import 'package:aurora/core/goodput_gate.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/core/physical_network.dart';
import 'package:aurora/data/connection_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SessionBridge bridge;
  late AuroraContract contract;
  late VpnSessionSupervisor supervisor;

  setUp(() {
    bridge = SessionBridge();
    contract = AuroraContract.fromJson(
      jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      coordinatorFactory: (activeBridge) => PathHealthCoordinator(
        bridge: activeBridge,
        healthInterval: Duration.zero,
        startupGracePeriod: Duration.zero,
        probe: (_, _) async => verified,
        refreshLease: (_, _) async => lease,
      ),
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    await bridge.close();
  });

  test('attaches only after VPN connected and owns group stream', () async {
    bridge.currentStatus = AuroraStatus.connecting;
    await supervisor.attach(bridge, contract, PathPreference.auto);
    expect(supervisor.hasActiveSession, isFalse);

    bridge.emitStatus(AuroraStatus.connected);
    await pumpEvents();
    expect(supervisor.hasActiveSession, isTrue);
    expect(bridge.urlTests, ['relay-public-auto', 'relay-tailnet-auto', 'home-auto']);

    bridge.emitGroups(groups(publicDelays: [0, 0, 0]));
    await pumpEvents();
    bridge.emitGroups(groups(publicDelays: [0, 0, 0], tailnetBump: 1));
    await pumpEvents();
    expect(bridge.selections, [
      ('proxy', 'relay-public-auto'),
      ('proxy', 'relay-tailnet-auto'),
    ]);
  });

  test('canceling a page observer does not dispose the VPN session', () async {
    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, contract, PathPreference.auto);
    final pageSubscription = supervisor.snapshots.listen((_) {});
    await pageSubscription.cancel();

    await supervisor.setPreference(PathPreference.homeDirect);
    expect(supervisor.hasActiveSession, isTrue);
    expect(bridge.selections.last, ('proxy', 'home-auto'));
  });

  test('disconnected and error are the only automatic detach states', () async {
    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, contract, PathPreference.auto);

    bridge.emitStatus(AuroraStatus.disconnecting);
    await pumpEvents();
    expect(supervisor.hasActiveSession, isTrue);

    bridge.emitStatus(AuroraStatus.disconnected);
    await pumpEvents();
    expect(supervisor.hasActiveSession, isFalse);

    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, contract, PathPreference.auto);
    bridge.emitStatus(AuroraStatus.error);
    await pumpEvents();
    expect(supervisor.hasActiveSession, isFalse);
  });

  test('network epoch retest is forwarded to the live coordinator', () async {
    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, contract, PathPreference.auto);
    await supervisor.networkChanged();

    expect(bridge.urlTests.length, 6);
  });

  test(
    'startup verification finishes before reachability watchdog probes',
    () async {
      final startupProbe = Completer<EgressProbeReport>();
      final startupEntered = Completer<void>();
      var reachabilityCalls = 0;
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogGrace: Duration.zero,
        watchdogInterval: const Duration(hours: 1),
        watchdogProbe: () async {
          reachabilityCalls++;
          return healthyReport;
        },
        coordinatorFactory: (activeBridge) => PathHealthCoordinator(
          bridge: activeBridge,
          healthInterval: Duration.zero,
          probe: (_, _) {
            if (!startupEntered.isCompleted) startupEntered.complete();
            return startupProbe.future;
          },
          refreshLease: (_, _) async => lease,
        ),
      );
      bridge.currentStatus = AuroraStatus.connected;
      final attaching = supervisor.attach(
        bridge,
        contract,
        PathPreference.auto,
      );
      await startupEntered.future;
      await pumpEvents();
      final callsDuringBootstrap = reachabilityCalls;
      startupProbe.complete(verified);
      await attaching;
      await pumpEvents();

      expect(
        callsDuringBootstrap,
        0,
        reason:
            'NE connected still carries fail-closed/candidate traffic during bootstrap',
      );
      expect(reachabilityCalls, 1);
    },
  );

  for (final change in ['family', 'network']) {
    test('a $change change clears the previous path death verdict', () async {
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogGrace: Duration.zero,
        watchdogInterval: const Duration(hours: 1),
        watchdogConfirmDelay: Duration.zero,
        watchdogProbe: () async => deadReport,
      );
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      );
      await _waitUntil(
        () => supervisor.dataPlaneHealth == DataPlaneHealth.dead,
      );

      if (change == 'family') {
        supervisor.setRouteFamily('relay');
      } else {
        await supervisor.networkChanged();
      }
      expect(
        supervisor.dataPlaneHealth,
        DataPlaneHealth.unknown,
        reason: 'the replacement path has no failed probe evidence yet',
      );
    });
  }

  test(
    'activation failure restores fail-closed before surfacing error',
    () async {
      bridge.currentStatus = AuroraStatus.connected;
      bridge.failSelectionTag = 'relay-public-auto';

      await expectLater(
        supervisor.attach(bridge, contract, PathPreference.auto),
        throwsA(isA<StateError>()),
      );

      expect(bridge.selections.last, ('proxy', 'fail-closed'));
      expect(supervisor.hasActiveSession, isFalse);
    },
  );

  test(
    'a late watchdog result from a stopped session cannot mark its replacement alive',
    () async {
      final plain = AuroraContract.fromJson(
        jsonDecode(
              File('test/fixtures/contract.sample.json').readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final oldProbe = Completer<ConnectionProbeReport>();
      final nextProbe = Completer<ConnectionProbeReport>();
      var calls = 0;
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogGrace: Duration.zero,
        watchdogInterval: const Duration(hours: 1),
        watchdogProbe: () => ++calls == 1 ? oldProbe.future : nextProbe.future,
      );
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plain, PathPreference.auto);
      await _waitUntil(() => calls == 1);
      await supervisor.detachAfterVpnStopped();
      await supervisor.attach(bridge, plain, PathPreference.auto);
      oldProbe.complete(healthyReport);
      await pumpEvents();
      expect(supervisor.dataPlaneHealth, DataPlaneHealth.unknown);
      nextProbe.complete(healthyReport);
      await pumpEvents();
    },
  );

  test('a replacement session activates before an old startup finishes', () async {
    final selectionStarted = Completer<void>();
    final oldSelection = Completer<void>();
    var firstSelection = true;
    bridge.onSelect = (_, tag) {
      if (tag == 'relay-public-auto' && firstSelection) {
        firstSelection = false;
        selectionStarted.complete();
        return oldSelection.future;
      }
      return Future.value();
    };
    bridge.currentStatus = AuroraStatus.connected;
    Object? oldError;
    final starting = supervisor.attach(bridge, contract, PathPreference.auto)
        .catchError((Object error) { oldError = error; });
    await selectionStarted.future;
    await supervisor.detachAfterVpnStopped();
    await supervisor.attach(bridge, contract, PathPreference.auto);
    final replacementActive = supervisor.hasActiveSession;
    oldSelection.completeError(StateError('old_selection_failed'));
    await starting;

    expect(replacementActive, isTrue);
    expect(supervisor.hasActiveSession, isTrue);
    expect(oldError, isNull);
    expect(bridge.selections, [
      ('proxy', 'relay-public-auto'),
      ('proxy', 'relay-public-auto'),
    ]);
  });

  test('a stale demotion acknowledgement cannot label the next session', () async {
    final selectionStarted = Completer<void>();
    final oldSelection = Completer<void>();
    final freshProbe = Completer<ConnectionProbeReport>();
    final gate = GoodputGate();
    gate.observeHardFailure(
      node: 'old-node',
      candidates: ['old-node', 'alternate'],
      at: DateTime.now(),
    );
    var calls = 0;
    await supervisor.dispose();
    supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      watchdogGrace: const Duration(milliseconds: 20),
      watchdogInterval: const Duration(hours: 1),
      watchdogConfirmDelay: Duration.zero,
      watchdogProbe: () => ++calls <= 2
          ? Future.value(deadReport) : freshProbe.future,
      goodputGate: gate,
    );
    bridge.onSelect = (_, _) {
      selectionStarted.complete();
      return oldSelection.future;
    };
    bridge.currentStatus = AuroraStatus.connected;
    final plain = plainContract();
    await supervisor.attach(bridge, plain, PathPreference.auto);
    bridge.emitGroups(nodeGroups('old-node'));
    await selectionStarted.future.timeout(const Duration(seconds: 2));
    await supervisor.detachAfterVpnStopped();
    await supervisor.attach(bridge, plain, PathPreference.auto);
    oldSelection.complete();
    await pumpEvents();

    expect(supervisor.lastDemotedFrom, isNull);
    expect(supervisor.lastDemotedTo, isNull);
    freshProbe.complete(healthyReport);
  });

  test('a watchdog result for a replaced node cannot count as its failure', () async {
    final probeStarted = Completer<void>();
    final oldProbe = Completer<ConnectionProbeReport>();
    await supervisor.dispose();
    supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      watchdogGrace: const Duration(milliseconds: 20),
      watchdogInterval: const Duration(hours: 1),
      watchdogConfirmDelay: const Duration(hours: 1),
      watchdogProbe: () {
        probeStarted.complete();
        return oldProbe.future;
      },
    );
    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, plainContract(), PathPreference.auto);
    bridge.emitGroups(nodeGroups('old-node'));
    await probeStarted.future.timeout(const Duration(seconds: 2));
    bridge.emitGroups(nodeGroups('alternate'));
    await pumpEvents();
    oldProbe.complete(deadReport);
    await pumpEvents();

    expect(bridge.urlTests, isEmpty);
    expect(supervisor.dataPlaneHealth, DataPlaneHealth.unknown);
  });

  test(
    'a late throughput sample cannot switch the replacement session',
    () async {
      final plain = AuroraContract.fromJson(
        jsonDecode(
              File('test/fixtures/contract.sample.json').readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final oldSample = Completer<GoodputSample>();
      final started = Completer<void>();
      final gate = GoodputGate();
      gate.observe(
        node: 'old-node',
        reachable: true,
        bytesPerSecond: 1,
        candidates: ['old-node', 'alternate'],
        at: DateTime.now(),
      );
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogGrace: const Duration(milliseconds: 20),
        watchdogInterval: const Duration(hours: 1),
        watchdogProbe: () async => healthyReport,
        goodputGate: gate,
        goodputProbe: () {
          started.complete();
          return oldSample.future;
        },
      );
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plain, PathPreference.auto);
      bridge.emitGroups([
        const OutboundGroupInfo(
          tag: 'proxy',
          type: 'selector',
          selected: 'auto',
          selectable: true,
          items: [
            OutboundItem(tag: 'old-node', type: 'proxy', delayMs: 1),
            OutboundItem(tag: 'alternate', type: 'proxy', delayMs: 2),
          ],
        ),
        const OutboundGroupInfo(
          tag: 'auto',
          type: 'urltest',
          selected: 'old-node',
          selectable: false,
          items: [
            OutboundItem(tag: 'old-node', type: 'proxy', delayMs: 1),
            OutboundItem(tag: 'alternate', type: 'proxy', delayMs: 2),
          ],
        ),
      ]);
      await started.future.timeout(const Duration(seconds: 2));
      await supervisor.detachAfterVpnStopped();
      await supervisor.attach(bridge, plain, PathPreference.auto);
      oldSample.complete(
        const GoodputSample(
          bytes: 1,
          elapsed: Duration(seconds: 1),
          reachable: true,
        ),
      );
      await pumpEvents();
      expect(bridge.selections, isEmpty);
    },
  );

  test('a leg whose payloads all stall is switched away from', () async {
    // A relay entry's small requests get through on some carriers, so the watchdog
    // judges the tunnel alive, while every throughput measurement receives nothing
    // within its deadline. The second confirmation must arrive within seconds, as it
    // does for low throughput, instead of waiting a full goodputInterval.
    final events = <String>[];
    await supervisor.dispose();
    supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      watchdogGrace: Duration.zero,
      watchdogInterval: const Duration(milliseconds: 25),
      watchdogConfirmDelay: const Duration(milliseconds: 10),
      selectionSettle: Duration.zero,
      goodputInterval: const Duration(hours: 1),
      goodputConfirmDelay: const Duration(milliseconds: 10),
      watchdogProbe: () async => healthyReport,
      goodputProbe: () async => const GoodputSample(
        bytes: 0,
        elapsed: Duration(seconds: 8),
        reachable: false,
        stalled: true,
      ),
      pathEventLog: _RecordingLog(events),
    );
    bridge.currentStatus = AuroraStatus.connected;
    await supervisor.attach(bridge, plainContract(), PathPreference.auto);
    bridge.emitGroups(nodeGroups('old-node'));
    await _waitUntil(() => bridge.selections.contains(('proxy', 'alternate')));
    expect(events, contains('goodput_demote'));
  });

  for (final change in ['physical network', 'selected family']) {
    test('a watchdog result predating a $change change is discarded', () async {
      final plain = AuroraContract.fromJson(jsonDecode(
          File('test/fixtures/contract.sample.json').readAsStringSync()) as Map<String, dynamic>);
      final pending = Completer<ConnectionProbeReport>();
      final started = Completer<void>();
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogGrace: Duration.zero,
        watchdogInterval: const Duration(hours: 1),
        watchdogProbe: () { started.complete(); return pending.future; },
      );
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plain, PathPreference.auto);
      await started.future.timeout(const Duration(seconds: 2));
      if (change == 'physical network') {
        await supervisor.networkChanged();
      } else {
        supervisor.setRouteFamily('relay');
      }
      pending.complete(healthyReport);
      await pumpEvents();
      expect(supervisor.dataPlaneHealth, DataPlaneHealth.unknown);
    });
  }

  group('tunnel watchdog', () {
    late AuroraContract plainContract;
    late List<ConnectionProbeReport> probeScript;
    late int probeCalls;
    late int restarts;

    setUp(() {
      plainContract = AuroraContract.fromJson(
        jsonDecode(File('test/fixtures/contract.sample.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      probeScript = [];
      probeCalls = 0;
      restarts = 0;
    });

    VpnSessionSupervisor watchdogSupervisor() {
      final s = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: const Duration(milliseconds: 25),
        watchdogGrace: Duration.zero,
        watchdogConfirmDelay: const Duration(milliseconds: 10),
        // The DNS wait after a route change is tested separately, by the test about
        // changing the route itself.
        selectionSettle: Duration.zero,
        watchdogProbe: () async {
          probeCalls++;
          return probeScript.isEmpty
              ? healthyReport
              : probeScript.removeAt(0);
        },
      );
      s.tunnelRestartHandler = () async {
        restarts++;
        return true;
      };
      return s;
    }

    test(
      'dead probe JSONL preserves TLS evidence without arbitrary names or healthy spam',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'aurora-tls-watchdog-',
        );
        final log = PathEventLog(directory: dir);
        final recovered = Completer<void>();
        var calls = 0;
        await supervisor.dispose();
        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 25),
          watchdogGrace: Duration.zero,
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          pathEventLog: log,
          goodputInterval: Duration.zero,
          watchdogProbe: () async {
            if (++calls == 1) {
              return const ConnectionProbeReport([
                ProbeResult(
                  name: 'Google 204',
                  category: ProbeCategory.tls,
                  tlsFailure: TlsFailure.certificateValidation,
                ),
                ProbeResult(
                  name: 'Cloudflare 204',
                  category: ProbeCategory.tls,
                  tlsFailure: TlsFailure.handshakeClosed,
                ),
                ProbeResult(
                  name: 'https://private.example?token=test-secret',
                  category: ProbeCategory.tls,
                  tlsFailure: TlsFailure.handshake,
                ),
              ]);
            }
            if (calls == 3) recovered.complete();
            return healthyReport;
          },
        );
        addTearDown(() async {
          await supervisor.dispose();
          await log.record('test_flush');
          await dir.delete(recursive: true);
        });
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await recovered.future.timeout(const Duration(seconds: 2));
        await supervisor.dispose();
        await log.record('test_flush');
        final text = await File('${dir.path}/path-events.jsonl').readAsString();
        final events = const LineSplitter()
            .convert(text)
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
        final failures = events
            .where((e) => e['e'] == 'watchdog_probe_dead')
            .toList();
        expect(failures, hasLength(1));
        expect(failures.single['category'], 'tls');
        expect(failures.single['probes'], [
          {
            'target': 'google_204',
            'category': 'tls',
            'tls_failure': 'certificateValidation',
          },
          {
            'target': 'cloudflare_204',
            'category': 'tls',
            'tls_failure': 'handshakeClosed',
          },
          {'target': 'unknown', 'category': 'tls', 'tls_failure': 'handshake'},
        ]);
        expect(
          events.where((e) => e.containsKey('probes')),
          hasLength(1),
          reason: 'Healthy rounds must not append per-target probe records',
        );
        for (final sensitive in [
          'private.example',
          'test-secret',
          'https://',
        ]) {
          expect(text, isNot(contains(sensitive)));
        }
      },
    );

    test(
      'dead probe JSONL records what the active group\'s URL tests saw',
      () async {
        // Without this, the field evidence only says "all probes dead" and not whether
        // each leg's URL test in the group was alive or dead at that moment, which is
        // exactly the evidence for judging whether switching legs or restarting could help.
        final dir = await Directory.systemTemp.createTemp(
          'aurora-watchdog-delays-',
        );
        final log = PathEventLog(directory: dir);
        await supervisor.dispose();
        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 25),
          watchdogGrace: Duration.zero,
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          pathEventLog: log,
          goodputInterval: Duration.zero,
          watchdogProbe: () async => deadReport,
        );
        addTearDown(() async {
          await supervisor.dispose();
          await dir.delete(recursive: true);
        });
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups(nodeGroups('old-node'));
        await _waitUntil(() {
          final file = File('${dir.path}/path-events.jsonl');
          return file.existsSync() &&
              file.readAsStringSync().contains('watchdog_probe_dead');
        });
        await supervisor.dispose();
        await log.record('test_flush');
        final events = const LineSplitter()
            .convert(
              await File('${dir.path}/path-events.jsonl').readAsString(),
            )
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .where((e) => e['e'] == 'watchdog_probe_dead')
            .toList();
        expect(events, isNotEmpty);
        final first = events.first;
        expect(first['group'], 'auto');
        expect(first['node'], 'old-node');
        expect(first['delays'], {'old-node': 1, 'alternate': 2});
      },
    );

    test('healthy probes never trigger a restart', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(probeCalls, greaterThan(1));
      expect(restarts, 0);
    });

    test('a single dead probe only nudges urltest, no restart', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      probeScript.add(deadReport);
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(restarts, 0);
      expect(bridge.urlTests, isNotEmpty);
    });

    test('two consecutive dead probes restart the tunnel once', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      // Continuously dead: restart must fire exactly once (90s min gap).
      probeScript.addAll(List.filled(20, deadReport));
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(restarts, 1);
    });

    test('partial reachability is not treated as tunnel death', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      probeScript.addAll(List.filled(20, partialReport));
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(restarts, 0);
    });

    test('a silent tunnel DNS is death even while cached names connect', () async {
      // Air, 2026-10-11 22:16–22:24: one stuck DoH dial held every DNS
      // question for 8.5 minutes. The three probe names were still in the
      // system resolver's cache and kept connecting, so the watchdog said
      // alive and nobody restarted anything — no new site could resolve.
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      final seen = <DataPlaneHealth>[];
      supervisor.dataPlaneStream.listen(seen.add);
      probeScript.addAll(List.filled(20, dnsSilentReport));
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(seen, contains(DataPlaneHealth.dead));
      expect(restarts, 1);
    });

    test('an answering tunnel DNS leaves a healthy report alive', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      probeScript.addAll(List.filled(20, dnsAnsweringReport));
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(restarts, 0);
      expect(supervisor.dataPlaneHealth, DataPlaneHealth.alive);
    });

    test('watchdog stops probing after VPN disconnects', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      bridge.emitStatus(AuroraStatus.disconnected);
      await pumpEvents();
      final callsAtDetach = probeCalls;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(probeCalls, callsAtDetach);
    });

    test('confirmed death is reported to the UI, not just to the log', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      final seen = <DataPlaneHealth>[];
      supervisor.dataPlaneStream.listen(seen.add);
      probeScript.addAll(List.filled(20, deadReport));
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(seen, contains(DataPlaneHealth.dead));
      expect(supervisor.dataPlaneHealth, isNot(DataPlaneHealth.alive));
    });

    test('a live probe reports the data plane as alive', () async {
      await supervisor.dispose();
      supervisor = watchdogSupervisor();
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(supervisor.dataPlaneHealth, DataPlaneHealth.alive);
    });

    test('gives up restarting once reconnects stop helping', () async {
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: const Duration(milliseconds: 25),
        watchdogGrace: Duration.zero,
        watchdogConfirmDelay: const Duration(milliseconds: 10),
        // One failed recovery is enough here; production allows two before
        // concluding the far side is simply unreachable.
        maxRestartsWithoutRecovery: 1,
        watchdogProbe: () async {
          probeCalls++;
          return deadReport;
        },
      );
      // Model the real reconnect: the platform drops and re-establishes the
      // tunnel, and the UI re-attaches the supervisor to the new session.
      supervisor.tunnelRestartHandler = () async {
        restarts++;
        bridge.emitStatus(AuroraStatus.disconnected);
        await pumpEvents();
        bridge.currentStatus = AuroraStatus.connected;
        bridge.emitStatus(AuroraStatus.connected);
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        return true;
      };
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, plainContract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // A blackholed server IP survives reconnects, so the loop must stop and
      // say so instead of churning the tunnel forever.
      expect(restarts, 1);
      expect(supervisor.dataPlaneHealth, DataPlaneHealth.deadUnrecoverable);
    });

    group('physical network outage', () {
      // When the Wi-Fi drops, every probe times out, and the watchdog used to keep
      // counting, switching legs and restarting anyway. The restart then hit the
      // platform's "No network available", the whole reconnect budget burned down, and
      // nobody reconnected once the network came back. The watchdog needs an explicit
      // judgement for "the physical network is gone" instead of treating it as a dead
      // tunnel.
      const online = 'en0:IPv4:10.0.0.5';
      late String physical;
      late List<String> events;

      VpnSessionSupervisor offlineAwareSupervisor({
        GoodputGate? gate,
        int maxRestartsWithoutRecovery = 2,
      }) {
        final s = VpnSessionSupervisor(
          networkPollInterval: const Duration(milliseconds: 10),
          physicalNetworkSignature: () async => physical,
          watchdogInterval: const Duration(milliseconds: 25),
          watchdogGrace: Duration.zero,
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          maxRestartsWithoutRecovery: maxRestartsWithoutRecovery,
          goodputGate: gate,
          watchdogProbe: () async {
            probeCalls++;
            return probeScript.isEmpty
                ? healthyReport
                : probeScript.removeAt(0);
          },
          pathEventLog: _RecordingLog(events = []),
        );
        s.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };
        return s;
      }

      setUp(() {
        physical = online;
      });

      test('dead probes while offline neither count nor restart', () async {
        await supervisor.dispose();
        physical = physicalNetworkOffline;
        supervisor = offlineAwareSupervisor();
        probeScript.addAll(List.filled(40, deadReport));
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(restarts, 0);
        expect(supervisor.dataPlaneHealth, DataPlaneHealth.offline);
        expect(events, contains('physical_network_down'));
        expect(events, isNot(contains('watchdog_probe_dead')));
        expect(
          probeCalls,
          0,
          reason: 'probing a tunnel with no physical network proves nothing',
        );
      });

      test('going offline cancels a pending death confirmation', () async {
        await supervisor.dispose();
        supervisor = offlineAwareSupervisor();
        // First round dead → confirm scheduled. The network vanishes before
        // the confirmation runs; it must not be charged as round two.
        probeScript.addAll(List.filled(40, deadReport));
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await _waitUntil(() => events.contains('watchdog_probe_dead'));
        physical = physicalNetworkOffline;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(restarts, 0);
        expect(events.where((e) => e == 'watchdog_probe_dead').length, 1);
        expect(supervisor.dataPlaneHealth, DataPlaneHealth.offline);
      });

      test(
        'network return refunds budgets, forgets cooldowns and re-verifies',
        () async {
          await supervisor.dispose();
          final gate = GoodputGate();
          supervisor = offlineAwareSupervisor(
            gate: gate,
            maxRestartsWithoutRecovery: 1,
          );
          // Exhaust the restart budget on a genuinely dead tunnel first.
          probeScript.addAll(List.filled(6, deadReport));
          bridge.currentStatus = AuroraStatus.connected;
          await supervisor.attach(bridge, plainContract, PathPreference.auto);
          await _waitUntil(() => restarts == 1);
          await _waitUntil(
            () => supervisor.dataPlaneHealth == DataPlaneHealth.deadUnrecoverable,
          );
          // A node burnt by hard failures during that episode.
          gate.observeHardFailure(
            node: 'home-reality',
            candidates: const ['home-reality', 'home-ss'],
            at: DateTime.now(),
          );
          gate.observeHardFailure(
            node: 'home-reality',
            candidates: const ['home-reality', 'home-ss'],
            at: DateTime.now(),
          );
          expect(gate.isCoolingDown('home-reality', DateTime.now()), isTrue);

          physical = physicalNetworkOffline;
          await _waitUntil(
            () => supervisor.dataPlaneHealth == DataPlaneHealth.offline,
          );
          probeScript.clear();
          physical = online;
          await _waitUntil(() => events.contains('physical_network_up'));
          await _waitUntil(
            () => supervisor.dataPlaneHealth == DataPlaneHealth.alive,
          );
          expect(gate.isCoolingDown('home-reality', DateTime.now()), isFalse);
          // The selector is handed back to the group in effect so a stale
          // pin on a node this network cannot reach does not outlive the
          // outage (dns-proxy rides that pin).
          expect(bridge.selections, contains(('proxy', 'auto')));
          expect(bridge.urlTests, contains('auto'));
          // The give-up verdict was refunded: a later confirmed death may
          // restart again.
          probeScript.addAll(List.filled(40, deadReport));
          await _waitUntil(() => restarts == 2);
        },
      );

      test(
        'a re-election right after a network change is verified at once',
        () async {
          // On a network change the core resets its network itself and DoH gets a new
          // connection pool, so there is no old dial to wait for; a network that just came
          // back or just changed should be verified immediately (selectionSettle defaults to
          // 11s).
          await supervisor.dispose();
          supervisor = VpnSessionSupervisor(
            networkPollInterval: const Duration(milliseconds: 10),
            physicalNetworkSignature: () async => physical,
            watchdogInterval: const Duration(milliseconds: 25),
            watchdogGrace: Duration.zero,
            watchdogConfirmDelay: const Duration(milliseconds: 10),
            watchdogProbe: () async {
              probeCalls++;
              return healthyReport;
            },
            goodputProbe: () async => const GoodputSample(
              bytes: 10 << 20,
              elapsed: Duration(seconds: 1),
              reachable: true,
            ),
            pathEventLog: _RecordingLog(events = []),
          );
          bridge.currentStatus = AuroraStatus.connected;
          await supervisor.attach(bridge, plainContract, PathPreference.auto);
          bridge.emitGroups(nodeGroups('old-node'));
          await _waitUntil(() => probeCalls >= 1);
          physical = 'en0:IPv4:10.99.0.7';
          await _waitUntil(() => events.contains('network_changed'));
          bridge.emitGroups(nodeGroups('alternate'));
          await pumpEvents();
          final calls = probeCalls;
          await _waitUntil(() => probeCalls > calls);
        },
      );

      test('a session attached during an outage is reported offline', () async {
        // The supervisor outlives sessions. A session that ends while offline
        // and a replacement that attaches while still offline never see an
        // online→offline transition, so the verdict must come from the
        // steady state, not from the edge.
        await supervisor.dispose();
        supervisor = offlineAwareSupervisor();
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await _waitUntil(() => probeCalls >= 1);
        physical = physicalNetworkOffline;
        await _waitUntil(() => events.contains('physical_network_down'));
        bridge.emitStatus(AuroraStatus.disconnected);
        await pumpEvents();
        expect(supervisor.hasActiveSession, isFalse);

        bridge.currentStatus = AuroraStatus.connected;
        bridge.emitStatus(AuroraStatus.connected);
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await _waitUntil(
          () => supervisor.dataPlaneHealth == DataPlaneHealth.offline,
        );
        expect(events.where((e) => e == 'physical_network_down').length, 1);
        // Route-family changes must not erase the offline verdict either.
        supervisor.setRouteFamily('relay');
        expect(supervisor.dataPlaneHealth, DataPlaneHealth.offline);
      });

      test('coming back on the same lease is still a network change', () async {
        await supervisor.dispose();
        supervisor = offlineAwareSupervisor();
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        await _waitUntil(() => probeCalls >= 1);
        physical = physicalNetworkOffline;
        await _waitUntil(() => events.contains('physical_network_down'));
        physical = online;
        await _waitUntil(() => events.contains('physical_network_up'));
        expect(events, contains('network_changed'));
      });
    });

    test('watchdog also runs alongside a path coordinator', () async {
      await supervisor.dispose();
      supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: const Duration(milliseconds: 25),
        watchdogGrace: Duration.zero,
        watchdogProbe: () async {
          probeCalls++;
          return healthyReport;
        },
        coordinatorFactory: (activeBridge) => PathHealthCoordinator(
          bridge: activeBridge,
          healthInterval: Duration.zero,
          startupGracePeriod: Duration.zero,
          probe: (_, _) async => verified,
          refreshLease: (_, _) async => lease,
        ),
      );
      bridge.currentStatus = AuroraStatus.connected;
      await supervisor.attach(bridge, contract, PathPreference.auto);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(supervisor.hasActiveSession, isTrue);
      expect(probeCalls, greaterThan(0));
    });

    test(
      'the self-heal url test targets the pinned family group, not the '
      'contract auto group',
      () async {
        await supervisor.dispose();
        supervisor = watchdogSupervisor();
        // Always failing: every probe round reports everything dead, so the first tick
        // necessarily triggers a self-heal speed test.
        probeScript.addAll(List.filled(20, deadReport));
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(
          bridge,
          flatMultiFamilyContract(),
          PathPreference.auto,
        );
        // Pinned to relay: the self-heal speed test must no longer hit the contract's
        // default 'auto' group, which is not in use.
        supervisor.setRouteFamily('relay');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(bridge.urlTests, contains('via-relay'));
        expect(bridge.urlTests, isNot(contains('auto')));
      },
    );

    test(
      'a family locked before attach (cold start restoring a saved pin) '
      'still steers the self-heal probe once the session comes up',
      () async {
        await supervisor.dispose();
        supervisor = watchdogSupervisor();
        probeScript.addAll(List.filled(20, deadReport));
        // The real cold-start order: _loadInitialState restores _routeFamily from the
        // saved value first (no session has been attached yet), and only then, finding the
        // tunnel already connected, attaches. setRouteFamily called before attach must not
        // be silently cleared by _clearSession (attach's first step); that is the core
        // assertion for the earlier hole where the cold-start path was not synchronized.
        supervisor.setRouteFamily('relay');
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(
          bridge,
          flatMultiFamilyContract(),
          PathPreference.auto,
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(bridge.urlTests, contains('via-relay'));
        expect(bridge.urlTests, isNot(contains('auto')));
      },
    );

    test(
      'a fresh gate spends its first episode on one restart and only swaps the node on the second',
      () async {
        // This is the path a real user takes, with nothing preset: a fresh GoodputGate's
        // first confirmation of total loss, observeHardFailure remembers only one entry
        // and cannot swap, so it necessarily falls back to a restart; this is the
        // trade-off documented on _demoteDeadNode, not a bug. The restart zeroes
        // _watchdogFailures, but the fake bridge does not simulate sing-box really
        // reselecting, so the same groups snapshot is still there and effectiveNode is
        // still the same dead node: when the second confirmation finds everything lost,
        // that is the node's second hard-failure entry, the cooldown triggers, and this
        // time it really swaps and no longer restarts.
        await supervisor.dispose();
        const node = 'home-via-relay-public-hy2';
        const candidates = [
          'home-via-relay-public-reality',
          node,
          'home-via-relay-public-ss',
        ];

        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          watchdogProbe: () async {
            probeCalls++;
            return deadReport;
          },
        );
        supervisor.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };

        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups([
          OutboundGroupInfo(
            tag: 'proxy',
            type: 'selector',
            selected: 'auto',
            selectable: true,
            items: [
              const OutboundItem(tag: 'auto', type: 'urltest', delayMs: 0),
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
          OutboundGroupInfo(
            tag: 'auto',
            type: 'urltest',
            selected: node,
            selectable: false,
            items: [
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
        ]);
        await pumpEvents();

        // Episode one: cannot swap, spends one restart, and there must be no
        // selectOutbound in the meantime.
        await _waitUntil(() => restarts >= 1);
        expect(restarts, 1);
        expect(bridge.selections, isEmpty);

        // Episode two: the same dead node is confirmed a second time, so this time it
        // must swap and must not restart again.
        await _waitUntil(() => bridge.selections.isNotEmpty);
        expect(restarts, 1);
        expect(bridge.selections.last.$1, 'proxy');
        expect(bridge.selections.last.$2, isNot(node));
      },
    );

    test(
      'on the second failed confirmation swaps the node within the family and no longer restarts the tunnel',
      () async {
        await supervisor.dispose();
        const node = 'home-via-relay-public-hy2';
        const candidates = [
          'home-via-relay-public-reality',
          node,
          'home-via-relay-public-ss',
        ];
        final gate = GoodputGate();
        // GoodputGate's tracker is designed to outlive sessions (see the comment at the
        // top of goodput_gate.dart). Here an earlier hard failure is recorded directly to
        // simulate "the previous watchdog round already confirmed total loss once". The
        // next confirmation by the watchdog itself is then the second in a row and really
        // triggers the node swap, without spending a whole first "count but do nothing"
        // round in the test.
        gate.observeHardFailure(
          node: node,
          candidates: candidates,
          at: DateTime.now(),
        );

        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          goodputGate: gate,
          watchdogProbe: () async {
            probeCalls++;
            return deadReport;
          },
        );
        supervisor.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };

        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        // A flat contract (selector('proxy') -> urltest('auto') -> three members),
        // isomorphic to _groups() in GoodputGate's own unit tests: 'auto' currently
        // selects exactly the hy2 that can no longer be dialled.
        bridge.emitGroups([
          OutboundGroupInfo(
            tag: 'proxy',
            type: 'selector',
            selected: 'auto',
            selectable: true,
            items: [
              const OutboundItem(tag: 'auto', type: 'urltest', delayMs: 0),
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
          OutboundGroupInfo(
            tag: 'auto',
            type: 'urltest',
            selected: node,
            selectable: false,
            items: [
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
        ]);
        await pumpEvents();

        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(restarts, 0);
        expect(probeCalls, greaterThanOrEqualTo(2));
        expect(bridge.selections.last.$1, 'proxy');
        expect(bridge.selections.last.$2, isNot(node));
        expect(supervisor.lastDemotedFrom, node);
        expect(supervisor.lastDemotedTo, bridge.selections.last.$2);
      },
    );

    test(
      'after swapping the route itself, the next probe waits out the DNS deadline of the core',
      () async {
        // Since DoH reuses one connection: if a DoH dial is stuck on the node that was
        // just swapped out at the moment of the switch, later resolutions all wait for its
        // own deadline (the core's 10s). The watchdog probe times out after only 8s, so
        // judging the new node dead during that window would be inventing evidence.
        await supervisor.dispose();
        const node = 'home-via-relay-public-hy2';
        const candidates = [
          'home-via-relay-public-reality',
          node,
          'home-via-relay-public-ss',
        ];
        final gate = GoodputGate();
        gate.observeHardFailure(
          node: node,
          candidates: candidates,
          at: DateTime.now(),
        );
        final probeTimes = <DateTime>[];
        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          selectionSettle: const Duration(milliseconds: 300),
          goodputGate: gate,
          watchdogProbe: () async {
            probeTimes.add(DateTime.now());
            return deadReport;
          },
        );
        supervisor.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups([
          OutboundGroupInfo(
            tag: 'proxy',
            type: 'selector',
            selected: 'auto',
            selectable: true,
            items: [
              const OutboundItem(tag: 'auto', type: 'urltest', delayMs: 0),
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
          OutboundGroupInfo(
            tag: 'auto',
            type: 'urltest',
            selected: node,
            selectable: false,
            items: [
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
        ]);
        await _waitUntil(() => bridge.selections.isNotEmpty);
        final selectedAt = DateTime.now();
        await _waitUntil(() => probeTimes.any((t) => t.isAfter(selectedAt)));
        expect(
          probeTimes.firstWhere((t) => t.isAfter(selectedAt)).difference(selectedAt),
          greaterThanOrEqualTo(const Duration(milliseconds: 250)),
          reason: 'no verdict may be taken inside the DNS settle window',
        );
      },
    );

    test(
      'when the core switches legs itself (urltest re-election) it also waits out the DNS deadline before judging',
      () async {
        // After the watchdog judges the tunnel dead in its first round it triggers a
        // urlTest itself; the group moving off the dead leg is the same kind of change as
        // a route swap: internal connections are closed, but the DoH dial in progress stays
        // on the dead leg. This change does not pass through the watchdog's route command
        // and can only be seen in the group state the core reports.
        await supervisor.dispose();
        final probeTimes = <DateTime>[];
        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          selectionSettle: const Duration(milliseconds: 300),
          watchdogProbe: () async {
            probeTimes.add(DateTime.now());
            return healthyReport;
          },
          goodputProbe: () async => const GoodputSample(
            bytes: 10 << 20,
            elapsed: Duration(seconds: 1),
            reachable: true,
          ),
        );
        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups(nodeGroups('old-node'));
        await _waitUntil(() => probeTimes.length >= 2);
        bridge.emitGroups(nodeGroups('alternate'));
        await pumpEvents();
        final changedAt = DateTime.now();
        await _waitUntil(() => probeTimes.any((t) => t.isAfter(changedAt)));
        expect(
          probeTimes.firstWhere((t) => t.isAfter(changedAt)).difference(changedAt),
          greaterThanOrEqualTo(const Duration(milliseconds: 250)),
        );
        expect(bridge.selections, isEmpty, reason: 'the core changed legs, not us');
      },
    );

    test(
      'after a leg swap the data plane is re-verified healthy, the old swap record must be cleared, '
      'otherwise the next unrelated death would inherit a stale reason pointing at another node',
      () async {
        await supervisor.dispose();
        const node = 'home-via-relay-public-hy2';
        const candidates = [
          'home-via-relay-public-reality',
          node,
          'home-via-relay-public-ss',
        ];
        final gate = GoodputGate();
        gate.observeHardFailure(
          node: node,
          candidates: candidates,
          at: DateTime.now(),
        );

        var probeIsDead = true;
        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          selectionSettle: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          goodputGate: gate,
          watchdogProbe: () async {
            probeCalls++;
            return probeIsDead ? deadReport : healthyReport;
          },
        );
        supervisor.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };

        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups([
          OutboundGroupInfo(
            tag: 'proxy',
            type: 'selector',
            selected: 'auto',
            selectable: true,
            items: [
              const OutboundItem(tag: 'auto', type: 'urltest', delayMs: 0),
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
          OutboundGroupInfo(
            tag: 'auto',
            type: 'urltest',
            selected: node,
            selectable: false,
            items: [
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
        ]);
        await pumpEvents();

        // First wait for the leg swap to really happen, with the same evidence as the
        // test above.
        await _waitUntil(() => supervisor.lastDemotedFrom == node);
        expect(supervisor.lastDemotedTo, isNot(node));

        // After the swap the network recovers: the next probe round reports healthy and
        // the data plane returns to alive.
        probeIsDead = false;
        await _waitUntil(
          () => supervisor.dataPlaneHealth == DataPlaneHealth.alive,
        );

        expect(supervisor.lastDemotedFrom, isNull);
        expect(supervisor.lastDemotedTo, isNull);
      },
    );

    test(
      'ending the session (VPN disconnect) must clear the swap record so it does not carry into the next session',
      () async {
        await supervisor.dispose();
        const node = 'home-via-relay-public-hy2';
        const candidates = [
          'home-via-relay-public-reality',
          node,
          'home-via-relay-public-ss',
        ];
        final gate = GoodputGate();
        gate.observeHardFailure(
          node: node,
          candidates: candidates,
          at: DateTime.now(),
        );

        supervisor = VpnSessionSupervisor(
          networkPollInterval: Duration.zero,
          watchdogGrace: Duration.zero,
          watchdogInterval: const Duration(milliseconds: 10),
          watchdogConfirmDelay: const Duration(milliseconds: 10),
          goodputGate: gate,
          watchdogProbe: () async {
            probeCalls++;
            return deadReport;
          },
        );
        supervisor.tunnelRestartHandler = () async {
          restarts++;
          return true;
        };

        bridge.currentStatus = AuroraStatus.connected;
        await supervisor.attach(bridge, plainContract, PathPreference.auto);
        bridge.emitGroups([
          OutboundGroupInfo(
            tag: 'proxy',
            type: 'selector',
            selected: 'auto',
            selectable: true,
            items: [
              const OutboundItem(tag: 'auto', type: 'urltest', delayMs: 0),
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
          OutboundGroupInfo(
            tag: 'auto',
            type: 'urltest',
            selected: node,
            selectable: false,
            items: [
              for (final c in candidates)
                OutboundItem(tag: c, type: 'proxy', delayMs: 0),
            ],
          ),
        ]);
        await pumpEvents();

        await _waitUntil(() => supervisor.lastDemotedFrom == node);

        // VPN disconnected: the session ended, and this record from the previous session
        // must not be carried into the next one.
        bridge.emitStatus(AuroraStatus.disconnected);
        await pumpEvents();

        expect(supervisor.lastDemotedFrom, isNull);
        expect(supervisor.lastDemotedTo, isNull);
      },
    );
  });
}

/// Two-family contract in the flat shape (no paths/pathPolicy/egress): manual
/// family pinning only applies to this shape, see the comment at the top of
/// route_family.dart. Shared by the two "self-heal speed test hits the right group"
/// tests.
AuroraContract flatMultiFamilyContract() => AuroraContract(
  version: 1,
  revision: 1,
  defaultMode: 'global',
  nodes: [
    AuroraNode(
      id: 'home-direct',
      role: 'primary',
      protocol: 'shadowsocks-2022',
      server: '203.0.113.10',
      port: 8443,
      via: 'direct',
      params: const {
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'multiplex': true,
      },
    ),
    AuroraNode(
      id: 'home-via-relay',
      role: 'exit',
      protocol: 'shadowsocks-2022',
      server: '203.0.113.10',
      port: 8443,
      detour: 'relay-entry',
      via: 'relay',
      params: const {
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'multiplex': true,
      },
    ),
  ],
  outboundGroup: OutboundGroup(
    selectorTag: 'proxy',
    selectorMembers: const ['auto', 'home-direct', 'home-via-relay'],
    selectorDefault: 'auto',
    urltestTag: 'auto',
    urltestMembers: const ['home-direct', 'home-via-relay'],
    urltestUrl: '',
    urltestInterval: '',
  ),
);

const healthyReport = ConnectionProbeReport([
  ProbeResult(name: 'Google 204', category: ProbeCategory.ok, statusCode: 204),
  ProbeResult(
    name: 'Cloudflare 204',
    category: ProbeCategory.ok,
    statusCode: 204,
  ),
  ProbeResult(
    name: 'GitHub assets',
    category: ProbeCategory.ok,
    statusCode: 200,
  ),
]);

/// Every endpoint unreachable at the transport layer — the tunnel is dead.
const deadReport = ConnectionProbeReport([
  ProbeResult(name: 'Google 204', category: ProbeCategory.timeout),
  ProbeResult(name: 'Cloudflare 204', category: ProbeCategory.timeout),
  ProbeResult(name: 'GitHub assets', category: ProbeCategory.transport),
]);

/// Every endpoint connects (their names are cached), but a fresh name sent
/// straight to the tunnel's DNS got no answer.
const dnsSilentReport = ConnectionProbeReport([
  ProbeResult(name: 'Google 204', category: ProbeCategory.ok, statusCode: 204),
  ProbeResult(
    name: 'Cloudflare 204',
    category: ProbeCategory.ok,
    statusCode: 204,
  ),
  ProbeResult(
    name: 'GitHub assets',
    category: ProbeCategory.ok,
    statusCode: 200,
  ),
], tunnelDnsAnswered: false);

const dnsAnsweringReport = ConnectionProbeReport([
  ProbeResult(name: 'Google 204', category: ProbeCategory.ok, statusCode: 204),
  ProbeResult(
    name: 'Cloudflare 204',
    category: ProbeCategory.ok,
    statusCode: 204,
  ),
  ProbeResult(
    name: 'GitHub assets',
    category: ProbeCategory.ok,
    statusCode: 200,
  ),
], tunnelDnsAnswered: true);

/// One endpoint slow/broken while another still answers — NOT death.
const partialReport = ConnectionProbeReport([
  ProbeResult(name: 'Google 204', category: ProbeCategory.ok, statusCode: 204),
  ProbeResult(name: 'Cloudflare 204', category: ProbeCategory.timeout),
  ProbeResult(name: 'GitHub assets', category: ProbeCategory.transport),
]);

Future<void> pumpEvents() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

AuroraContract plainContract() => AuroraContract.fromJson(
  jsonDecode(File('test/fixtures/contract.sample.json').readAsStringSync())
      as Map<String, dynamic>,
);

List<OutboundGroupInfo> nodeGroups(String node) => [
  const OutboundGroupInfo(
    tag: 'proxy', type: 'selector', selected: 'auto', selectable: true,
    items: [
      OutboundItem(tag: 'old-node', type: 'proxy', delayMs: 1),
      OutboundItem(tag: 'alternate', type: 'proxy', delayMs: 2),
    ],
  ),
  OutboundGroupInfo(
    tag: 'auto', type: 'urltest', selected: node, selectable: false,
    items: const [
      OutboundItem(tag: 'old-node', type: 'proxy', delayMs: 1),
      OutboundItem(tag: 'alternate', type: 'proxy', delayMs: 2),
    ],
  ),
];

/// Polls until a condition becomes true instead of betting on a fixed sleep: the
/// watchdog's timing across the two episodes (restart, zero the failure count,
/// run another confirmation round) is not constant, and a fixed delay is either too
/// short or wasted waiting, whereas polling does not care about timing. Only a
/// timeout counts as failure, so it never actually hangs the test.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not satisfied within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final lease = EgressLease(
  keyId: 'home-egress-1',
  homeName: 'home.example.net',
  ipv4: '203.0.113.10',
  sequence: 12,
  issuedAt: DateTime.utc(2026, 7, 22),
  expiresAt: DateTime.utc(2099),
  signature: 'test',
);

const verified = EgressProbeReport(
  egress: EgressStatus.verified,
  category: ProbeCategory.ok,
);

List<OutboundGroupInfo> groups({
  required List<int> publicDelays,
  int tailnetBump = 0,
}) => [
  OutboundGroupInfo(
    tag: 'proxy',
    type: 'selector',
    selected: 'relay-public-auto',
    selectable: true,
    items: const [],
  ),
  pathGroup('relay-public-auto', 'public', publicDelays),
  pathGroup('relay-tailnet-auto', 'tailnet', [260 + tailnetBump, 270, 280]),
  pathGroup('home-auto', 'home', const [140, 150, 160]),
];

OutboundGroupInfo pathGroup(String tag, String prefix, List<int> delays) =>
    OutboundGroupInfo(
      tag: tag,
      type: 'urltest',
      selected: '$prefix-1',
      selectable: false,
      items: [
        for (var i = 0; i < delays.length; i++)
          OutboundItem(
            tag: '$prefix-${i + 1}',
            type: 'proxy',
            delayMs: delays[i],
          ),
      ],
    );

class SessionBridge implements AuroraBridge {
  final statusController = StreamController<AuroraStatus>.broadcast();
  final groupsController =
      StreamController<List<OutboundGroupInfo>>.broadcast();
  final urlTests = <String>[];
  final selections = <(String, String)>[];
  AuroraStatus currentStatus = AuroraStatus.disconnected;
  String? failSelectionTag;
  Future<void> Function(String group, String tag)? onSelect;

  void emitStatus(AuroraStatus status) {
    currentStatus = status;
    statusController.add(status);
  }

  void emitGroups(List<OutboundGroupInfo> groups) =>
      groupsController.add(groups);

  Future<void> close() async {
    await statusController.close();
    await groupsController.close();
  }

  @override
  Future<AuroraStatus> status() async => currentStatus;

  @override
  Stream<AuroraStatus> statusStream() => statusController.stream;

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() => groupsController.stream;

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
  Future<void> urlTest(String group) async => urlTests.add(group);

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> start(String configJson) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<String> logStream() => const Stream.empty();

  @override
  Future<TrafficStat> queryStats() async => const TrafficStat();

  @override
  Stream<TrafficStat> statsStream() => const Stream.empty();

  @override
  Future<void> openVpnSettings() async {}
}

class _RecordingLog extends PathEventLog {
  _RecordingLog(this.events) : super(enabled: false);

  final List<String> events;

  @override
  Future<void> record(
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    events.add(event);
  }
}
