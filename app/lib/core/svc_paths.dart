import 'dart:io';

import 'windows_paths.dart';

/// The set of paths on each platform that the app and the privileged helper can both compute to the same location.
///
/// The one rule: **derive only from machine-level information**. The helper runs
/// as SYSTEM/root and the app as the logged-in user; any location derived from
/// `%APPDATA%` / `$HOME` / `$XDG_*` comes out different in the two. On Windows
/// this mistake produced
/// "aurora-svc start failed (403) config path outside allowed dir"
/// (see `desktop/aurora-svc/paths.go`); on Linux the same trap is `$HOME`.
abstract class SvcPaths {
  String get sharedDir;
  String get svcTokenPath;
  String get singBoxLogPath;

  /// Re-read from disk on every call, never cached: the helper only writes this
  /// credential at startup, and it can appear later than the app (first install,
  /// service repair).
  String readSvcToken();
}

/// Windows: an instance view of [SvcPaths] that forwards to the existing static
/// implementation of [WindowsPaths]; not one line of `windows_paths.dart` changes,
/// and existing call sites such as `desktop_shell.dart`/`svc_installer.dart` keep
/// using the original static members.
class WindowsSvcPaths implements SvcPaths {
  const WindowsSvcPaths();

  @override
  String get sharedDir => WindowsPaths.sharedDir;

  @override
  String get svcTokenPath => WindowsPaths.svcTokenPath;

  @override
  String get singBoxLogPath => WindowsPaths.singBoxLogPath;

  @override
  String readSvcToken() => WindowsPaths.readSvcToken();
}

/// Linux: state lives in `/var/lib/aurora`, matching `StateDirectory` in the systemd unit.
class LinuxPaths implements SvcPaths {
  const LinuxPaths();

  @override
  String get sharedDir => '/var/lib/aurora';

  @override
  String get svcTokenPath => '$sharedDir/svc-token';

  @override
  String get singBoxLogPath => '$sharedDir/logs/sing-box.log';

  @override
  String readSvcToken() {
    try {
      final file = File(svcTokenPath);
      return file.existsSync() ? file.readAsStringSync().trim() : '';
    } catch (_) {
      return '';
    }
  }
}

/// Pick a loopback port that is free right now, for the connect flow to compile
/// into this config and then tell aurora-svc to probe (`clash_probe.port`).
/// Binding to port 0 lets the kernel allocate a port nobody is using, and it is
/// closed immediately to release it. There is a tiny race window (another process
/// may grab it first), but that is closer to the truth than hard-coding 9090,
/// which Clash/mihomo/v2rayN hold permanently.
Future<int> pickFreeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
