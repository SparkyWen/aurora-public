/// Deterministic ordered household-path health and failover policy.
///
/// This unit has no Flutter, bridge, network, or wall-clock dependency. The
/// caller supplies every observation, timestamp, and physical-network epoch.
library;

import 'contract.dart';

enum PathPreference { auto, homeDirect }

enum AuroraPathState {
  relayPublic,
  relayTailnet,
  homeDirect,
  recovering,
  homeBlocked,

  // Compatibility states for a legacy two-path contract/UI during migration.
  relayPreferred,
  relaySuspect,
  homeFallback,
  relayRecovering,
}

enum EgressStatus { unknown, verified, mismatch }

abstract final class PathReason {
  static const pathHealthy = 'path_healthy';
  static const pathHardFailure = 'path_hard_failure';
  static const pathLoss = 'path_loss';
  static const pathJitter = 'path_jitter';
  static const pathLatency = 'path_latency';
  static const pathRecovered = 'path_recovered';
  static const manualHome = 'manual_home';
  static const egressMismatch = 'egress_mismatch';
  static const egressUnverified = 'egress_unverified';
  static const homeUnavailable = 'home_unavailable';
  static const flapCooldown = 'flap_cooldown';

  // Stable aliases consumed by the current UI while it migrates to N paths.
  static const relayHealthy = pathHealthy;
  static const relayHardFailure = pathHardFailure;
  static const relayLoss = pathLoss;
  static const relayLatency = pathLatency;
  static const relayRecovered = pathRecovered;
}

class PathObservation {
  const PathObservation({
    this.selectedNode = '',
    required this.attempts,
    required this.successes,
    required this.egress,
    this.delayMs,
    this.p50Ms,
    this.p95Ms,
    this.jitterMs,
    this.transportFailure = false,
    this.compatibilityOnly = false,
  }) : assert(attempts >= 0),
       assert(successes >= 0),
       assert(successes <= attempts),
       assert(delayMs == null || delayMs >= 0),
       assert(p50Ms == null || p50Ms >= 0),
       assert(p95Ms == null || p95Ms >= 0),
       assert(jitterMs == null || jitterMs >= 0);

  /// The urltest group's selected member. Delays from unselected members are
  /// deliberately absent from this observation.
  final String selectedNode;
  final int attempts;
  final int successes;
  final int? delayMs;
  final int? p50Ms;
  final int? p95Ms;
  final int? jitterMs;
  final bool transportFailure;

  /// A completed Challenge, CAPTCHA, 403, or 429 is site compatibility data,
  /// not a failed transport observation.
  final bool compatibilityOnly;
  final EgressStatus egress;

  double get successRate => attempts == 0 ? 0 : successes / attempts;
  bool get completelyFailed =>
      transportFailure || (attempts > 0 && successes == 0);
  /// Latency policy uses the temporal median. The instantaneous selected-item
  /// delay is only a bootstrap fallback until enough temporal data is present.
  int? get representativeDelayMs => p50Ms ?? delayMs ?? p95Ms;
}

class PathDecision {
  const PathDecision({
    required this.state,
    required this.selectedGroup,
    required this.reasonCode,
    required this.switchRequired,
    required this.requiresEgressVerification,
    this.selectedPath = '',
    this.recoveryRounds = 0,
  });

  final AuroraPathState state;
  final String selectedPath;
  final String selectedGroup;
  final String reasonCode;
  final bool switchRequired;
  final bool requiresEgressVerification;
  final int recoveryRounds;
}

class PathHealthController {
  PathHealthController({
    required this.policy,
    List<String>? pathOrder,
    Map<String, String>? groups,
    String? relayGroup,
    String? homeGroup,
  }) : pathOrder = List.unmodifiable(pathOrder ?? const <String>['relay', 'home']),
       groups = Map.unmodifiable(
         groups ??
             <String, String>{
               'relay': relayGroup ?? 'relay-auto',
               'home': homeGroup ?? 'home-auto',
             },
       ) {
    if (this.pathOrder.length < 2 ||
        this.pathOrder.toSet().length != this.pathOrder.length ||
        !this.pathOrder.every(this.groups.containsKey)) {
      throw ArgumentError('path order/groups are invalid');
    }
    _selectedIndex = 0;
    _decision = _decisionFor(
      pathIndex: 0,
      reason: PathReason.pathHealthy,
      switched: false,
      requiresVerification: true,
    );
  }

