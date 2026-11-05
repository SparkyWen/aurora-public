import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/app/path_health_coordinator.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/egress_lease.dart';
import 'package:aurora/app/tunnel_recovery.dart';
import 'package:aurora/app/vpn_session_supervisor.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/mobile_session_control.dart';
import 'package:aurora/core/path_health.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'vpn_session_supervisor_test.dart'
    show SessionBridge, flatMultiFamilyContract, verified, lease, healthyReport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileBridge bridge;
  setUp(() {
    bridge = MobileBridge();
    ConnectFlow.lastBackgroundError.value = null;
  });
  tearDown(() async {
    await VpnSessionSupervisor.instance.detachAfterVpnStopped();
    await bridge.close();
  });
  test(
    'mobile recovery reloads the existing session without prepare or system restart',
    () async {
      await VpnSessionSupervisor.instance.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      );
      final acted = await TunnelRecovery(bridge: bridge).restart();
      expect(acted, true);
      expect(bridge.reloads, ['session-1']);
      expect(bridge.prepares, 0);
      expect(bridge.stops, 0);
      expect(bridge.starts, 0);
    },
  );
  test('mobile unavailable session never reacquires VPN permission', () async {
    bridge.sessionId = null;
    final acted = await TunnelRecovery(bridge: bridge).restart();
    expect(acted, false);
    expect(bridge.prepares, 0);
    expect(bridge.stops, 0);
    expect(bridge.reloads, isEmpty);
  });
  test(
    'reload revalidates household lease and releases fail-closed through a fresh coordinator',
    () async {
      var leaseRefreshes = 0;
      final supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: Duration.zero,
        coordinatorFactory: (b) => PathHealthCoordinator(
          bridge: b,
          healthInterval: Duration.zero,
          startupGracePeriod: Duration.zero,
          probe: (_, _) async => verified,
          refreshLease: (_, _) async {
            leaseRefreshes++;
            return lease;
          },
        ),
      );
      final contract = AuroraContract.fromJson(
        jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      await supervisor.attach(bridge, contract, PathPreference.auto);
      expect(leaseRefreshes, 1);
      bridge.onReload = () {
        bridge.selections.clear();
      };
      try {
        expect(
          await TunnelRecovery(
            bridge: bridge,
            supervisor: supervisor,
          ).restart(),
          true,
        );
        expect(leaseRefreshes, 2);
        expect(bridge.selections.last, ('proxy', 'relay-public-auto'));
        expect(supervisor.hasActiveSession, true);
      } finally {
        await supervisor.dispose();
      }
    },
  );
  test(
    'external stop during reload rejects its late reply and never starts a new VPN',
    () async {
      await VpnSessionSupervisor.instance.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      );
      bridge.reloadGate = Completer<MobileReloadResult>();
      final recovery = TunnelRecovery(bridge: bridge);
      final pending = recovery.restart();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bridge.reloads, ['session-1']);
      bridge.emitStatus(AuroraStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bridge.reloadGate!.complete(MobileReloadResult.reloaded);
      await pending;
      expect(bridge.prepares, 0);
      expect(bridge.starts, 0);
      expect(bridge.stops, 0);
      expect(ConnectFlow.lastBackgroundError.value, isNull);
      expect(VpnSessionSupervisor.instance.hasActiveSession, false);
    },
  );
  test('paused mobile app does not reload a core', () async {
    expect(
      await TunnelRecovery(bridge: bridge, canRecover: () => false).restart(),
      false,
    );
    expect(bridge.reloads, isEmpty);
    expect(bridge.prepares, 0);
  });
  test('concurrent mobile watchdog requests share one native reload', () async {
    await VpnSessionSupervisor.instance.attach(
      bridge,
      flatMultiFamilyContract(),
      PathPreference.auto,
    );
    bridge.reloadGate = Completer<MobileReloadResult>();
    final recovery = TunnelRecovery(bridge: bridge);
    final first = recovery.restart();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await recovery.restart(), false);
    bridge.reloadGate!.complete(MobileReloadResult.reloaded);
    expect(await first, true);
    expect(bridge.reloads.length, 1);
    expect(bridge.prepares, 0);
  });
  test(
    'native failure asks for explicit reconnect without reclaiming VPN',
    () async {
      await VpnSessionSupervisor.instance.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      );
      bridge.reloadGate = Completer<MobileReloadResult>()
        ..complete(MobileReloadResult.requiresReconnect);
      expect(await TunnelRecovery(bridge: bridge).restart(), true);
      expect(ConnectFlow.lastBackgroundError.value, contains('manually'));
      expect(bridge.prepares, 0);
      expect(bridge.starts, 0);
    },
  );
  test(
    'timed-out native reload cannot apply a late successful reply',
    () async {
      await VpnSessionSupervisor.instance.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      );
      bridge.reloadGate = Completer<MobileReloadResult>();
      final recovery = TunnelRecovery(
        bridge: bridge,
        stopTimeout: const Duration(milliseconds: 15),
      );
      expect(await recovery.restart(), true);
      expect(recovery.isBusy, false);
      expect(ConnectFlow.lastBackgroundError.value, contains('manually'));
      bridge.reloadGate!.complete(MobileReloadResult.reloaded);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bridge.prepares, 0);
      expect(bridge.starts, 0);
      expect(bridge.selections, isEmpty);
    },
  );
  test('reload waits for the retired coordinator selector RPC', () async {
    final supervisor = pathSupervisor();
    await supervisor.attach(bridge, pathContract(), PathPreference.auto);
    final gate = Completer<void>();
    final entered = Completer<void>();
    bridge.onSelect = (_, _) async {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    };
    final selecting = supervisor.setPreference(PathPreference.homeDirect);
    await entered.future;
    final recovering = TunnelRecovery(
      bridge: bridge,
      supervisor: supervisor,
    ).restart();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(bridge.reloads, isEmpty);
    gate.complete();
    await selecting;
    bridge.onSelect = null;
    expect(await recovering, true);
    expect(bridge.reloads.length, 1);
    expect(bridge.selections.last, ('proxy', 'home-auto'));
    await supervisor.dispose();
  });
  test(
    'background during selector drain restores supervision without a core reload',
    () async {
      var probes = 0;
      final supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: const Duration(milliseconds: 20),
        watchdogGrace: Duration.zero,
        watchdogProbe: () async {
          probes++;
          return healthyReport;
        },
        coordinatorFactory: (b) => PathHealthCoordinator(
          bridge: b,
          healthInterval: Duration.zero,
          startupGracePeriod: Duration.zero,
          probe: (_, _) async => verified,
          refreshLease: (_, _) async => lease,
        ),
      );
      await supervisor.attach(bridge, pathContract(), PathPreference.auto);
      final gate = Completer<void>();
      final entered = Completer<void>();
      bridge.onSelect = (_, _) async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
      };
      final selecting = supervisor.setPreference(PathPreference.homeDirect);
      await entered.future;
      var foreground = true;
      final recovery = TunnelRecovery(
        bridge: bridge,
        supervisor: supervisor,
        canRecover: () => foreground,
      );
      final pending = recovery.restart();
      try {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(bridge.reloads, isEmpty);
        foreground = false;
        gate.complete();
        await selecting;
        bridge.onSelect = null;
        expect(await pending, false);
        expect(bridge.reloads, isEmpty);
        expect(bridge.prepares + bridge.starts + bridge.stops, 0);
        expect(supervisor.hasActiveSession, true);
        expect(supervisor.latest?.selectedGroup, 'home-auto');
        final before = probes;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          probes,
          greaterThan(before),
          reason: 'the still-running TUN must retain its watchdog',
        );
        await supervisor.setPreference(PathPreference.auto);
        expect(bridge.selections.last, ('proxy', 'relay-public-auto'));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await pending;
        await supervisor.dispose();
      }
    },
  );
  for (final invalidation in ['replacement', 'disconnected', 'manual']) {
    test(
      'cancelled background reload cannot restore $invalidation session',
      () async {
        final supervisor = pathSupervisor();
        await supervisor.attach(bridge, pathContract(), PathPreference.auto);
        final selectorGate = Completer<void>();
        final selectingEntered = Completer<void>();
        bridge.onSelect = (_, _) async {
          if (!selectingEntered.isCompleted) selectingEntered.complete();
          await selectorGate.future;
        };
        final selecting = supervisor.setPreference(PathPreference.homeDirect);
        await selectingEntered.future;
        final snapshotEntered = Completer<void>();
        final snapshotReply = Completer<MobileSessionSnapshot>();
        var snapshots = 0;
        bridge.onSnapshot = () async {
          if (++snapshots == 1) {
            return const MobileSessionSnapshot(
              status: AuroraStatus.connected,
              sessionId: 'session-1',
            );
          }
          snapshotEntered.complete();
          return snapshotReply.future;
        };
        var foreground = true;
        final recovery = TunnelRecovery(
          bridge: bridge,
          supervisor: supervisor,
          canRecover: () => foreground,
        );
        final pending = recovery.restart();
        try {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          foreground = false;
          selectorGate.complete();
          await selecting;
          bridge.onSelect = null;
          await snapshotEntered.future.timeout(const Duration(seconds: 2));
          final selections = bridge.selections.length;
          if (invalidation == 'manual') recovery.cancel();
          snapshotReply.complete(
            MobileSessionSnapshot(
              status: invalidation == 'disconnected'
                  ? AuroraStatus.disconnected
                  : AuroraStatus.connected,
              sessionId: invalidation == 'replacement'
                  ? 'session-2'
                  : 'session-1',
            ),
          );
          await pending;
          expect(bridge.reloads, isEmpty);
          expect(bridge.prepares + bridge.starts + bridge.stops, 0);
          expect(bridge.selections.length, selections);
          expect(supervisor.hasActiveSession, false);
          expect(ConnectFlow.lastBackgroundError.value, isNull);
        } finally {
          if (!selectorGate.isCompleted) selectorGate.complete();
          if (!snapshotReply.isCompleted) {
            snapshotReply.complete(
              const MobileSessionSnapshot(
                status: AuroraStatus.disconnected,
                sessionId: null,
              ),
            );
          }
          await pending;
          await supervisor.dispose();
        }
      },
    );
  }
  test(
    'reload never releases fail-closed after household lease validation fails',
    () async {
      var refreshes = 0;
      final supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: Duration.zero,
        coordinatorFactory: (b) => PathHealthCoordinator(
          bridge: b,
          healthInterval: Duration.zero,
          startupGracePeriod: Duration.zero,
          probe: (_, _) async => verified,
          refreshLease: (_, _) async {
            if (++refreshes > 1) throw StateError('lease_auth_failed');
            return lease;
          },
        ),
      );
      await supervisor.attach(bridge, pathContract(), PathPreference.auto);
      bridge.onReload = () => bridge.selections.clear();
      await TunnelRecovery(bridge: bridge, supervisor: supervisor).restart();
      expect(refreshes, 2);
      expect(
        bridge.selections.every(
          (item) => item.$2 == auroraFailClosedOutboundTag,
        ),
        true,
      );
      expect(supervisor.latest?.blocked, true);
      await supervisor.dispose();
    },
  );
  for (final manualCancel in [false, true]) {
    test(
      'failed native teardown preserves actionable result, manual=$manualCancel',
      () async {
        final supervisor = pathSupervisor();
        await supervisor.attach(bridge, pathContract(), PathPreference.auto);
        bridge.reloadGate = Completer<MobileReloadResult>();
        final recovery = TunnelRecovery(bridge: bridge, supervisor: supervisor);
        final pending = recovery.restart();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (manualCancel) recovery.cancel();
        bridge.emitStatus(AuroraStatus.disconnected);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bridge.reloadGate!.complete(MobileReloadResult.requiresReconnect);
        await pending;
        expect(
          ConnectFlow.lastBackgroundError.value,
          manualCancel ? isNull : contains('manually'),
        );
        expect(supervisor.hasActiveSession, false);
        expect(bridge.starts + bridge.stops + bridge.prepares, 0);
        await supervisor.dispose();
      },
    );
  }
  test(
    'reload replaces in-flight activation without waiting for an obsolete lease',
    () async {
      final initialLease = Completer<EgressLease>();
      final entered = Completer<void>();
      var refreshes = 0;
      final supervisor = VpnSessionSupervisor(
        networkPollInterval: Duration.zero,
        watchdogInterval: Duration.zero,
        coordinatorFactory: (b) => PathHealthCoordinator(
          bridge: b,
          healthInterval: Duration.zero,
          startupGracePeriod: Duration.zero,
          probe: (_, _) async => verified,
          refreshLease: (_, _) async {
            if (++refreshes == 1) {
              entered.complete();
              return await initialLease.future;
            }
            return lease;
          },
        ),
      );
      final attaching = supervisor.attach(
        bridge,
        pathContract(),
        PathPreference.auto,
      );
      await entered.future;
      try {
        expect(
          await TunnelRecovery(
            bridge: bridge,
            supervisor: supervisor,
          ).restart(),
          true,
        );
        expect(refreshes, 2);
        expect(supervisor.hasActiveSession, true);
        expect(bridge.selections.last, ('proxy', 'relay-public-auto'));
      } finally {
        initialLease.complete(lease);
        await attaching;
        await supervisor.dispose();
      }
    },
  );
  test(
    'native unavailable after retiring paths requires an explicit reconnect',
    () async {
      final supervisor = pathSupervisor();
      await supervisor.attach(bridge, pathContract(), PathPreference.auto);
      bridge.reloadGate = Completer<MobileReloadResult>()
        ..complete(MobileReloadResult.unavailable);
      await TunnelRecovery(bridge: bridge, supervisor: supervisor).restart();
      expect(bridge.currentStatus, AuroraStatus.connected);
      expect(ConnectFlow.lastBackgroundError.value, contains('manually'));
      expect(bridge.starts + bridge.stops + bridge.prepares, 0);
      await supervisor.dispose();
    },
  );
  for (final mobile in [true, false]) {
    test('initial terminal retry respects mobile=$mobile', () async {
      final raw =
          jsonDecode(
                File('test/fixtures/contract.sample.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      raw['delivery'] = <String, dynamic>{};
      FlutterSecureStorage.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'Aurora',
        packageName: 'test.aurora',
        version: '1.9.18',
        buildNumber: '42',
        buildSignature: '',
      );
      rootBundle.evict('assets/configs/aurora-contract.json');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            'flutter/assets',
            (message) async => ByteData.sublistView(
              Uint8List.fromList(utf8.encode(jsonEncode(raw))),
            ),
          );
      bridge.failStarts = true;
      bridge.mobileRecovery = mobile;
      try {
        await expectLater(
          ConnectFlow.compileAndStart(bridge, mode: AuroraMode.global),
          throwsA(isA<StateError>()),
        );
        expect(bridge.starts, mobile ? 1 : 2);
        expect(bridge.stops, mobile ? 0 : 1);
      } finally {
        rootBundle.evict('assets/configs/aurora-contract.json');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMessageHandler('flutter/assets', null);
      }
    });
  }
}

