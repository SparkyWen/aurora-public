import 'aurora_bridge.dart';

/// Mobile recovery never prepares or starts a replacement system VPN.
/// macOS shares the Apple bridge but does not opt into this capability.
abstract interface class AuroraMobileSessionControl {
  bool get usesMobileSessionRecovery;
  Future<MobileSessionSnapshot> sessionSnapshot();
  Future<MobileReloadResult> reloadCurrentSession(String sessionId);
}

class MobileSessionSnapshot {
  const MobileSessionSnapshot({required this.status, this.sessionId});

  factory MobileSessionSnapshot.fromMap(Map<dynamic, dynamic>? value) {
    final id = value?['sessionId'];
    return MobileSessionSnapshot(
      status: auroraStatusFromString(value?['status'] as String?),
      sessionId: id is String && id.isNotEmpty ? id : null,
    );
  }

  final AuroraStatus status;
  final String? sessionId;
}

enum MobileReloadResult {
  reloaded,
  unavailable,
  requiresReconnect;

  static MobileReloadResult fromWire(String? value) => switch (value) {
    'reloaded' => reloaded,
    'unavailable' => unavailable,
    _ => requiresReconnect,
  };
}

bool usesMobileSessionRecovery(AuroraBridge bridge) =>
    bridge is AuroraMobileSessionControl &&
    (bridge as AuroraMobileSessionControl).usesMobileSessionRecovery;
