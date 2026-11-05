import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/connect_flow.dart';
import '../../core/aurora_bridge.dart';
import '../../core/aurora_bridge_factory.dart';
import '../../core/aurora_bridge_svc.dart';
import '../../core/aurora_svc_client.dart';
import '../../core/contract.dart';
import '../../core/path_health.dart';
import '../../data/connection_probe.dart';
import '../../data/contract_repository.dart';
import '../../data/egress_lease_repository.dart';

class DiagnosticReport {
  DiagnosticReport._(this.data);

  static const ninePaths = [
    'home-via-relay-public-reality',
    'home-via-relay-public-hy2',
    'home-via-relay-public-ss',
    'home-via-relay-tailnet-reality',
    'home-via-relay-tailnet-hy2',
    'home-via-relay-tailnet-ss',
    'home-reality',
    'home-hy2',
    'home-ss',
  ];

  final Map<String, dynamic> data;

  factory DiagnosticReport.build({
    required String expectedIpv4,
    required Map<String, String> pathStatus,
    required bool egressVerified,
    required String dnsStatus,
    required String ipv6Status,
    required int mtu,
    required String udpBlockStatus,
    required String githubAssetsStatus,
    String throughputStatus = 'not-run-manual-only',
    String leaseStatus = 'unavailable',
    String? leaseKeyId,
    int? leaseSequence,
    String? leaseSequenceSuffix,
    String leaseExpiryStatus = 'unknown',
    ConnectionProbeReport? connectionProbe,
    EgressProbeReport? egressProbe,
  }) {
    final egressHash = sha256
        .convert(utf8.encode(expectedIpv4))
        .toString()
        .substring(0, 12);
    return DiagnosticReport._({
      'schema': 1,
      'paths': {
        for (final path in ninePaths) path: pathStatus[path] ?? 'pending',
      },
      'egress': {
        'verified': egressVerified,
        'egress_hash': egressHash,
        if (egressProbe != null) 'category': egressProbe.category.name,
        if (egressProbe?.category == ProbeCategory.tls &&
            egressProbe?.tlsFailure != null)
          'tls_failure': egressProbe!.tlsFailure!.name,
      },
      if (connectionProbe != null)
        'connection': {
          'healthy': connectionProbe.healthy,
          'category': connectionProbe.category.name,
          'probes': connectionProbe.diagnosticResults,
        },
      'lease': {
        'status': leaseStatus,
        'key_id': leaseKeyId ?? 'unavailable',
        'sequence_suffix':
            leaseSequenceSuffix ?? _sequenceSuffix(leaseSequence),
        'expiry': leaseExpiryStatus,
      },
      'dns': dnsStatus,
      'ipv6': ipv6Status,
      'mtu': mtu,
      'udp_block': udpBlockStatus,
      'github_assets': githubAssetsStatus,
      'throughput': throughputStatus,
      'challenge_sample': {
        'site': 'itdog.cn',
        'mode': 'manual_only',
        'automated': false,
      },
    });
  }

  String toSanitizedJson() =>
      const JsonEncoder.withIndent('  ').convert(sanitizeDiagnosticValue(data));

  DiagnosticReport withThroughputStatus(String status) =>
      DiagnosticReport._({...data, 'throughput': status});

  static String _sequenceSuffix(int? sequence) {
    if (sequence == null) return 'unavailable';
    final value = sequence.toString();
    return value.length <= 4
        ? value.padLeft(4, '0')
        : value.substring(value.length - 4);
  }
}

