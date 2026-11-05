import 'dart:async';
import 'dart:io';

import 'package:aurora/data/secure_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const migration = MethodChannel('aurora/secure-store');
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  testWidgets(
    'all CRUD wait for successful macOS migration; failures retry without storage access',
    (tester) async {
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(migration, null);
        messenger.setMockMethodCallHandler(storage, null);
      });
      final storageCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(storage, (call) async {
        storageCalls.add(call);
        return call.method == 'read' ? 'preserved' : null;
      });
      var preparation = Completer<bool>();
      var preparations = 0;
      messenger.setMockMethodCallHandler(migration, (call) async {
        expect(call.method, 'prepareBackgroundAccess');
        expect(call.arguments, isNull);
        preparations++;
        return preparation.future;
      });

      // Non-macOS never waits for this macOS-only native capability.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await SecureStore.loadContract(), 'preserved');
      expect(preparations, 0);
      storageCalls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final operations = <Future<Object?> Function()>[
        SecureStore.loadContract,
        () => SecureStore.saveContract('contract'),
        SecureStore.clearContract,
        SecureStore.loadDeliveryUrl,
        () => SecureStore.saveDeliveryUrl('url'),
        SecureStore.loadMode,
        () => SecureStore.saveMode('smart'),
        SecureStore.loadPathPreference,
        () => SecureStore.savePathPreference('auto'),
        SecureStore.loadEgressLease,
        () => SecureStore.saveEgressLease('lease'),
        SecureStore.clearEgressLease,
        SecureStore.loadRouteFamily,
        () => SecureStore.saveRouteFamily('family'),
        SecureStore.clearRouteFamily,
        SecureStore.loadEgressInterface,
        () => SecureStore.saveEgressInterface('en0'),
        SecureStore.clearEgressInterface,
      ];
      final denied = operations
          .map(
            (operation) =>
                expectLater(operation(), throwsA(isA<PlatformException>())),
          )
          .toList();
      await tester.pump();
      expect(
        storageCalls,
        isEmpty,
        reason: 'writes/deletes/reads must not race legacy accessibility',
      );
      expect(preparations, 1, reason: 'concurrent callers share one migration');
      var expired = 0;
      for (final call in denied) {
        unawaited(
          call.then((_) {
            expired++;
          }),
        );
      }
      await tester.pump(const Duration(seconds: 10));
      expect(
        expired,
        18,
        reason:
            'caller timeout must release ConnectFlow even if native is stuck',
      );
      await Future.wait(denied);
      final stillWaiting = expectLater(
        SecureStore.loadContract(),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump();
      expect(
        preparations,
        1,
        reason: 'timeout must not spawn a parallel migration',
      );
      await tester.pump(const Duration(seconds: 10));
      await stillWaiting;
      expect(storageCalls, isEmpty);
      preparation.completeError(
        PlatformException(code: 'keychain_migration', details: -25308),
      );
      await tester.pump();
      expect(storageCalls, isEmpty);

      // A malformed native success also stays closed, and is not cached.
      preparation = Completer<bool>()..complete(false);
      await expectLater(
        SecureStore.loadContract(),
        throwsA(isA<PlatformException>()),
      );
      expect(storageCalls, isEmpty);
      expect(preparations, 2);

      preparation = Completer<bool>();
      final late = expectLater(
        SecureStore.loadContract(),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump(const Duration(seconds: 10));
      await late;
      expect(preparations, 3);
      preparation.complete(true);
      await tester.pump();
      expect(
        storageCalls,
        isEmpty,
        reason: 'late native success cannot revive expired CRUD',
      );
      final allowed = operations.map((operation) => operation()).toList();
      final values = await Future.wait(allowed);
      expect(values.first, 'preserved');
      expect(storageCalls.length, 18);
      // flutter_secure_storage selects options using dart:io, independently of
      // Flutter's test platform override. Inspect the Mac payload on Mac hosts;
      // the asynchronous admission checks above run on every CI platform.
      if (Platform.isMacOS) {
        for (final call in storageCalls) {
          final options = (call.arguments as Map)['options'] as Map;
          expect(options['accessibility'], 'first_unlock_this_device');
          expect(options['accountName'], 'flutter_secure_storage_service');
          expect(options['synchronizable'], 'false');
          expect(options['useDataProtectionKeyChain'], 'true');
        }
      }
      expect(await SecureStore.loadContract(), 'preserved');
      expect(preparations, 3, reason: 'only a successful migration is cached');
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