  final PathHealthPolicy policy;
  final List<String> pathOrder;
  final Map<String, String> groups;

  late int _selectedIndex;
  late PathDecision _decision;
  int? _networkEpoch;
  final Map<String, List<PathObservation>> _rounds = {};
  final Map<String, int> _hardFailureRounds = {};
  final Map<String, int> _latencyRounds = {};
  final List<DateTime> _switches = [];
  String? _recoveryCandidate;
  int _recoveryRounds = 0;
  DateTime? _recoveryStarted;
  DateTime? _cooldownUntil;

  PathDecision get currentDecision => _decision;

  PathDecision evaluate({
    Map<String, PathObservation>? observations,
    PathObservation? relay,
    PathObservation? home,
    required PathPreference preference,
    required DateTime now,
    required int networkEpoch,
  }) {
    final values =
        observations ??
        <String, PathObservation>{
          pathOrder.first: relay ?? _missingObservation,
          pathOrder.last: home ?? _missingObservation,
        };
    final networkChanged =
        _networkEpoch != null && _networkEpoch != networkEpoch;
    if (_networkEpoch == null || networkChanged) {
      _resetForNetwork(networkEpoch);
      _selectedIndex = preference == PathPreference.homeDirect
          ? pathOrder.length - 1
          : 0;
    }
    for (final pathId in pathOrder) {
      _append(pathId, values[pathId] ?? _missingObservation);
    }

    if (preference == PathPreference.homeDirect) {
      _clearRecovery();
      final homeIndex = pathOrder.length - 1;
      final observation = values[pathOrder[homeIndex]] ?? _missingObservation;
      if (_unusable(observation)) {
        return _block(PathReason.homeUnavailable);
      }
      return _select(
        homeIndex,
        PathReason.manualHome,
        now,
        countForFlap: false,
        requiresVerification:
            networkChanged || observation.egress == EgressStatus.unknown,
      );
    }

    if (_selectedIndex >= pathOrder.length) {
      final homeIndex = pathOrder.length - 1;
      final homeObservation =
          values[pathOrder[homeIndex]] ?? _missingObservation;
      if (_unusable(homeObservation)) {
        return _block(PathReason.homeUnavailable);
      }
      return _select(
        homeIndex,
        PathReason.pathRecovered,
        now,
        requiresVerification: homeObservation.egress == EgressStatus.unknown,
      );
    }

    final currentPath = pathOrder[_selectedIndex];
    final current = values[currentPath] ?? _missingObservation;
    if (current.egress == EgressStatus.mismatch) {
      return _downgrade(values, now, PathReason.egressMismatch);
    }

    final hardFailure = current.completelyFailed && !current.compatibilityOnly;
    _hardFailureRounds[currentPath] = hardFailure
        ? (_hardFailureRounds[currentPath] ?? 0) + 1
        : 0;
    if (_hardFailureRounds[currentPath]! >= policy.hardFailureRounds) {
      return _downgrade(values, now, PathReason.pathHardFailure);
    }
    if (hardFailure) {
      return _stay(
        PathReason.pathHardFailure,
        networkChanged || current.egress == EgressStatus.unknown,
        suspect: true,
      );
    }

    if (_lossDegraded(currentPath)) {
      return _downgrade(values, now, PathReason.pathLoss);
    }
    if (_jitterDegraded(currentPath)) {
      return _downgrade(values, now, PathReason.pathJitter);
    }

    final next = _nextUsable(values, _selectedIndex + 1);
    final nextObservation = next == null
        ? null
        : values[pathOrder[next]] ?? _missingObservation;
    final latencyBad =
        !current.compatibilityOnly &&
        nextObservation != null &&
        !_unusable(nextObservation) &&
        _extremeLatency(current, nextObservation);
    _latencyRounds[currentPath] = latencyBad
        ? (_latencyRounds[currentPath] ?? 0) + 1
        : 0;
    if (_latencyRounds[currentPath]! >= 5) {
      return _downgrade(values, now, PathReason.pathLatency);
    }

    if (_selectedIndex > 0) {
      final recovery = _tryRecovery(values, now, networkChanged);
      if (recovery != null) return recovery;
    }
    return _stay(
      latencyBad ? PathReason.pathLatency : PathReason.pathHealthy,
      networkChanged || current.egress == EgressStatus.unknown,
      suspect: latencyBad,
    );
  }

