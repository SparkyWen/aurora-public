import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The command line must be pure Dart.
///
/// A single `package:flutter/*` import leaking into `lib/cli/` or `bin/` makes
/// `dart build cli` unable to produce an executable - and that step only runs in
/// CI's Linux job, where someone editing on Mac/Windows never sees it. This test
/// moves the same discipline into every `flutter test` run, with a failure message
/// that points straight at the file.
void main() {
  test('lib/cli and bin have no Flutter dependency', () {
    final offenders = <String>[];

    for (final dir in [Directory('lib/cli'), Directory('bin')]) {
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final source = entry.readAsStringSync();
        for (final line in const LineSplitter().convert(source)) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
            continue;
          }
          if (trimmed.contains('package:flutter/') ||
              trimmed.contains('package:flutter_test/') ||
              trimmed.contains('dart:ui')) {
            offenders.add('${entry.path}: $trimmed');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'the CLI must run on a machine with no graphical environment, so it cannot depend on the Flutter engine',
    );
  });
}
