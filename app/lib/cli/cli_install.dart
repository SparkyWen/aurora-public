/// Install layout: how the command line finds what it needs on disk. Pure Dart.
///
/// `aurora-cli` is installed next to the Flutter output under `/opt/aurora/`:
///
/// ```
/// /opt/aurora/
///   aurora                     GUI
///   aurora-cli                 this command
///   sing-box  aurora-svc
///   data/flutter_assets/
///     version.json             <- version number
///     assets/configs/aurora-contract.json   <- embedded contract (optional, private builds only)
///     assets/rule_sets/*.srs   <- rule sets for smart mode
/// ```
///
/// Everything is located relative to [Platform.resolvedExecutable], with no environment variables read — the same approach
/// `tray_manager` uses to find the tray icon, and it also avoids the "derive a path from an environment variable" pattern
/// that has caused trouble across the privilege boundary (hard constraint in CONTRIBUTING.md).
library;

import 'dart:convert';
import 'dart:io';

import '../core/rule_set_assets.dart';

/// Directory of the executable.
Directory auroraInstallDir() => File(Platform.resolvedExecutable).parent;

/// The version number the install package reports.
///
/// This reads the `version.json` Flutter itself writes into the bundle — on Linux `package_info_plus`
/// (which the GUI uses) reads the same file, so both entry points always report the same number and there is no need to inject it again
/// at build time (`dart build cli` indeed does not support `--define`).
///
/// Returns `0.0.0` when it cannot be read: this value is only used for the contract signature's `min_client_version`, and reporting a low one
/// only means the remote refresh is rejected and it falls back to the local contract (which still connects); claiming a high version is the one that is really
/// dangerous.
String readAuroraVersion(Directory installDir) {
  try {
    final file = File('${installDir.path}/data/flutter_assets/version.json');
    if (!file.existsSync()) return '0.0.0';
    final parsed = json.decode(file.readAsStringSync());
    if (parsed is! Map) return '0.0.0';
    final version = parsed['version'];
    return version is String && version.isNotEmpty ? version : '0.0.0';
  } catch (_) {
    return '0.0.0';
  }
}

/// The `.srs` files smart mode needs (tag -> absolute path).
///
/// If any is missing, an empty map is returned and the caller refuses smart mode — compiling a config that references a file that does not exist
/// makes sing-box fail only at startup, by which point the error message is far from the cause.
Map<String, String> auroraRuleSetPaths(Directory installDir) {
  final base = '${installDir.path}/data/flutter_assets/$auroraRuleSetAssetDir';
  final paths = <String, String>{};
  for (final entry in auroraRuleSetFiles.entries) {
    final file = File('$base/${entry.value}');
    if (!file.existsSync()) return const {};
    paths[entry.key] = file.path;
  }
  return paths;
}

/// Per-user state directory (the command line's own contract cache).
///
/// A **user** directory, unrelated to aurora-svc's root-owned `/var/lib/aurora`: the command line
/// never hands a path it computed to the privileged service (the config goes over as bytes), so using a per-user
/// path here does not touch the trap described by the privilege-boundary hard constraint in CONTRIBUTING.md.
Directory defaultCliStateDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_STATE_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory('$xdg/aurora');
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    return Directory('$home/.local/state/aurora');
  }
  return Directory('/tmp/aurora-cli');
}