  PathDecision _downgrade(
    Map<String, PathObservation> observations,
    DateTime now,
    String reason,
  ) {
    _clearRecovery();
    final next = _nextUsable(observations, _selectedIndex + 1);
    if (next == null) return _block(PathReason.homeUnavailable);
    final observation = observations[pathOrder[next]] ?? _missingObservation;
    return _select(
      next,
      reason,
      now,
      requiresVerification: observation.egress == EgressStatus.unknown,
    );
  }

  PathDecision? _tryRecovery(
    Map<String, PathObservation> observations,
    DateTime now,
    bool networkChanged,
  ) {
    final candidateIndex = _selectedIndex - 1;
    final candidatePath = pathOrder[candidateIndex];
    final candidate = observations[candidatePath] ?? _missingObservation;
    if (_cooldownUntil != null && now.isBefore(_cooldownUntil!)) {
      _clearRecovery();
      return _stay(PathReason.flapCooldown, networkChanged);
    }
    if (!_healthyForRecovery(candidate)) {
      _clearRecovery();
      return null;
    }
    if (_recoveryCandidate != candidatePath) {
      _recoveryCandidate = candidatePath;
      _recoveryRounds = 0;
      _recoveryStarted = now;
    }
    _recoveryRounds++;
    final held = now.difference(_recoveryStarted!) >= policy.recoveryHold;
    if (_recoveryRounds >= policy.recoveryRounds && held) {
      if (_wouldEnterFlapCooldown(now)) {
        _cooldownUntil = now.add(policy.flapCooldown);
        _clearRecovery();
        return _stay(PathReason.flapCooldown, false);
      }
      _clearRecovery();
      return _select(
        candidateIndex,
        PathReason.pathRecovered,
        now,
        requiresVerification: candidate.egress == EgressStatus.unknown,
      );
    }
    return _decisionFor(
      pathIndex: _selectedIndex,
      reason: PathReason.pathRecovered,
      switched: false,
      requiresVerification: networkChanged,
      recovering: true,
      recoveryRounds: _recoveryRounds,
    );
  }

  int? _nextUsable(Map<String, PathObservation> observations, int start) {
    for (var index = start; index < pathOrder.length; index++) {
      if (!_unusable(observations[pathOrder[index]] ?? _missingObservation)) {
        return index;
      }
    }
    return null;
  }

  bool _lossDegraded(String pathId) {
    final eligible = (_rounds[pathId] ?? const <PathObservation>[])
        .where((round) => !round.compatibilityOnly)
        .toList();
    if (eligible.length < policy.rollingWindow) return false;
    final window = eligible.sublist(eligible.length - policy.rollingWindow);
    final successfulRounds = window
        .where((round) => round.successes > 0)
        .length;
    final minimumSuccessful = (policy.minimumSuccessRate * policy.rollingWindow)
        .ceil();
    final degradedRounds = window
        .where(
          (round) =>
              round.attempts > 0 &&
              round.successRate < policy.minimumSuccessRate,
        )
        .length;
    return successfulRounds < minimumSuccessful &&
        degradedRounds >= policy.performanceFailureRounds;
  }

  bool _jitterDegraded(String pathId) {
    final rounds = _rounds[pathId] ?? const <PathObservation>[];
    final bad = rounds.where((round) {
      if (round.compatibilityOnly || round.p95Ms == null) return false;
      final jitter =
          round.jitterMs ??
          (round.p50Ms == null ? 0 : round.p95Ms! - round.p50Ms!);
      return round.p95Ms! > 1000 && jitter > 300;
    }).length;
    return bad >= policy.performanceFailureRounds;
  }

  bool _extremeLatency(PathObservation current, PathObservation next) {
    final currentDelay = current.representativeDelayMs;
    final nextDelay = next.representativeDelayMs;
    if (currentDelay == null || nextDelay == null) return false;
    return currentDelay > nextDelay * policy.latencyRatio &&
        currentDelay - nextDelay >= policy.latencyDeltaMs;
  }

