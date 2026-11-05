import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/core/tailnet_bridge.dart';
import 'package:aurora/core/tailnet_options.dart';

const node = '0e450b54-b6d3-4afe-9a3f-2a237e5b33b4';
const session = '09091a98-9fe3-4a16-8faa-c9a78d05ef75';
const secret = 'private-sentinel-never-echo';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aurora/tailnet');
  const bridge = MethodChannelAuroraMobileTailnet();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? reply;
  Map<String, Object?> settings() => {
    'schema': 1,
    'settingsGeneration': 2,
    'enabled': true,
    'nodeGeneration': node,
  };
  Map<String, Object?> context() => {
    'schema': 1,
    'settingsGeneration': 2,
    'nodeGeneration': node,
    'stateDirectory': '/private/aurora-tailnet/node',
    'hostname': 'aurora-ios-fixture',
  };
  Map<String, Object?> snapshot() => {
    'schema': 1,
    'sessionId': session,
    'nodeGeneration': node,
    'publicStatus': 'connected',
    'tailnetStatus': 'unverified',
    'authAvailable': false,
  };
  setUp(() {
    calls.clear();
    reply = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'missing native capability remains unsupported without a start',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await bridge.tailnetCapability(), isFalse);
    },
  );
  test('capability is exactly a native bool, not a readiness claim', () async {
    reply = true;
    expect(await bridge.tailnetCapability(), isTrue);
    reply = false;
    expect(await bridge.tailnetCapability(), isFalse);
    reply = {'supported': true};
    await expectLater(bridge.tailnetCapability(), throwsFormatException);
    expect(
      calls.every((c) => c.method == 'capability' && c.arguments == null),
      isTrue,
    );
  });
  test('settings retain generation and are immutable', () async {
    reply = settings();
    final value = await bridge.readTailnetSettings();
    expect(value, settings());
    expect(() => value['enabled'] = false, throwsUnsupportedError);
    expect(calls.single.method, 'readSettings');
  });
  test(
    'generation uses nonnegative int64 without accepting a double',
    () async {
      for (final generation in [0, 0x7fffffffffffffff]) {
        reply = settings()..['settingsGeneration'] = generation;
        expect(
          (await bridge.readTailnetSettings())['settingsGeneration'],
          generation,
        );
      }
      reply = settings()..['settingsGeneration'] = 2.0;
      await expectLater(bridge.readTailnetSettings(), throwsFormatException);
    },
  );
  test(
    'legal uppercase UUIDs round trip without changing native ownership',
    () async {
      reply = settings()..['nodeGeneration'] = node.toUpperCase();
      expect(
        (await bridge.readTailnetSettings())['nodeGeneration'],
        node.toUpperCase(),
      );
      reply = 'opened';
      await bridge.openTailnetAuthentication(
        session.toUpperCase(),
        node.toUpperCase(),
      );
      expect(calls.last.arguments, {
        'sessionId': session.toUpperCase(),
        'nodeGeneration': node.toUpperCase(),
      });
    },
  );
  for (final entry in <String, Object?>{
    'schema': 2,
    'settingsGeneration': -1,
    'enabled': 1,
    'nodeGeneration': 'bad-uuid',
    'authUrl': secret,
  }.entries) {
    test('settings reject malformed or extra ${entry.key}', () async {
      reply = settings()..[entry.key] = entry.value;
      await expectLater(bridge.readTailnetSettings(), throwsFormatException);
    });
  }
  test(
    'setEnabled sends the expected generation and never starts a VPN',
    () async {
      reply = settings();
      expect(await bridge.setTailnetEnabled(1, true), settings());
      expect(calls.single.method, 'setEnabled');
      expect(calls.single.arguments, {
        'expectedGeneration': 1,
        'enabled': true,
      });
    },
  );
  test(
    'setEnabled rejects a stale or contradictory successful response',
    () async {
      reply = settings()..['settingsGeneration'] = 0;
      await expectLater(
        bridge.setTailnetEnabled(1, true),
        throwsFormatException,
      );
      reply = settings()..['enabled'] = false;
      await expectLater(
        bridge.setTailnetEnabled(1, true),
        throwsFormatException,
      );
    },
  );
  test('disabled prepare is null; a valid context is native-owned', () async {
    expect(await bridge.prepareTailnetStart(2), isNull);
    reply = context();
    final value = (await bridge.prepareTailnetStart(2))!;
    expect(value.settingsGeneration, 2);
    expect(value.nodeGeneration, node);
    expect(value.options.stateDirectory, '/private/aurora-tailnet/node');
    expect(value.options.hostname, 'aurora-ios-fixture');
    expect(calls.last.arguments, {'expectedGeneration': 2});
  });
  for (final entry in <String, Object?>{
    'schema': 0,
    'settingsGeneration': 3,
    'nodeGeneration': null,
    'stateDirectory': r'/private/$HOME/node',
    'hostname': 'bad.host',
    'authUrl': secret,
  }.entries) {
    test('prepare rejects invalid ${entry.key} without starting', () async {
      reply = context()..[entry.key] = entry.value;
      await expectLater(bridge.prepareTailnetStart(2), throwsFormatException);
      expect(calls.single.method, 'prepareStart');
    });
  }
  test(
    'start sends only config and captured generations, exactly once',
    () async {
      final value = TailnetStartContext(
        settingsGeneration: 2,
        nodeGeneration: node,
        options: TailnetOptions(
          stateDirectory: '/private/aurora-tailnet/node',
          hostname: 'aurora-ios-fixture',
        ),
      );
      await bridge.startWithTailnet('{"fixture":true}', value);
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {
        'config': '{"fixture":true}',
        'settingsGeneration': 2,
        'nodeGeneration': node,
      });
    },
  );
  test(
    'snapshot reports unverified even when public VPN is connected',
    () async {
      reply = snapshot();
      expect(await bridge.tailnetSnapshot(), snapshot());
      expect(calls.single.method, 'snapshot');
    },
  );
  for (final entry in <String, Object?>{
    'publicStatus': 'unknown',
    'tailnetStatus': 'authenticated',
    'authAvailable': true,
    'sessionId': 'bad',
    'url': secret,
  }.entries) {
    test('snapshot refuses unsupported or inconsistent ${entry.key}', () async {
      reply = snapshot()..[entry.key] = entry.value;
      await expectLater(bridge.tailnetSnapshot(), throwsFormatException);
    });
  }
  test('login availability is bound to an existing session and node', () async {
    reply = snapshot()
      ..['tailnetStatus'] = 'needsLogin'
      ..['authAvailable'] = true;
    expect((await bridge.tailnetSnapshot())['authAvailable'], isTrue);
    reply = (reply as Map)..['sessionId'] = null;
    await expectLater(bridge.tailnetSnapshot(), throwsFormatException);
  });
  for (final result in ['opened', 'unavailable', 'stale']) {
    test('authentication accepts only native result $result', () async {
      reply = result;
      expect(await bridge.openTailnetAuthentication(session, node), result);
      expect(calls.single.arguments, {
        'sessionId': session,
        'nodeGeneration': node,
      });
    });
  }
  for (final result in <Object?>[
    null,
    true,
    'authenticated',
    {'url': secret},
  ]) {
    test(
      'authentication refuses a non-protocol response ${result.runtimeType}',
      () async {
        reply = result;
        await expectLater(
          bridge.openTailnetAuthentication(session, node),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'no private response',
              isNot(contains(secret)),
            ),
          ),
        );
      },
    );
  }
  test(
    'forget requires the node generation and does not implicitly stop',
    () async {
      for (final result in ['forgotten', 'busy', 'stale']) {
        reply = result;
        expect(await bridge.forgetTailnetNode(node), result);
      }
      expect(
        calls.every(
          (c) =>
              c.method == 'forget' &&
              (c.arguments as Map)['nodeGeneration'] == node,
        ),
        isTrue,
      );
    },
  );
  test('invalid outgoing identities never cross the native boundary', () async {
    await expectLater(bridge.setTailnetEnabled(-1, true), throwsArgumentError);
    await expectLater(bridge.prepareTailnetStart(-1), throwsArgumentError);
    await expectLater(
      bridge.openTailnetAuthentication('$session\n', node),
      throwsArgumentError,
    );
    await expectLater(bridge.forgetTailnetNode(secret), throwsArgumentError);
    expect(calls, isEmpty);
  });
  test(
    'native errors cannot expose an authentication URL or private details',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: secret,
          message: secret,
          details: {'url': secret},
        );
      });
      await expectLater(
        bridge.openTailnetAuthentication(session, node),
        throwsA(
          isA<TailnetBridgeFailure>()
              .having((e) => e.code, 'safe code', 'native-failure')
              .having(
                (e) => e.toString(),
                'no native secret',
                isNot(contains(secret)),
              ),
        ),
      );
    },
  );
  test('timeout reports failure and never retries the native action', () async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return pending.future;
    });
    const short = MethodChannelAuroraMobileTailnet(
      timeout: Duration(milliseconds: 10),
    );
    await expectLater(
      short.openTailnetAuthentication(session, node),
      throwsA(
        isA<TailnetBridgeFailure>().having((e) => e.code, 'code', 'timeout'),
      ),
    );
    pending.complete('opened');
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));
  });
}
