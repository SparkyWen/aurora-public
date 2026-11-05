import 'dart:io';

import 'aurora_svc_client.dart';
import 'windows_paths.dart';

/// Installs/repairs/uninstalls the aurora-svc Windows service.
///
/// Normally the Windows *installer* has already done this (it runs
/// `aurora-svc.exe install` elevated), so a fresh machine connects without ever
/// touching these controls. They remain for repair: a service left over from an
/// older portable build points at a directory that no longer exists, and
/// `install` reconciles it onto the current binary.
///
/// Uses ShellExecute "runas" (via PowerShell `Start-Process -Verb RunAs`) so a
/// repair costs exactly ONE UAC prompt; connect/disconnect never need elevation.
class SvcInstaller {
  static String get _svcExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${Platform.pathSeparator}aurora-svc.exe';
  }

  static AuroraSvcClient _client() =>
      AuroraSvcClient(token: WindowsPaths.readSvcToken);

  /// True once the helper answers on localhost.
  static Future<bool> isReady() async {
    final c = _client();
    try {
      return await c.installed();
    } finally {
      c.close();
    }
  }

  /// Installs (or repairs) the service, then waits for it to actually answer.
  ///
  /// The elevated child's exit code does not propagate through
  /// `Start-Process -Wait`, so reachability — not an exit code — is what
  /// "installed" means here.
  static Future<bool> install() async {
    if (!await _runElevated('install')) return false;
    return _waitUntilReady(const Duration(seconds: 15));
  }

  static Future<bool> uninstall() => _runElevated('uninstall');

  static Future<bool> _waitUntilReady(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (await isReady()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  static Future<bool> _runElevated(String verb) async {
    // PowerShell single-quoted strings escape a quote by doubling it.
    final exe = _svcExe.replaceAll("'", "''");
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath '$exe' -ArgumentList '$verb' "
          '-Verb RunAs -Wait -WindowStyle Hidden',
    ]);
    return r.exitCode == 0;
  }
}
