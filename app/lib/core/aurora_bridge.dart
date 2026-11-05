/// Shared (Android + iOS) contract between Flutter and the native VPN layer.
///
/// The native side owns the platform VPN lifecycle and feeds the compiled
/// sing-box JSON to libbox; Flutter only drives it through this narrow interface.
/// **Do not change these signatures unilaterally** — the iOS implementation
/// depends on them (architecture spec §4.3 / android spec §5, §12).
library;

import 'dart:async';

enum AuroraStatus { disconnected, connecting, connected, disconnecting, error }

AuroraStatus auroraStatusFromString(String? s) {
  switch (s) {
    case 'connecting':
      return AuroraStatus.connecting;
    case 'connected':
      return AuroraStatus.connected;
    case 'disconnecting':
      return AuroraStatus.disconnecting;
    case 'error':
      return AuroraStatus.error;
    case 'disconnected':
    default:
      return AuroraStatus.disconnected;
  }
}

/// Live traffic snapshot (rates + cumulative). From libbox StatusMessage.
class TrafficStat {
  const TrafficStat({
    this.uplink = 0,
    this.downlink = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
  });

  final int uplink; // bytes/s
  final int downlink; // bytes/s
  final int uplinkTotal;
  final int downlinkTotal;

  factory TrafficStat.fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return const TrafficStat();
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return TrafficStat(
      uplink: n('uplink'),
      downlink: n('downlink'),
      uplinkTotal: n('uplinkTotal'),
      downlinkTotal: n('downlinkTotal'),
    );
  }
}

/// A member of an outbound group (a node, or "auto"/"direct").
class OutboundItem {
  const OutboundItem({
    required this.tag,
    required this.type,
    required this.delayMs,
  });
  final String tag;
  final String type;
  final int delayMs; // urltest delay; 0 = untested/unavailable

  factory OutboundItem.fromMap(Map<dynamic, dynamic> m) => OutboundItem(
    tag: m['tag'] as String? ?? '',
    type: m['type'] as String? ?? '',
    delayMs: (m['delay'] as num?)?.toInt() ?? 0,
  );
}

/// An outbound group (e.g. the "proxy" selector) with its current selection.
class OutboundGroupInfo {
  const OutboundGroupInfo({
    required this.tag,
    required this.type,
    required this.selected,
    required this.selectable,
    required this.items,
  });
  final String tag;
  final String type;
  final String selected;
  final bool selectable;
  final List<OutboundItem> items;

  factory OutboundGroupInfo.fromMap(Map<dynamic, dynamic> m) =>
      OutboundGroupInfo(
        tag: m['tag'] as String? ?? '',
        type: m['type'] as String? ?? '',
        selected: m['selected'] as String? ?? '',
        selectable: m['selectable'] as bool? ?? false,
        items: ((m['items'] as List?) ?? const [])
            .map((e) => OutboundItem.fromMap(e as Map))
            .toList(),
      );
}

/// Sends a selector command and waits until the core's group stream reports the
/// requested value. A platform-channel return only proves command delivery;
/// this readback proves the running sing-box instance applied it.
Future<void> selectOutboundWithConfirmation({
  required Stream<List<OutboundGroupInfo>> groups,
  required Future<void> Function() send,
  required String group,
  required String tag,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final confirmed = Completer<void>();
  late final StreamSubscription<List<OutboundGroupInfo>> subscription;
  subscription = groups.listen(
    (snapshot) {
      for (final candidate in snapshot) {
        if (candidate.tag == group && candidate.selected == tag) {
          if (!confirmed.isCompleted) confirmed.complete();
          return;
        }
      }
    },
    onError: (Object _, StackTrace _) {
      if (!confirmed.isCompleted) {
        confirmed.completeError(StateError('selector_readback_failed'));
      }
    },
  );
  try {
    await (() async {
      await send();
      await confirmed.future;
    })().timeout(
      timeout,
      onTimeout: () => throw StateError('selector_confirmation_timeout'),
    );
  } finally {
    await subscription.cancel();
  }
}

abstract class AuroraBridge {
  /// Requests VPN consent. Returns true if already authorized or granted.
  Future<bool> prepare();

  /// Starts the tunnel with a full sing-box JSON config (from ConfigCompiler).
  Future<void> start(String configJson);

  /// Stops the tunnel.
  Future<void> stop();

  /// One-shot current status.
  Future<AuroraStatus> status();

  /// Status changes (connect/disconnect lifecycle).
  Stream<AuroraStatus> statusStream();

  /// Live core logs (empty until M-later wires libbox CommandLog).
  Stream<String> logStream();

  /// One-shot traffic snapshot.
  Future<TrafficStat> queryStats();

  /// Live traffic stream (≈1 Hz while connected).
  Stream<TrafficStat> statsStream();

  /// Live outbound groups (nodes, urltest delays, current selection).
  Stream<List<OutboundGroupInfo>> groupsStream();

  /// Select [tag] within [group] and return only after the running core has
  /// acknowledged/read back that selection. Throws when it cannot be proven.
  Future<void> selectOutbound(String group, String tag);

  /// Trigger a urltest of [group].
  Future<void> urlTest(String group);

  /// Open the OS VPN settings (for Always-on VPN / block-non-VPN kill-switch).
  Future<void> openVpnSettings();
}

/// A bridge that can say "why the last start failed": an optional capability,
/// not part of the lifecycle contract (same approach as
/// [AuroraMobileSessionControl]; only implementations that have it provide it).
///
/// Android does not provide it yet; Apple reads it from the NE's
/// `fetchLastDisconnectError` (a rejection such as "No network available" is known
/// only there, since the extension process was never even launched);
/// Windows/Linux read it from the `detail` of aurora-svc `/status`.
/// `ConnectFlow.startFailureReason` ranks it ahead of log inference.
abstract interface class AuroraStartFailureDetail {
  /// The platform's own words about the last start/stop failure, or null if there is none.
  Future<String?> lastStartFailureDetail();
}
