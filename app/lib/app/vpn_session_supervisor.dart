import 'dart:async';

import '../core/aurora_bridge.dart';
import '../core/mobile_session_control.dart';
import '../core/contract.dart';
import '../core/goodput_gate.dart';
import '../core/path_health.dart';
import '../core/physical_network.dart';
import '../core/route_family.dart';
import '../data/connection_probe.dart';
import 'path_event_log.dart';
import 'path_health_coordinator.dart';

typedef PathCoordinatorFactory =
    PathHealthCoordinator Function(AuroraBridge bridge);
typedef PhysicalNetworkSignature = Future<String> Function();
typedef WatchdogProbe = Future<ConnectionProbeReport> Function();
typedef GoodputProbe = Future<GoodputSample> Function();

/// The end-to-end watchdog's own verdict on the data path.
///
/// [AuroraStatus.connected] is control-plane truth — it only says a platform
/// tunnel object exists. When every node of a contract sits behind one blocked
/// server IP the tunnel stays up while nothing crosses it, and reporting that
/// as "Connected" is a lie the user cannot act on. This is what the probes through
/// the tunnel actually saw.
enum DataPlaneHealth {
  /// No probe has completed yet for this session (still inside the grace
  /// window), or there is no session.
  unknown,

  /// A probe reached the internet through the tunnel.
  alive,

  /// Consecutive probe rounds lost every endpoint. A restart is still worth
  /// trying (the engine may pick another node, the network may have moved).
  dead,

  /// Dead, and restarting has already been tried without recovering. Nothing
  /// the client can do will fix it — the far side is unreachable.
  deadUnrecoverable,

  /// The physical network itself has no usable interface (Wi-Fi dropped, cable
  /// out). The tunnel cannot be judged in this state: every probe would fail
  /// for a reason that has nothing to do with the tunnel, the route family or
  /// the far side. Nothing is charged, demoted or restarted until the network
  /// is back — see `_pollPhysicalNetwork`.
  offline,
}

/// Process-scoped owner of automatic path health.
///
/// A page may subscribe and unsubscribe freely. The coordinator itself lives
/// until the platform VPN reports disconnected/error, so hiding a desktop
/// window or navigating away cannot silently disable failover.
class VpnSessionSupervisor {
  VpnSessionSupervisor({
    PathCoordinatorFactory? coordinatorFactory,
    PhysicalNetworkSignature? physicalNetworkSignature,
    this.networkPollInterval = const Duration(seconds: 5),
    this.watchdogInterval = const Duration(seconds: 30),
    this.watchdogGrace = const Duration(seconds: 15),
    this.watchdogConfirmDelay = const Duration(seconds: 8),
    this.maxRestartsWithoutRecovery = 2,
    this.goodputInterval = const Duration(seconds: 90),
    this.goodputConfirmDelay = const Duration(seconds: 20),
    this.selectionSettle = const Duration(seconds: 11),
    WatchdogProbe? watchdogProbe,
    GoodputProbe? goodputProbe,
    GoodputGate? goodputGate,
    PathEventLog? pathEventLog,
  }) : _coordinatorFactory =
           coordinatorFactory ??
           ((bridge) => PathHealthCoordinator(bridge: bridge)),
       _physicalNetworkSignature =
           physicalNetworkSignature ?? readPhysicalNetworkSignature,
       _watchdogProbe = watchdogProbe ?? ConnectionProbeService.runThroughTunnel,
       _goodputProbe = goodputProbe ?? ConnectionProbeService.runGoodput,
       _pathEventLog = pathEventLog ?? PathEventLog.instance,
       goodputGate = goodputGate ?? GoodputGate();

  static final VpnSessionSupervisor instance = VpnSessionSupervisor();

  final PathCoordinatorFactory _coordinatorFactory;
  final PhysicalNetworkSignature _physicalNetworkSignature;
  final Duration networkPollInterval;
  final Duration watchdogInterval;
  final Duration watchdogGrace;
  final Duration watchdogConfirmDelay;

  /// How many restarts may fail to produce a live probe before the watchdog
  /// concludes the far side is unreachable and stops restarting.
  final int maxRestartsWithoutRecovery;

  /// How often the expensive bulk-transfer check may run. Far rarer than the
  /// reachability probe: it moves real bytes over the user's link.
  final Duration goodputInterval;

  /// How soon to re-measure after a sub-floor sample, so the confirming look
  /// costs the user seconds rather than another full interval.
  final Duration goodputConfirmDelay;

  /// After the watchdog itself changes the route selection, the next verdict waits at least this long.
  ///
  /// dns-proxy reuses a single DoH connection: if a DoH dial is stuck on the node that was just
  /// swapped out at the moment of the swap, every later resolution queues behind it until its own deadline
  /// (fixed at 10s in the core, not configurable). The probe timeout is only 8s, so judging the new node
  /// dead within that window manufactures evidence from nothing — another swap, another restart, the very
  /// loop this is meant to break. 10s plus 1s of margin.
  ///
  /// The window starts when "the active node reported by the core changed" (a urltest re-election, the watchdog's own
  /// urlTest, the path coordinator and manual switches all count), and also after the watchdog's own
  /// selection command is confirmed. The first verdict of a new session is covered by [watchdogGrace] (15s) being larger than this window.
  final Duration selectionSettle;
  final WatchdogProbe _watchdogProbe;
  final GoodputProbe _goodputProbe;
  final PathEventLog _pathEventLog;

