import 'aurora_bridge.dart';
import 'node_stability.dart';

/// Demotes proxy nodes that answer quickly but cannot actually carry traffic.
///
/// sing-box's `urltest` ranks members by one number: how fast the probe URL
/// returns its first byte. That number lies on a throttled link. A measurement
/// from a carrier that throttles UDP, with three legs to the same exit:
///
///   reality   ttfb 1.41s   1039 KB/s
///   hy2       ttfb 1.02s      2 KB/s   <- urltest elects this
///   ss        ttfb 1.10s    913 KB/s
///
/// Hysteria2 rides UDP, and the carrier lets the handshake through while
/// strangling sustained UDP throughput. So it wins every election and then
/// nothing loads: pages connect (TTFB is genuinely fine) and never finish.
///
/// Every existing health check missed this, because they all fetch tiny bodies
/// — two 204s and a ~1 KB favicon, which even 2 KB/s delivers inside a 4s
/// timeout. The watchdog eventually times out and restarts the tunnel, the
/// restart resets the selector to `auto`, urltest re-elects the same node by
/// the same latency, and the loop repeats indefinitely.
///
/// This gate is the missing judgement: a node has to move a real payload at a
/// real rate to keep its job. Pure and clock-injected, so the cooldown and
/// selection rules are testable without a network or a timer.
class GoodputGate {
  GoodputGate({
    this.floorBytesPerSecond = 16 * 1024,
    Duration cooldown = const Duration(minutes: 15),
  }) : _tracker = NodeStabilityTracker(
         // Two in a row. One sub-floor sample can be a moment of congestion or
         // the probe competing with the user's own download; demoting on it
         // would tear down every live connection for nothing. The fault this
         // catches is persistent, so waiting for a second look costs little —
         // and the supervisor shortens the gap after a bad sample so the
         // confirmation arrives in seconds, not minutes.
         maxConsecutiveFailures: 2,
         cooldown: cooldown,
       );

  /// Below this, a path is treated as unusable rather than merely slow.
  ///
  /// Measured through the live tunnel on the link this exists for: a healthy
  /// path samples between 52 and 212 KB/s (it shares the link with real
  /// traffic, so it swings), while the throttled one sits at 2 KB/s. 16 KB/s
  /// sits ~3x above the broken case and ~3x below the worst healthy sample, so
  /// neither verdict rides on a borderline number. An earlier 48 KB/s floor was
  /// close enough to that 52 KB/s low-water mark to have condemned a working
  /// path.
  final int floorBytesPerSecond;

  /// Whether a measurement counts as a failure. The supervisor uses this to
  /// decide it should re-check soon rather than wait a full interval.
  bool isBelowFloor(int bytesPerSecond) => bytesPerSecond < floorBytesPerSecond;

  final NodeStabilityTracker _tracker;

  /// The node actually carrying traffic. The selector usually points at a
  /// urltest group rather than a node, and blaming the group would demote the
  /// good members along with the bad one — so follow the indirection to the
  /// concrete node underneath.
  static String? effectiveNode(
    List<OutboundGroupInfo> groups,
    String selectorTag,
  ) {
    final selector = _find(groups, selectorTag);
    if (selector == null || selector.selected.isEmpty) return null;
    final nested = _find(groups, selector.selected);
    if (nested == null) return selector.selected;
    return nested.selected.isEmpty ? null : nested.selected;
  }

  /// Selector members that are concrete nodes. Pinning the selector back to a
  /// group would just hand the decision to the latency-only election that
  /// picked the bad node to begin with.
  static List<String> selectableNodes(
    List<OutboundGroupInfo> groups,
    String selectorTag,
  ) {
    final selector = _find(groups, selectorTag);
    if (selector == null) return const [];
    final groupTags = groups.map((g) => g.tag).toSet();
    return [
      for (final item in selector.items)
        if (!groupTags.contains(item.tag)) item.tag,
    ];
  }

  /// Replacement candidates, confined to the group that is actually in effect.
  ///
  /// When the user has locked a route family, [groupTag] is that family's
  /// group, and confining the choice to it is the whole point: a lock that can
  /// be silently escaped by a health check is not a lock. On auto, [groupTag]
  /// is the contract's own urltest group, so the choice spans every node the
  /// engine would have considered anyway.
  static List<String> candidatesIn(
    List<OutboundGroupInfo> groups,
    String groupTag,
    String selectorTag,
  ) {
    final group = _find(groups, groupTag);
    if (group == null) return const [];
    // A member the selector cannot be pinned to is not a candidate, however
    // healthy it looks.
    final selectable = selectableNodes(groups, selectorTag).toSet();
    return [
      for (final item in group.items)
        if (selectable.contains(item.tag)) item.tag,
    ];
  }

