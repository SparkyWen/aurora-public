// Developer-only physical-device target. Build with --release
// --target tool/device_connection_smoke.dart and
// --dart-define=AURORA_EXPECTED_EGRESS=<current household IPv4>.
// Reinstall the ordinary lib/main.dart target after collecting the report.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/app/vpn_session_supervisor.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/aurora_bridge_factory.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/data/connection_probe.dart';

const _expectedEgress = String.fromEnvironment('AURORA_EXPECTED_EGRESS');
final _display = ValueNotifier<String>('Preparing on-device network verification…');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Aurora on-device verification')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ValueListenableBuilder<String>(
            valueListenable: _display,
            builder: (_, value, _) => SelectableText(value),
          ),
        ),
      ),
    ),
  );
  unawaited(_DeviceSmoke().run());
}

class _DeviceSmoke {
  final _bridge = createAuroraBridge();
  final _clock = Stopwatch();
  final _events = <Map<String, Object?>>[];
  File? _reportFile;
  Future<void> _writeTail = Future<void>.value();
  bool _cancelled = false;
  bool _finished = false;
  bool _allPassed = true;
  String _stage = 'prepare_report';

  Future<void> run() async {
    _clock.start();
    try {
      await _body().timeout(const Duration(seconds: 150));
    } catch (error) {
      _allPassed = false;
      _cancelled = true;
      await _record('failure', {
        'stage': _stage,
        // Raw native exceptions may contain endpoint/config data.
        'error_type': error.runtimeType.toString(),
      });
    } finally {
      _cancelled = true;
      try {
        await _stopConfirmed().timeout(const Duration(seconds: 25));
        await _record('final_stop', {'confirmed': true});
      } catch (error) {
        _allPassed = false;
        await _record('final_stop', {
          'confirmed': false,
          'error_type': error.runtimeType.toString(),
        });
      }
      _finished = true;
      await _record('complete', {'passed': _allPassed});
    }
  }

  Future<void> _body() async {
    final directory = await getApplicationDocumentsDirectory();
    _reportFile = File('${directory.path}/aurora-device-smoke.json');
    await _record('begin', {
      'build': const String.fromEnvironment(
        'AURORA_BUILD_ID',
        defaultValue: 'device-smoke',
      ),
      'expected_egress_configured': _expectedEgress.isNotEmpty,
    });
    if (InternetAddress.tryParse(_expectedEgress)?.type !=
        InternetAddressType.IPv4) {
      throw StateError('expected_egress_required');
    }
    _stage = 'initial_stop';
    await _stopConfirmed().timeout(const Duration(seconds: 25));
    final first = await _start('first_start');
    final nodes =
        first.contract.nodes
            .where((node) => node.id.startsWith('home-via-relay-'))
            .map((node) => node.id)
            .toList()
          ..sort();
    await _record('relay_inventory', {'node_count': nodes.length});
    if (nodes.length != 6) throw StateError('expected_six_relay_outbounds');
    final selector = first.contract.outboundGroup.selectorTag;
    await _probe(selector, 'via-relay');
    for (final node in nodes) {
      await _probe(selector, node);
    }
    _checkActive();
    _stage = 'cycle_stop';
    await _stopConfirmed().timeout(const Duration(seconds: 25));
    await _record('cycle_stop', {'confirmed': true});
    final second = await _start('second_start');
    await _probe(second.contract.outboundGroup.selectorTag, 'via-relay');
  }

  Future<ConnectOutcome> _start(String stage) async {
    _checkActive();
    _stage = stage;
    if (!await _bridge.prepare().timeout(const Duration(seconds: 12))) {
      throw StateError('permission_denied');
    }
    _checkActive();
    final outcome = await ConnectFlow.compileAndStart(
      _bridge,
      isCancelled: () => _cancelled,
    ).timeout(const Duration(seconds: 40));
    _checkActive();
    final status = await _bridge.status().timeout(const Duration(seconds: 3));
    if (status != AuroraStatus.connected) throw StateError('start_unconfirmed');
    final supervisor = VpnSessionSupervisor.instance;
    supervisor.setRouteFamily('relay');
    // Full startup above exercises the real supervisor/bootstrap. During the
    // concrete-node sweep, prevent automatic goodput/failover from changing
    // the selected outbound underneath an in-flight measurement.
    await supervisor.detachAfterVpnStopped();
    _checkActive();
    await _record(stage, {
      'connected': true,
      'config_sha256': outcome.configId,
    });
    return outcome;
  }

  Future<void> _probe(String selector, String tag) async {
    _checkActive();
    _stage = 'probe:$tag';
    await _record('probe_started', {'tag': tag});
    try {
      await _bridge
          .selectOutbound(selector, tag)
          .timeout(const Duration(seconds: 11));
      _checkActive();
      final reports = await Future.wait<Object>([
        ConnectionProbeService.run(
          perRequestTimeout: const Duration(seconds: 8),
          totalBudget: const Duration(seconds: 8),
        ),
        ConnectionProbeService.runEgress(
          expectedIpv4: _expectedEgress,
          timeout: const Duration(seconds: 8),
        ),
      ]).timeout(const Duration(seconds: 10));
      _checkActive();
      final network = reports[0] as ConnectionProbeReport;
      final egress = reports[1] as EgressProbeReport;
      final passed = network.healthy && egress.egress == EgressStatus.verified;
      _allPassed = _allPassed && passed;
      await _record('probe_result', {
        'tag': tag,
        'selected_confirmed': true,
        'passed': passed,
        'https_healthy': network.healthy,
        'egress': egress.egress.name,
        'egress_category': egress.category.name,
        'checks': [
          for (final result in network.results)
            {
              'name': result.name,
              'category': result.category.name,
              'http_status': result.statusCode,
            },
        ],
      });
    } catch (error) {
      _checkActive();
      _allPassed = false;
      await _record('probe_error', {
        'tag': tag,
        'error_type': error.runtimeType.toString(),
      });
    }
  }

  Future<void> _stopConfirmed() async {
    final clock = Stopwatch()..start();
    await VpnSessionSupervisor.instance.detachAfterVpnStopped().timeout(
      const Duration(seconds: 3),
    );
    await _bridge.stop().timeout(const Duration(seconds: 8));
    while (clock.elapsed < const Duration(seconds: 20)) {
      final remaining = const Duration(seconds: 20) - clock.elapsed;
      final status = await _bridge.status().timeout(
        remaining < const Duration(seconds: 3)
            ? remaining
            : const Duration(seconds: 3),
      );
      if (status == AuroraStatus.disconnected) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException('stop_unconfirmed');
  }

  void _checkActive() {
    if (_cancelled) throw StateError('smoke_cancelled');
  }

  Future<void> _record(String event, Map<String, Object?> details) {
    final row = <String, Object?>{
      'event': event,
      'elapsed_ms': _clock.elapsedMilliseconds,
      ...details,
    };
    _events.add(row);
    final report = const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'finished': _finished,
      'passed': _finished && _allPassed,
      'events': _events,
    });
    _display.value = report;
    debugPrint('AURORA_DEVICE_SMOKE ${jsonEncode(row)}');
    _writeTail = _writeTail.catchError((Object _) {}).then((_) async {
      final file = _reportFile;
      if (file == null) return;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(report, flush: true);
      await temporary.rename(file.path);
    });
    return _writeTail;
  }
}