  /// Survives sessions on purpose — see [_checkGoodput].
  final GoodputGate goodputGate;
  bool _goodputInFlight = false;
  DateTime? _nextGoodputAt;

  /// Stops and reconnects the tunnel when the watchdog confirms the data path
  /// is dead. Wired by the desktop shell (ConnectFlow); when null the watchdog
  /// only records evidence. Returns true only if a restart actually acted, so
  /// no-op attempts (a manual connect racing it) don't consume the rate-limit
  /// budget.
  Future<bool> Function()? tunnelRestartHandler;
  void Function()? cancelTunnelRestartHandler;

  final StreamController<PathHealthSnapshot> _snapshots =
      StreamController<PathHealthSnapshot>.broadcast();

  final StreamController<DataPlaneHealth> _dataPlane =
      StreamController<DataPlaneHealth>.broadcast();

  // The UI consumes the same session/path-scoped evidence as the watchdog.
  // null invalidates a report after a stop, network change or route change.
  final StreamController<ConnectionProbeReport?> _connectionReports =
      StreamController<ConnectionProbeReport?>.broadcast();
  ConnectionProbeReport? _latestConnectionReport;

  Stream<ConnectionProbeReport?> get connectionReports =>
      _connectionReports.stream;
  ConnectionProbeReport? get latestConnectionReport => _latestConnectionReport;

  AuroraBridge? _bridge;
  AuroraContract? _contract;
  PathPreference _preference = PathPreference.auto;

  /// The route family the user locked. The watchdog's self-heal speed test must hit the **currently active group**:
  /// with relay locked, running urlTest('auto') measures a group that is not in use.
  String? _routeFamily;
  PathHealthCoordinator? _coordinator;
  StreamSubscription<AuroraStatus>? _statusSubscription;
  StreamSubscription<List<OutboundGroupInfo>>? _groupsSubscription;
  StreamSubscription<PathHealthSnapshot>? _snapshotSubscription;
  Timer? _networkTimer;
  Timer? _watchdogTimer;
  Timer? _watchdogConfirmTimer;
  int _watchdogFailures = 0;
  bool _watchdogProbeInFlight = false;
  DateTime? _probeNotBefore;

  /// Last physical network change: the core does ResetNetwork itself at that point and DNS moves to a new connection pool.
  DateTime? _networkChangedAt;
  DataPlaneHealth _dataPlaneHealth = DataPlaneHealth.unknown;

  /// Charged restarts that were not followed by a live probe. A blackholed
  /// server IP survives any number of reconnects, so this is what lets the
  /// watchdog stop instead of churning the tunnel forever.
  int _restartsWithoutRecovery = 0;
  bool _suppressionLogged = false;
  final List<DateTime> _autoRestarts = [];
  List<OutboundGroupInfo>? _pendingGroups;
  String? _networkSignature;

  /// The poller's last verdict on the physical network. Starts true so a
  /// session whose first poll has not landed yet is judged exactly as before
  /// this state existed.
  bool _physicalOnline = true;

  /// One restart may skip the 90s spacing after the network returns.
  bool _restartSpacingWaived = false;
  String? _lastLoggedTransition;
  PathHealthSnapshot? _latest;
  bool _everConnected = false;
  Object? _activationToken;
  int _coreRevision = 0;
  final Set<Future<void>> _pendingSelections = {};
  bool _disposed = false;
  int _generation = 0;
  int _probeEpoch = 0;

  Stream<PathHealthSnapshot> get snapshots => _snapshots.stream;
  PathHealthSnapshot? get latest => _latest;

  /// The watchdog's verdict on whether traffic actually crosses the tunnel.
  Stream<DataPlaneHealth> get dataPlaneStream => _dataPlane.stream;
  DataPlaneHealth get dataPlaneHealth => _dataPlaneHealth;

  void _setDataPlaneHealth(DataPlaneHealth health) {
    if (_dataPlaneHealth == health) return;
    _dataPlaneHealth = health;
    if (health == DataPlaneHealth.alive) {
      // Recovering to healthy means the problem the last swap (if any) targeted is over — the next
      // time it is judged dead, that must be new evidence it gathered itself, and not inherit an
      // old reason that is long past and may point at a completely different node. See the comment on [lastDemotedFrom].
      lastDemotedFrom = null;
      lastDemotedTo = null;
    }
    if (!_dataPlane.isClosed) _dataPlane.add(health);
  }

  bool get hasActiveSession => _coordinator != null;

  Future<void> attach(
    AuroraBridge bridge,
    AuroraContract contract,
    PathPreference preference,
  ) async {
    if (_disposed) throw StateError('vpn_session_supervisor_disposed');
    if (identical(_bridge, bridge) && _sameContract(_contract, contract)) {
      await setPreference(preference);
      return;
    }
    await _clearSession();
    final generation = ++_generation;
    _bridge = bridge;
    _contract = contract;
    _preference = preference;
    _statusSubscription = bridge.statusStream().listen(
      (status) => unawaited(_handleStatus(status, generation)),
      onError: (_) {},
    );
    _groupsSubscription = bridge.groupsStream().listen((groups) {
      final selectorTag = _contract?.outboundGroup.selectorTag;
      final previous = _pendingGroups;
      if (selectorTag != null && previous != null) {
        final before = GoodputGate.effectiveNode(previous, selectorTag);
        final after = GoodputGate.effectiveNode(groups, selectorTag);
        if (before != null && after != null && before != after) {
          _noteSelectorChange(observed: true);
        }
      }
      _pendingGroups = groups;
      final coordinator = _coordinator;
      if (coordinator != null) unawaited(coordinator.onGroups(groups));
    }, onError: (_) {});
    // The initial status read is a best-effort kick. It must not throw out of
    // attach(): callers run this right after a successful bridge.start(), and a
    // platform-channel exception here would surface as a connect failure while
    // the tunnel is actually up — leaving it running with no supervision. The
    // status stream subscription above still drives activation on the next
    // event either way.
    AuroraStatus status;
    try {
      status = await bridge.status();
    } catch (_) {
      return;
    }
    if (generation != _generation) return;
    await _handleStatus(status, generation);
  }

