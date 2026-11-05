/// The body of `aurora-cli`. **Pure Dart** (see `cli_options.dart`): `lib/cli/` must
/// never import `package:flutter/*`, or `dart build cli` cannot produce this binary
/// that runs without a display.
///
/// It shares one core with the GUI: `ConfigCompiler` compiles, `AuroraBridgeSvc` talks
/// to aurora-svc, and `route_family.dart` decides the default route. Only two things
/// differ, both deliberately:
///
/// 1. **Contract storage.** The GUI uses `flutter_secure_storage` (libsecret), whose
///    keyring is usually locked in an SSH session. The CLI keeps its own user-owned
///    cache file instead.
/// 2. **Session supervision.** The GUI keeps health-checking and failing over after
///    connecting. The CLI connects and exits, leaving the tunnel to aurora-svc, so it
///    connects a **pinned** route that never switches on its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import '../core/aurora_bridge.dart';
import '../core/aurora_bridge_svc.dart';
import '../core/config_compiler.dart';
import '../core/contract.dart';
import '../core/route_family.dart';
import '../core/server_bundle.dart';
import '../core/svc_paths.dart';
import '../core/windows_paths.dart';
import 'cli_contract_source.dart';
import 'cli_options.dart';


/// One contract load: the contract, where it came from, and how to promote it to the
/// local last-known-good once connected. Same rule as the GUI: promote only **after**
/// connecting, so a failure never overwrites a contract known to work.
class CliContractLoad {
  const CliContractLoad(this.contract, this.source, {this.promote});

  final AuroraContract contract;
  final String source;
  final Future<void> Function()? promote;
}

/// Which group `--line` means. Null means this contract has no such route.
///
/// [resolveDefaultRouteTarget] answers "where is the default"; this answers "where is
/// the thing the user named", and hands over to the former when nothing was named.
AuroraRouteTarget? resolveCliRouteTarget(String? line, AuroraContract contract) {
  if (line == null) return resolveDefaultRouteTarget(contract);

  final paths = contract.paths;
  if (paths != null) {
    if (line == auroraAutoRouteSelection) {
      final preferred = paths.items[paths.preferred];
      if (preferred == null) return null;
      return AuroraRouteTarget(
        groupTag: preferred.groupTag,
        label: 'preferred path ${paths.preferred}',
        isPreferred: true,
      );
    }
    final exact = paths.items[line];
    if (exact != null) {
      return AuroraRouteTarget(
        groupTag: exact.groupTag,
        label: 'path $line',
        isPreferred: true,
      );
    }
    // Shorthand such as `--line relay`: multi-path contracts name these paths
    // relay_public and relay_tailnet.
    //
    // The order is preferred, then fallback order, then the rest, not the map order:
    // `--line relay` must land on the path the contract prefers, not on whichever key
    // happens to come first in the JSON.
    final ordered = <String>{
      paths.preferred,
      ...?contract.pathPolicy?.fallbackOrder,
      ...paths.items.keys,
    };
    for (final pathId in ordered) {
      final path = paths.items[pathId];
      if (path == null || !pathId.startsWith(line)) continue;
      return AuroraRouteTarget(
        groupTag: path.groupTag,
        label: 'path $pathId',
        isPreferred: true,
      );
    }
    return null;
  }

  if (line == auroraAutoRouteSelection) {
    return AuroraRouteTarget(
      groupTag: contract.outboundGroup.urltestTag,
      label: 'automatic selection (lowest latency across routes)',
      isPreferred: true,
    );
  }
  // Someone with one server may well name it. There is no group per family then, because
  // `auto` is exactly that server, so naming it is not an error.
  if (contract.routeFamilies.length == 1 && contract.routeFamilies.single == line) {
    return AuroraRouteTarget(
      groupTag: contract.outboundGroup.urltestTag,
      label: routeFamilyLabel(line),
      isPreferred: true,
    );
  }
  // Only families the compiled config really has a group for: selecting a tag that
  // does not exist can only fail.
  if (!renderableRouteFamilies(contract).contains(line)) return null;
  return AuroraRouteTarget(
    groupTag: routeFamilyGroupTag(line),
    label: routeFamilyLabel(line),
    isPreferred: true,
    family: line,
  );
}

