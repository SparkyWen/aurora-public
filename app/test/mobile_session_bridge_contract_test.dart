import 'dart:io';

import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/aurora_bridge_android.dart';
import 'package:aurora/core/aurora_bridge_apple.dart';
import 'package:aurora/core/mobile_session_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aurora/method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final entry in <String, AuroraMobileSessionControl>{
    'Android': AuroraBridgeAndroid(),
    'Apple': AuroraBridgeApple(),
  }.entries) {
    test(
      '${entry.key} uses the exact snapshot and reload wire contract',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'sessionSnapshot' => {
              'status': 'connecting',
              'sessionId': 'owned-id',
            },
            'reloadCurrentSession' => 'reloaded',
            _ => throw StateError('Unexpected platform method'),
          };
        });
        final snapshot = await entry.value.sessionSnapshot();
        expect(snapshot.status, AuroraStatus.connecting);
        expect(snapshot.sessionId, 'owned-id');
        expect(
          await entry.value.reloadCurrentSession('owned-id'),
          MobileReloadResult.reloaded,
        );
        expect(calls.map((call) => call.method), [
          'sessionSnapshot',
          'reloadCurrentSession',
        ]);
        expect(calls.first.arguments, null);
        expect(calls.last.arguments, {'sessionId': 'owned-id'});
      },
    );
    test(
      '${entry.key} missing identity and unknown result fail closed',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'sessionSnapshot'
              ? {'status': 'disconnected'}
              : 'unknown-future-result',
        );
        expect((await entry.value.sessionSnapshot()).sessionId, null);
        expect(
          await entry.value.reloadCurrentSession('old-id'),
          MobileReloadResult.requiresReconnect,
        );
      },
    );
  }
  test(
    'Android opts in; shared Apple bridge keeps macOS recovery unchanged',
    () {
      expect(usesMobileSessionRecovery(AuroraBridgeAndroid()), true);
      expect(usesMobileSessionRecovery(AuroraBridgeApple()), Platform.isIOS);
    },
  );
}
