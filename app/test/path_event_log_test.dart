import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/path_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('path-event-log-test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('records timestamped JSONL events in order', () async {
    final log = PathEventLog(
      directory: dir,
      now: () => DateTime.utc(2026, 7, 22, 12),
    );
    await log.record('vpn_connected');
    await log.record('path', {'state': 'homeBlocked', 'reason': 'x'});

    final lines = File('${dir.path}/path-events.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    final first = jsonDecode(lines[0]) as Map<String, dynamic>;
    final second = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(first['t'], '2026-07-22T12:00:00.000Z');
    expect(first['e'], 'vpn_connected');
    expect(second['e'], 'path');
    expect(second['state'], 'homeBlocked');
  });

  test('rotates once past the size cap instead of growing forever', () async {
    final log = PathEventLog(directory: dir, maxBytes: 120);
    for (var i = 0; i < 10; i++) {
      await log.record('event', {'index': i});
    }

    expect(File('${dir.path}/path-events.1.jsonl').existsSync(), isTrue);
    expect(
      File('${dir.path}/path-events.jsonl').lengthSync(),
      lessThan(240),
    );
  });

  test('default directory per platform', () {
    // iOS: devicectl may only copy Library/Documents/tmp out of an app
    // container, so the timeline has to live under Library to be pullable.
    expect(
      PathEventLog.iosDirectoryPath(
        '/var/mobile/Containers/Data/Application/X/Library',
      ),
      '/var/mobile/Containers/Data/Application/X/Library/Application Support/Aurora',
    );
    // Dart's Platform.environment is always empty on iOS, so a HOME-based
    // default could never resolve on a device; main.dart injects it instead.
    expect(
      PathEventLog.defaultDirectoryPath('ios', {
        'HOME': '/var/mobile/Containers/Data/Application/X',
      }),
      isNull,
    );
    expect(
      PathEventLog.defaultDirectoryPath('macos', {'HOME': '/Users/u'}),
      '/Users/u/Library/Application Support/Aurora',
    );
    expect(
      PathEventLog.defaultDirectoryPath('windows', {'APPDATA': r'C:\A'}),
      r'C:\A\Aurora',
    );
    expect(
      PathEventLog.defaultDirectoryPath('linux', {'HOME': '/home/u'}),
      '/home/u/.local/share/Aurora',
    );
    expect(
      PathEventLog.defaultDirectoryPath('linux', {
        'HOME': '/home/u',
        'XDG_DATA_HOME': '/x',
      }),
      '/x/Aurora',
    );
    expect(PathEventLog.defaultDirectoryPath('android', {'HOME': '/'}), isNull);
    expect(PathEventLog.defaultDirectoryPath('ios', {}), isNull);
  });

  test('a directory set after construction is where events go', () async {
    // The shared instance is built with no directory; iOS hands one in at
    // startup.
    final log = PathEventLog();
    log.directory = Directory('${dir.path}/Library/Application Support/Aurora');
    await log.record('app_launch');

    final file = File(
      '${dir.path}/Library/Application Support/Aurora/path-events.jsonl',
    );
    expect(file.readAsLinesSync(), hasLength(1));
  });

  test('a disabled log writes nothing', () async {
    final log = PathEventLog(directory: dir, enabled: false);
    await log.record('vpn_connected');

    expect(File('${dir.path}/path-events.jsonl').existsSync(), isFalse);
  });
}