  bool isCoolingDown(String tag, DateTime now) => _tracker.inCooldown(tag, now);

  /// Wipes every recorded sample and cooldown.
  ///
  /// The gate outlives sessions on purpose, so this is deliberately not called
  /// on reconnect. It is called when the physical network comes back after an
  /// outage: nodes that were hard-failed while there was no network at all
  /// were never at fault, and a 15-minute cooldown on each of them, all burnt
  /// in one outage, would keep the session pinned to whichever
  /// node happened to be last in line.
  void forgetHistory() => _tracker.clear();

  /// Records one goodput observation for [node] and returns the node to switch
  /// to, or null to stay where we are.
  String? observe({
    required String node,
    required bool reachable,
    required int bytesPerSecond,
    required List<String> candidates,
    required DateTime at,
    bool stalled = false,
  }) {
    // Absence of evidence is not evidence of slowness. An endpoint that is down,
    // challenged, or blocked says nothing about this path's throughput, and a
    // path that is fully dead is the watchdog's job, not this one's. Demote only
    // on a measurement that actually happened.
    //
    // A stall is one: nothing at all came back from any provider, through a
    // path whose tiny probes still pass (see GoodputSample.stalled). The
    // watchdog cannot catch that leg — it is not fully dead — so if this gate
    // also looks away, nothing ever moves the session off it.
    if (!reachable && !stalled) return null;

    final healthy = !stalled && !isBelowFloor(bytesPerSecond);
    _tracker.record(node, success: healthy, at: at, latencyMs: null);
    if (healthy) return null;

    // One bad sample is recorded but not acted on. The tracker trips into
    // cooldown only once the failures are consecutive enough to be believed,
    // and that is the same signal that keeps the engine from handing this node
    // straight back.
    if (!_tracker.inCooldown(node, at)) return null;

    // Contract order is the declared preference, so walking it gives a
    // deterministic, explainable choice. The tracker is consulted only for who
    // is burnt — ranking burnt nodes against each other would just pick the
    // least-bad way to stay broken.
    for (final candidate in candidates) {
      if (candidate == node) continue;
      if (_tracker.inCooldown(candidate, at)) continue;
      return candidate;
    }
    // Everything is burnt. Switching costs every in-flight connection and buys
    // nothing, so hold still and let the watchdog escalate.
    return null;
  }

  /// Records a **hard failure**: the watchdog has confirmed that every endpoint in
  /// this round was lost while [node] was the one running.
  ///
  /// Why [observe] is not enough: its first line is `if (!reachable) return null`.
  /// The design intent is "could not measure != slow", but the side effect is that a
  /// leg that cannot be dialed at all **never enters cooldown** and can only rely on
  /// sing-box's urltest to exclude it. urltest looks only at the first-byte latency
  /// of the probe URL, and the handshake of a leg such as hy2 occasionally gets
  /// through, so it keeps being re-selected periodically. Observed: when a carrier
  /// blocked UDP/443 to the relay, the relay-public hy2 leg failed 9 of 9 probes,
  /// while the same path was healthy (0.84s) from a network without that block.
  ///
  /// The criterion and the demotion action are identical to the low-throughput case
  /// (same tracker, same two consecutive hits, same replacement chosen only inside
  /// the active group, same holding still when every candidate is burned), so both
  /// failure kinds behave as one.
  String? observeHardFailure({
    required String node,
    required List<String> candidates,
    required DateTime at,
  }) {
    _tracker.record(node, success: false, at: at, latencyMs: null);
    if (!_tracker.inCooldown(node, at)) return null;
    for (final candidate in candidates) {
      if (candidate == node) continue;
      if (_tracker.inCooldown(candidate, at)) continue;
      return candidate;
    }
    // All burned. Switching nodes costs every in-flight connection and buys
    // nothing, so hold still and let the watchdog escalate.
    return null;
  }

  static OutboundGroupInfo? _find(List<OutboundGroupInfo> groups, String tag) {
    for (final group in groups) {
      if (group.tag == tag) return group;
    }
    return null;
  }
}