const _usage = '''
aurora - command line

Usage:
  aurora [connect] [options]   Connect
  aurora disconnect            Disconnect
  aurora status [--json]       Show state
  aurora import '<link>'       Add a server (the aurora:// link from install.sh)
  aurora servers               List added servers
  aurora remove <name>         Remove a server
  aurora version               Show the version
  aurora help                  Show this text

Options:
  --mode global|smart   Override the default global mode
  --line <route|auto>   Override the default route; auto picks by latency
  --contract <file>     Use this contract file, skipping refresh
  --no-refresh          Use the local contract without contacting a control plane
  --timeout <seconds>   How long to wait for the tunnel (default 30)
  --json                Machine-readable output (status)

Notes:
  aurora-svc (a systemd service) holds the tunnel, so it keeps running after this
  command exits. A route connected from here is pinned: unlike the GUI, it does not
  fail over on its own.
''';

/// Exit codes: 0 success, 1 runtime failure, 2 usage error.
class AuroraCliApp {
  AuroraCliApp({
    required this.bridge,
    required this.loadContract,
    required this.out,
    this.contractSource,
    this.ruleSetPaths = const {},
    this.version = '0.0.0',
    this.pollInterval = const Duration(milliseconds: 250),
  });

  final AuroraBridge bridge;
  final Future<CliContractLoad> Function() loadContract;
  final void Function(String line) out;

  /// Local server management (`import`, `servers`, `remove`).
  final CliContractSource? contractSource;

  /// `.srs` paths for smart mode (tag to absolute path). Unused in global mode.
  final Map<String, String> ruleSetPaths;

  /// The installed package's version (printed by `aurora version`). See
  /// `cli_install.dart`.
  final String version;

  final Duration pollInterval;

  Future<int> run(AuroraCliOptions options) async {
    final error = options.error;
    if (error != null) {
      out('Error: $error');
      out('');
      out(_usage);
      return 2;
    }
    switch (options.verb) {
      case AuroraCliVerb.help:
        out(_usage);
        return 0;
      case AuroraCliVerb.version:
        out('aurora $version');
        return 0;
      case AuroraCliVerb.status:
        return _status(options);
      case AuroraCliVerb.disconnect:
        return _disconnect();
      case AuroraCliVerb.connect:
        return _connect(options);
      case AuroraCliVerb.import:
        return _import(options.arguments);
      case AuroraCliVerb.servers:
        return _servers();
      case AuroraCliVerb.remove:
        return _remove(options.arguments.first);
    }
  }

  int _import(List<String> links) {
    final source = contractSource;
    if (source == null) return _noSource();
    try {
      final added = source.importText(links.join('\n'));
      out('Added: ${added.join(', ')}');
      out('Connect with: aurora connect');
      return 0;
    } on AuroraLinkException catch (error) {
      out('Could not add that: ${error.message}');
      return 2;
    }
  }

  int _servers() {
    final source = contractSource;
    if (source == null) return _noSource();
    final servers = source.listServers();
    if (servers.isEmpty) {
      out("No servers yet. Run: aurora import '<link from install.sh>'");
      return 0;
    }
    for (final server in servers) {
      out('${server.group}  ${server.host}  (${server.nodeCount} nodes)');
    }
    return 0;
  }

  int _remove(String name) {
    final source = contractSource;
    if (source == null) return _noSource();
    if (!source.removeServer(name)) {
      out('No server named "$name". See: aurora servers');
      return 2;
    }
    out('Removed $name.');
    return 0;
  }

  int _noSource() {
    out('Server management is not available in this build.');
    return 1;
  }

  /// Called out on its own because the raw form (`SocketException: connection
  /// refused`) means nothing to someone who just typed `aurora connect`.
  static const _svcDown =
      'aurora-svc is not running, so the local privileged service '
      '(127.0.0.1:53421) cannot be reached.\n'
      '  sudo systemctl status aurora-svc\n'
      '  sudo systemctl start aurora-svc';

  Future<int> _status(AuroraCliOptions options) async {
    final AuroraStatus status;
    try {
      status = await bridge.status();
    } catch (error) {
      out(_svcDown);
      out('(Original error: $error)');
      return 1;
    }
    if (options.json) {
      out(jsonEncode({
        'state': status.name,
        'detail': ?_failureDetail(),
      }));
      return 0;
    }
    out('State: ${_statusLabel(status)}');
    final detail = _failureDetail();
    if (detail != null) out('Last failure: $detail');
    return 0;
  }

  Future<int> _disconnect() async {
    try {
      await bridge.stop();
    } catch (error) {
      out('Disconnect failed: $error');
      return 1;
    }
    out('Disconnected.');
    return 0;
  }

