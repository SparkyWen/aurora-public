import 'dart:io';
import 'dart:math';

/// Windows-specific paths + secret generation for the svc/Clash bridge (spec §4).
///
/// Everything shared with `aurora-svc` hangs off `%ProgramData%\Aurora`, and
/// nothing here may be derived from a per-user variable: the helper runs as
/// LocalSystem while this app runs as the logged-in user, so `%APPDATA%` and
/// friends expand to two different directories in the two processes. Agreeing
/// on a location through one of them is what produced
/// "aurora-svc start failed (403) config path outside allowed dir" — see
/// `desktop/aurora-svc/paths.go`.
class WindowsPaths {
  /// `%ProgramData%\Aurora` — identical for SYSTEM and for the user.
  static String get sharedDir {
    final env = Platform.environment;
    final base =
        env['ProgramData']?.trim().isNotEmpty == true
        ? env['ProgramData']!.trim()
        : env['ALLUSERSPROFILE']?.trim().isNotEmpty == true
        ? env['ALLUSERSPROFILE']!.trim()
        // Last resort matches the helper's own default rather than something
        // user-scoped, so the two sides still meet.
        : r'C:\ProgramData';
    return '$base${Platform.pathSeparator}Aurora';
  }

  static String get svcTokenPath =>
      '$sharedDir${Platform.pathSeparator}svc-token';

  /// Where the helper mirrors sing-box's stdout/stderr — the first thing to
  /// read when a connect fails on Windows.
  static String get singBoxLogPath =>
      '$sharedDir${Platform.pathSeparator}logs'
      '${Platform.pathSeparator}sing-box.log';

  /// Reads the shared bearer token. Called per request, never cached: the
  /// helper provisions it, and it may appear after the app is already up.
  static String readSvcToken() {
    try {
      final f = File(svcTokenPath);
      return f.existsSync() ? f.readAsStringSync().trim() : '';
    } catch (_) {
      return '';
    }
  }

  /// Deletes the config that pre-installer builds wrote to `%APPDATA%\Aurora\`.
  ///
  /// Nothing reads it any more — the compiled config travels over the wire to
  /// the helper now — but it holds real node credentials in plaintext, so
  /// leaving it behind on every machine that ever ran an older build is not
  /// acceptable. The installer cannot do this: it runs elevated, and
  /// `%APPDATA%` there is the elevating admin's, not the user's.
  static void removeLegacyUserConfig() {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return;
      final f = File(
        '$appData${Platform.pathSeparator}Aurora'
        '${Platform.pathSeparator}config.json',
      );
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Best effort — never block startup over a cleanup.
    }
  }

  /// 32 hex chars from a cryptographically-strong source.
  static String randomSecret() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
