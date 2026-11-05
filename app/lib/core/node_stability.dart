/// App-side per-node health used to inform node selection beyond sing-box's
/// single-latency urltest. Pure and deterministic: every observation and query
/// carries an explicit timestamp, so cooldown/window behaviour is unit-testable
/// without a real clock.
library;

class _Sample {
  const _Sample({required this.success, required this.at, this.latencyMs});
  final bool success;
  final int? latencyMs;
  final DateTime at;
}

class NodeScore {
  const NodeScore({
    required this.samples,
    required this.successRate,
    this.p50Ms,
    this.p95Ms,
    this.consecutiveFailures = 0,
  });

  final int samples;
  final double successRate;

  /// Nearest-rank percentiles over successful samples' first-byte latency.
  /// Null when there is no successful sample to measure.
  final int? p50Ms;
  final int? p95Ms;

  /// Length of the trailing run of failures (0 if the latest sample succeeded).
  final int consecutiveFailures;

  static const empty = NodeScore(samples: 0, successRate: 0.0);
}

class NodeStabilityTracker {
  NodeStabilityTracker({
    this.windowSize = 20,
    this.maxConsecutiveFailures = 3,
    this.cooldown = const Duration(seconds: 60),
    this.switchMargin = 0.15,
  });

  /// How many most-recent samples per node feed the score.
  final int windowSize;

  /// Trailing failures that trip a node into cooldown.
  final int maxConsecutiveFailures;

  /// How long a tripped node stays in cooldown, measured from its last failure.
  final Duration cooldown;

  /// Hysteresis band: a rival must beat a healthy current node's success rate by
  /// at least this much before we switch, so near-equal nodes don't flap.
  final double switchMargin;

  final Map<String, List<_Sample>> _byNode = {};

  /// True while [tag] is being penalised for a recent failure run: it has at
  /// least [maxConsecutiveFailures] trailing failures and the most recent one is
  /// within [cooldown] of [now]. A single success clears it (resets the run).
  bool inCooldown(String tag, DateTime now) {
    final samples = _byNode[tag];
    if (samples == null || samples.isEmpty) return false;
    if (_trailingFailures(samples) < maxConsecutiveFailures) return false;
    final lastFailure = samples.last.at;
    return now.isBefore(lastFailure.add(cooldown));
  }

  /// Forgets every node's history, cooldowns included.
  void clear() => _byNode.clear();

  void record(
    String tag, {
    required bool success,
    required DateTime at,
    int? latencyMs,
  }) {
    final list = _byNode[tag] ??= [];
    list.add(_Sample(success: success, latencyMs: latencyMs, at: at));
    if (list.length > windowSize) {
      list.removeRange(0, list.length - windowSize);
    }
  }

  /// Which node to run on, given the currently-selected [current] and the
  /// selectable [candidates]. Returns [current] to stay put. Hysteresis:
  ///
  /// - Nodes in cooldown rank below any node that is not.
  /// - Otherwise rank by success rate, then lower P95 latency, then more samples.
  /// - If [current] is in cooldown, switch to the best candidate (cooldown wins).
  /// - If [current] is healthy and proven, only switch when the best rival beats
  ///   it by more than [switchMargin] on success rate — else stay.
  /// - An unproven current (no samples) offers no hysteresis protection.
  String recommend({
    required String current,
    required List<String> candidates,
    required DateTime now,
  }) {
    if (candidates.isEmpty) return current;
    final ranked = [...candidates]
      ..sort((a, b) => _compareKeys(_rankKey(b, now), _rankKey(a, now)));
    final best = ranked.first;
    if (best == current) return current;

    final currentScore = scoreFor(current);
    // Cooldown or a never-proven current => no hysteresis; take the best.
    if (inCooldown(current, now) || currentScore.samples == 0) {
      // But if the best is itself in cooldown (everyone is), don't churn.
      return inCooldown(best, now) ? current : best;
    }
    if (inCooldown(best, now)) return current;

    final bestScore = scoreFor(best);
    if (bestScore.successRate > currentScore.successRate + switchMargin) {
      return best;
    }
    return current;
  }

  /// Comparable rank: higher is better. Encodes (eligible > cooldown), then
  /// success rate, then latency (lower better), then sample count.
  List<num> _rankKey(String tag, DateTime now) {
    final s = scoreFor(tag);
    final eligible = inCooldown(tag, now) ? 0 : 1;
    // Negate latency so "higher key = better"; unknown latency ranks worst.
    final latencyKey = s.p95Ms == null ? -1 << 30 : -s.p95Ms!;
    return [eligible, s.successRate, latencyKey, s.samples];
  }

  static int _compareKeys(List<num> a, List<num> b) {
    for (var i = 0; i < a.length; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  NodeScore scoreFor(String tag) {
    final samples = _byNode[tag];
    if (samples == null || samples.isEmpty) return NodeScore.empty;
    final ok = samples.where((s) => s.success).length;
    final latencies =
        samples.where((s) => s.success && s.latencyMs != null).map((s) => s.latencyMs!).toList()
          ..sort();
    return NodeScore(
      samples: samples.length,
      successRate: ok / samples.length,
      p50Ms: _percentile(latencies, 0.50),
      p95Ms: _percentile(latencies, 0.95),
      consecutiveFailures: _trailingFailures(samples),
    );
  }

  static int? _percentile(List<int> sorted, double q) {
    if (sorted.isEmpty) return null;
    final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  static int _trailingFailures(List<_Sample> samples) {
    var count = 0;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].success) break;
      count++;
    }
    return count;
  }
}
