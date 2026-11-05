import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;

/// Local-only, size-capped JSONL timeline of connect and path decisions.
///
/// NEVPN logs only see tunnel starts/stops and the sing-box core does not log
/// to the unified log, so a mid-session fail-closed or path switch used to
/// leave no on-disk trace at all. This file is that missing evidence. It stays
/// on the machine — Aurora has no telemetry.
class PathEventLog {
  PathEventLog({
    this.enabled = true,
    this._directory,
    DateTime Function()? now,
    this._maxBytes = 512 * 1024,
  }) : _now = now ?? DateTime.now;

  /// Shared instance. Disabled by default so unit tests (and Android) never
  /// touch the filesystem; desktop and iOS opt in at startup (main.dart).
  static final PathEventLog instance = PathEventLog(enabled: false);

  bool enabled;
  Directory? _directory;

  /// Overrides where the timeline lives; set before the first [record].
  /// iOS needs this: see [iosDirectoryPath].
  set directory(Directory value) {
    _directory = value;
    _resolved = null;
    _unavailable = false;
  }
  final DateTime Function() _now;
  final int _maxBytes;

  Directory? _resolved;
  bool _unavailable = false;
  Future<void> _tail = Future.value();

  /// Appends one event line. Serialized through a chain so concurrent calls
  /// cannot interleave partial lines; any I/O failure is swallowed because
  /// diagnostics must never break connectivity code paths.
  Future<void> record(
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    if (!enabled) return Future.value();
    return _tail = _tail.then((_) => _append(event, fields));
  }

  Future<void> _append(String event, Map<String, Object?> fields) async {
    final dir = _resolve();
    if (dir == null) return;
    try {
      final file = File('${dir.path}/path-events.jsonl');
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.renameSync('${dir.path}/path-events.1.jsonl');
      }
      final line = jsonEncode({
        't': _now().toUtc().toIso8601String(),
        'e': event,
        ...fields,
      });
      await file.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Never let diagnostics interfere with the session.
    }
  }

  Directory? _resolve() {
    if (_unavailable) return null;
    final existing = _resolved;
    if (existing != null) return existing;
    var dir = _directory;
    if (dir == null) {
      final path = defaultDirectoryPath(
        Platform.operatingSystem,
        Platform.environment,
      );
      if (path != null) dir = Directory(path);
    }
    if (dir == null) {
      _unavailable = true;
      return null;
    }
    try {
      dir.createSync(recursive: true);
    } catch (_) {
      _unavailable = true;
      return null;
    }
    return _resolved = dir;
  }

  /// Where the timeline lives when no directory is injected; null where the
  /// platform has none (the log then stays a silent no-op).
  @visibleForTesting
  static String? defaultDirectoryPath(String os, Map<String, String> env) {
    String? nonEmpty(String key) {
      final value = env[key];
      return value == null || value.isEmpty ? null : value;
    }

    switch (os) {
      // iOS is not here: see [iosDirectoryPath].
      case 'macos':
        final home = nonEmpty('HOME');
        return home == null ? null : '$home/Library/Application Support/Aurora';
      // Windows had no timeline at all, which made every desktop failure there
      // a guessing game — the one file this project reaches for first when a
      // session drops. Per-user (the app is unelevated and installs into
      // Program Files, which it cannot write).
      case 'windows':
        final appData = nonEmpty('APPDATA');
        return appData == null ? null : '$appData\\Aurora';
      // Linux: isDesktop was turned on for Linux, but this timeline was never wired
      // up — without this branch, _unavailable landed directly and record() became a silent no-op from then on.
      // This file is written by the app itself (as the logged-in user), not by the privileged aurora-svc as service
      // state — that kind of thing belongs to LinuxPaths in svc_paths.dart (/var/lib/aurora,
      // systemd StateDirectory, root-owned). What is wanted here is "a directory the logged-in user can
      // read and write", which corresponds to the user data directory of the XDG Base Directory spec (falling back to ~/.local/share when
      // XDG_DATA_HOME is unset), for the same reason the macOS branch above lands in
      // ~/Library/Application Support, just with each platform's own equivalent.
      case 'linux':
        final xdgDataHome = nonEmpty('XDG_DATA_HOME');
        if (xdgDataHome != null) return '$xdgDataHome/Aurora';
        final home = nonEmpty('HOME');
        return home == null ? null : '$home/.local/share/Aurora';
      default:
        return null;
    }
  }

  /// The iOS timeline directory; [libraryPath] is the app container's Library (main.dart obtains it via
  /// path_provider and hands it in through [directory]).
  ///
  /// It must live under Library — devicectl only allows copying out of the app container's
  /// Library/Documents/tmp, and this is the only timeline on an iPhone that can be retrieved afterwards (there was not a single record
  /// when investigating a speed problem on iOS). It cannot read HOME like macOS does:
  /// the Dart VM's `Platform.environment` is always empty on iOS
  /// (`runtime/bin/platform_macos.cc`), and the first version did exactly that and wrote nothing at all on a real device.
  static String iosDirectoryPath(String libraryPath) =>
      '$libraryPath/Application Support/Aurora';
}