  /// A UI page re-attaching with its own instance of the same stored contract
  /// must not tear down the live session (it would reset watchdog/coordinator
  /// state). Revisions are monotonically increasing, so an equal non-zero
  /// revision means the same contract content.
  static bool _sameContract(AuroraContract? current, AuroraContract candidate) {
    if (current == null) return false;
    if (identical(current, candidate)) return true;
    return current.revision != 0 && current.revision == candidate.revision;
  }

  Future<void> setPreference(PathPreference preference) async {
    _preference = preference;
    await _coordinator?.setPreference(preference);
  }

  /// Called synchronously by `_applyRouteFamily` (connect_page.dart) — that function is the only exit
  /// through which a family choice is pushed; both cold-start paths (`_loadInitialState` finding it already connected /
  /// the transition branch of `_handleStatus`) and manual family switches meet there, so syncing
  /// once here covers all three call sites, with no need to patch each of them.
  void setRouteFamily(String? family) {
    if (_routeFamily == family) return;
    _routeFamily = family;
    _invalidateProbes();
  }

  /// [observed] = a change seen in the group state. It does not count right after a network change: the core has already swapped its DNS
  /// connection pool, so there is no old dial to wait for. Route commands the watchdog itself sent still count.
  void _noteSelectorChange({bool observed = false}) {
    if (selectionSettle <= Duration.zero) return;
    final now = DateTime.now();
    final networkChangedAt = _networkChangedAt;
    if (observed &&
        networkChangedAt != null &&
        now.difference(networkChangedAt) < selectionSettle) {
      return;
    }
    _probeNotBefore = now.add(selectionSettle);
  }

  /// Read-only entry for the desktop tray to name the locked route — the same state the watchdog's self-heal uses,
  /// so no separate ConnectPage → Tray channel is needed.
  String? get routeFamily => _routeFamily;

  /// Which group the watchdog's self-heal should test: if a family is locked, that family's `via-<family>` group; if none is locked
  /// (or not yet attached), fall back to the contract's own legacy urltest group.
  String get _activeGroupTag {
    final contract = _contract;
    if (contract == null) return 'auto';
    return _routeFamily == null
        ? contract.outboundGroup.urltestTag
        : routeFamilyGroupTag(_routeFamily);
  }

  /// The latest URL-test latency of each leg in the currently active group (0 = not tested or unreachable), saved together
  /// with the dead verdict. If every probe is dead yet some leg in the group still tests reachable, the problem is on this machine's side and
  /// swapping legs / restarting may help; if the group is all 0, the whole path is down, and swapping or restarting only cuts the user's connections.
  /// This evidence did not exist before: in-family hard-failure swaps were followed by another dead verdict 38 times out of 50,
  /// with no way to tell which kind it was.
  Map<String, int> _activeGroupDelays() {
    final tag = _activeGroupTag;
    for (final group in _pendingGroups ?? const <OutboundGroupInfo>[]) {
      if (group.tag == tag) {
        return {for (final item in group.items) item.tag: item.delayMs};
      }
    }
    return const {};
  }

  Future<void> networkChanged() async {
    _invalidateProbes();
    await _coordinator?.onNetworkChanged();
  }

  /// Rebuild path/lease evidence around a core reload while retaining the
  /// system VPN. The old coordinator must never apply a stale selection to
  /// the new core, whose path selector deliberately starts fail-closed.
  Future<MobileReloadResult> reloadMobileSession(
    AuroraBridge bridge,
    String sessionId, {
    required bool Function() isCancelled,
    required bool Function() canReload,
    required Duration nativeTimeout,
  }) async {
    if (_disposed ||
        !identical(_bridge, bridge) ||
        _contract == null ||
        !usesMobileSessionRecovery(bridge)) {
      return MobileReloadResult.unavailable;
    }
    final generation = _generation;
    bool stale() => _disposed || generation != _generation || isCancelled();
    _invalidateProbes();
    _stopWatchdog();
    _coreRevision++;
    _activationToken = null;
    final coordinator = _coordinator;
    _coordinator = null;
    _latest = null;
    await _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    await coordinator?.disposeForCoreReload();
    // Goodput/hard-failure demotions are issued by this owner rather than the
    // path coordinator. Drain those already-issued selector RPCs as well.
    await Future.wait(
      _pendingSelections.toList().map(
        (pending) => pending.catchError((Object _) {}),
      ),
    );
    if (stale()) return MobileReloadResult.unavailable;
    _pendingGroups = null;
    final control = bridge as AuroraMobileSessionControl;
    if (!canReload()) {
      // Eligibility can change while the retired selector drains. The core
      // has not been touched: restore its supervision even in the background,
      // but only if this transaction still owns that exact live VPN session.
      final live = await control.sessionSnapshot().timeout(nativeTimeout);
      if (stale() ||
          live.sessionId != sessionId ||
          live.status != AuroraStatus.connected) {
        return MobileReloadResult.unavailable;
      }
      try {
        await _activate(generation);
      } finally {
        if (!stale()) _startWatchdog();
      }
      return MobileReloadResult.unavailable;
    }
    final result = await control
        .reloadCurrentSession(sessionId)
        .timeout(nativeTimeout);
    // Failure may close the native VPN before its reply. Pass that terminal
    // result through for the UI, while stale success can never reactivate it.
    if (result == MobileReloadResult.requiresReconnect) return result;
    if (stale()) return MobileReloadResult.unavailable;
    if (result != MobileReloadResult.reloaded) {
      // The old coordinator has been retired. Do not silently leave a live
      // but unsupervised VPN, or resume selectors against an uncertain core.
      return MobileReloadResult.requiresReconnect;
    }
    final live = await control.sessionSnapshot().timeout(nativeTimeout);
    if (stale() ||
        live.sessionId != sessionId ||
        live.status != AuroraStatus.connected) {
      return MobileReloadResult.unavailable;
    }
    _pendingGroups = null;
    await _activate(generation);
    if (stale()) return MobileReloadResult.unavailable;
    final contract = _contract!;
    if (contract.paths == null && _routeFamily != null) {
      // Legacy cache files preserve selector choices, but the user's family
      // preference is authoritative if it changed while reload was pending.
      await _selectOutbound(
        bridge,
        contract.outboundGroup.selectorTag,
        routeFamilyGroupTag(_routeFamily!),
      );
      if (stale()) return MobileReloadResult.unavailable;
    }
    _startWatchdog();
    return MobileReloadResult.reloaded;
  }

