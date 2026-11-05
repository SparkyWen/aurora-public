import 'dart:async';

import 'package:aurora/app/vpn_session_supervisor.dart';
import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/data/connection_probe.dart';
import 'package:aurora/features/connect/connect_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_session_supervisor_test.dart'
    show SessionBridge, flatMultiFamilyContract, healthyReport, deadReport;

void main() {
  testWidgets('click during native teardown only cancels automatic recovery', (
    tester,
  ) async {
    final bridge = _DisconnectingBridge()
      ..currentStatus = AuroraStatus.disconnecting;
    final supervisor = VpnSessionSupervisor(networkPollInterval: Duration.zero);
    var cancellations = 0;
    supervisor.cancelTunnelRestartHandler = () => cancellations++;
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectPage(bridge: bridge, supervisor: supervisor),
      ),
    );
    ConnectFlow.latestOutcome.value = ConnectOutcome(
      contract: flatMultiFamilyContract(),
      mode: AuroraMode.global,
      pathPreference: PathPreference.auto,
      configId: List.filled(64, 'b').join(),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.power_off));
    await tester.pump();
    expect(bridge.prepares, 0);
    expect(cancellations, 1);
    await tester.pumpWidget(const SizedBox());
    ConnectFlow.latestOutcome.value = null;
    await tester.runAsync(supervisor.dispose);
    await tester.runAsync(bridge.close);
  });
  testWidgets('background connect outcome updates the mounted page identity', (
    tester,
  ) async {
    final bridge = SessionBridge();
    final supervisor = VpnSessionSupervisor(networkPollInterval: Duration.zero);
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectPage(bridge: bridge, supervisor: supervisor),
      ),
    );
    ConnectFlow.latestOutcome.value = ConnectOutcome(
      contract: flatMultiFamilyContract(),
      mode: AuroraMode.global,
      pathPreference: PathPreference.auto,
      configId: List.filled(64, 'a').join(),
    );
    await tester.pump();
    expect(find.textContaining('Config aaaaaaaaaaaa'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ConnectFlow.latestOutcome.value = null;
    await tester.runAsync(supervisor.dispose);
    await tester.runAsync(bridge.close);
  });

  testWidgets('healthy watchdog report replaces an earlier timeout summary', (
    tester,
  ) async {
    final bridge = SessionBridge();
    var report = deadReport;
    final supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      watchdogGrace: Duration.zero,
      watchdogInterval: const Duration(milliseconds: 50),
      watchdogConfirmDelay: const Duration(milliseconds: 50),
      watchdogProbe: () async => report,
    );
    bridge.currentStatus = AuroraStatus.connected;
    await tester.runAsync(
      () => supervisor.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      ),
    );
    addTearDown(() async {
      await supervisor.dispose();
      await bridge.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectPage(bridge: bridge, supervisor: supervisor),
      ),
    );
    await tester.runAsync(
      () => _waitFor(() => supervisor.latestConnectionReport != null),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Network check failed: connection timed out'), findsOneWidget);
    report = healthyReport;
    await tester.runAsync(
      () => _waitFor(() => supervisor.latestConnectionReport?.healthy == true),
    );
    await tester.pump();
    expect(find.text('Network check failed: connection timed out'), findsNothing);
    expect(find.text(healthyReport.summary), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('family change invalidates a pending old-path summary', (
    tester,
  ) async {
    final bridge = SessionBridge();
    final pending = Completer<ConnectionProbeReport>();
    final supervisor = VpnSessionSupervisor(
      networkPollInterval: Duration.zero,
      watchdogGrace: Duration.zero,
      watchdogInterval: const Duration(seconds: 30),
      watchdogProbe: () => pending.future,
    );
    bridge.currentStatus = AuroraStatus.connected;
    await tester.runAsync(
      () => supervisor.attach(
        bridge,
        flatMultiFamilyContract(),
        PathPreference.auto,
      ),
    );
    addTearDown(() async {
      await supervisor.dispose();
      await bridge.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectPage(bridge: bridge, supervisor: supervisor),
      ),
    );
    await tester.pump();
    supervisor.setRouteFamily('relay');
    pending.complete(deadReport);
    await tester.pump();
    expect(find.text('Network check failed: connection timed out'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

class _DisconnectingBridge extends SessionBridge {
  int prepares = 0;

  @override
  Future<bool> prepare() async {
    prepares++;
    return false;
  }
}

Future<void> _waitFor(bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 2)) {
      fail('probe did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
