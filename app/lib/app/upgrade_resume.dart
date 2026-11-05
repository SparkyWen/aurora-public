import 'dart:io';

/// Brings the tunnel back after an iOS in-place upgrade.
///
/// Installing a new build (devicectl, TestFlight, the App Store — all alike)
/// kills the app together with its packet-tunnel extension, and nothing on
/// iOS reconnects it: desktop connects on launch, mobile waits for a tap. On
/// After 1.9.25 was installed the iPhone sat at "Disconnected", which looked
/// exactly like the install had not happened. The extension also only holds
/// the config the previous build compiled, so the reconnect has to come from
/// the app, through the new compiler.
///
/// The file holds the build the tunnel was last seen up under. It lives in the
/// app container, so an upgrade keeps it and deleting the app removes it —
/// unlike the Keychain, a reinstall never inherits it. Every failure is
/// swallowed: this must never stand in the way of connecting or stopping.
class UpgradeResume {
  UpgradeResume(this._file, this._currentBuild);

  final File _file;
  final Future<String> Function() _currentBuild;

  /// The tunnel is up under the running build.
  Future<void> tunnelUp() async {
    try {
      final build = await _currentBuild();
      if (_read() != build) _write(build);
    } catch (_) {}
  }

  /// The user turned it off in the app: an upgrade must leave it off.
  Future<void> userStopped() async {
    try {
      if (_file.existsSync()) _file.deleteSync();
    } catch (_) {}
  }

  /// At launch, with the tunnel down: the builds to resume between, or null.
  /// Claiming records the running build first, so each upgrade gets exactly
  /// one attempt, whether or not it connects.
  Future<({String from, String to})?> claim() async {
    try {
      final previous = _read();
      final build = await _currentBuild();
      if (previous == null || previous == build) return null;
      _write(build);
      return (from: previous, to: build);
    } catch (_) {
      return null;
    }
  }

  String? _read() {
    try {
      final value = _file.readAsStringSync().trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  void _write(String build) {
    _file.parent.createSync(recursive: true);
    final staged = File('${_file.path}.tmp');
    staged.writeAsStringSync(build, flush: true);
    staged.renameSync(_file.path);
  }
}
