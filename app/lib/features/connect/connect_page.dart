import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/connect_flow.dart';
import '../../app/desktop_connection_recovery.dart';
import '../../app/path_event_log.dart';
import '../../app/path_health_coordinator.dart';
import '../../app/route_family_lock.dart';
import '../../app/upgrade_resume.dart';
import '../../app/vpn_session_supervisor.dart';
import '../../core/aurora_bridge.dart';
import '../../core/aurora_bridge_factory.dart';
import '../../core/config_compiler.dart';
import '../../core/contract.dart';
import '../../core/path_health.dart';
import '../../core/route_family.dart';
import '../../data/connection_probe.dart';
import '../../data/contract_repository.dart';
import '../../data/secure_store.dart';
import '../nodes/nodes_page.dart';
import '../servers/add_server_page.dart';
import '../settings/settings_page.dart';

/// Connect screen: Smart/Global toggle + connect button. Loads the bundled
/// contract, compiles it (ConfigCompiler), and drives AuroraBridge.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, this.bridge, this.supervisor});

  final AuroraBridge? bridge;
  final VpnSessionSupervisor? supervisor;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  static const _buildId = String.fromEnvironment(
    'AURORA_BUILD_ID',
    defaultValue: 'dev',
  );

  late final AuroraBridge _bridge = widget.bridge ?? createAuroraBridge();
  AuroraStatus _status = AuroraStatus.disconnected;
  AuroraMode _mode = AuroraMode.smart;
  PathPreference _pathPreference = PathPreference.auto;
  late final RouteFamilyLock _routeFamilyLock = RouteFamilyLock(
    persist: _persistRouteFamily,
    apply: _pushRouteFamily,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  AuroraContract? _contract;
  late final VpnSessionSupervisor _sessionSupervisor =
      widget.supervisor ?? VpnSessionSupervisor.instance;
  // iOS only (see UpgradeResume); desktop already connects on launch.
  late final Future<UpgradeResume?> _upgradeResume = Platform.isIOS
      ? _iosUpgradeResume()
      : Future.value(null);
  PathHealthSnapshot? _pathSnapshot;
  TrafficStat _stats = const TrafficStat();
  String _node = '';
  String _server = '';
  String _appIdentity = '';
  String _contractIdentity = '';
  String _configId = '';
  String _probeSummary = '';
  bool _initializing = true;

  /// No server has been added yet: show how to add one instead of a connect
  /// button that can only fail.
  bool _noServers = false;
  bool _connectInFlight = false;
  int _mtu = 1400;
  StreamSubscription<AuroraStatus>? _sub;
  StreamSubscription<TrafficStat>? _statsSub;
  StreamSubscription<PathHealthSnapshot>? _pathSub;
  StreamSubscription<DataPlaneHealth>? _dataPlaneSub;
  StreamSubscription<ConnectionProbeReport?>? _probeSub;
  DataPlaneHealth _dataPlane = DataPlaneHealth.unknown;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitialState());
    ContractRepository.changes.addListener(_onServersChanged);
    // The tray's launch auto-connect may already have failed (or fail later)
    // before the user ever clicks anything — mirror that reason here.
    ConnectFlow.lastBackgroundError.addListener(_onBackgroundError);
    ConnectFlow.latestOutcome.addListener(_onConnectOutcome);
    _error ??= ConnectFlow.lastBackgroundError.value;
    _sub = _bridge.statusStream().listen(_handleStatus, onError: (_) {});
    _statsSub = _bridge.statsStream().listen((t) {
      if (mounted) setState(() => _stats = t);
    }, onError: (_) {});
    _pathSub = _sessionSupervisor.snapshots.listen((snapshot) {
      if (!mounted) return;
      setState(() {
        _pathSnapshot = snapshot;
        _node = snapshot.activeNode;
      });
    }, onError: (_) {});
    _dataPlane = _sessionSupervisor.dataPlaneHealth;
    _probeSummary = _sessionSupervisor.latestConnectionReport?.summary ?? '';
    _probeSub = _sessionSupervisor.connectionReports.listen((report) {
      if (!mounted) return;
      setState(() {
        _probeSummary = _status == AuroraStatus.connected
            ? report?.summary ?? 'Verifying HTTPS and GitHub images…'
            : '';
      });
    });
    _dataPlaneSub = _sessionSupervisor.dataPlaneStream.listen((health) {
      if (!mounted) return;
      setState(() {
        _dataPlane = health;
      });
    }, onError: (_) {});
    _bridge.status().then(_handleStatus).catchError((_) {});
  }

  void _handleStatus(AuroraStatus status) {
    if (!mounted) return;
    final previous = _status;
    setState(() {
      _status = status;
      if (status == AuroraStatus.disconnected ||
          status == AuroraStatus.disconnecting ||
          status == AuroraStatus.error) {
        _probeSummary = '';
      } else if (status == AuroraStatus.connected) {
        _probeSummary =
            _sessionSupervisor.latestConnectionReport?.summary ??
            'Verifying HTTPS and GitHub images…';
      }
    });
    if (status == AuroraStatus.connected) {
      unawaited(_upgradeResume.then((resume) => resume?.tunnelUp()));
      // A UI relaunch can adopt a tunnel that is already alive. The process
      // supervisor, not this page, owns health until the platform VPN stops.
      if (!_connectInFlight && !ConnectFlow.isBusy && _contract != null) {
        unawaited(
          _sessionSupervisor.attach(_bridge, _contract!, _pathPreference),
        );
      }
      if (previous != AuroraStatus.connected) {
        unawaited(ContractRepository.promotePending());
        if (!ConnectFlow.isBusy) _pushRouteFamilyQuietly();
      }
    } else if (status == AuroraStatus.disconnected ||
        status == AuroraStatus.error) {
      ContractRepository.discardPending();
      if (mounted) setState(() => _pathSnapshot = null);
    }
  }

  Future<void> _loadInitialState() async {
    final startingOutcome = ConnectFlow.latestOutcome.value;
    try {
      final contract = await ContractRepository.load();
      final savedMode = await SecureStore.loadMode();
      final savedPath = await SecureStore.loadPathPreference();
      final savedRouteFamily = await SecureStore.loadRouteFamily();
      final package = await PackageInfo.fromPlatform();
      if (!mounted) return;
      if (!identical(startingOutcome, ConnectFlow.latestOutcome.value)) return;
      setState(() {
        _mode = ConnectFlow.resolveMode(savedMode, contract);
        _pathPreference = ConnectFlow.resolvePathPreference(
          savedPath,
          contract,
        );
        _routeFamilyLock.adopt(contract, savedRouteFamily);
        _contract = contract;
        _server = contract.nodes.isEmpty
            ? ''
            : (contract.nodes.first.name ?? contract.nodes.first.id);
        _appIdentity = '${package.version}+${package.buildNumber} · $_buildId';
        _contractIdentity = _describeContract(contract);
        _mtu = contract.network.mtu;
        _initializing = false;
        _noServers = false;
      });
      final latest = _sessionSupervisor.latest;
      if (latest != null && mounted) setState(() => _pathSnapshot = latest);
      if (_status == AuroraStatus.connected && !ConnectFlow.isBusy) {
        // Symmetric with the reasoning for _pushRouteFamily below: this single bridge.status() platform call
        // can return before the chain of awaits above (contract + three storage reads + package info).
        // Pushing only in _handleStatus's transition branch means this cold-start path would never catch up,
        // and the selector would stay on the value cached by cache_file in the previous session.
        unawaited(
          _sessionSupervisor.attach(_bridge, contract, _pathPreference),
        );
        _pushRouteFamilyQuietly();
      }
      unawaited(_resumeAfterUpgrade());
    } on NoContractException {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _noServers = true;
        _contract = null;
      });
    } catch (error) {
      if (!mounted) return;
      if (!identical(startingOutcome, ConnectFlow.latestOutcome.value)) return;
      setState(() {
        _initializing = false;
        _error = 'Initialization failed: $error';
      });
    }
  }

  static Future<UpgradeResume?> _iosUpgradeResume() async {
    try {
      final library = await getLibraryDirectory();
      return UpgradeResume(
        File('${PathEventLog.iosDirectoryPath(library.path)}/resume-build'),
        () async {
          final package = await PackageInfo.fromPlatform();
          return '${package.version}+${package.buildNumber}';
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// The first launch after an upgrade puts back the tunnel the upgrade
  /// killed (see [UpgradeResume]). Called once the saved mode, path and route
  /// family are loaded, so it connects exactly as a tap on Connect would.
  Future<void> _resumeAfterUpgrade() async {
    final resume = await _upgradeResume;
    if (resume == null || !mounted) return;
    final AuroraStatus status;
    try {
      status = await _bridge.status();
    } catch (_) {
      return;
    }
    if (!mounted || status != AuroraStatus.disconnected) return;
    if (_connectInFlight || ConnectFlow.isBusy) return;
    final claim = await resume.claim();
    if (claim == null || !mounted) return;
    unawaited(
      PathEventLog.instance.record('resume_after_upgrade', {
        'from': claim.from,
        'to': claim.to,
      }),
    );
    _handleStatus(status);
    await _toggle();
  }

  static String _describeContract(AuroraContract contract) {
    final revision = contract.revision == 0 ? '' : ' · r${contract.revision}';
    final updated = contract.updated == null ? '' : ' · ${contract.updated}';
    return 'v${contract.version}$revision$updated';
  }

  bool get _hasDualPath =>
      _contract?.paths != null &&
      _contract?.pathPolicy != null &&
      _contract?.egress != null;

  Future<void> _changePathPreference(PathPreference preference) async {
    if (_pathPreference == preference) return;
    setState(() => _pathPreference = preference);
    await SecureStore.savePathPreference(
      ConnectFlow.pathPreferenceStorageValue(preference),
    );
    await _sessionSupervisor.setPreference(preference);
  }

  // Manual family locking only applies to the flat shape (not paths); and the families rendered
  // must be the ones the compiled output really emits a via-<family> group for, otherwise the user
  // can tap a group that does not exist and selectOutbound fails (see the note in route_family.dart).
  List<String> get _routeFamilies => _hasDualPath || _contract == null
      ? const []
      : renderableRouteFamilies(_contract!);

  /// "Back to automatic" must not delete the saved value or write an 'auto' placeholder — symmetric with clearEgressLease,
  /// and the reason SecureStore.clearRouteFamily exists.
  /// Choosing "Auto" must **explicitly save `'auto'`**, never clear the key.
  ///
  /// Clearing the key used to be how "back to automatic" was expressed, but the default is now
  /// the contract's default route (`resolveDefaultRouteTarget`): no saved value = never chose = use the default.
  /// Keep expressing "automatic" by clearing, and the next launch would be taken back by the default, so the user's tap would be useless.
  Future<void> _persistRouteFamily(String? family) =>
      SecureStore.saveRouteFamily(family ?? 'auto');

  Future<void> _changeRouteFamily(String? family) async {
    // State, persistence and rollback live in RouteFamilyLock (the only place unit tests can
    // cover); this only shows the reason for a rollback.
    final error = await _routeFamilyLock.change(family);
    if (error != null && mounted) {
      setState(() => _error = ConnectFlow.describeError(error));
    }
  }

  /// Push explicitly instead of relying on the selector's default: the flat shape enables cache_file,
  /// and sing-box persists the last selector choice, which would stick if not pushed explicitly.
  /// The decision itself, "whether to push / to which tag", is extracted as the pure function
  /// ConnectFlow.routeFamilyTagToApply, because it must give the same answer on both cold-start
  /// paths (status transition / finding already-connected at init); see the comment on that function in connect_flow.dart.
  ///
  /// Syncing the supervisor's routeFamily is also done here, outside the early return on the tag
  /// check below: the watchdog's self-heal target should not depend on whether the selector should
  /// be pushed at this moment, only on which family the user currently chose. This function is the only
  /// exit through which a family choice is pushed — both cold-start paths and manual switches meet here,
  /// so syncing once here covers every call site (missing the cold-start path last time was exactly that).
  ///
  /// Failure **must propagate**: RouteFamilyLock uses it to decide whether to roll back.
  Future<void> _pushRouteFamily(String? family) async {
    // Defense in depth: the paths shape has no "family lock" at all, its paths are managed by PathHealthCoordinator.
    // ConnectFlow.resolveRouteFamily already guards where the family comes from; this blocks the push itself again —
    // a via-* selectOutbound would be written by the native side unconditionally into
    // desiredSelections, overriding the coordinator's replay target.
    if (_hasDualPath) return;
    _sessionSupervisor.setRouteFamily(family);
    final contract = _contract;
    final tag = ConnectFlow.routeFamilyTagToApply(
      contract: contract,
      status: _status,
      routeFamily: family,
    );
    if (tag == null) return;
    await _bridge.selectOutbound(contract!.outboundGroup.selectorTag, tag);
  }

  /// Pushes on the two cold-start paths: a failure can only be swallowed, and it is safe to. The reason differs
  /// from a manual switch — on a manual switch the UI already shows the new family first, so staying silent
  /// would be lying; here the selector stays on the last choice cached by cache_file, and that
  /// last choice is the same locked family, so the UI is not lying.
  void _pushRouteFamilyQuietly() {
    unawaited(
      _pushRouteFamily(_routeFamilyLock.family).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    ConnectFlow.lastBackgroundError.removeListener(_onBackgroundError);
    ConnectFlow.latestOutcome.removeListener(_onConnectOutcome);
    _sub?.cancel();
    _statsSub?.cancel();
    _pathSub?.cancel();
    _dataPlaneSub?.cancel();
    _probeSub?.cancel();
    ContractRepository.changes.removeListener(_onServersChanged);
    super.dispose();
  }

  void _onServersChanged() {
    if (mounted) unawaited(_loadInitialState());
  }

  void _openAddServer() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<bool>(builder: (_) => const AddServerPage()));
  }

  void _onBackgroundError() {
    if (!mounted) return;
    // A change to null means a connect attempt just succeeded — stale failure
    // text would contradict the Connected header, so mirror the value either way.
    setState(() => _error = ConnectFlow.lastBackgroundError.value);
  }

  static String _fmtRate(int bps) {
    if (bps < 1024) return '$bps B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  bool get _isOn =>
      _status == AuroraStatus.connected || _status == AuroraStatus.connecting;

  Future<void> _toggle() async {
    if (_status == AuroraStatus.disconnecting) {
      _sessionSupervisor.cancelTunnelRestartHandler?.call();
      return;
    }
    if (_connectInFlight && !_isOn) return;
    final desktopRecovery = DesktopConnectionRecovery.active;
    bool Function()? isCancelled;
    var startedHere = false;
    setState(() => _error = null);
    try {
      if (_isOn) {
        _sessionSupervisor.cancelTunnelRestartHandler?.call();
        await (await _upgradeResume)?.userStopped();
        await _bridge.stop();
        return;
      }
      if (ConnectFlow.isBusy) return; // tray auto-connect already running
      _connectInFlight = true;
      startedHere = true;
      isCancelled = desktopRecovery?.beginConnection();
      final granted = await _bridge.prepare();
      if (!granted) {
        if (mounted) setState(() => _error = 'VPN permission denied');
        return;
      }
      await ConnectFlow.compileAndStart(
        _bridge,
        mode: _mode,
        pathPreference: _pathPreference,
        isCancelled: isCancelled,
      );
    } on PlatformException catch (e) {
      final message = e.message?.trim();
      if (mounted) {
        setState(
          () => _error = message == null || message.isEmpty
              ? 'VPN operation failed (${e.code})'
              : message,
        );
      }
    } catch (e) {
      if (isCancelled?.call() ?? false) return;
      if (mounted) setState(() => _error = ConnectFlow.describeError(e));
    } finally {
      if (startedHere) {
        _connectInFlight = false;
        if (!(isCancelled?.call() ?? false)) desktopRecovery?.endConnection();
      }
    }
  }

  void _onConnectOutcome() {
    final outcome = ConnectFlow.latestOutcome.value;
    if (!mounted || outcome == null) return;
    final contract = outcome.contract;
    setState(() {
      _initializing = false;
      _contract = contract;
      _mode = outcome.mode;
      _pathPreference = outcome.pathPreference;
      _configId = outcome.configId.substring(0, 12);
      _contractIdentity = _describeContract(contract);
      _mtu = contract.network.mtu;
      _server = contract.nodes.isEmpty
          ? ''
          : (contract.nodes.first.name ?? contract.nodes.first.id);
      _routeFamilyLock.adopt(contract);
    });
    _pushRouteFamilyQuietly();
  }

  /// The platform reports a tunnel object, not working internet. When the
  /// watchdog has proven nothing crosses that tunnel, saying "Connected" sends the
  /// user hunting for a fault on their own machine.
  bool get _tunnelUpButDead =>
      _status == AuroraStatus.connected &&
      (_dataPlane == DataPlaneHealth.dead ||
          _dataPlane == DataPlaneHealth.deadUnrecoverable);

  // When a family is locked, the fault names which one is unavailable instead of a vague "no internet": the route the user
  // chose themselves, and a vague message would send them to check the global network instead of the locked route.
  String get _deadLabelSuffix => _routeFamilyLock.family == null
      ? 'No internet'
      : '${routeFamilyLabel(_routeFamilyLock.family!)} unavailable';

  /// The physical network itself is gone (Wi-Fi dropped, no IP). The tunnel, route family and certificates
  /// have not been judged at all — writing it as "relay unavailable" would send the user off to check routes.
  bool get _physicalOffline =>
      _status == AuroraStatus.connected &&
      _dataPlane == DataPlaneHealth.offline;

  String get _label => switch (_status) {
    AuroraStatus.connected when _physicalOffline => 'Connected · local network down',
    AuroraStatus.connected when _tunnelUpButDead => 'Connected · $_deadLabelSuffix',
    AuroraStatus.connected => 'Connected',
    AuroraStatus.connecting => 'Connecting…',
    AuroraStatus.disconnecting => 'Disconnecting…',
    AuroraStatus.error => 'Error',
    AuroraStatus.disconnected => 'Disconnected',
  };

  Color get _color => switch (_status) {
    AuroraStatus.connected when _physicalOffline => Colors.orange,
    AuroraStatus.connected when _tunnelUpButDead => Colors.red,
    AuroraStatus.connected => Colors.green,
    AuroraStatus.connecting || AuroraStatus.disconnecting => Colors.orange,
    AuroraStatus.error => Colors.red,
    AuroraStatus.disconnected => Colors.grey,
  };

  /// The leg that was just replaced because it could not be reached at all. Naming it tells the user
  /// it is "this one in the family" that has a problem, not the whole family.
  String get _demotedHint {
    final from = VpnSessionSupervisor.instance.lastDemotedFrom;
    final to = VpnSessionSupervisor.instance.lastDemotedTo;
    if (from == null || to == null) return '';
    return '($from is unavailable on the current network, switched to $to)';
  }

  /// Actionable, not just alarming: the user's next move differs depending on
  /// whether reconnecting is still being tried or has already been ruled out.
  String get _deadReason => switch (_dataPlane) {
    DataPlaneHealth.deadUnrecoverable =>
      'Tunnel is up, but every node is unreachable and reconnecting does not help. '
          'This is usually the server IP being blocked by the network — switch to a different network, or use a different entry node under Settings · Import.'
          '$_lockedFamilyHint$_demotedHint',
    _ => 'Tunnel is up, but traffic cannot get out; reconnecting automatically…$_lockedFamilyHint$_demotedHint',
  };

  // Once a family is locked, self-healing / reconnecting only circle within that family and never switch across families —
  // without saying so, the user seeing "unavailable" would assume a global fault and not know they can switch to "Auto" to get out.
  String get _lockedFamilyHint =>
      _routeFamilyLock.family == null ? '' : 'Route is locked and will not switch to another automatically; you can switch to Auto.';

  Widget _firstRun(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 64),
          const SizedBox(height: 16),
          Text(
            'Add your first server',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Aurora connects to servers you own: a VPS or a machine at home. '
            'Setting one up takes one command.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('first-run-add-server'),
            icon: const Icon(Icons.add),
            label: const Text('Add a server'),
            onPressed: _openAddServer,
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aurora'),
        actions: [
          IconButton(
            icon: const Icon(Icons.dns),
            tooltip: 'Nodes',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const NodesPage())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: _noServers ? _firstRun(context) : Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<AuroraMode>(
              segments: const [
                ButtonSegment(value: AuroraMode.smart, label: Text('Smart')),
                ButtonSegment(value: AuroraMode.global, label: Text('Global')),
              ],
              selected: {_mode},
              onSelectionChanged: _hasDualPath || _isOn || _initializing
                  ? null
                  : (selection) {
                      final mode = selection.first;
                      setState(() => _mode = mode);
                      unawaited(SecureStore.saveMode(mode.name));
                    },
            ),
            if (_hasDualPath) ...[
              const SizedBox(height: 16),
              PathPreferenceControl(
                preference: _pathPreference,
                enabled:
                    !_initializing &&
                    _status != AuroraStatus.connecting &&
                    _status != AuroraStatus.disconnecting,
                onChanged: (preference) =>
                    unawaited(_changePathPreference(preference)),
              ),
            ],
            if (!_hasDualPath && _routeFamilies.length > 1) ...[
              const SizedBox(height: 16),
              RouteFamilyControl(
                families: _routeFamilies,
                selected: _routeFamilyLock.family,
                enabled:
                    !_initializing &&
                    _status != AuroraStatus.connecting &&
                    _status != AuroraStatus.disconnecting,
                onChanged: (family) => unawaited(_changeRouteFamily(family)),
              ),
            ],
            const SizedBox(height: 32),
            GestureDetector(
              onTap: _initializing ? null : _toggle,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _color.withValues(alpha: 0.15),
                  border: Border.all(color: _color, width: 6),
                ),
                child: Icon(
                  _isOn ? Icons.power_settings_new : Icons.power_off,
                  size: 72,
                  color: _color,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(_label, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '${_mode == AuroraMode.smart ? 'Smart' : 'Global'}${_server.isEmpty ? '' : ' · $_server'}',
            ),
            if (_appIdentity.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'App $_appIdentity · Contract $_contractIdentity',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (_configId.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Config $_configId · MTU $_mtu',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_status == AuroraStatus.connected) ...[
              const SizedBox(height: 8),
              if (_physicalOffline) ...[
                Text(
                  'No usable network on this device (Wi-Fi disconnected or no IP address). '
                  'Routes will not be switched and the tunnel will not be restarted for this; it re-verifies automatically when the network returns.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade800,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
              ] else if (_tunnelUpButDead) ...[
                Text(
                  _deadReason,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
              ],
              if (_pathSnapshot != null)
                PathStatusView(snapshot: _pathSnapshot!)
              else if (_node.isNotEmpty)
                Text('Exit: $_node')
              else if (_dataPlane == DataPlaneHealth.alive)
                const Text('Exit: verified and usable')
              else if (!_tunnelUpButDead && !_physicalOffline)
                const Text('Exit: verifying…'),
              const SizedBox(height: 4),
              Text(
                '↑ ${_fmtRate(_stats.uplink)}   ↓ ${_fmtRate(_stats.downlink)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_probeSummary.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  _probeSummary,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _initializing ? null : _toggle,
              child: Text(_initializing ? 'Initializing…' : (_isOn ? 'Disconnect' : 'Connect')),
            ),
          ],
        ),
      ),
    );
  }
}

class PathPreferenceControl extends StatelessWidget {
  const PathPreferenceControl({
    required this.preference,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final PathPreference preference;
  final bool enabled;
  final ValueChanged<PathPreference> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<PathPreference>(
    segments: const [
      ButtonSegment(
        value: PathPreference.auto,
        icon: Icon(Icons.alt_route),
        label: Text('Auto (relay first)'),
      ),
      ButtonSegment(
        value: PathPreference.homeDirect,
        icon: Icon(Icons.home),
        label: Text('Home (direct)'),
      ),
    ],
    selected: {preference},
    onSelectionChanged: enabled
        ? (selection) => onChanged(selection.first)
        : null,
  );
}

class PathStatusView extends StatelessWidget {
  const PathStatusView({required this.snapshot, super.key});

  final PathHealthSnapshot snapshot;

  String get _pathLabel => switch (snapshot.state) {
    AuroraPathState.relayPublic => 'Relay to home (public)',
    AuroraPathState.relayTailnet => 'Relay to home (Tailnet)',
    AuroraPathState.homeDirect => 'Home (direct)',
    AuroraPathState.recovering => 'Current path (verifying recovery of a higher-priority path)',
    AuroraPathState.relayPreferred || AuroraPathState.relaySuspect => 'Relay to home',
    AuroraPathState.relayRecovering => 'Home (direct), verifying relay recovery',
    AuroraPathState.homeFallback => 'Home (direct)',
    AuroraPathState.homeBlocked => 'Home exit failing (blocked inside the TUN)',
  };

  String get _reason => switch (snapshot.reasonCode) {
    PathReason.pathHardFailure => 'Current path failed to connect, demoted automatically',
    PathReason.pathLoss => 'Current path keeps dropping packets, demoted automatically',
    PathReason.pathJitter => 'Current path jitter too high, demoted automatically',
    PathReason.pathLatency => 'Current path latency abnormal, demoted automatically',
    PathReason.egressMismatch => 'Exit identity abnormal, path isolated',
    PathReason.pathRecovered => 'A higher-priority path is recovering or has recovered stably',
    PathReason.manualHome => 'Home (direct) selected manually',
    PathReason.flapCooldown => 'Path switching too often; staying on the current safe path during cooldown',
    PathReason.homeUnavailable => 'Home exit unavailable, failed closed',
    _ => 'Current path healthy',
  };

  String get _leaseLabel => switch (snapshot.leaseHealth) {
    LeaseHealth.valid => 'Valid',
    LeaseHealth.refreshing => 'Refreshing',
    LeaseHealth.invalid => 'Invalid / expired',
    LeaseHealth.unavailable => 'Old contract (no dynamic lease)',
  };

  String get _leaseSuffix {
    final sequence = snapshot.leaseSequence?.toString();
    if (sequence == null) return '';
    final suffix = sequence.length <= 4
        ? sequence.padLeft(4, '0')
        : sequence.substring(sequence.length - 4);
    return ' · #$suffix';
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Path: $_pathLabel'),
      const SizedBox(height: 2),
      Text(_reason, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 2),
      Text(
        snapshot.egressVerified ? 'Home exit verified' : 'Home exit verifying / failing',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Text(
        'Lease: $_leaseLabel$_leaseSuffix',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (snapshot.activeNode.isNotEmpty)
        Text(
          'Protocol: ${snapshot.activeNode}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      if (snapshot.p50Ms != null || snapshot.p95Ms != null)
        Text(
          'Latency: p50 ${snapshot.p50Ms ?? '—'} ms · '
          'p95 ${snapshot.p95Ms ?? '—'} ms · '
          'jitter ${snapshot.jitterMs ?? '—'} ms',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      if (snapshot.state == AuroraPathState.recovering ||
          snapshot.state == AuroraPathState.relayRecovering)
        Text(
          'Recovery progress: ${snapshot.recoveryRounds}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );
}

/// Manual route selection for flat-shape contracts. After a family is chosen the selector is pinned to that family's urltest group,
/// and sing-box does not hop across groups — "locked means locked" is implemented this way, with no extra guard logic needed.
class RouteFamilyControl extends StatelessWidget {
  const RouteFamilyControl({
    required this.families,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final List<String> families;
  final String? selected;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
    segments: [
      const ButtonSegment(
        value: '',
        icon: Icon(Icons.auto_mode),
        label: Text('Auto'),
      ),
      for (final family in families)
        ButtonSegment(value: family, label: Text(routeFamilyLabel(family))),
    ],
    selected: {selected ?? ''},
    onSelectionChanged: enabled
        ? (selection) {
            final value = selection.first;
            onChanged(value.isEmpty ? null : value);
          }
        : null,
  );
}
