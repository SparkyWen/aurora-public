import 'dart:async';

import '../core/aurora_bridge.dart';
import '../core/contract.dart';
import '../core/egress_lease.dart';
import '../core/path_health.dart';
import '../data/connection_probe.dart';
import '../data/egress_lease_repository.dart';

typedef PathEgressProbe =
    Future<EgressProbeReport> Function(String group, EgressPolicy policy);
typedef LeaseRefresh =
    Future<EgressLease> Function(EgressPolicy policy, DeliveryInfo delivery);

enum LeaseHealth { unavailable, refreshing, valid, invalid }

class PathHealthSnapshot {
  const PathHealthSnapshot({
    required this.preference,
    required this.state,
    required this.selectedGroup,
    required this.reasonCode,
    required this.egressVerified,
    this.selectedPath = '',
    this.activeNode = '',
    this.delayMs,
    this.p50Ms,
    this.p95Ms,
    this.jitterMs,
    this.recoveryRounds = 0,
    this.leaseHealth = LeaseHealth.unavailable,
    this.leaseKeyId,
    this.leaseSequence,
    this.leaseExpiresAt,
  });

  final PathPreference preference;
  final AuroraPathState state;
  final String selectedPath;
  final String selectedGroup;
  final String activeNode;
  final String reasonCode;
  final bool egressVerified;
  final int? delayMs;
  final int? p50Ms;
  final int? p95Ms;
  final int? jitterMs;
  final int recoveryRounds;
  final LeaseHealth leaseHealth;
  final String? leaseKeyId;
  final int? leaseSequence;
  final DateTime? leaseExpiresAt;

  bool get blocked => state == AuroraPathState.homeBlocked;
}

/// Converts libbox group snapshots into ordered path observations, refreshes
/// the signed home-egress lease, and applies selector changes without ever
/// stopping the OS TUN as a fallback action.
class PathHealthCoordinator {
  PathHealthCoordinator({
    required this.bridge,
    DateTime Function()? now,
    PathEgressProbe? probe,
    LeaseRefresh? refreshLease,
    this.healthInterval = const Duration(seconds: 30),
    this.fastRetestDelay = const Duration(seconds: 5),
    this.startupGracePeriod = const Duration(seconds: 12),
  }) : _now = now ?? DateTime.now,
       _probe =
           probe ??
           ((_, policy) => ConnectionProbeService.runEgress(
             expectedIpv4: policy.expectedIpv4,
           )) {
    if (refreshLease == null) {
      final repository = EgressLeaseRepository(now: _now);
      _leaseRepository = repository;
      _refreshLease = repository.refresh;
    } else {
      _refreshLease = refreshLease;
    }
  }

  final AuroraBridge bridge;
  final DateTime Function() _now;
  final PathEgressProbe _probe;
  final Duration healthInterval;
  final Duration fastRetestDelay;
  final Duration startupGracePeriod;
  late final LeaseRefresh _refreshLease;
  EgressLeaseRepository? _leaseRepository;
  final StreamController<PathHealthSnapshot> _snapshots =
      StreamController<PathHealthSnapshot>.broadcast();

  AuroraContract? _contract;
  PathHealthController? _controller;
  PathPreference _preference = PathPreference.auto;
  List<String> _pathOrder = const [];
  Map<String, String> _groupsByPath = const {};
  final Map<String, EgressProbeReport> _egress = {};

  /// Network epoch in which each path last had a *verified* egress probe.
  /// A later unknown/timeout probe never clears this: verification becoming
  /// unavailable is not evidence that the exit moved.
  final Map<String, int> _lastVerifiedEpoch = {};
  final Map<String, PathObservation> _observations = {};
  final Map<String, List<int>> _delaySamples = {};
  List<OutboundGroupInfo> _lastGroups = const [];
  String _selectedPath = '';
  String _selectedGroup = '';
  String _bridgeSelectedGroup = '';
  String? _lastRoundSignature;
  DateTime? _lastRoundAt;
  DateTime? _startedAt;
  EgressLease? _lease;
  LeaseHealth _leaseHealth = LeaseHealth.unavailable;
  Timer? _timer;
  Timer? _fastRetestTimer;
  bool _roundInFlight = false;
  bool _bootstrapped = false;
  bool _disposed = false;
  int _networkEpoch = 0;
  int _operationGeneration = 0;
  int? _activeOperationGeneration;
  Future<void> _operationTail = Future<void>.value();
  Future<void> _selectorTail = Future<void>.value();
  bool _selectionInFlight = false;
  List<OutboundGroupInfo>? _pendingGroups;
  Future<void>? _groupsOperation;

