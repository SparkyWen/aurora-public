import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'aurora_bridge.dart';
import 'mobile_session_control.dart';

/// Apple (iOS + macOS) implementation of [AuroraBridge]. Uses the SAME channel
/// contract as Android (architecture spec §4.3 / iOS spec §8): MethodChannel
/// `aurora/method` and EventChannels `aurora/events` (status), `aurora/stats`
/// (traffic), `aurora/groups` (nodes). Native side: AuroraVPN (Runner) drives a
/// NETunnelProviderManager and a libbox CommandClient connected to the
/// PacketTunnel extension's CommandServer over the shared App Group. iOS and
/// macOS share this Dart side; only the native `AuroraVPN.swift` differs.
class AuroraBridgeApple
    implements AuroraBridge, AuroraMobileSessionControl, AuroraStartFailureDetail {
  AuroraBridgeApple._();

  /// Singleton: all bridge state is static (shared broadcast streams), and the
  /// process VPN supervisor keys off `identical(bridge, …)` to avoid tearing
  /// down and rebuilding a live session when a page re-attaches with its own
  /// bridge handle. Returning distinct instances broke that short-circuit.
  static final AuroraBridgeApple instance = AuroraBridgeApple._();
  factory AuroraBridgeApple() => instance;

  static const MethodChannel _method = MethodChannel('aurora/method');
  static const EventChannel _events = EventChannel('aurora/events');
  static const EventChannel _stats = EventChannel('aurora/stats');
  static const EventChannel _groups = EventChannel('aurora/groups');

  // One shared broadcast stream per EventChannel — same rationale as the
  // Android bridge: a second receiveBroadcastStream() on the same channel
  // replaces the platform-side handler and breaks the first subscriber.
  static final Stream<AuroraStatus> _statusBroadcast = _events
      .receiveBroadcastStream()
      .map((e) => auroraStatusFromString(e as String?));
  static final Stream<TrafficStat> _statsBroadcast = _stats
      .receiveBroadcastStream()
      .map((e) => TrafficStat.fromMap(e as Map<dynamic, dynamic>?));
  static final Stream<List<OutboundGroupInfo>> _groupsBroadcast = _groups
      .receiveBroadcastStream()
      .map(
        (e) => ((e as List?) ?? const [])
            .map((g) => OutboundGroupInfo.fromMap(g as Map))
            .toList(),
      );

  @override
  bool get usesMobileSessionRecovery => Platform.isIOS;

  @override
  Future<MobileSessionSnapshot> sessionSnapshot() async =>
      MobileSessionSnapshot.fromMap(
        await _method.invokeMapMethod<dynamic, dynamic>('sessionSnapshot'),
      );

  @override
  Future<MobileReloadResult> reloadCurrentSession(String sessionId) async =>
      MobileReloadResult.fromWire(
        await _method.invokeMethod<String>('reloadCurrentSession', {
          'sessionId': sessionId,
        }),
      );

  @override
  Future<bool> prepare() async =>
      await _method.invokeMethod<bool>('prepare') ?? false;

  @override
  Future<void> start(String configJson) async {
    await _method.invokeMethod<void>('start', {'config': configJson});
  }

  @override
  Future<void> stop() async => _method.invokeMethod<void>('stop');

  @override
  Future<AuroraStatus> status() async =>
      auroraStatusFromString(await _method.invokeMethod<String>('status'));

  @override
  Stream<AuroraStatus> statusStream() => _statusBroadcast;

  @override
  Stream<String> logStream() => const Stream<String>.empty();

  @override
  Future<TrafficStat> queryStats() async => TrafficStat.fromMap(
    await _method.invokeMethod<Map<dynamic, dynamic>>('queryStats'),
  );

  @override
  Stream<TrafficStat> statsStream() => _statsBroadcast;

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() => _groupsBroadcast;

  @override
  Future<void> selectOutbound(String group, String tag) async {
    await selectOutboundWithConfirmation(
      groups: _groupsBroadcast,
      group: group,
      tag: tag,
      send: () => _method.invokeMethod<void>('selectOutbound', {
        'group': group,
        'tag': tag,
      }),
    );
  }

  @override
  Future<void> urlTest(String group) async {
    await _method.invokeMethod<void>('urlTest', {'group': group});
  }

  @override
  Future<void> openVpnSettings() async {
    await _method.invokeMethod<void>('openVpnSettings');
  }

  /// The last disconnect reason recorded by the NE (`fetchLastDisconnectError`,
  /// macOS 13+ / iOS 16+). The native side clears it on every start, so what comes
  /// back is always the conclusion of this start. Returns null on an older system
  /// or an older native side that lacks the method.
  @override
  Future<String?> lastStartFailureDetail() async {
    try {
      return await _method.invokeMethod<String>('lastDisconnectError');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
