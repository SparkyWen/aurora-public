import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:path_provider/path_provider.dart';

import 'rule_set_assets.dart';

/// Extracts the embedded `.srs` rule sets (Smart mode) from Flutter assets to a
/// writable dir so libbox can reference them by `local` path. Architecture
/// §5.4: rule sets are bundled, never fetched from GitHub at runtime.
class RuleSets {
  /// rule-set tag -> asset file name. The manifest is in `rule_set_assets.dart`
  /// (pure Dart); the command-line path reads the same one, see that file.
  static const Map<String, String> _files = auroraRuleSetFiles;

  /// Writable base dir for the extracted rule sets.
  ///
  /// iOS: the PacketTunnel extension is a separate process that can only read
  /// the shared App Group container, so the `.srs` MUST land there (not the
  /// app-private support dir, which the extension can't see). Android's
  /// VpnService shares the app sandbox, so the support dir is fine.
  static Future<Directory> _baseDir() async {
    if (Platform.isIOS) {
      const channel = MethodChannel('aurora/method');
      final group =
          await channel.invokeMethod<String>('appGroupContainer');
      if (group == null || group.isEmpty) {
        throw StateError('iOS App Group container unavailable');
      }
      return Directory(group);
    }
    return getApplicationSupportDirectory();
  }

  /// Ensures all `.srs` are on disk; returns {tag: absolutePath}.
  static Future<Map<String, String>> ensureExtracted() async {
    final base = await _baseDir();
    final dir = Directory('${base.path}/rule_sets');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final paths = <String, String>{};
    for (final entry in _files.entries) {
      final file = File('${dir.path}/${entry.value}');
      if (!file.existsSync()) {
        final data = await rootBundle.load(
          '$auroraRuleSetAssetDir/${entry.value}',
        );
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      paths[entry.key] = file.path;
    }
    return paths;
  }
}