  Future<void> _selectOutbound(
    AuroraBridge bridge,
    String group,
    String tag, {
    bool settleDns = true,
  }) async {
    final pending = bridge.selectOutbound(group, tag);
    _pendingSelections.add(pending);
    try {
      await pending;
      if (settleDns) _noteSelectorChange();
    } finally {
      _pendingSelections.remove(pending);
    }
  }

  Future<void> _handleStatus(AuroraStatus status, int generation) async {
    if (generation != _generation || _disposed) return;
    if (status == AuroraStatus.connected) {
      // Only the transition into connected matters. The native side can still
      // deliver the same status repeatedly (multiple live NEVPNConnection
      // objects); re-logging and re-starting on each would spam the timeline
      // and the guards below.
      if (_everConnected) return;
      _everConnected = true;
      unawaited(_pathEventLog.record('vpn_connected'));
      _startNetworkMonitor();
      final coreRevision = _coreRevision;
      try {
        await _activate(generation);
      } finally {
        // NE connected only means the TUN exists. A path contract can still be
        // fail-closed or testing candidates until activation finishes. A failed
        // bootstrap also needs supervision while its TUN remains alive.
        if (generation == _generation &&
            coreRevision == _coreRevision &&
            !_disposed &&
            _everConnected) {
          _startWatchdog();
        }
      }
      return;
    }
    if ((status == AuroraStatus.disconnected && _everConnected) ||
        status == AuroraStatus.error) {
      unawaited(
        _pathEventLog.record('vpn_stopped', {'status': status.name}),
      );
      await detachAfterVpnStopped();
    }
  }

  Future<void> _activate(int generation) async {
    if (_coordinator != null || _activationToken != null) return;
    final bridge = _bridge;
    final contract = _contract;
    if (bridge == null || contract == null) return;
    if (contract.paths == null ||
        contract.pathPolicy == null ||
        contract.egress == null) {
      return;
    }
    final activation = Object();
    _activationToken = activation;
    final coordinator = _coordinatorFactory(bridge);
    coordinator.setPhysicalNetworkOnline(_physicalOnline);
    _coordinator = coordinator;
    _snapshotSubscription = coordinator.snapshots.listen((snapshot) {
      _latest = snapshot;
      if (!_snapshots.isClosed) _snapshots.add(snapshot);
      _logTransition(snapshot);
    }, onError: (_) {});
    try {
      await coordinator.start(contract, _preference);
      if (generation != _generation || _coordinator != coordinator) return;
      final pending = _pendingGroups;
      if (pending != null) await coordinator.onGroups(pending);
    } catch (_) {
      // A superseded bootstrap may still finish with a native command error.
      // Its bridge can already serve a replacement session, so it no longer
      // owns either that selector or the current observer subscription.
      if (_disposed ||
          generation != _generation ||
          _coordinator != coordinator) {
        await coordinator.dispose();
        return;
      }
      // Any coordinator/bootstrap failure leaves the still-running TUN on its
      // block outbound. Do this before disposing observers so an exception can
      // never strand the selector on the candidate that was being probed.
      try {
        await _selectOutbound(
          bridge,
          contract.outboundGroup.selectorTag,
          auroraFailClosedOutboundTag,
        );
      } catch (_) {
        // The compiler default is also fail-closed; preserve the original
        // activation failure for the caller if the command channel is gone.
      }
      if (_coordinator == coordinator) {
        _coordinator = null;
        await _snapshotSubscription?.cancel();
        _snapshotSubscription = null;
      }
      await coordinator.dispose();
      rethrow;
    } finally {
      if (identical(_activationToken, activation)) _activationToken = null;
    }
  }

