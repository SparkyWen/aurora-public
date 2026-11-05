import 'package:aurora/core/node_stability.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic base time; all observations feed explicit timestamps so the
/// tracker's cooldown/window logic is testable without a real clock.
final t0 = DateTime.parse('2026-07-19T00:00:00Z');
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

void main() {
  test('success rate reflects the recorded outcomes for a node', () {
    final tracker = NodeStabilityTracker();
    tracker.record('home-hy2', success: true, latencyMs: 40, at: at(0));
    tracker.record('home-hy2', success: true, latencyMs: 50, at: at(1));
    tracker.record('home-hy2', success: false, at: at(2));
    tracker.record('home-hy2', success: true, latencyMs: 60, at: at(3));

    final score = tracker.scoreFor('home-hy2');
    expect(score.samples, 4);
    expect(score.successRate, 0.75);
  });

  test('an unseen node has an empty score', () {
    final tracker = NodeStabilityTracker();
    final score = tracker.scoreFor('never-seen');
    expect(score.samples, 0);
    expect(score.successRate, 0.0);
  });

  test('only the last windowSize samples are retained', () {
    final tracker = NodeStabilityTracker(windowSize: 5);
    // 3 failures then 5 successes: the 3 oldest failures fall out of the window.
    for (var i = 0; i < 3; i++) {
      tracker.record('n', success: false, at: at(i));
    }
    for (var i = 3; i < 8; i++) {
      tracker.record('n', success: true, latencyMs: 10, at: at(i));
    }
    final score = tracker.scoreFor('n');
    expect(score.samples, 5);
    expect(score.successRate, 1.0);
  });

  test('P50/P95 come from successful-sample latencies', () {
    final tracker = NodeStabilityTracker();
    // latencies 10..100 (10 successful samples) + one failure (no latency).
    for (var i = 1; i <= 10; i++) {
      tracker.record('n', success: true, latencyMs: i * 10, at: at(i));
    }
    tracker.record('n', success: false, at: at(11));
    final score = tracker.scoreFor('n');
    // nearest-rank: P50 of [10..100] -> index ceil(0.5*10)-1=4 -> 50;
    // P95 -> index ceil(0.95*10)-1=9 -> 100.
    expect(score.p50Ms, 50);
    expect(score.p95Ms, 100);
  });

  test('consecutive failures count the trailing run only', () {
    final tracker = NodeStabilityTracker();
    tracker.record('n', success: true, latencyMs: 10, at: at(0));
    tracker.record('n', success: false, at: at(1));
    tracker.record('n', success: false, at: at(2));
    tracker.record('n', success: false, at: at(3));
    expect(tracker.scoreFor('n').consecutiveFailures, 3);

    tracker.record('n', success: true, latencyMs: 10, at: at(4));
    expect(tracker.scoreFor('n').consecutiveFailures, 0);
  });

  test('a node enters cooldown after maxConsecutiveFailures and expires', () {
    final tracker = NodeStabilityTracker(
      maxConsecutiveFailures: 3,
      cooldown: const Duration(seconds: 60),
    );
    tracker.record('n', success: false, at: at(0));
    tracker.record('n', success: false, at: at(1));
    expect(tracker.inCooldown('n', at(2)), isFalse); // only 2 failures
    tracker.record('n', success: false, at: at(2)); // 3rd failure -> cooldown

    expect(tracker.inCooldown('n', at(3)), isTrue);
    expect(tracker.inCooldown('n', at(61)), isTrue); // within 60s of last fail
    expect(tracker.inCooldown('n', at(63)), isFalse); // 61s after last fail
  });

  test('a success clears cooldown immediately', () {
    final tracker = NodeStabilityTracker(
      maxConsecutiveFailures: 3,
      cooldown: const Duration(seconds: 60),
    );
    for (var i = 0; i < 3; i++) {
      tracker.record('n', success: false, at: at(i));
    }
    expect(tracker.inCooldown('n', at(3)), isTrue);
    tracker.record('n', success: true, latencyMs: 10, at: at(4));
    expect(tracker.inCooldown('n', at(5)), isFalse);
  });

  // --- recommend() hysteresis ---

  void fill(NodeStabilityTracker t, String tag, int ok, int fail,
      {int latencyMs = 20}) {
    var s = 0;
    for (var i = 0; i < ok; i++) {
      t.record(tag, success: true, latencyMs: latencyMs, at: at(s++));
    }
    for (var i = 0; i < fail; i++) {
      t.record(tag, success: false, at: at(s++));
    }
  }

  test('stays on a healthy current when a rival is only marginally better', () {
    final tracker = NodeStabilityTracker(switchMargin: 0.15);
    fill(tracker, 'hy2', 9, 1); // 0.90
    fill(tracker, 'ss', 10, 0); // 1.00 — only +0.10, within margin
    final pick = tracker.recommend(
      current: 'hy2',
      candidates: ['hy2', 'ss'],
      now: at(100),
    );
    expect(pick, 'hy2');
  });

  test('switches when a rival beats current beyond the margin', () {
    final tracker = NodeStabilityTracker(switchMargin: 0.15);
    fill(tracker, 'hy2', 5, 5); // 0.50
    fill(tracker, 'ss', 10, 0); // 1.00 — +0.50, beyond margin
    final pick = tracker.recommend(
      current: 'hy2',
      candidates: ['hy2', 'ss'],
      now: at(100),
    );
    expect(pick, 'ss');
  });

  test('cooldown on current overrides hysteresis and forces a switch', () {
    final tracker = NodeStabilityTracker(
      switchMargin: 0.15,
      maxConsecutiveFailures: 3,
      cooldown: const Duration(seconds: 60),
    );
    // hy2: 3 trailing failures ending at at(2) -> in cooldown at at(3).
    tracker.record('hy2', success: false, at: at(0));
    tracker.record('hy2', success: false, at: at(1));
    tracker.record('hy2', success: false, at: at(2));
    fill(tracker, 'ss', 10, 0);
    final pick = tracker.recommend(
      current: 'hy2',
      candidates: ['hy2', 'ss'],
      now: at(3),
    );
    expect(pick, 'ss');
  });

  test('stays put when every candidate is in cooldown', () {
    final tracker = NodeStabilityTracker(
      maxConsecutiveFailures: 3,
      cooldown: const Duration(seconds: 60),
    );
    for (final tag in ['hy2', 'ss']) {
      tracker.record(tag, success: false, at: at(0));
      tracker.record(tag, success: false, at: at(1));
      tracker.record(tag, success: false, at: at(2));
    }
    final pick = tracker.recommend(
      current: 'hy2',
      candidates: ['hy2', 'ss'],
      now: at(3),
    );
    expect(pick, 'hy2');
  });

  test('an unproven current yields to a node with a good track record', () {
    final tracker = NodeStabilityTracker(switchMargin: 0.15);
    // 'hy2' has no samples; 'ss' is proven.
    fill(tracker, 'ss', 10, 0);
    final pick = tracker.recommend(
      current: 'hy2',
      candidates: ['hy2', 'ss'],
      now: at(100),
    );
    expect(pick, 'ss');
  });

  test('ties broken by lower P95 latency', () {
    final tracker = NodeStabilityTracker(switchMargin: 0.15);
    fill(tracker, 'hy2', 10, 0, latencyMs: 200); // 1.00 but slow
    fill(tracker, 'ss', 10, 0, latencyMs: 30); // 1.00 and fast
    // current is a third, unproven node so hysteresis doesn't pin it.
    final pick = tracker.recommend(
      current: 'reality',
      candidates: ['reality', 'hy2', 'ss'],
      now: at(100),
    );
    expect(pick, 'ss');
  });
}
