import 'dart:async';

import 'package:aurora/app/desktop_shell.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

/// A minimal bridge that only answers status. Tray init needs only [status] and
/// [statusStream]; reporting `connected` makes `autoConnectOnLaunch` return
/// immediately, so the test makes no network calls and starts no timers.
class _StubBridge implements AuroraBridge {
  @override
  Future<AuroraStatus> status() async => AuroraStatus.connected;

  @override
  Stream<AuroraStatus> statusStream() => const Stream<AuroraStatus>.empty();

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> start(String configJson) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<String> logStream() => const Stream<String>.empty();

  @override
  Future<TrafficStat> queryStats() async => const TrafficStat();

  @override
  Stream<TrafficStat> statsStream() => const Stream<TrafficStat>.empty();

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() =>
      const Stream<List<OutboundGroupInfo>>.empty();

  @override
  Future<void> selectOutbound(String group, String tag) async {}

  @override
  Future<void> urlTest(String group) async {}

  @override
  Future<void> openVpnSettings() async {}
}

class _RecoveryBridge extends _StubBridge {
  AuroraStatus current = AuroraStatus.connected;
  int stopCalls = 0;
  int prepareCalls = 0;
  int statusCalls = 0;
  bool statusFails = false;
  final stopGate = Completer<void>();

  @override
  Future<AuroraStatus> status() async {
    statusCalls++;
    if (statusFails) throw StateError('svc_status_timeout');
    return current;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    current = AuroraStatus.disconnecting;
    await stopGate.future;
  }

  @override
  Future<bool> prepare() async {
    prepareCalls++;
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tray toggle during teardown cancels recovery without a new start', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge();
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      tray.restartTunnel();
      clock.flushMicrotasks();
      tray.handleStatus(AuroraStatus.disconnecting);
      tray.onTrayMenuItemClick(MenuItem(key: 'toggle', label: 'Stay disconnected'));
      clock.flushMicrotasks();
      expect(bridge.prepareCalls, 0);
      bridge.current = AuroraStatus.disconnected;
      bridge.stopGate.complete();
      clock.elapse(const Duration(minutes: 1));
      expect(bridge.prepareCalls, 0);
      tray.connections.dispose();
    });
  });

  test('launch waits for an already disconnecting native tunnel', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge()..current = AuroraStatus.disconnecting;
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      expect(bridge.prepareCalls, 0);
      tray.connections.dispose();
    });
  });

  test('queued desktop recovery respects a completed manual disconnect', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge()..current = AuroraStatus.disconnected;
      AuroraTray(bridge).restartTunnel();
      clock.flushMicrotasks();
      expect(bridge.stopCalls, 0);
      expect(bridge.prepareCalls, 0);
    });
  });

  test('concurrent desktop recovery requests stop the tunnel once', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge();
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      tray.restartTunnel();
      clock.flushMicrotasks();
      tray.restartTunnel();
      clock.flushMicrotasks();
      expect(bridge.stopCalls, 1);
    });
  });

  test('desktop teardown timeout never begins another connection', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge()..stopGate.complete();
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      tray.restartTunnel();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 31));
      expect(bridge.prepareCalls, 0);
    });
  });

  test('tray disconnect cancels recovery waiting for teardown', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge();
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      tray.handleStatus(AuroraStatus.connected);
      tray.restartTunnel();
      clock.flushMicrotasks();
      tray.onTrayMenuItemClick(MenuItem(key: 'toggle', label: 'Disconnect'));
      clock.flushMicrotasks();
      bridge.current = AuroraStatus.disconnected;
      bridge.stopGate.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
      expect(bridge.prepareCalls, 0);
    });
  });

  test('manual cancellation also stops the queued launch retry', () {
    fakeAsync((clock) {
      final bridge = _RecoveryBridge()..current = AuroraStatus.disconnected;
      final tray = AuroraTray(bridge);
      tray.autoConnectOnLaunch();
      clock.flushMicrotasks();
      expect(bridge.prepareCalls, 1);
      tray.cancelRecovery();
      clock.elapse(const Duration(minutes: 1));
      expect(bridge.prepareCalls, 1);
    });
  });

  test(
    'launch while the helper is offline still schedules bounded recovery',
    () {
      fakeAsync((clock) {
        final bridge = _RecoveryBridge()..statusFails = true;
        final tray = AuroraTray(bridge);
        tray.connections.start();
        tray.autoConnectOnLaunch();
        clock.flushMicrotasks();
        final initialQueries = bridge.statusCalls;
        clock.elapse(const Duration(seconds: 2));
        expect(bridge.statusCalls, greaterThan(initialQueries));
        tray.connections.dispose();
        clock.flushMicrotasks();
      });
    },
  );

  const trayChannel = MethodChannel('tray_manager');

  /// Installs a fake tray_manager plugin and records the names of the methods called.
  List<String> recordTrayCalls() {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trayChannel, (call) async {
          calls.add(call.method);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trayChannel, null),
    );
    return calls;
  }

  test('tray init does not throw when the plugin is missing methods', () async {
    // No plugin is registered in the test environment, so every channel call throws
    // MissingPluginException, the same class of failure seen on real Linux:
    // tray_manager's Linux implementation only has
    // destroy/setIcon/setTitle/setContextMenu, and setToolTip does not exist. The
    // exception propagated from AuroraTray.init to the await in main(), runApp never
    // ran, and the user saw a completely black window.
    await AuroraTray(_StubBridge()).init();
    await pumpEventQueue();
  });

  test('Linux shows status with setTitle and never calls the unimplemented setToolTip', () async {
    final calls = recordTrayCalls();

    await AuroraTray(_StubBridge(), isLinux: true).init();
    await pumpEventQueue();

    expect(calls, contains('setIcon'));
    expect(calls, contains('setContextMenu'));
    expect(calls, contains('setTitle'));
    expect(calls, isNot(contains('setToolTip')));
  });

  test('non-Linux desktops still use setToolTip', () async {
    final calls = recordTrayCalls();

    await AuroraTray(_StubBridge(), isLinux: false).init();
    await pumpEventQueue();

    expect(calls, contains('setToolTip'));
    expect(calls, isNot(contains('setTitle')));
  });

  test('status changes produce no uncaught async exceptions', () async {
    // The menu rebuild and status text in _onStatus are fire-and-forget Futures: when
    // the plugin is missing they become async exceptions nobody catches, which is
    // equally fatal in Flutter.
    final tray = AuroraTray(_StubBridge());
    await tray.init();

    tray.handleStatus(AuroraStatus.connecting);
    tray.handleStatus(AuroraStatus.connected);
    tray.handleStatus(AuroraStatus.error);
    await pumpEventQueue();
  });

  test('desktop shell init does not throw as a whole (window plugin missing too)', () async {
    // initDesktopShell is awaited before runApp: any exception it throws is a black screen.
    await initDesktopShell(_StubBridge());
    await pumpEventQueue();
  });
}