  /// One line per state/reason/path/lease change — steady healthy snapshots
  /// every 30s round would otherwise drown the timeline.
  void _logTransition(PathHealthSnapshot snapshot) {
    final key =
        '${snapshot.state.name}|${snapshot.reasonCode}|'
        '${snapshot.selectedPath}|${snapshot.leaseHealth.name}';
    if (key == _lastLoggedTransition) return;
    _lastLoggedTransition = key;
    unawaited(
      _pathEventLog.record('path', {
        'state': snapshot.state.name,
        'reason': snapshot.reasonCode,
        'path': snapshot.selectedPath,
        'lease': snapshot.leaseHealth.name,
        'egressVerified': snapshot.egressVerified,
        'delayMs': snapshot.delayMs,
      }),
    );
  }

  void _startNetworkMonitor() {
    // Physical-network monitoring belongs to the session, not to the path
    // coordinator: single-path contracts have no coordinator, and they are
    // exactly the sessions that most need to notice the user changed networks.
    if (networkPollInterval > Duration.zero && _networkTimer == null) {
      _networkTimer = Timer.periodic(
        networkPollInterval,
        (_) => unawaited(_pollPhysicalNetwork()),
      );
      unawaited(_pollPhysicalNetwork());
    }
  }

  /// Runs for every contract shape after bootstrap. Two consecutive total-loss
  /// rounds can restart the tunnel via [tunnelRestartHandler].
  void _startWatchdog() {
    if (watchdogInterval <= Duration.zero) return;
    if (_watchdogTimer != null) return;
    _watchdogFailures = 0;
    _watchdogTimer = Timer(watchdogGrace, () {
      if (_disposed) return;
      unawaited(_watchdogTick());
      _watchdogTimer = Timer.periodic(
        watchdogInterval,
        (_) => unawaited(_watchdogTick()),
      );
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _watchdogConfirmTimer?.cancel();
    _watchdogConfirmTimer = null;
    _watchdogFailures = 0;
  }

  Future<void> _watchdogTick() async {
    if (_disposed || _watchdogProbeInFlight || _bridge == null) return;
    // No physical network: the probe can only fail, and that failure says
    // nothing about the tunnel. Charging it is what turned every hotel Wi-Fi
    // drop into a restart against NE's "No network available".
    if (!_physicalOnline) return;
    // The route was just changed: wait for the DNS deadline to pass (see [selectionSettle]) rather than skipping this
    // round — a round that is confirming is postponed the same way, so already-recorded failures are not lost.
    final notBefore = _probeNotBefore;
    if (notBefore != null) {
      var wait = notBefore.difference(DateTime.now());
      if (wait > selectionSettle) {
        // The wall clock was set back: do not make the watchdog wait for the clock to catch up.
        wait = selectionSettle;
        _probeNotBefore = DateTime.now().add(wait);
      }
      if (wait > Duration.zero) {
        _watchdogConfirmTimer?.cancel();
        _watchdogConfirmTimer = Timer(wait, () => unawaited(_watchdogTick()));
        return;
      }
      _probeNotBefore = null;
    }
    final epoch = _probeEpoch;
    final selectorTag = _contract?.outboundGroup.selectorTag;
    final node = selectorTag == null
        ? null
        : GoodputGate.effectiveNode(_pendingGroups ?? const [], selectorTag);
    _watchdogProbeInFlight = true;
    try {
      final report = await _watchdogProbe();
      // The session may have been torn down while the probe was in flight.
      if (_disposed || _watchdogTimer == null || epoch != _probeEpoch) return;
      final currentNode = selectorTag == null
          ? null
          : GoodputGate.effectiveNode(_pendingGroups ?? const [], selectorTag);
      if (node != null && currentNode != null && node != currentNode) return;
      _latestConnectionReport = report;
      if (!_connectionReports.isClosed) _connectionReports.add(report);
      // Keep this combined verdict; do not simplify it to "dead whenever no endpoint is reachable": when a round of probes
      // returns only unexpected HTTP-layer responses (a captcha wall, a block page, a rate-limit challenge), transportFailure
      // is false and reachable is all false too, but that is an interception page, not a broken tunnel — restarting the tunnel
      // can neither cure a captcha wall / captive portal, and would cut all of the user's in-flight connections and
      // burn the restart budget for nothing. compatibilityOnly exists precisely to separate these HTTP responses from
      // real transport-layer failures.
      //
      // Tunnel DNS not answering is also dead: the three sites' names are in the system cache, so being able to connect does not mean
      // new names still resolve (a machine-wide DNS hang of 8.5 minutes happened while those three sites stayed reachable).
      // Swapping legs cannot rescue a stuck DoH dial; if it is still dead after swapping, it falls through to a restart — only a new core clears it.
      final dead =
          (report.transportFailure &&
              !report.results.any((result) => result.reachable)) ||
          report.tunnelDnsDead;
      if (!dead) {
        if (_watchdogFailures > 0) {
          unawaited(_pathEventLog.record('watchdog_recovered'));
        }
        _watchdogFailures = 0;
        // A live probe is the only thing that proves a restart worked, so it is
        // also the only thing that may refund the give-up budget.
        _restartsWithoutRecovery = 0;
        _setDataPlaneHealth(DataPlaneHealth.alive);
        // "Alive" here only means tiny payloads came back. A node can pass
        // every one of those and still be unable to load a page, so ask the
        // more expensive question periodically.
        unawaited(_checkGoodput());
        return;
      }
      _watchdogFailures++;
      unawaited(
        _pathEventLog.record('watchdog_probe_dead', {
          'consecutive': _watchdogFailures,
          'category': report.category.name,
          'probes': report.diagnosticResults,
          'group': _activeGroupTag,
          'node': ?currentNode,
          'delays': _activeGroupDelays(),
        }),
      );
      if (_watchdogFailures == 1) {
        // Give the engine one chance to self-heal (urltest re-probes every
        // member and can switch protocols), then confirm quickly instead of
        // waiting a full interval. It must hit the currently active group: once a family is locked, the contract's
        // legacy urltest group is not in use at all, and testing it says nothing about whether the locked family is alive.
        try {
          await _bridge?.urlTest(_activeGroupTag);
        } catch (_) {}
        if (epoch != _probeEpoch || _disposed) return;
        _watchdogConfirmTimer?.cancel();
        _watchdogConfirmTimer = Timer(
          watchdogConfirmDelay,
          () => unawaited(_watchdogTick()),
        );
        return;
      }
      // Confirmed: two consecutive rounds of total loss. Say so now, so the UI does not keep claiming the connection is healthy.
      if (_dataPlaneHealth != DataPlaneHealth.deadUnrecoverable) {
        _setDataPlaneHealth(DataPlaneHealth.dead);
      }
      // Swapping a node is much lighter than restarting the tunnel: a restart cuts every in-flight connection, while the problem is often
      // only this one member (a leg blocked by a carrier). So try swapping first, and restart only if swapping does not work.
      if (await _demoteDeadNode(epoch)) return;
      if (epoch != _probeEpoch || _disposed) return;
      _triggerAutoRestart();
    } finally {
      if (epoch == _probeEpoch) _watchdogProbeInFlight = false;
    }
  }

  /// Books the currently active node as a "hard failure" and swaps it if possible. Returns true if the swap succeeded.
  ///
  /// Candidates are taken **only from the currently active group** (`_activeGroupTag`) — for a user who has locked a family, the lock must never
  /// be bypassed by a health check.
  ///
  /// **The first confirmed total loss necessarily spends one restart budget and cannot swap a node**: `observeHardFailure`
  /// needs two consecutive hard failures before it will call a node burnt out (a single total loss may just be the user's WiFi
  /// blipping, and swapping a node then costs tearing down every in-flight connection for nothing).
  /// A fresh `GoodputGate` called here the first time books the first charge, and `observeHardFailure`
  /// can only return null, so this time it necessarily falls to `_triggerAutoRestart()`.
  ///
  /// What really guards against "the same member being re-selected over and over" is that `goodputGate` **survives across sessions**
  /// (see the comment on [goodputGate]): a restart puts the selector back to `auto`, and if
  /// urltest picks the same dead node again, when the watchdog confirms total loss a second time, that is this node's second
  /// hard-failure charge — the cooldown triggers and this time the swap really happens. So the effect is: each gate lifetime (in
  /// practice roughly each app process) pays for only one restart, and from the second time on swapping a node no longer restarts. This is a
  /// deliberate trade-off, not a hole to be patched.
  Future<bool> _demoteDeadNode(int epoch) async {
    final bridge = _bridge;
    final contract = _contract;
    final groups = _pendingGroups;
    if (bridge == null || contract == null || groups == null) return false;
    final selectorTag = contract.outboundGroup.selectorTag;
    final node = GoodputGate.effectiveNode(groups, selectorTag);
    if (node == null) return false;
    final candidates = GoodputGate.candidatesIn(
      groups,
      _activeGroupTag,
      selectorTag,
    );
    if (candidates.length < 2) return false;
    final replacement = goodputGate.observeHardFailure(
      node: node,
      candidates: candidates,
      at: DateTime.now(),
    );
    if (replacement == null) return false;
    try {
      await _selectOutbound(bridge, selectorTag, replacement);
    } catch (_) {
      // If the swap did not go through, treat it as not swapped and let the restart path take over.
      return false;
    }
    if (_disposed || epoch != _probeEpoch) return false;
    lastDemotedFrom = node;
    lastDemotedTo = replacement;
    unawaited(
      _pathEventLog.record('hard_failure_demote', {
        'from': node,
        'to': replacement,
      }),
    );
    // After a node swap the failure counter is zeroed: the next round of probes has to prove from scratch whether the new node works,
    // rather than triggering a restart at once with the previous node's tally.
    _watchdogFailures = 0;
    return true;
  }

  /// The node most recently swapped out because of a hard failure, and its replacement, for the UI to name (null means it has not happened yet,
  /// or the last record was cleared by one of the two moments below).
  ///
  /// When it is cleared (missing either makes the UI name the wrong thing the next time it dies):
  /// one is when the data plane is re-verified as [DataPlaneHealth.alive] (`_setDataPlaneHealth`) —
  /// the problem the swap targeted is over; the other is when the session ends or is displaced (`_clearSession`) —
  /// the record no longer even makes sense for "which session is current". Without either, a new death could
  /// inherit an old reason pointing at a completely different node / session.
  String? lastDemotedFrom;
  String? lastDemotedTo;

  /// Measures what the active node can actually carry and demotes it if the
  /// answer is "nothing useful".
  ///
  /// The gate deliberately outlives individual sessions: a watchdog restart
  /// resets the selector to `auto`, urltest re-elects the same lowest-latency
  /// node, and without a cooldown that survives the restart the engine and this
  /// check would simply fight each other forever.
  Future<void> _checkGoodput() async {
    if (_disposed || _goodputInFlight) return;
    final due = _nextGoodputAt;
    if (due != null && DateTime.now().isBefore(due)) return;
    final bridge = _bridge;
    final contract = _contract;
    final groups = _pendingGroups;
    if (bridge == null || contract == null || groups == null) return;

    final selectorTag = contract.outboundGroup.selectorTag;
    final node = GoodputGate.effectiveNode(groups, selectorTag);
    if (node == null) return;
    // Confined to the group in effect, so a locked route family is never
    // escaped by a demotion.
    final candidates = GoodputGate.candidatesIn(
      groups,
      _activeGroupTag,
      selectorTag,
    );
    if (candidates.length < 2) return;

    final epoch = _probeEpoch;
    final groupTag = _activeGroupTag;
    _goodputInFlight = true;
    try {
      final sample = await _goodputProbe();
      if (_disposed || _watchdogTimer == null || epoch != _probeEpoch) return;
      if (groupTag != _activeGroupTag ||
          GoodputGate.effectiveNode(_pendingGroups ?? const [], selectorTag) !=
              node) {
        return;
      }
      final at = DateTime.now();
      // A sub-floor sample needs a second look before anything is torn down,
      // and that look should not be 90 seconds away — the user is staring at a
      // page that will not load. Same shape as the watchdog's confirm delay.
      final suspect =
          (sample.reachable || sample.stalled) &&
          goodputGate.isBelowFloor(sample.bytesPerSecond);
      _nextGoodputAt = at.add(suspect ? goodputConfirmDelay : goodputInterval);
      final replacement = goodputGate.observe(
        node: node,
        reachable: sample.reachable,
        stalled: sample.stalled,
        bytesPerSecond: sample.bytesPerSecond,
        candidates: candidates,
        at: at,
      );
      // Record every completed measurement, not just the ones that act. A
      // check that leaves no trace when it passes is indistinguishable from a
      // check that never ran — which is precisely how this class of fault
      // stayed invisible for weeks.
      unawaited(
        _pathEventLog.record('goodput', {
          'node': node,
          'kbps': sample.bytesPerSecond ~/ 1024,
          'reachable': sample.reachable,
          if (sample.stalled) 'stalled': true,
        }),
      );
      if (replacement == null) return;
      unawaited(
        _pathEventLog.record('goodput_demote', {
          'from': node,
          'to': replacement,
          'kbps': sample.bytesPerSecond ~/ 1024,
        }),
      );
      await _selectOutbound(bridge, selectorTag, replacement);
    } catch (_) {
      // Diagnostics must never break connectivity; the next tick retries.
    } finally {
      if (epoch == _probeEpoch) _goodputInFlight = false;
    }
  }

  /// Rate-limited so a genuinely dead physical network can never turn the
  /// watchdog into a restart loop: ≥90s between attempts, ≤4 per hour. The
  /// budget is charged only when the handler reports it actually acted.
  void _triggerAutoRestart() {
    final handler = tunnelRestartHandler;
    if (handler == null) return;
    // Restarting cannot reach a server whose IP is blackholed, and each cycle
    // tears down the default route the user's physical network is still
    // carrying. After two restarts that never produced a live probe, stop and
    // report instead of churning.
    if (_restartsWithoutRecovery >= maxRestartsWithoutRecovery) {
      if (_dataPlaneHealth != DataPlaneHealth.deadUnrecoverable) {
        unawaited(
          _pathEventLog.record('watchdog_restart_abandoned', {
            'restartsWithoutRecovery': _restartsWithoutRecovery,
          }),
        );
        _setDataPlaneHealth(DataPlaneHealth.deadUnrecoverable);
      }
      return;
    }
    final now = DateTime.now();
    _autoRestarts.removeWhere(
      (t) => now.difference(t) > const Duration(hours: 1),
    );
    final tooSoon =
        !_restartSpacingWaived &&
        _autoRestarts.isNotEmpty &&
        now.difference(_autoRestarts.last) < const Duration(seconds: 90);
    if (tooSoon || _autoRestarts.length >= 4) {
      // Once per suppression episode, not once per 30s tick: a long outage
      // otherwise fills the timeline with identical lines.
      if (!_suppressionLogged) {
        _suppressionLogged = true;
        unawaited(
          _pathEventLog.record('watchdog_restart_suppressed', {
            'restartsLastHour': _autoRestarts.length,
          }),
        );
      }
      return;
    }
    _suppressionLogged = false;
    _restartSpacingWaived = false;
    unawaited(_pathEventLog.record('watchdog_restart'));
    // Reset the failure counter so the next probe round starts fresh instead
    // of immediately re-triggering before the reconnect has a chance to prove
    // itself.
    _watchdogFailures = 0;
    unawaited(
      Future<bool>(handler)
          .then((acted) {
            if (acted) {
              _autoRestarts.add(DateTime.now());
              _restartsWithoutRecovery++;
            }
          })
          .catchError((Object error) {
            unawaited(
              _pathEventLog.record('watchdog_restart_failed', {
                'error': '$error',
              }),
            );
          }),
    );
  }

  Future<void> _pollPhysicalNetwork() async {
    if (_disposed) return;
    try {
      final signature = await _physicalNetworkSignature();
      if (signature.isEmpty || _disposed) return;
      final previous = _networkSignature;
      _networkSignature = signature;
      final online = isPhysicalNetworkOnline(signature);
      if (online != _physicalOnline) {
        _physicalOnline = online;
        _coordinator?.setPhysicalNetworkOnline(online);
        if (!online) {
          // Everything in flight was measured against a network that no
          // longer exists: a pending confirmation must not become round two.
          unawaited(_pathEventLog.record('physical_network_down'));
          _invalidateProbes();
          _setDataPlaneHealth(DataPlaneHealth.offline);
          return;
        }
        unawaited(_pathEventLog.record('physical_network_up'));
        // Nodes burnt while the network was gone were never at fault. The
        // gate deliberately outlives sessions (see [goodputGate]); this is
        // the one event that legitimately wipes it.
        goodputGate.forgetHistory();
        // The 90s spacing between restarts exists to let a reconnect prove
        // itself; a network that just came back deserves an immediate look.
        // The per-hour cap stays — a flapping link must not defeat it.
        _restartSpacingWaived = true;
      } else if (!online) {
        // A session that attached while the network was already gone never
        // sees a transition; still say so instead of "verifying…" forever.
        _coordinator?.setPhysicalNetworkOnline(false);
        _setDataPlaneHealth(DataPlaneHealth.offline);
        return;
      }
      if (previous != null && previous != signature) {
        // Timing only — the signature itself contains local addresses and
        // never belongs on disk.
        unawaited(_pathEventLog.record('network_changed'));
        // The core does ResetNetwork on a network change and DNS gets a new connection pool: any wait left over from an earlier swap is void.
        _networkChangedAt = DateTime.now();
        _probeNotBefore = null;
        // A different physical network is the one circumstance that can make a
        // previously hopeless server reachable again, so it refunds the
        // give-up budget.
        _restartsWithoutRecovery = 0;
        _suppressionLogged = false;
        if (_dataPlaneHealth == DataPlaneHealth.deadUnrecoverable) {
          _setDataPlaneHealth(DataPlaneHealth.dead);
        }
        await networkChanged();
        await _reelectAfterNetworkChange();
      }
    } catch (_) {
      // Interface enumeration is advisory; path probes continue without it.
    }
  }

  /// Hands the selector back to the group in effect so the engine re-elects.
  ///
  /// In one field incident every hard-failure demotion pins the selector
  /// to one concrete node, and nothing ever un-pins it. After the outage the
  /// pin sat on a direct-to-home node that this network cannot reach, and
  /// since dns-proxy rides the selector, 5 814 DNS exchanges died on that one
  /// dial (`dial tcp <home>:8443: i/o timeout`) — the "DNS keeps having problems" the
  /// user saw. A network change is exactly when the old verdict stops being
  /// worth anything, so re-elect instead of trusting it.
  ///
  /// Respects the family lock: [_activeGroupTag] is the locked `via-<family>`
  /// group when one is set. Paths-shaped contracts are the coordinator's job.
  Future<void> _reelectAfterNetworkChange() async {
    final bridge = _bridge;
    final contract = _contract;
    if (bridge == null || contract == null || contract.paths != null) return;
    final group = _activeGroupTag;
    try {
      // Do not wait for the DNS deadline: on a network change the core does ResetNetwork itself, DoH moves to a new connection
      // pool, and a dial stuck in the old pool no longer blocks new queries; right after the network returns is exactly when to verify.
      await _selectOutbound(
        bridge,
        contract.outboundGroup.selectorTag,
        group,
        settleDns: false,
      );
      await bridge.urlTest(group);
      unawaited(_pathEventLog.record('network_reelect', {'group': group}));
    } catch (_) {
      // The core may still be coming back with the network; the watchdog's
      // next round decides what to do about it.
    }
  }

  Future<void> detachAfterVpnStopped() async {
    _generation++;
    await _clearSession();
  }

  // A request already in flight may complete after reconnect, network change
  // or a manual family change. Its evidence belongs only to its original path.
  void _invalidateProbes() {
    _probeEpoch++;
    // An offline verdict is about the physical network, not about any probe;
    // only the poller may lift it.
    _setDataPlaneHealth(
      _physicalOnline ? DataPlaneHealth.unknown : DataPlaneHealth.offline,
    );
    _latestConnectionReport = null;
    if (!_connectionReports.isClosed) _connectionReports.add(null);
    _watchdogProbeInFlight = false;
    _goodputInFlight = false;
    _nextGoodputAt = null;
    _watchdogFailures = 0;
    _watchdogConfirmTimer?.cancel();
    _watchdogConfirmTimer = null;
  }

  Future<void> _clearSession() async {
    _activationToken = null;
    _invalidateProbes();
    _stopWatchdog();
    // A new session is a new core; there is no dial stuck on an old node to wait for.
    _probeNotBefore = null;
    _networkChangedAt = null;
    // No session means no data-plane observation. The give-up counter is
    // deliberately NOT reset here: it has to survive the watchdog's own
    // stop+start cycle, which is the thing it counts.
    _setDataPlaneHealth(DataPlaneHealth.unknown);
    _networkTimer?.cancel();
    _networkTimer = null;
    _networkSignature = null;
    _lastLoggedTransition = null;
    _pendingGroups = null;
    _everConnected = false;
    await _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    final coordinator = _coordinator;
    _coordinator = null;
    if (coordinator != null) await coordinator.dispose();
    await _groupsSubscription?.cancel();
    _groupsSubscription = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    _bridge = null;
    _contract = null;
    // The swap record belongs to the session that just ended (or the one about to be displaced by attach()) —
    // it must never be inherited by the next session. A new session's first dead verdict must be its own evidence, not
    // a UI pinned to an old reason from a previous session that may involve a completely different family / node.
    lastDemotedFrom = null;
    lastDemotedTo = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _clearSession();
    await _snapshots.close();
    await _dataPlane.close();
    await _connectionReports.close();
  }
}
