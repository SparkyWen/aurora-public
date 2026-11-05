import 'dart:async';

import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/app/desktop_connection_recovery.dart';
import 'package:aurora/app/path_event_log.dart';
import 'package:aurora/app/tunnel_recovery.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/physical_network.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements AuroraBridge {
  final events = StreamController<AuroraStatus>.broadcast(sync: true);
  AuroraStatus current = AuroraStatus.connected;
  bool available = true;
  int stops = 0;
  Completer<void>? stopGate;

  void emit(AuroraStatus status) {
    current = status;
    events.add(status);
  }

  @override
  Future<AuroraStatus> status() async {
    if (!available) throw StateError('svc_status_timeout');
    return current;
  }

  @override
  Stream<AuroraStatus> statusStream() => events.stream;

  @override
  Future<void> stop() async {
    if (!available) throw StateError('svc_stop_timeout');
    stops++;
    emit(AuroraStatus.disconnecting);
    await stopGate?.future;
    emit(AuroraStatus.disconnected);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  void scenario(
    void Function(FakeAsync, _Bridge, DesktopConnectionRecovery, int Function())
    body, {
    bool failConnect = false,
    String Function()? physicalNetwork,
  }) {
    fakeAsync((clock) {
      ConnectFlow.lastBackgroundError.value = null;
      final bridge = _Bridge();
      var starts = 0;
      final recovery = TunnelRecovery(
        bridge: bridge,
        connect: () async {
          starts++;
          if (failConnect) throw StateError('svc_status_timeout');
          bridge.emit(AuroraStatus.connected);
        },
      );
      final controller = DesktopConnectionRecovery(
        bridge: bridge,
        recovery: recovery,
        // Never the real interface list inside fakeAsync: its completion
        // would land on whatever elapse() happens next, and a machine with no
        // network would silently change what these scenarios test.
        physicalNetworkSignature: () async =>
            physicalNetwork?.call() ?? 'en0:IPv4:10.0.0.2',
        pathEventLog: PathEventLog(enabled: false),
      );
      controller.start();
      clock.flushMicrotasks();
      controller.beginConnection();
      controller.endConnection();
      body(clock, bridge, controller, () => starts);
      controller.dispose();
      bridge.events.close();
      clock.flushMicrotasks();
    });
  }

  test('unexpected child exit restores a requested desktop connection', () {
    scenario((clock, bridge, controller, starts) {
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(seconds: 2));
      expect(bridge.stops, 1, reason: 'error must first confirm teardown');
      expect(starts(), 1);
      expect(bridge.current, AuroraStatus.connected);
    });
  });

  test('short service outage retries after the service comes back', () {
    scenario((clock, bridge, controller, starts) {
      bridge.available = false;
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(seconds: 2));
      expect(starts(), 0);
      bridge.available = true;
      bridge.current = AuroraStatus.disconnected;
      clock.elapse(const Duration(seconds: 5));
      expect(starts(), 1);
      expect(bridge.current, AuroraStatus.connected);
    });
  });

  test('manual disconnect or exit cancels queued recovery intent', () {
    scenario((clock, bridge, controller, starts) {
      bridge.emit(AuroraStatus.error);
      controller.stopRequested();
      bridge.emit(AuroraStatus.disconnected);
      clock.elapse(const Duration(minutes: 1));
      expect(starts(), 0);
      expect(bridge.stops, 0);
    });
  });

  test('manual disconnect cancels an in-flight stop before reconnect', () {
    scenario((clock, bridge, controller, starts) {
      bridge.stopGate = Completer<void>();
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(seconds: 2));
      controller.stopRequested();
      bridge.stopGate!.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(starts(), 0);
      expect(bridge.stops, 1);
    });
  });

  test('a new manual connection supersedes old automatic recovery', () {
    scenario((clock, bridge, controller, starts) {
      bridge.stopGate = Completer<void>();
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(seconds: 2));
      final cancelled = controller.beginConnection();
      bridge.stopGate!.complete();
      clock.flushMicrotasks();
      bridge.emit(AuroraStatus.connected);
      controller.endConnection();
      clock.elapse(const Duration(minutes: 1));
      expect(cancelled(), isFalse);
      expect(starts(), 0);
      expect(bridge.stops, 1);
    });
  });

  test(
    'failed new manual connection retains its own recovery after old stop drains',
    () {
      scenario((clock, bridge, controller, starts) {
        bridge.stopGate = Completer<void>();
        bridge.emit(AuroraStatus.error);
        clock.elapse(const Duration(seconds: 2));
        controller.beginConnection();
        controller.endConnection(status: AuroraStatus.disconnected);
        bridge.stopGate!.complete();
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 2));
        expect(starts(), 1);
      });
    },
  );

  test('three failed attempts exhaust the budget until a new user request', () {
    scenario((clock, bridge, controller, starts) {
      bridge.emit(AuroraStatus.disconnected);
      clock.elapse(const Duration(hours: 1));
      expect(starts(), 3);
      expect(ConnectFlow.lastBackgroundError.value, isNotNull);
      controller.beginConnection();
      controller.endConnection();
      clock.elapse(const Duration(seconds: 2));
      expect(starts(), 4);
    }, failConnect: true);
  });

  test('late connected status cannot revive manually cancelled intent', () {
    scenario((clock, bridge, controller, starts) {
      controller.stopRequested();
      bridge.emit(AuroraStatus.connected);
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(minutes: 1));
      expect(starts(), 0);
    });
  });

  test('briefly successful restarts still exhaust the same outage budget', () {
    scenario((clock, bridge, controller, starts) {
      for (final delay in [2, 5, 15]) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(Duration(seconds: delay));
        clock.elapse(const Duration(seconds: 1));
      }
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(hours: 1));
      expect(starts(), 3);
    });
  });

  test('two minutes of stable connection restores the recovery budget', () {
    scenario((clock, bridge, controller, starts) {
      for (final delay in [2, 5, 15]) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(Duration(seconds: delay));
      }
      clock.elapse(const Duration(seconds: 120));
      bridge.emit(AuroraStatus.error);
      clock.elapse(const Duration(seconds: 2));
      expect(starts(), 4);
    });
  });

  group('physical network outage', () {
    // Seen on a laptop: the tunnel was restarted into a Wi-Fi outage, NE refused
    // every start with "No network available", the three-round budget went in
    // 40 seconds, and when Wi-Fi returned a minute later nothing reconnected
    // for seven hours.
    const online = 'en0:IPv4:10.0.0.5';

    test('a disconnect while offline waits for the network instead of retrying', () {
      var network = physicalNetworkOffline;
      scenario((clock, bridge, controller, starts) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(const Duration(minutes: 5));
        expect(starts(), 0);
        expect(ConnectFlow.lastBackgroundError.value, contains('network'));

        network = online;
        clock.elapse(const Duration(seconds: 10));
        expect(starts(), 1);
        expect(bridge.current, AuroraStatus.connected);
        expect(ConnectFlow.lastBackgroundError.value, isNull);
      }, physicalNetwork: () => network);
    });

    test('an exhausted budget is refunded when the network comes back', () {
      var network = online;
      scenario((clock, bridge, controller, starts) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(const Duration(hours: 1));
        expect(starts(), 3, reason: 'budget exhausted while online');

        network = physicalNetworkOffline;
        clock.elapse(const Duration(seconds: 30));
        network = online;
        clock.elapse(const Duration(seconds: 10));
        expect(starts(), 4, reason: 'network return re-arms recovery');
      }, failConnect: true, physicalNetwork: () => network);
    });

    test('a different network while exhausted also re-arms recovery', () {
      var network = online;
      scenario((clock, bridge, controller, starts) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(const Duration(hours: 1));
        expect(starts(), 3);
        network = 'en0:IPv4:192.168.7.21';
        clock.elapse(const Duration(seconds: 10));
        expect(starts(), 4);
      }, failConnect: true, physicalNetwork: () => network);
    });

    test('a network drop while connected does not start recovery by itself', () {
      var network = online;
      scenario((clock, bridge, controller, starts) {
        network = physicalNetworkOffline;
        clock.elapse(const Duration(seconds: 30));
        network = online;
        clock.elapse(const Duration(seconds: 30));
        expect(starts(), 0, reason: 'the tunnel is still up; NE keeps it');
      }, physicalNetwork: () => network);
    });

    test('manual disconnect cancels the wait for the network', () {
      var network = physicalNetworkOffline;
      scenario((clock, bridge, controller, starts) {
        bridge.emit(AuroraStatus.disconnected);
        clock.elapse(const Duration(seconds: 10));
        controller.stopRequested();
        network = online;
        clock.elapse(const Duration(minutes: 1));
        expect(starts(), 0);
      }, physicalNetwork: () => network);
    });
  });
}
