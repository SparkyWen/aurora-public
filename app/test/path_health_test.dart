import 'package:aurora/core/contract.dart';
import 'package:aurora/core/path_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final origin = DateTime.utc(2026, 7, 22);

  group('ordered PathHealthController', () {
    test('uses relay public by default and manual mode selects only home', () {
      final controller = _controller();
      final automatic = _evaluate(controller, origin);
      expect(automatic.state, AuroraPathState.relayPublic);
      expect(automatic.selectedGroup, 'relay-public-auto');

      final manual = _evaluate(
        controller,
        origin.add(const Duration(seconds: 30)),
        preference: PathPreference.homeDirect,
      );
      expect(manual.state, AuroraPathState.homeDirect);
      expect(manual.selectedGroup, 'home-auto');
      expect(manual.reasonCode, PathReason.manualHome);
    });

    test('two hard failures degrade one level to relay Tailnet', () {
      final controller = _controller();
      final first = _evaluate(
        controller,
        origin,
        observations: _observations(relayPublic: _failed()),
      );
      expect(first.state, AuroraPathState.relayPublic);
      expect(first.reasonCode, PathReason.pathHardFailure);

      final second = _evaluate(
        controller,
        origin.add(const Duration(seconds: 5)),
        observations: _observations(relayPublic: _failed()),
      );
      expect(second.state, AuroraPathState.relayTailnet);
      expect(second.selectedGroup, 'relay-tailnet-auto');
      expect(second.switchRequired, isTrue);
    });

    test('skips an unusable lower path and blocks when all are unusable', () {
      final controller = _controller();
      _evaluate(
        controller,
        origin,
        observations: _observations(relayPublic: _failed()),
      );
      final skipped = _evaluate(
        controller,
        origin.add(const Duration(seconds: 5)),
        observations: _observations(relayPublic: _failed(), relayTailnet: _failed()),
      );
      expect(skipped.state, AuroraPathState.homeDirect);
      expect(skipped.selectedGroup, 'home-auto');

      final blockedController = _controller();
      _evaluate(
        blockedController,
        origin,
        observations: _observations(
          relayPublic: _failed(),
          relayTailnet: _failed(),
          home: _failed(),
        ),
      );
      final blocked = _evaluate(
        blockedController,
        origin.add(const Duration(seconds: 5)),
        observations: _observations(
          relayPublic: _failed(),
          relayTailnet: _failed(),
          home: _failed(),
        ),
      );
      expect(blocked.state, AuroraPathState.homeBlocked);
      expect(blocked.selectedGroup, isEmpty);
    });

    test('egress mismatch isolates the current path immediately', () {
      final controller = _controller();
      final decision = _evaluate(
        controller,
        origin,
        observations: _observations(
          relayPublic: _healthy(egress: EgressStatus.mismatch),
        ),
      );
      expect(decision.state, AuroraPathState.relayTailnet);
      expect(decision.reasonCode, PathReason.egressMismatch);
    });

    test(
      'fewer than five successful rounds in six with four degraded falls back',
      () {
        final controller = _controller();
        PathDecision decision = controller.currentDecision;
        for (var round = 0; round < 6; round++) {
          decision = _evaluate(
            controller,
            origin.add(Duration(seconds: round * 30)),
            observations: _observations(
              relayPublic: switch (round) {
                0 || 2 => _failedWithoutTransportFlag(),
                1 || 3 => _lossy(),
                _ => _healthy(),
              },
            ),
          );
        }
        expect(decision.state, AuroraPathState.relayTailnet);
        expect(decision.reasonCode, PathReason.pathLoss);
      },
    );

    test('four sustained high-jitter rounds fall back', () {
      final controller = _controller();
      PathDecision decision = controller.currentDecision;
      for (var round = 0; round < 4; round++) {
        decision = _evaluate(
          controller,
          origin.add(Duration(seconds: round * 30)),
          observations: _observations(relayPublic: _jittery()),
        );
      }
      expect(decision.state, AuroraPathState.relayTailnet);
      expect(decision.reasonCode, PathReason.pathJitter);
    });

    test('extreme selected-protocol latency requires five rounds', () {
      final controller = _controller();
      PathDecision decision = controller.currentDecision;
      for (var round = 0; round < 4; round++) {
        decision = _evaluate(
          controller,
          origin.add(Duration(seconds: round * 30)),
          observations: _observations(
            relayPublic: _healthy(delayMs: 1300),
            relayTailnet: _healthy(delayMs: 200),
          ),
        );
      }
      expect(decision.state, AuroraPathState.relayPublic);
      decision = _evaluate(
        controller,
        origin.add(const Duration(seconds: 120)),
        observations: _observations(
          relayPublic: _healthy(delayMs: 1300),
          relayTailnet: _healthy(delayMs: 200),
        ),
      );
      expect(decision.state, AuroraPathState.relayTailnet);
      expect(decision.reasonCode, PathReason.pathLatency);
    });

    test('compatibility responses and unselected slowness never degrade', () {
      final controller = _controller();
      for (var round = 0; round < 8; round++) {
        final decision = _evaluate(
          controller,
          origin.add(Duration(seconds: round * 30)),
          observations: _observations(
            relayPublic: _healthy(
              delayMs: 250,
              compatibilityOnly: true,
              selectedNode: 'home-via-relay-public-reality',
            ),
          ),
        );
        expect(decision.state, AuroraPathState.relayPublic);
      }
    });

    test('recovers one level only after three rounds and 120 seconds', () {
      final controller = _controller(flapThreshold: 4);
      _evaluate(
        controller,
        origin,
        observations: _observations(
          relayPublic: _healthy(egress: EgressStatus.mismatch),
        ),
      );
      expect(controller.currentDecision.state, AuroraPathState.relayTailnet);

      _evaluate(controller, origin.add(const Duration(seconds: 10)));
      _evaluate(controller, origin.add(const Duration(seconds: 70)));
      final recovered = _evaluate(
        controller,
        origin.add(const Duration(seconds: 131)),
      );
      expect(recovered.state, AuroraPathState.relayPublic);
      expect(recovered.reasonCode, PathReason.pathRecovered);
    });

    test('flap cooldown blocks upgrade but never safety downgrade', () {
      final controller = _controller(flapThreshold: 2);
      _evaluate(
        controller,
        origin,
        observations: _observations(
          relayPublic: _healthy(egress: EgressStatus.mismatch),
        ),
      );
      _evaluate(controller, origin.add(const Duration(seconds: 10)));
      _evaluate(controller, origin.add(const Duration(seconds: 70)));
      final cooled = _evaluate(
        controller,
        origin.add(const Duration(seconds: 131)),
      );
      expect(cooled.state, AuroraPathState.relayTailnet);
      expect(cooled.reasonCode, PathReason.flapCooldown);

      _evaluate(
        controller,
        origin.add(const Duration(seconds: 140)),
        observations: _observations(relayTailnet: _failed()),
      );
      final downgraded = _evaluate(
        controller,
        origin.add(const Duration(seconds: 145)),
        observations: _observations(relayTailnet: _failed()),
      );
      expect(downgraded.state, AuroraPathState.homeDirect);
    });

    test('network epoch clears old failures and requires verification', () {
      final controller = _controller();
      _evaluate(
        controller,
        origin,
        observations: _observations(relayPublic: _failed()),
      );
      final changed = _evaluate(
        controller,
        origin.add(const Duration(seconds: 5)),
        networkEpoch: 2,
        observations: _observations(
          relayPublic: _healthy(egress: EgressStatus.unknown),
        ),
      );
      expect(changed.state, AuroraPathState.relayPublic);
      expect(changed.requiresEgressVerification, isTrue);
    });

    test('manual home blocks when the household egress mismatches', () {
      final controller = _controller();
      final decision = _evaluate(
        controller,
        origin,
        preference: PathPreference.homeDirect,
        observations: _observations(
          home: _healthy(egress: EgressStatus.mismatch),
        ),
      );
      expect(decision.state, AuroraPathState.homeBlocked);
      expect(decision.selectedGroup, isEmpty);
    });
  });
}

