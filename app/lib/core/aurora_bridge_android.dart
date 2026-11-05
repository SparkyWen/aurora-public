import 'package:flutter/services.dart';

import 'aurora_bridge.dart';
import 'mobile_session_control.dart';

/// Android implementation of [AuroraBridge] over MethodChannel `aurora/method`
/// and EventChannels `aurora/events` (status), `aurora/stats` (traffic),
/// `aurora/groups` (nodes). Native side: MainActivity + AuroraVpnService.
class AuroraBridgeAndroid implements AuroraBridge, AuroraMobileSessionControl {
  AuroraBridgeAndroid._();

  /// Singleton (see [AuroraBridgeApple.instance]): shared static stream state,
  /// and the supervisor's `identical` short-circuit needs one stable instance.
  static final AuroraBridgeAndroid instance = AuroraBridgeAndroid._();
  factory AuroraBridgeAndroid() => instance;

  static const MethodChannel _method = MethodChannel('aurora/method');
  static const EventChannel _events = EventChannel('aurora/events');
  static const EventChannel _stats = EventChannel('aurora/stats');
  static const EventChannel _groups = EventChannel('aurora/groups');

  // One shared broadcast stream per EventChannel. Each receiveBroadcastStream()
  // call re-sends "listen" on the same channel name, replacing the platform-side
  // handler — with two pages subscribed (ConnectPage + NodesPage on groups), the
  // first page's stream silently freezes and a pop() unregisters the native
  // listener under the survivor. Pages create their own bridge instances, so the
  // sharing must be static.
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
  bool get usesMobileSessionRecovery => true;

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
}
