import 'dart:async';

import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/app/tunnel_recovery.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RecoveryBridge bridge;
  late int starts;

  setUp(() {
    bridge = RecoveryBridge();
    starts = 0;
    ConnectFlow.lastBackgroundError.value = null;
  });

  test('mobile recovery waits for teardown before reconnecting', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        expect(bridge.currentStatus, AuroraStatus.disconnected);
        starts++;
      },
      pollInterval: const Duration(milliseconds: 1),
    );
    final recovering = recovery.restart();
    await bridge.stopped.future;
    expect(starts, 0);
    bridge.currentStatus = AuroraStatus.disconnected;
    expect(await recovering, isTrue);
    expect(starts, 1);
  });

  test('concurrent watchdog requests perform one stop and start', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
      pollInterval: const Duration(milliseconds: 1),
    );
    final first = recovery.restart();
    await bridge.stopped.future;
    expect(await recovery.restart(), isFalse);
    bridge.currentStatus = AuroraStatus.disconnected;
    expect(await first, isTrue);
    expect(bridge.stopCalls, 1);
    expect(starts, 1);
  });

  test('teardown timeout never starts over an outgoing tunnel', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
      stopTimeout: const Duration(milliseconds: 15),
      pollInterval: const Duration(milliseconds: 1),
    );
    expect(await recovery.restart(), isTrue);
    expect(starts, 0);
    expect(ConnectFlow.lastBackgroundError.value, isNotNull);
  });

  test('manual disconnection before queued recovery is respected', () async {
    bridge.currentStatus = AuroraStatus.disconnected;
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
    );
    expect(await recovery.restart(), isFalse);
    expect(bridge.stopCalls, 0);
    expect(starts, 0);
  });

  test('a stop error status does not confirm teardown', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
      stopTimeout: const Duration(milliseconds: 15),
      pollInterval: const Duration(milliseconds: 1),
    );
    final pending = recovery.restart();
    await bridge.stopped.future;
    bridge.currentStatus = AuroraStatus.error;
    expect(await pending, isTrue);
    expect(starts, 0);
  });

  test('manual connect excludes an automatic restart', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
    );
    await ConnectFlow.runExclusive(() async {
      expect(await recovery.restart(), isFalse);
    });
    expect(bridge.stopCalls, 0);
  });

  test('cancel during teardown never reconnects', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      connect: () async {
        starts++;
      },
      pollInterval: const Duration(milliseconds: 1),
    );
    final pending = recovery.restart();
    await bridge.stopped.future;
    recovery.cancel();
    bridge.currentStatus = AuroraStatus.disconnected;
    expect(await pending, isTrue);
    expect(starts, 0);
    expect(ConnectFlow.lastBackgroundError.value, isNull);
  });

  test('paused app does not initiate a recovery stop', () async {
    final recovery = TunnelRecovery(
      bridge: bridge,
      canRecover: () => false,
      connect: () async {
        starts++;
      },
    );
    expect(await recovery.restart(), isFalse);
    expect(bridge.stopCalls, 0);
    expect(starts, 0);
  });

  for (final waitFor in ['stop', 'disconnection']) {
    test('pausing while waiting for $waitFor skips recovery prepare', () async {
      var foreground = true;
      bridge.stopGate = Completer<void>();
      bridge.teardownStatus = Completer<AuroraStatus>();
      final recovery = TunnelRecovery(
        bridge: bridge,
        canRecover: () => foreground,
      );
      final pending = recovery.restart();
      await bridge.stopped.future;
      if (waitFor == 'disconnection') {
        bridge.stopGate!.complete();
        await bridge.teardownQueried.future;
      }

      foreground = false;
      if (waitFor == 'stop') bridge.stopGate!.complete();
      bridge.teardownStatus!.complete(AuroraStatus.disconnected);

      expect(await pending, isTrue, reason: 'the old tunnel was stopped');
      expect(bridge.stopCalls, 1);
      expect(bridge.prepareCalls, 0);
      expect(ConnectFlow.lastBackgroundError.value, isNull);
      expect(recovery.isBusy, isFalse);
    });
  }
}

class RecoveryBridge implements AuroraBridge {
  AuroraStatus currentStatus = AuroraStatus.connected;
  int stopCalls = 0;
  int prepareCalls = 0;
  final stopped = Completer<void>();
  Completer<void>? stopGate;
  Completer<AuroraStatus>? teardownStatus;
  final teardownQueried = Completer<void>();

  @override
  Future<AuroraStatus> status() async {
    if (stopCalls > 0 && teardownStatus != null) {
      teardownQueried.complete();
      return teardownStatus!.future;
    }
    return currentStatus;
  }

  @override
  Future<bool> prepare() async {
    prepareCalls++;
    return false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    currentStatus = AuroraStatus.disconnecting;
    stopped.complete();
    await stopGate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