PathHealthController _controller({int flapThreshold = 4}) =>
    PathHealthController(
      policy: PathHealthPolicy(
        rollingWindow: 6,
        minimumSuccessRate: 0.83,
        hardFailureRounds: 2,
        performanceFailureRounds: 4,
        latencyRatio: 3,
        latencyDeltaMs: 600,
        recoveryRounds: 3,
        recoveryHold: const Duration(seconds: 120),
        flapWindow: const Duration(seconds: 600),
        flapThreshold: flapThreshold,
        flapCooldown: const Duration(seconds: 900),
      ),
      pathOrder: const ['relay_public', 'relay_tailnet', 'home'],
      groups: const {
        'relay_public': 'relay-public-auto',
        'relay_tailnet': 'relay-tailnet-auto',
        'home': 'home-auto',
      },
    );

PathDecision _evaluate(
  PathHealthController controller,
  DateTime now, {
  Map<String, PathObservation>? observations,
  PathPreference preference = PathPreference.auto,
  int networkEpoch = 1,
}) => controller.evaluate(
  observations: observations ?? _observations(),
  preference: preference,
  now: now,
  networkEpoch: networkEpoch,
);

Map<String, PathObservation> _observations({
  PathObservation? relayPublic,
  PathObservation? relayTailnet,
  PathObservation? home,
}) => {
  'relay_public': relayPublic ?? _healthy(delayMs: 300),
  'relay_tailnet': relayTailnet ?? _healthy(delayMs: 350),
  'home': home ?? _healthy(delayMs: 400),
};

PathObservation _healthy({
  int delayMs = 250,
  EgressStatus egress = EgressStatus.verified,
  bool compatibilityOnly = false,
  String selectedNode = 'selected-node',
}) => PathObservation(
  selectedNode: selectedNode,
  attempts: 1,
  successes: 1,
  delayMs: delayMs,
  p50Ms: delayMs,
  p95Ms: delayMs,
  jitterMs: 0,
  egress: egress,
  compatibilityOnly: compatibilityOnly,
);

PathObservation _lossy() => const PathObservation(
  selectedNode: 'selected-node',
  attempts: 3,
  successes: 2,
  delayMs: 500,
  egress: EgressStatus.verified,
);

PathObservation _failedWithoutTransportFlag() => const PathObservation(
  selectedNode: 'selected-node',
  attempts: 3,
  successes: 0,
  egress: EgressStatus.verified,
);

PathObservation _jittery() => const PathObservation(
  selectedNode: 'selected-node',
  attempts: 1,
  successes: 1,
  delayMs: 1200,
  p50Ms: 600,
  p95Ms: 1200,
  jitterMs: 600,
  egress: EgressStatus.verified,
);

PathObservation _failed() => const PathObservation(
  selectedNode: 'selected-node',
  attempts: 1,
  successes: 0,
  transportFailure: true,
  egress: EgressStatus.unknown,
);