  PathHealthSnapshot _current = const PathHealthSnapshot(
    preference: PathPreference.auto,
    state: AuroraPathState.relayPublic,
    selectedGroup: '',
    reasonCode: PathReason.pathHealthy,
    egressVerified: false,
  );

  Stream<PathHealthSnapshot> get snapshots => _snapshots.stream;
  PathHealthSnapshot get current => _current;
  int get networkEpoch => _networkEpoch;

  Future<void> start(AuroraContract contract, PathPreference preference) async {
    final paths = contract.paths;
    final policy = contract.pathPolicy;
    final egress = contract.egress;
    if (paths == null || policy == null || egress == null || _disposed) return;

    _contract = contract;
    _startedAt = _now();
    _preference = preference;
    _pathOrder = [paths.preferred, ...policy.fallbackOrder];
    _groupsByPath = {
      for (final pathId in _pathOrder) pathId: paths.items[pathId]!.groupTag,
    };
    _selectedPath = '';
    _selectedGroup = '';
    _bridgeSelectedGroup = auroraFailClosedOutboundTag;
    _controller = PathHealthController(
      policy: policy.health,
      pathOrder: _pathOrder,
      groups: _groupsByPath,
    );
    // Network changes can invalidate startup's in-flight lease/probe too.
    // Retry the bootstrap in the latest generation before enabling telemetry.
    while (!_disposed && !_bootstrapped) {
      await _serialize(() async {
        await _refreshLeaseNow();
        if (!await _enforceLeaseBoundary()) {
          await _verifyStartupPaths();
        }
        _checkOperation();
        _bootstrapped = true;
        if (healthInterval > Duration.zero) {
          _timer = Timer.periodic(
            healthInterval,
            (_) => unawaited(_runHealthRound()),
          );
        }
        await _requestUrlTests();
      });
    }
  }

  Future<void> setPreference(PathPreference preference) async {
    if (_contract == null || _disposed || _preference == preference) return;
    // Record the latest user intent immediately; queued requests must not
    // overwrite a newer preference or lose it when the network changes.
    _preference = preference;
    await _serialize(() async {
      await _refreshLeaseNow();
      if (await _enforceLeaseBoundary()) {
        await _requestUrlTests();
        return;
      }
      if (_observations.length == _pathOrder.length) {
        await _evaluate();
        return;
      }
      await _verifyPreferredPaths();
    });
  }

  Future<void> onGroups(List<OutboundGroupInfo> groups) async {
    // libbox streams snapshots from the moment the tunnel is up, racing the
    // startup lease fetch and path sweep. The supervisor replays the pending
    // snapshot once start() returns, so dropping these loses nothing.
    if (_contract == null || _disposed) return;
    // Expiry must preempt a pending probe, even for incomplete/duplicate
    // telemetry. All ordinary decisions share the probe's operation queue.
    if (_signedLeaseInvalid && (_bootstrapped || _lease != null)) {
      await _enforceLeaseBoundary(preempt: true);
      return;
    }
    if (!_bootstrapped) return;
    _pendingGroups = groups;
    await (_groupsOperation ??= _drainGroups());
  }

  Future<void> _drainGroups() async {
    try {
      while (!_disposed && _pendingGroups != null) {
        await _serialize(() async {
          final groups = _pendingGroups;
          _pendingGroups = null;
          if (groups != null) await _consumeGroups(groups);
        });
      }
    } finally {
      _groupsOperation = null;
    }
  }