dynamic sanitizeDiagnosticValue(dynamic value, {String key = ''}) {
  final lowered = key.toLowerCase();
  if (RegExp(
    r'password|private.?key|token|uuid|certificate|signature|secret',
  ).hasMatch(lowered)) {
    return '<redacted>';
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): sanitizeDiagnosticValue(
          entry.value,
          key: entry.key.toString(),
        ),
    };
  }
  if (value is List) {
    return value.map((item) => sanitizeDiagnosticValue(item)).toList();
  }
  if (value is String) {
    return value
        .replaceAll(RegExp(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'), '<ipv4>')
        .replaceAll(
          RegExp(
            r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
          ),
          '<uuid>',
        );
  }
  return value;
}

/// All the citable evidence of a failed connection; a pure function, unit-testable.
///
/// **Never includes the compiled config itself** — it holds real UUIDs / passwords / keys. The fingerprint
/// (sha256) is enough to answer "which one was running", the only question that needs the config. This function
/// only concatenates strings and never touches `dart:io` (including not reading `Platform` — that is host environment too, and `platform`
/// is passed in by the caller): all I/O and platform detection are left to the caller, so it can be covered by unit tests,
/// and so a test can check what the output looks like for a platform other than the host's.
String buildSupportBundle({
  required String appVersion,
  required String platform,
  required String svcState,
  required String? lastFailureDetail,
  required String logTail,
  required String configSha256,
  String? networkState,
  DiagnosticReport? diagnosticReport,
}) {
  final buffer = StringBuffer()
    ..writeln('# Aurora diagnostics')
    ..writeln('app: $appVersion')
    ..writeln('platform: $platform')
    ..writeln('svc state: $svcState')
    ..writeln('config sha256: ${configSha256.isEmpty ? "(not connected)" : configSha256}')
    ..writeln()
    ..writeln('## Most recent failure reason')
    ..writeln(lastFailureDetail ?? '(none)');
  // "Shows connected but nothing loads" cannot be seen from inside the app: the basis for "connected" is only that
  // sing-box's Clash API answered, which proves the process is up and does not prove the system actually handed
  // traffic to it. This section is the local network as seen from the privileged side — whether the virtual adapter exists, and which other
  // adapters are competing for the default route (a Hyper-V/WSL virtual switch, another VPN, a cable that is up but has no internet).
  // It contains no secrets, so the whole section can be shared as a screenshot.
  if (networkState != null && networkState.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Local network state (aurora-svc /diagnose)')
      ..writeln(networkState.trim());
  }
  buffer
    ..writeln()
    ..writeln('## sing-box log tail')
    ..writeln(logTail.isEmpty ? '(empty)' : logTail);
  if (diagnosticReport != null) {
    buffer
      ..writeln()
      ..writeln('## Network probes (redacted)')
      ..writeln(diagnosticReport.toSanitizedJson());
  }
  return buffer.toString();
}

/// Reads aurora-svc's service state and failure detail.
///
/// **Never throws**: not being able to reach the service (`aurora-svc` not running / blocked by a firewall) is exactly the
/// state the user is trying to diagnose — this step failing must become a readable sentence and not be thrown, otherwise
/// it would take down the log tail the caller can still read afterwards, which has nothing to do with this HTTP request (see the
/// former bug in [_DiagnosticsPageState._exportDiagnostics]: one try wrapped all the
/// sources, a throw from an earlier source skipped all the later ones, the ready-made sing-box log on disk was
/// discarded with them, and no file was written at the very moment an export mattered most).
///
/// [client] is only for unit tests to inject fake HTTP behaviour; in production a real [AuroraSvcClient] is
/// built on demand from `bridge.paths.readSvcToken`.
@visibleForTesting
Future<({String state, String? detail})> readSvcStatusInfo(
  AuroraBridgeSvc bridge, {
  AuroraSvcClient? client,
}) async {
  String? ownDetail() {
    final detail = bridge.lastFailureDetail?.trim();
    return detail != null && detail.isNotEmpty ? detail : null;
  }

  try {
    final c = client ?? AuroraSvcClient(token: bridge.paths.readSvcToken);
    final status = await c.status();
    return (
      state: status.state,
      detail: ownDetail() ?? (status.detail.isEmpty ? null : status.detail),
    );
  } catch (e) {
    return (state: '(cannot connect to aurora-svc: $e)', detail: ownDetail());
  }
}

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final AuroraBridge _bridge = createAuroraBridge();
  StreamSubscription<List<OutboundGroupInfo>>? _groupsSub;
  AuroraContract? _contract;
  List<OutboundGroupInfo> _groups = const [];
  DiagnosticReport? _report;
  bool _running = false;
  bool _exporting = false;
  String? _bundlePath;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    ContractRepository.load()
        .then((contract) {
          if (mounted) setState(() => _contract = contract);
        })
        .catchError((_) {});
    _groupsSub = _bridge.groupsStream().listen((groups) {
      if (mounted) setState(() => _groups = groups);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _groupsSub?.cancel();
    super.dispose();
  }

  Future<void> _runDiagnostics() async {
    final AuroraContract contract;
    try {
      contract = _contract ?? await ContractRepository.load();
    } on NoContractException {
      // Nothing to diagnose before a server exists; the first-run screen explains.
      if (mounted) setState(() => _exportError = 'Add a server first.');
      return;
    }
    final egressPolicy = contract.egress;
    setState(() => _running = true);
    // Single-path contracts (the deployed home-direct one) have no egress/lease
    // section, but the user opening diagnostics still wants the connectivity
    // probe. Run it and report egress/lease as unavailable rather than silently
    // doing nothing.
    if (egressPolicy == null) {
      final connection = await ConnectionProbeService.run();
      final github = connection.results
          .where((result) => result.name == 'GitHub assets')
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _contract = contract;
        _running = false;
        _report = DiagnosticReport.build(
          expectedIpv4: 'n/a',
          pathStatus: _pathStatus(_groups),
          egressVerified: false,
          dnsStatus: connection.category == ProbeCategory.dns
              ? 'fail'
              : (connection.healthy ? 'pass' : 'indeterminate'),
          ipv6Status: contract.network.ipv6Mode == AuroraIpv6Mode.block
              ? 'blocked-by-policy'
              : 'native-enabled',
          mtu: contract.network.mtu,
          udpBlockStatus: _udpStatus(_groups),
          githubAssetsStatus: github?.reachable == true ? 'pass' : 'fail',
          leaseStatus: 'unavailable',
          connectionProbe: connection,
        );
      });
      return;
    }
    final connection = await ConnectionProbeService.run();
    final leaseRepository = EgressLeaseRepository();
    final lease = egressPolicy.hasSignedLease
        ? await leaseRepository.loadValid(egressPolicy)
        : null;
    await leaseRepository.close();
    final expectedIpv4 = egressPolicy.hasSignedLease
        ? lease?.ipv4
        : egressPolicy.expectedIpv4;
    final egress = expectedIpv4 == null
        ? const EgressProbeReport(
            egress: EgressStatus.unknown,
            category: ProbeCategory.transport,
            transportFailure: true,
          )
        : await ConnectionProbeService.runEgress(expectedIpv4: expectedIpv4);
    final pathStatus = _pathStatus(_groups);
    final github = connection.results
        .where((result) => result.name == 'GitHub assets')
        .firstOrNull;
    if (!mounted) return;
    setState(() {
      _contract = contract;
      _running = false;
      _report = DiagnosticReport.build(
        expectedIpv4: expectedIpv4 ?? egressPolicy.expectedIpv4,
        pathStatus: pathStatus,
        egressVerified: egress.egress == EgressStatus.verified,
        dnsStatus: connection.category == ProbeCategory.dns
            ? 'fail'
            : (connection.healthy ? 'pass' : 'indeterminate'),
        ipv6Status: contract.network.ipv6Mode == AuroraIpv6Mode.block
            ? 'blocked-by-policy'
            : 'native-enabled',
        mtu: contract.network.mtu,
        udpBlockStatus: _udpStatus(_groups),
        githubAssetsStatus: github?.reachable == true ? 'pass' : 'fail',
        leaseStatus: egressPolicy.hasSignedLease
            ? (lease == null ? 'invalid' : 'valid')
            : 'unavailable',
        leaseKeyId: lease?.keyId ?? egressPolicy.leaseKeyId,
        leaseSequence: lease?.sequence,
        leaseExpiryStatus: _leaseExpiryStatus(lease?.expiresAt),
        connectionProbe: connection,
        egressProbe: egress,
      );
    });
  }

  Future<void> _runThroughput() async {
    final report = _report;
    final contract = _contract;
    if (report == null || contract?.egress == null) return;
    setState(() => _running = true);
    String status;
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.parse('https://speed.cloudflare.com/__down?bytes=1048576'))
          .timeout(const Duration(seconds: 20));
      stopwatch.stop();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        final mbps =
            response.bodyBytes.length *
            8 /
            stopwatch.elapsedMicroseconds.clamp(1, 1 << 62) *
            1000000 /
            1000000;
        status = '${mbps.toStringAsFixed(1)}-mbps-manual';
      } else {
        status = 'http-${response.statusCode}-manual';
      }
    } catch (_) {
      status = 'failed-manual';
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report.withThroughputStatus(status);
    });
  }

  /// Export a diagnostics evidence file that can be shared or pasted directly. The assembly itself is in [buildSupportBundle]
  /// (a pure function, unit-testable); this does only the platform-dependent I/O — reading service/log, writing the file.
  ///
  /// The three desktop platforms read "service state" from different places: Windows/Linux go through aurora-svc's
  /// HTTP `/status` ([readSvcStatusInfo], never throws); macOS has no such helper
  /// (it uses the NE extension), so it can only fall back to the generic `AuroraBridge.status()`, and the log tail becomes the extension's
  /// own `/tmp/aurora-ext.log` (`ConnectFlow.startFailureReason` uses
  /// the same file — see that function's comment).
  ///
  /// **Each source has its own fallback; they do not share one try**: an earlier version put all sources in one
  /// try block, and `aurora-svc` being unreachable (the very reason this feature exists — the user is diagnosing
  /// exactly that state) would throw at the service-state read and skip the disk log tail below, which should
  /// have been read as usual and has nothing to do with this HTTP request; the whole export ended up as a generic error,
  /// **with not a single file written** — failing exactly when this button should work. Now any
  /// one source failing only turns itself into a readable placeholder, without affecting the other fields or
  /// the file finally being written.
  Future<void> _exportDiagnostics() async {
    setState(() {
      _exporting = true;
      _exportError = null;
      _bundlePath = null;
    });
    try {
      String appVersion;
      try {
        final package = await PackageInfo.fromPlatform();
        appVersion = '${package.version}+${package.buildNumber}';
      } catch (e) {
        appVersion = '(failed to read version: $e)';
      }

      final bridge = _bridge;
      String svcState;
      String? lastFailureDetail;
      String logTail;
      String? networkState;
      if (bridge is AuroraBridgeSvc) {
        final info = await readSvcStatusInfo(bridge);
        svcState = info.state;
        lastFailureDetail = info.detail;
        // Whether the HTTP request above failed or not does not affect this line: the log is on disk and does not go through
        // aurora-svc's `/status` endpoint.
        logTail = await _tailFile(bridge.paths.singBoxLogPath);
        // Also each with its own fallback: `diagnose()` swallows every exception itself and returns null (see
        // AuroraSvcClient), so an unreachable service only makes this section absent and does not take other fields down.
        networkState = await bridge.diagnose();
      } else if (Platform.isMacOS) {
        try {
          svcState = (await bridge.status()).name;
        } catch (e) {
          svcState = '(cannot read state: $e)';
        }
        lastFailureDetail = null;
        logTail = await _tailFile('/tmp/aurora-ext.log');
      } else {
        // Mobile has no such privileged service / extension log to read; the export still works, those two blocks are just left empty.
        try {
          svcState = (await bridge.status()).name;
        } catch (e) {
          svcState = '(cannot read state: $e)';
        }
        lastFailureDetail = null;
        logTail = '';
      }

      final bundle = buildSupportBundle(
        appVersion: appVersion,
        platform:
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        svcState: svcState,
        lastFailureDetail: lastFailureDetail,
        logTail: logTail,
        networkState: networkState,
        // Never pass the config itself — only the fingerprint ConnectFlow computed at compile time; the config JSON itself
        // never left that call stack in connect_flow.dart.
        configSha256: ConnectFlow.lastConfigSha256 ?? '',
        diagnosticReport: _report,
      );

      // By here, all the evidence obtainable has been put into the bundle — even if every source above
      // failed, the bundle itself honestly says "none of it could be read", which is a useful
      // diagnostic conclusion in itself. The only thing that can still fail is "where to write": if it cannot be written there is truly no file
      // to hand over, and only then is the whole export allowed to report an error.
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(
        RegExp('[:.]'),
        '-',
      );
      final file = File(
        '${dir.path}${Platform.pathSeparator}aurora-diagnostics-$stamp.txt',
      );
      await file.writeAsString(bundle);
      if (!mounted) return;
      setState(() => _bundlePath = file.path);
    } catch (e) {
      if (mounted) setState(() => _exportError = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The last [maxLines] lines; a missing or unreadable file just returns an empty string — a diagnostics export must not crash because of
  /// a missing log file or a permissions problem.
  static Future<String> _tailFile(String path, {int maxLines = 200}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return '';
      final lines = await file.readAsLines();
      final tail = lines.length <= maxLines
          ? lines
          : lines.sublist(lines.length - maxLines);
      return tail.join('\n');
    } catch (_) {
      return '';
    }
  }

  static Map<String, String> _pathStatus(List<OutboundGroupInfo> groups) {
    final result = <String, String>{};
    for (final group in groups) {
      if (group.tag != 'relay-public-auto' &&
          group.tag != 'relay-tailnet-auto' &&
          group.tag != 'home-auto') {
        continue;
      }
      for (final item in group.items) {
        if (DiagnosticReport.ninePaths.contains(item.tag)) {
          result[item.tag] = item.delayMs > 0 ? 'pass' : 'fail-or-untested';
        }
      }
    }
    return result;
  }

  static String _udpStatus(List<OutboundGroupInfo> groups) {
    for (final group in groups) {
      for (final item in group.items) {
        if (item.tag.endsWith('-hy2')) {
          return item.delayMs > 0 ? 'not-detected' : 'possible-or-untested';
        }
      }
    }
    return 'pending';
  }

  static String _leaseExpiryStatus(DateTime? expiresAt) {
    if (expiresAt == null) return 'unknown';
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) return 'expired';
    if (remaining >= const Duration(hours: 1)) return 'valid-for-over-60m';
    return 'valid-for-under-60m';
  }

  @override
  Widget build(BuildContext context) {
    final text = _report?.toSanitizedJson();
    return Scaffold(
      appBar: AppBar(title: const Text('Connection diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Local checks only; no telemetry is uploaded. Full IPs, UUIDs, tokens and keys never go into the report.'),
          const SizedBox(height: 8),
          const Text('itdog.cn: the challenge is completed manually only; Aurora never submits the page or CAPTCHA for you.'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _runDiagnostics,
            icon: const Icon(Icons.health_and_safety),
            label: Text(_running ? 'Checking…' : 'Run quick diagnostics'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _running || _report == null ? null : _runThroughput,
            icon: const Icon(Icons.speed),
            label: const Text('Run optional 1 MiB throughput test'),
          ),
          if (text != null) ...[
            const SizedBox(height: 16),
            SelectableText(text),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy redacted report'),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Export the evidence of this failure as a file — service state, log tail, config fingerprint (no real credentials) — to share as a screenshot or send to someone who can look at this machine.'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _exporting ? null : _exportDiagnostics,
            icon: const Icon(Icons.bug_report),
            label: Text(_exporting ? 'Exporting…' : 'Export diagnostics'),
          ),
          if (_bundlePath != null) ...[
            const SizedBox(height: 8),
            Text('Written to:', style: Theme.of(context).textTheme.bodySmall),
            SelectableText(_bundlePath!),
          ],
          if (_exportError != null) ...[
            const SizedBox(height: 8),
            Text(_exportError!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