  Future<int> _connect(AuroraCliOptions options) async {
    if (!await bridge.prepare()) {
      out(_svcDown);
      return 1;
    }

    final CliContractLoad load;
    try {
      load = await loadContract();
    } catch (error) {
      out('Could not read the contract: $error');
      return 1;
    }
    final contract = load.contract;

    final target = resolveCliRouteTarget(options.line, contract);
    if (target == null) {
      final available = contract.paths != null
          ? contract.paths!.items.keys.toList()
          : contract.routeFamilies;
      out('This contract has no route "${options.line}". Available: ${[...available, auroraAutoRouteSelection].join(', ')}');
      return 2;
    }

    final mode = options.mode ?? resolveAuroraMode(null, contract);
    if (mode == AuroraMode.smart && ruleSetPaths.isEmpty) {
      out('Smart mode needs rule set files, which were not found (assets/rule_sets in the package).');
      out('Use --mode global, or repair the installation.');
      return 1;
    }

    out('Contract: ${load.source} (revision ${contract.revision})');
    out('Mode: ${mode == AuroraMode.global ? 'global' : 'smart'}    '
        'Route: ${target.label} -> ${target.groupTag}');

    // Tear down an existing tunnel first: a failure such as "previous tunnel is still
    // up" means nothing to someone who just typed connect.
    if (await _currentStatus() == AuroraStatus.connected) {
      out('A tunnel is already running. Reconnecting with these settings.');
      try {
        await bridge.stop();
      } catch (error) {
        out('Could not stop the old tunnel: $error');
        return 1;
      }
    }

    String? clashSecret;
    var clashPort = 9090;
    final svc = bridge;
    if (svc is AuroraBridgeSvc) {
      // Same reason as the GUI: 9090 is the default port of Clash, mihomo and v2rayN,
      // and sing-box exits outright when it cannot bind.
      clashSecret = WindowsPaths.randomSecret();
      clashPort = await pickFreeLoopbackPort();
      svc.clashSecret = clashSecret;
      svc.clashPort = clashPort;
    }

    final String configJson;
    try {
      configJson = jsonEncode(
        ConfigCompiler.compile(
          contract,
          mode: mode,
          platform: _platform,
          ruleSetPaths: mode == AuroraMode.smart ? ruleSetPaths : const {},
          clashApiSecret: clashSecret,
          clashApiPort: clashPort,
        ),
      );
    } catch (error) {
      out('This contract does not compile: $error');
      return 1;
    }

    try {
      await bridge.start(configJson);
    } catch (error) {
      out('Start was refused: $error');
      final detail = _failureDetail();
      if (detail != null) out('Service said: $detail');
      return 1;
    }

    if (!await _awaitConnected(options.timeout)) {
      out('The tunnel did not become ready within ${options.timeout.inSeconds}s.');
      final detail = _failureDetail();
      if (detail != null) out('Service said: $detail');
      out('To investigate: journalctl -u aurora-svc -n 50, /var/lib/aurora/logs/sing-box.log');
      return 1;
    }

    // Not optional. A flat contract's selector starts on `auto`, a urltest across every
    // route, and a multi-path contract starts on `fail-closed`, which blocks everything.
    // The GUI has PathHealthCoordinator for this; the CLI has to name the target itself.
    try {
      await bridge.selectOutbound(contract.outboundGroup.selectorTag, target.groupTag);
    } catch (error) {
      out('The tunnel is up, but the route could not be confirmed: $error');
      out('The route in use right now is unknown. Run aurora disconnect and retry.');
      return 1;
    }

    if (!target.isPreferred) out('Note: using ${target.label}.');
    out('Connected. aurora-svc holds the tunnel, so it stays up after this command exits.');
    out('Check your exit: curl -s https://ipinfo.io/json');
    try {
      await load.promote?.call();
    } catch (_) {
      // Failing to cache the contract does not affect this connection.
    }
    return 0;
  }

  AuroraPlatform get _platform =>
      Platform.isWindows ? AuroraPlatform.windows : AuroraPlatform.linux;

  Future<AuroraStatus> _currentStatus() async {
    try {
      return await bridge.status();
    } catch (_) {
      return AuroraStatus.disconnected;
    }
  }

  /// Polls until connected. A terminal error stops immediately: that is not "not ready
  /// yet", it already failed.
  Future<bool> _awaitConnected(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final status = await _currentStatus();
      if (status == AuroraStatus.connected) return true;
      if (status == AuroraStatus.error) return false;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(pollInterval);
    }
  }

  String? _failureDetail() {
    final svc = bridge;
    if (svc is! AuroraBridgeSvc) return null;
    final detail = svc.lastFailureDetail?.trim();
    return (detail == null || detail.isEmpty) ? null : detail;
  }

  String _statusLabel(AuroraStatus status) => switch (status) {
    AuroraStatus.connected => 'connected',
    AuroraStatus.connecting => 'connecting',
    AuroraStatus.disconnecting => 'disconnecting',
    AuroraStatus.disconnected => 'disconnected',
    AuroraStatus.error => 'error',
  };
}