  Future<void> _consumeGroups(List<OutboundGroupInfo> groups) async {
    if (await _enforceLeaseBoundary()) return;
    _checkOperation();
    final pathGroups = <String, OutboundGroupInfo>{};
    for (final pathId in _pathOrder) {
      final group = _findGroup(groups, _groupsByPath[pathId]!);
      if (group == null || group.items.isEmpty) return;
      pathGroups[pathId] = group;
    }
    final now = _now();
    final startedAt = _startedAt;
    if (startedAt != null &&
        now.difference(startedAt) < startupGracePeriod &&
        pathGroups.values.any(_awaitingFirstResult)) {
      return;
    }
    final signature = _roundSignature(pathGroups.values);
    if (signature == _lastRoundSignature &&
        _lastRoundAt != null &&
        now.difference(_lastRoundAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastRoundSignature = signature;
    _lastRoundAt = now;
    _lastGroups = groups;
    _bridgeSelectedGroup =
        _findGroup(groups, _contract!.outboundGroup.selectorTag)?.selected ??
        _bridgeSelectedGroup;
    for (final entry in pathGroups.entries) {
      _observations[entry.key] = _observation(
        entry.key,
        entry.value,
        _egress[entry.key],
      );
    }
    await _evaluate();
  }

  Future<void> onNetworkChanged() async {
    if (_contract == null || _disposed) return;
    _operationGeneration++;
    _networkEpoch++;
    _pendingGroups = null;
    _egress.clear();
    _lastVerifiedEpoch.clear();
    _observations.clear();
    _delaySamples.clear();
    _lastRoundSignature = null;
    _lastRoundAt = null;
    _fastRetestTimer?.cancel();
    _fastRetestTimer = null;
    if (_signedLeaseInvalid && (_bootstrapped || _lease != null)) {
      await _enforceLeaseBoundary(preempt: true);
    }
    if (!_bootstrapped) return; // start() retries its invalidated operation.
    await _serialize(_recheckCurrentPath);
  }

  Future<void> _recheckCurrentPath() async {
    await _refreshLeaseNow();
    if (await _enforceLeaseBoundary()) {
      await _requestUrlTests();
      return;
    }
    _checkOperation();
    if (_selectedPath.isEmpty ||
        (_preference == PathPreference.homeDirect &&
            _selectedPath != _pathOrder.last)) {
      await _verifyPreferredPaths();
    } else {
      final report = await _probePath(_selectedPath);
      _checkOperation();
      if (await _enforceLeaseBoundary()) return;
      _checkOperation();
      if (await _isolateConfirmedMismatch(report)) {
        await _requestUrlTests();
        return;
      }
    }
    await _requestUrlTests();
  }

  /// Set by the session supervisor while the physical network has no usable
  /// interface. A health round then can only fail, and acting on that failure
  /// (walking the controller to fail-closed, burning flap budget) would blame
  /// a path for a network that does not exist. `onNetworkChanged` wipes the
  /// evidence and restarts rounds when the network is back.
  bool _physicalOnline = true;

  void setPhysicalNetworkOnline(bool online) {
    _physicalOnline = online;
    if (!online) {
      _fastRetestTimer?.cancel();
      _fastRetestTimer = null;
    }
  }

  Future<void> _runHealthRound() async {
    if (_disposed || _roundInFlight || _contract == null) return;
    if (!_physicalOnline) return;
    _roundInFlight = true;
    try {
      await _serialize(_recheckCurrentPath);
    } finally {
      _roundInFlight = false;
    }
  }

  Future<void> _verifyStartupPaths() async {
    await _verifyPreferredPaths();
  }

  Future<void> _verifyPreferredPaths({bool refreshBefore = false}) async {
    if (refreshBefore) await _refreshLeaseNow();
    if (await _enforceLeaseBoundary()) return;
    _checkOperation();
    final candidates = _preference == PathPreference.homeDirect
        ? <String>[_pathOrder.last]
        : _pathOrder;
    var sawMismatch = false;
    for (final pathId in candidates) {
      final group = _groupsByPath[pathId]!;
      await _selectGroup(group);
      _checkOperation();
      _selectedPath = pathId;
      _selectedGroup = group;
      final report = await _probePath(pathId);
      _checkOperation();
      if (await _enforceLeaseBoundary()) return;
      _checkOperation();
      if (report.egress == EgressStatus.verified) {
        _emitInitial();
        return;
      }
      sawMismatch = sawMismatch || report.egress == EgressStatus.mismatch;
    }
    // Report what actually happened: a confirmed foreign exit is a mismatch,
    // an unreachable verification chain is "unverified" — the distinction is
    // what the on-disk timeline needs to be diagnosable.
    await _stopForSafety(
      PathDecision(
        state: AuroraPathState.homeBlocked,
        selectedGroup: '',
        reasonCode: sawMismatch
            ? PathReason.egressMismatch
            : PathReason.egressUnverified,
        switchRequired: true,
        requiresEgressVerification: true,
      ),
    );
  }

  Future<void> _evaluate() async {
    _checkOperation();
    final controller = _controller;
    if (controller == null || _observations.length != _pathOrder.length) return;
    var decision = controller.evaluate(
      observations: _observationsWithProbes(),
      preference: _preference,
      now: _now(),
      networkEpoch: _networkEpoch,
    );
    if (decision.selectedGroup.isEmpty) {
      await _stopForSafety(decision);
      return;
    }

    final switched =
        decision.selectedGroup != _selectedGroup ||
        decision.selectedGroup != _bridgeSelectedGroup;
    if (switched) {
      decision = await _selectAndVerify(decision);
      _checkOperation();
      if (decision.selectedGroup.isEmpty) {
        await _stopForSafety(decision);
        return;
      }
    }
    _selectedPath = decision.selectedPath;
    _selectedGroup = decision.selectedGroup;
    _manageFastRetest(_observations[decision.selectedPath]);
    _emitDecision(decision);
  }

  Future<PathDecision> _selectAndVerify(PathDecision decision) async {
    final heldPath = _selectedPath;
    final heldGroup = _selectedGroup;
    for (var attempts = 0; attempts < _pathOrder.length; attempts++) {
      await _refreshLeaseNow();
      _checkOperation();
      if (_signedLeaseInvalid) return _leaseInvalidDecision;
      await _selectGroup(decision.selectedGroup);
      _checkOperation();
      _selectedPath = decision.selectedPath;
      _selectedGroup = decision.selectedGroup;
      final report = await _probePath(decision.selectedPath);
      _checkOperation();
      if (_signedLeaseInvalid) return _leaseInvalidDecision;
      if (report.egress == EgressStatus.verified) return decision;
      if (report.egress != EgressStatus.mismatch) {
        // The echo endpoints gave no identity answer at all (timeouts or
        // challenges). That is a verification outage, not evidence that this
        // candidate leaks — fabricating a mismatch here is what used to
        // cascade every candidate to unusable and land on fail-closed while
        // the tunnel was actually fine.
        return _holdVerifiedPath(heldPath, heldGroup);
      }

      // A newly selected path is not allowed to carry unverified traffic. Feed
      // the confirmed mismatch to the pure controller so an upgrade rolls back
      // one level, while a failed downgrade continues toward home/fail-closed.
      _egress[decision.selectedPath] = const EgressProbeReport(
        egress: EgressStatus.mismatch,
        category: ProbeCategory.transport,
        transportFailure: true,
      );
      decision = _controller!.evaluate(
        observations: _observationsWithProbes(),
        preference: _preference,
        now: _now(),
        networkEpoch: _networkEpoch,
      );
      if (decision.selectedGroup.isEmpty) return decision;
    }
    return const PathDecision(
      state: AuroraPathState.homeBlocked,
      selectedGroup: '',
      reasonCode: PathReason.homeUnavailable,
      switchRequired: true,
      requiresEgressVerification: true,
    );
  }

  /// Falls back to the path that already proved its egress in this network
  /// epoch and still has a live transport. Only when no such path exists does
  /// a verification outage degrade to fail-closed.
  Future<PathDecision> _holdVerifiedPath(String path, String group) async {
    final observation = _observations[path];
    final eligible =
        path.isNotEmpty &&
        group.isNotEmpty &&
        _lastVerifiedEpoch[path] == _networkEpoch &&
        observation != null &&
        !observation.completelyFailed;
    if (!eligible) {
      return const PathDecision(
        state: AuroraPathState.homeBlocked,
        selectedGroup: '',
        reasonCode: PathReason.egressUnverified,
        switchRequired: true,
        requiresEgressVerification: true,
      );
    }
    await _selectGroup(group);
    _checkOperation();
    _selectedPath = path;
    _selectedGroup = group;
    return PathDecision(
      state: _stateForPath(path),
      selectedPath: path,
      selectedGroup: group,
      reasonCode: PathReason.egressUnverified,
      switchRequired: false,
      requiresEgressVerification: true,
    );
  }

  Future<void> _selectGroup(String target) async {
    _checkOperation();
    _selectionInFlight = true;
    try {
      await _writeSelector(target, _activeOperationGeneration!);
    } finally {
      _selectionInFlight = false;
    }
  }

  // Safety may interrupt a probe, but must follow any selector command already
  // handed to the native bridge. Its acknowledgement cannot overtake blocking.
  Future<void> _writeSelector(String target, int generation) {
    final result = _selectorTail.then((_) async {
      _checkGeneration(generation);
      final contract = _contract;
      if (contract == null ||
          target.isEmpty ||
          target == _bridgeSelectedGroup) {
        return;
      }
      await bridge.selectOutbound(contract.outboundGroup.selectorTag, target);
      _bridgeSelectedGroup = target;
      _checkGeneration(generation);
    });
    _selectorTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<EgressProbeReport> _probePath(
    String pathId, {
    bool refreshBefore = false,
  }) async {
    _checkOperation();
    final epoch = _networkEpoch;
    final policy = _contract?.egress;
    final group = _groupsByPath[pathId];
    if (policy == null || group == null) return _unverifiedTransport;
    if (refreshBefore) await _refreshLeaseNow();
    _checkOperation();
    var effective = _effectiveEgressPolicy(policy);
    if (effective == null) {
      _egress[pathId] = _unverifiedTransport;
      return _unverifiedTransport;
    }
    var report = await _probe(group, effective);
    _checkOperation();
    if (report.egress == EgressStatus.mismatch && policy.hasSignedLease) {
      await _refreshLeaseNow();
      _checkOperation();
      effective = _effectiveEgressPolicy(policy);
      report = effective == null
          ? _unverifiedTransport
          : await _probe(group, effective);
      _checkOperation();
    }
    // The lease may expire while the echo request is in flight. Its response
    // cannot establish identity after that lease's validity window.
    if (_signedLeaseInvalid) return _unverifiedTransport;
    _egress[pathId] = report;
    if (report.egress == EgressStatus.verified) {
      _lastVerifiedEpoch[pathId] = epoch;
    }
    return report;
  }

  Future<void> _refreshLeaseNow() async {
    _checkOperation();
    final contract = _contract;
    final policy = contract?.egress;
    if (contract == null || policy == null || !policy.hasSignedLease) {
      _leaseHealth = LeaseHealth.unavailable;
      return;
    }
    _leaseHealth = LeaseHealth.refreshing;
    try {
      final candidate = await _refreshLease(policy, contract.delivery);
      _checkOperation();
      if (!candidate.isValidAt(_now())) throw StateError('lease_invalid');
      _lease = candidate;
      _leaseHealth = LeaseHealth.valid;
    } on _StalePathOperation {
      rethrow;
    } catch (_) {
      _checkOperation();
      if (_lease?.isValidAt(_now()) ?? false) {
        _leaseHealth = LeaseHealth.valid;
      } else {
        _lease = null;
        _leaseHealth = LeaseHealth.invalid;
      }
    }
  }

  /// The safety boundary is lease *validity*, not refresh activity. A refresh
  /// round-trip takes seconds through the double-hop tunnel and runs every 30s;
  /// treating the in-flight window (`LeaseHealth.refreshing`) as invalid let
  /// any concurrent groups event slam the selector to fail-closed mid-session.
  bool get _signedLeaseInvalid {
    final policy = _contract?.egress;
    if (policy == null || !policy.hasSignedLease) return false;
    final lease = _lease;
    return lease == null || !lease.isValidAt(_now());
  }

  Future<bool> _enforceLeaseBoundary({bool preempt = false}) async {
    if (!_signedLeaseInvalid) return false;
    if (preempt) {
      // Once the bridge is blocked, refreshing the lease is how it recovers.
      // Repeated telemetry must not keep canceling that recovery request.
      if (_selectedPath.isNotEmpty ||
          _bridgeSelectedGroup != auroraFailClosedOutboundTag ||
          _selectionInFlight) {
        _operationGeneration++;
      }
      _pendingGroups = null;
    }
    try {
      await _stopForSafety(
        _leaseInvalidDecision,
        generation: preempt ? _operationGeneration : null,
      );
    } on _StalePathOperation {
      if (!preempt) rethrow;
    }
    return true;
  }

  Future<bool> _isolateConfirmedMismatch(EgressProbeReport report) async {
    if (report.egress != EgressStatus.mismatch) return false;
    await _stopForSafety(_leaseInvalidDecision);
    return true;
  }

  EgressPolicy? _effectiveEgressPolicy(EgressPolicy policy) {
    if (!policy.hasSignedLease) return policy;
    final lease = _lease;
    if (lease == null || !lease.isValidAt(_now())) return null;
    return policy.copyWith(expectedIpv4: lease.ipv4);
  }

  Map<String, PathObservation> _observationsWithProbes() => {
    for (final entry in _observations.entries)
      entry.key: _withProbe(entry.value, _egress[entry.key]),
  };

  PathObservation _observation(
    String pathId,
    OutboundGroupInfo group,
    EgressProbeReport? probe,
  ) {
    OutboundItem? selected;
    for (final item in group.items) {
      if (item.tag == group.selected) {
        selected = item;
        break;
      }
    }
    if (selected == null) {
      final successful = group.items.where((item) => item.delayMs > 0).toList()
        ..sort((left, right) => left.delayMs.compareTo(right.delayMs));
      if (successful.isNotEmpty) selected = successful.first;
    }
    final delay = selected != null && selected.delayMs > 0
        ? selected.delayMs
        : null;
    final samples = _delaySamples.putIfAbsent(pathId, () => []);
    if (delay != null) {
      samples.add(delay);
      final window = _contract!.pathPolicy!.health.rollingWindow;
      if (samples.length > window) samples.removeAt(0);
    }
    final sorted = [...samples]..sort();
    final p50 = _percentile(sorted, .50);
    final p95 = _percentile(sorted, .95);
    return PathObservation(
      selectedNode: delay == null ? group.selected : selected!.tag,
      attempts: 1,
      successes: delay == null ? 0 : 1,
      delayMs: delay,
      p50Ms: p50,
      p95Ms: p95,
      jitterMs: p50 == null || p95 == null ? null : p95 - p50,
      transportFailure: group.items.isNotEmpty && delay == null,
      egress: probe?.egress ?? EgressStatus.unknown,
      compatibilityOnly: probe?.compatibilityOnly ?? false,
    );
  }

  PathObservation _withProbe(
    PathObservation source,
    EgressProbeReport? probe,
  ) => PathObservation(
    selectedNode: source.selectedNode,
    attempts: source.attempts,
    successes: source.successes,
    delayMs: source.delayMs,
    p50Ms: source.p50Ms,
    p95Ms: source.p95Ms,
    jitterMs: source.jitterMs,
    // Transport health is the group's own urltest signal. An IP-echo probe
    // failing (endpoint slow/throttled/down) while urltest still completes is
    // a verification outage, not a dead path — merging it here is what used
    // to escalate a probe hiccup into hard-failure rounds and fail-closed.
    transportFailure: source.transportFailure,
    compatibilityOnly: probe?.compatibilityOnly ?? false,
    egress: probe?.egress ?? EgressStatus.unknown,
  );

  void _manageFastRetest(PathObservation? observation) {
    if (observation == null ||
        observation.compatibilityOnly ||
        !observation.completelyFailed) {
      _fastRetestTimer?.cancel();
      _fastRetestTimer = null;
      return;
    }
    if (fastRetestDelay <= Duration.zero || _fastRetestTimer != null) return;
    _fastRetestTimer = Timer(fastRetestDelay, () {
      _fastRetestTimer = null;
      unawaited(_runHealthRound());
    });
  }

  Future<void> _stopForSafety(PathDecision decision, {int? generation}) async {
    final currentGeneration = generation ?? _activeOperationGeneration!;
    await _writeSelector(auroraFailClosedOutboundTag, currentGeneration);
    _checkGeneration(currentGeneration);
    // Mark the transition only after the bridge has acknowledged/read back the
    // running core selection. A transient error must remain retryable.
    _selectedPath = '';
    _selectedGroup = '';
    _emitDecision(decision);
  }

  Future<void> _requestUrlTests() async {
    _checkOperation();
    for (final pathId in _pathOrder) {
      await bridge.urlTest(_groupsByPath[pathId]!);
      _checkOperation();
    }
  }

  void _emitDecision(PathDecision decision) {
    final observation = _observations[decision.selectedPath];
    _current = PathHealthSnapshot(
      preference: _preference,
      state: decision.state,
      selectedPath: decision.selectedPath,
      selectedGroup: decision.selectedGroup,
      activeNode:
          observation?.selectedNode ?? _activeNode(decision.selectedGroup),
      reasonCode: decision.reasonCode,
      egressVerified:
          _egress[decision.selectedPath]?.egress == EgressStatus.verified,
      delayMs: observation?.delayMs,
      p50Ms: observation?.p50Ms,
      p95Ms: observation?.p95Ms,
      jitterMs: observation?.jitterMs,
      recoveryRounds: decision.recoveryRounds,
      leaseHealth: _leaseHealth,
      leaseKeyId: _lease?.keyId,
      leaseSequence: _lease?.sequence,
      leaseExpiresAt: _lease?.expiresAt,
    );
    if (!_snapshots.isClosed) _snapshots.add(_current);
  }

  AuroraPathState _stateForPath(String pathId) => switch (pathId) {
    'relay_public' => AuroraPathState.relayPublic,
    'relay_tailnet' => AuroraPathState.relayTailnet,
    'home' when _pathOrder.first == 'relay_public' => AuroraPathState.homeDirect,
    'home' => AuroraPathState.homeFallback,
    _ => AuroraPathState.relayPreferred,
  };

  void _emitInitial() {
    _checkOperation();
    final isHome = _selectedPath == _pathOrder.last;
    _current = PathHealthSnapshot(
      preference: _preference,
      state: _stateForPath(_selectedPath),
      selectedPath: _selectedPath,
      selectedGroup: _selectedGroup,
      reasonCode: isHome ? PathReason.manualHome : PathReason.pathHealthy,
      egressVerified: _egress[_selectedPath]?.egress == EgressStatus.verified,
      leaseHealth: _leaseHealth,
      leaseKeyId: _lease?.keyId,
      leaseSequence: _lease?.sequence,
      leaseExpiresAt: _lease?.expiresAt,
    );
    if (!_snapshots.isClosed) _snapshots.add(_current);
  }

  String _activeNode(String groupTag) =>
      _findGroup(_lastGroups, groupTag)?.selected ?? '';

  static bool _awaitingFirstResult(OutboundGroupInfo group) =>
      group.items.every((item) => item.delayMs <= 0);

  static int? _percentile(List<int> sorted, double percentile) {
    if (sorted.isEmpty) return null;
    final rank = (percentile * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  static OutboundGroupInfo? _findGroup(
    Iterable<OutboundGroupInfo> groups,
    String tag,
  ) {
    for (final group in groups) {
      if (group.tag == tag) return group;
    }
    return null;
  }

  static String _roundSignature(Iterable<OutboundGroupInfo> groups) => groups
      .expand(
        (group) => [
          group.tag,
          group.selected,
          ...group.items.map((item) => '${item.tag}:${item.delayMs}'),
        ],
      )
      .join('|');

  /// Retire this owner before reloading its core. A selector RPC already
  /// handed to the bridge must settle before the replacement is created.
  /// Other delayed probe results observe _disposed before issuing commands.
  Future<void> disposeForCoreReload() async {
    await dispose();
    await _selectorTail;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _operationGeneration++;
    _pendingGroups = null;
    _timer?.cancel();
    _fastRetestTimer?.cancel();
    await _leaseRepository?.close();
    await _snapshots.close();
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final generation = _operationGeneration;
    final result = _operationTail.then((_) async {
      if (_disposed || generation != _operationGeneration) return;
      _activeOperationGeneration = generation;
      try {
        await operation();
      } on _StalePathOperation {
        // The owning network/session was superseded while awaiting I/O.
      } finally {
        _activeOperationGeneration = null;
      }
    });
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _checkOperation() => _checkGeneration(_activeOperationGeneration!);

  void _checkGeneration(int generation) {
    if (_disposed || generation != _operationGeneration) {
      throw const _StalePathOperation();
    }
  }

  static const _unverifiedTransport = EgressProbeReport(
    egress: EgressStatus.unknown,
    category: ProbeCategory.transport,
    transportFailure: true,
  );

  static const _leaseInvalidDecision = PathDecision(
    state: AuroraPathState.homeBlocked,
    selectedGroup: '',
    reasonCode: PathReason.egressMismatch,
    switchRequired: true,
    requiresEgressVerification: true,
  );
}

class _StalePathOperation implements Exception {
  const _StalePathOperation();
}