AuroraContract pathContract() => AuroraContract.fromJson(
  jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
      as Map<String, dynamic>,
);
VpnSessionSupervisor pathSupervisor() => VpnSessionSupervisor(
  networkPollInterval: Duration.zero,
  watchdogInterval: Duration.zero,
  coordinatorFactory: (bridge) => PathHealthCoordinator(
    bridge: bridge,
    healthInterval: Duration.zero,
    startupGracePeriod: Duration.zero,
    probe: (_, _) async => verified,
    refreshLease: (_, _) async => lease,
  ),
);

class MobileBridge extends SessionBridge implements AuroraMobileSessionControl {
  MobileBridge() {
    currentStatus = AuroraStatus.connected;
  }
  @override
  bool get usesMobileSessionRecovery => mobileRecovery;
  bool mobileRecovery = true;
  String? sessionId = 'session-1';
  int prepares = 0, stops = 0, starts = 0;
  bool failStarts = false;
  final reloads = <String>[];
  Completer<MobileReloadResult>? reloadGate;
  void Function()? onReload;
  Future<MobileSessionSnapshot> Function()? onSnapshot;
  @override
  Future<MobileSessionSnapshot> sessionSnapshot() async =>
      await onSnapshot?.call() ??
      MobileSessionSnapshot(status: currentStatus, sessionId: sessionId);
  @override
  Future<MobileReloadResult> reloadCurrentSession(String id) async {
    reloads.add(id);
    onReload?.call();
    return await reloadGate?.future ?? MobileReloadResult.reloaded;
  }

  @override
  Future<bool> prepare() async {
    prepares++;
    return false;
  }

  @override
  Future<void> stop() async {
    stops++;
    emitStatus(AuroraStatus.disconnected);
  }

  @override
  Future<void> start(String configJson) async {
    starts++;
    if (failStarts) {
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        emitStatus(AuroraStatus.connecting);
        Future<void>.delayed(
          const Duration(milliseconds: 10),
          () => emitStatus(AuroraStatus.disconnected),
        );
      });
    }
  }
}
