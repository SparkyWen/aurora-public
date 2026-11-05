import 'dart:convert';

import 'package:aurora/core/server_bundle.dart';
import 'package:aurora/data/contract_repository.dart';
import 'package:aurora/data/secure_store.dart';
import 'package:aurora/features/connect/connect_page.dart';
import 'package:aurora/features/servers/add_server_page.dart';
import 'package:aurora/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

String _link(String name) {
  final encoded = base64Url
      .encode(
        utf8.encode(
          json.encode({
            'v': 1,
            'kind': 'vps',
            'name': name,
            'host': '203.0.113.10',
            'reality': {
              'port': 443,
              'uuid': '00000000-0000-0000-0000-000000000001',
              'pbk': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              'sid': '0123456789abcdef',
              'sni': 'www.apple.com',
            },
            'hy2': {
              'port': 443,
              'password': 'placeholder',
              'sni': 'www.bing.com',
              'spki': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            },
            'ss': {'port': 8443, 'password': 'AAAAAAAAAAAAAAAAAAAAAA=='},
          }),
        ),
      )
      .replaceAll('=', '');
  return 'aurora://v1/$encoded#$name';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    rootBundle.evict('assets/configs/aurora-contract.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          // The embedded contract is absent in a public build. Everything else
          // resolves to an empty asset so MaterialApp's font lookups still work.
          final key = utf8.decode(message!.buffer.asUint8List());
          if (key == 'assets/configs/aurora-contract.json') return null;
          if (key == 'AssetManifest.bin' || key == 'AssetManifest.smcbin') {
            return const StandardMessageCodec().encodeMessage(<String, Object>{});
          }
          return ByteData(0);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  Future<void> pumpPage(WidgetTester tester, {String? route}) async {
    await tester.pumpWidget(
      MaterialApp(home: AddServerPage(deepLinkRoute: route)),
    );
    await tester.pump();
  }

  String routeOf(String link) =>
      '/${link.substring('aurora://v1/'.length)}';

  testWidgets('the page tells a new user the command to run', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('install.sh'), findsOneWidget);
    expect(auroraInstallCommand, startsWith('curl -fsSL https://'));
    expect(auroraInstallCommand, endsWith('| sudo bash'));
  });

  testWidgets('a deep link asks first and imports nothing on its own', (
    tester,
  ) async {
    await pumpPage(tester, route: routeOf(_link('tokyo')));

    expect(find.text('Add this server?'), findsOneWidget);
    expect(find.byKey(const Key('pending-server')), findsOneWidget);
    expect(find.textContaining('tokyo (203.0.113.10)'), findsOneWidget);
    // Nothing is stored until the user confirms: a link on a web page must not be
    // able to reconfigure the VPN by itself.
    expect(await SecureStore.loadContract(), isNull);
  });

  testWidgets('cancelling a deep link adds nothing', (tester) async {
    await pumpPage(tester, route: routeOf(_link('tokyo')));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Add this server?'), findsNothing);
    expect(await SecureStore.loadContract(), isNull);
  });

  testWidgets('a malformed deep link explains itself instead of crashing', (
    tester,
  ) async {
    await pumpPage(tester, route: '/definitely!not!a!link');

    expect(find.text('Add this server?'), findsNothing);
    expect(find.byKey(const Key('add-server-error')), findsOneWidget);
  });

  testWidgets('pasting a bad link shows the problem and stores nothing', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.enterText(
      find.byKey(const Key('server-link-field')),
      'not a link',
    );
    await tester.ensureVisible(find.byKey(const Key('add-server-button')));
    await tester.tap(find.byKey(const Key('add-server-button')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.byKey(const Key('add-server-error')), findsOneWidget);
    expect(await SecureStore.loadContract(), isNull);
  });

  test('importing through the repository is what the page does on success', () async {
    await ContractRepository.importText(_link('tokyo'));
    final stored = json.decode((await SecureStore.loadContract())!) as Map;
    expect((stored['nodes'] as List).length, 3);
  });

  testWidgets('the app routes a pushed deep link to the confirmation page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const AuroraApp());
    await tester.pump();

    // Exactly what the engine sends for a scanned `aurora://` QR code.
    await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/navigation',
          const JSONMethodCodec().encodeMethodCall(
            MethodCall('pushRouteInformation', {
              'location': routeOf(_link('tokyo')),
              'state': null,
            }),
          ),
          null,
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Add this server?'), findsOneWidget);
    expect(await SecureStore.loadContract(), isNull);
  });

  // Scanning a QR code usually starts the app. The link then arrives as the initial route,
  // whole and with nothing underneath it, which a pushed route never shows.
  testWidgets('a deep link that starts the app can be confirmed and leads home', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.defaultRouteNameTestValue = _link('tokyo');
    addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);

    await tester.pumpWidget(const AuroraApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Add this server?'), findsOneWidget);
    expect(find.textContaining('damaged'), findsNothing);
    expect(await SecureStore.loadContract(), isNull);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Add server').first);
      await tester.pump();
      for (var i = 0; i < 20 && await SecureStore.loadContract() == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(await SecureStore.loadContract(), isNotNull);
    expect(find.byType(ConnectPage), findsOneWidget);
    expect(find.text('Add this server?'), findsNothing);
  });

  test('both shapes of a delivered route are the same link', () {
    final link = _link('tokyo');
    final bare = link.split('#').first;
    expect(AuroraLink.linkFromRoute(link), bare);
    expect(AuroraLink.linkFromRoute(routeOf(link)), bare);
    expect(AuroraLink.parseRoute(link), isA<ServerBundle>());
    expect(AuroraLink.parseRoute(routeOf(link)), isA<ServerBundle>());
  });
}
