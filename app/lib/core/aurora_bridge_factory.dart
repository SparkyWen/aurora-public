import 'dart:io' show Platform;

import 'aurora_bridge.dart';
import 'aurora_bridge_android.dart';
import 'aurora_bridge_apple.dart';
import 'aurora_bridge_svc.dart';

/// Returns the platform-appropriate [AuroraBridge] implementation.
///
/// The Dart channel contract (`aurora/method` + `aurora/events`/`stats`/`groups`)
/// is identical on Android/iOS/macOS; only the native side differs (Android
/// AuroraVpnService vs Apple NETunnelProviderManager + libbox CommandClient).
/// Windows and (upcoming) Linux drive sing-box out-of-process via a privileged
/// service + Clash API (no platform channel) but implement the same interface
/// through the shared [AuroraBridgeSvc]. Keeping a single factory means the
/// shared UI never branches on platform.
AuroraBridge createAuroraBridge() {
  if (Platform.isIOS || Platform.isMacOS) return AuroraBridgeApple();
  // Windows and Linux take the same path: a privileged helper runs the official
  // sing-box, and the app reads state and switches nodes through the Clash API.
  // The only difference is where the shared directory is, folded into SvcPaths.
  if (Platform.isWindows || Platform.isLinux) {
    return AuroraBridgeSvc.forPlatform();
  }
  return AuroraBridgeAndroid();
}