  PathDecision _select(
    int pathIndex,
    String reason,
    DateTime now, {
    required bool requiresVerification,
    bool countForFlap = true,
  }) {
    final switched = _selectedIndex != pathIndex;
    if (switched && countForFlap) {
      _trimSwitches(now);
      _switches.add(now);
    }
    _selectedIndex = pathIndex;
    _decision = _decisionFor(
      pathIndex: pathIndex,
      reason: reason,
      switched: switched,
      requiresVerification: requiresVerification,
    );
    return _decision;
  }

  PathDecision _stay(
    String reason,
    bool requiresVerification, {
    bool suspect = false,
  }) {
    _decision = _decisionFor(
      pathIndex: _selectedIndex,
      reason: reason,
      switched: false,
      requiresVerification: requiresVerification,
      suspect: suspect,
    );
    return _decision;
  }

  PathDecision _block(String reason) {
    final switched = _selectedIndex < pathOrder.length;
    _selectedIndex = pathOrder.length;
    _decision = PathDecision(
      state: AuroraPathState.homeBlocked,
      selectedGroup: '',
      reasonCode: reason,
      switchRequired: switched,
      requiresEgressVerification: true,
    );
    return _decision;
  }

  PathDecision _decisionFor({
    required int pathIndex,
    required String reason,
    required bool switched,
    required bool requiresVerification,
    bool suspect = false,
    bool recovering = false,
    int recoveryRounds = 0,
  }) {
    final pathId = pathOrder[pathIndex];
    return PathDecision(
      state: recovering
          ? (pathOrder.first == 'relay'
                ? AuroraPathState.relayRecovering
                : AuroraPathState.recovering)
          : _stateFor(pathId, suspect: suspect),
      selectedPath: pathId,
      selectedGroup: groups[pathId]!,
      reasonCode: reason,
      switchRequired: switched,
      requiresEgressVerification: requiresVerification,
      recoveryRounds: recoveryRounds,
    );
  }

  AuroraPathState _stateFor(String pathId, {bool suspect = false}) {
    return switch (pathId) {
      'relay_public' => AuroraPathState.relayPublic,
      'relay_tailnet' => AuroraPathState.relayTailnet,
      'home' when pathOrder.first == 'relay_public' => AuroraPathState.homeDirect,
      'relay' => suspect ? AuroraPathState.relaySuspect : AuroraPathState.relayPreferred,
      'home' => AuroraPathState.homeFallback,
      _ =>
        pathId == pathOrder.last
            ? AuroraPathState.homeDirect
            : AuroraPathState.relayTailnet,
    };
  }

  bool _unusable(PathObservation observation) =>
      observation.egress == EgressStatus.mismatch ||
      (observation.completelyFailed && !observation.compatibilityOnly);

  bool _healthyForRecovery(PathObservation observation) =>
      !observation.compatibilityOnly &&
      !observation.completelyFailed &&
      observation.egress == EgressStatus.verified &&
      observation.successRate >= policy.minimumSuccessRate;

  void _append(String pathId, PathObservation observation) {
    final rounds = _rounds.putIfAbsent(pathId, () => []);
    rounds.add(observation);
    if (rounds.length > policy.rollingWindow) {
      rounds.removeRange(0, rounds.length - policy.rollingWindow);
    }
  }

  bool _wouldEnterFlapCooldown(DateTime now) {
    _trimSwitches(now);
    return _switches.length + 1 >= policy.flapThreshold;
  }

  void _trimSwitches(DateTime now) {
    final cutoff = now.subtract(policy.flapWindow);
    _switches.removeWhere((switchedAt) => switchedAt.isBefore(cutoff));
  }

  void _clearRecovery() {
    _recoveryCandidate = null;
    _recoveryRounds = 0;
    _recoveryStarted = null;
  }

  void _resetForNetwork(int epoch) {
    _networkEpoch = epoch;
    _rounds.clear();
    _hardFailureRounds.clear();
    _latencyRounds.clear();
    _switches.clear();
    _cooldownUntil = null;
    _clearRecovery();
  }

  static const _missingObservation = PathObservation(
    attempts: 0,
    successes: 0,
    egress: EgressStatus.unknown,
  );
}
