import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/contract.dart';
import 'package:aurora/data/contract_repository.dart';
import 'package:aurora/data/secure_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

// A well-formed key nobody holds the private half of: nothing can verify against it.
const _pinnedKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String embedded;

  setUp(() {
    final raw =
        json.decode(
              File('test/fixtures/contract.sample.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    raw['revision'] = 42;
    raw['delivery'] = {
      'primary': 'https://trusted.example/v2/contract',
      'fallbacks': ['https://fallback.example/v2/contract'],
      'token': 'test-read-token',
      'signing': {'key_id': 'test-key', 'public_key': _pinnedKey},
    };
    embedded = json.encode(raw);
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Aurora',
      packageName: 'com.aurora.vpn',
      version: '0.1.3',
      buildNumber: '1',
      buildSignature: '',
    );
    rootBundle.evict('assets/configs/aurora-contract.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          if (utf8.decode(message!.buffer.asUint8List()) ==
              'assets/configs/aurora-contract.json') {
            return ByteData.sublistView(
              Uint8List.fromList(utf8.encode(embedded)),
            );
          }
          return null;
        });
    ContractRepository.discardPending();
  });

  tearDown(() {
    ContractRepository.discardPending();
    rootBundle.evict('assets/configs/aurora-contract.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  test(
    'refresh sends the current read token to its remembered trusted URL',
    () async {
      await ContractRepository.load();
      Uri? requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response('unauthorized', 401);
      });

      await expectLater(
        http.runWithClient(ContractRepository.refresh, () => client),
        throwsA(isA<String>()),
      );

      expect(requested!.queryParameters['token'], 'test-read-token');
      expect(await SecureStore.loadContract(), embedded);
    },
  );

  test('an unsigned primary cannot prevent checking the fallback', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.host);
      return http.Response(
        embedded.replaceFirst('"revision":42', '"revision":43'),
        200,
      );
    });

    final loaded = await http.runWithClient(
      ContractRepository.loadWithRefresh,
      () => client,
    );
    expect(requests, contains('fallback.example'));
    expect(loaded.revision, 42);
    await ContractRepository.promotePending();
    expect(await SecureStore.loadContract(), embedded);
  });

  test('refresh does not expose credentials from a malformed body', () async {
    await ContractRepository.load();
    final client = MockClient(
      (_) async =>
          http.Response('{"token":"test-response-secret", invalid', 200),
    );
    await expectLater(
      http.runWithClient(ContractRepository.refresh, () => client),
      throwsA(predicate((error) => !'$error'.contains('test-response-secret'))),
    );
    expect(await SecureStore.loadContract(), embedded);
  });

  test('refresh does not expose a token-bearing transport error', () async {
    await ContractRepository.load();
    final client = MockClient((request) async {
      throw http.ClientException(
        'request failed with test-read-token',
        request.url,
      );
    });

    await expectLater(
      http.runWithClient(ContractRepository.refresh, () => client),
      throwsA(predicate((error) => !'$error'.contains('test-read-token'))),
    );
  });

  group('without a pinned signing key', () {
    setUp(() {
      final raw = json.decode(embedded) as Map<String, dynamic>;
      (raw['delivery'] as Map).remove('signing');
      embedded = json.encode(raw);
    });

    test('connecting never touches the network', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      final loaded = await http.runWithClient(
        ContractRepository.loadWithRefresh,
        () => client,
      );
      expect(requests, 0);
      expect(loaded.revision, 42);
    });

    test('a manual refresh explains why it cannot run', () async {
      await expectLater(
        ContractRepository.refresh(),
        throwsA(predicate((error) => '$error'.contains('no control plane'))),
      );
    });
  });

  group('a public build with no embedded contract', () {
    setUp(() {
      rootBundle.evict('assets/configs/aurora-contract.json');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (_) async => null);
    });

    String link(String name, {String kind = 'vps'}) {
      final encoded = base64Url
          .encode(
            utf8.encode(
              json.encode({
                'v': 1,
                'kind': kind,
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
                  'spki': _pinnedKey,
                },
                'ss': {'port': 8443, 'password': 'AAAAAAAAAAAAAAAAAAAAAA=='},
              }),
            ),
          )
          .replaceAll('=', '');
      return 'aurora://v1/$encoded#$name';
    }

    test('starts in the first-run state rather than failing', () async {
      await expectLater(
        ContractRepository.load(),
        throwsA(isA<NoContractException>()),
      );
      expect(await ContractRepository.listServers(), isEmpty);
    });

    test('adding servers merges them and notifies listeners', () async {
      var notified = 0;
      void listener() => notified++;
      ContractRepository.changes.addListener(listener);
      addTearDown(() => ContractRepository.changes.removeListener(listener));

      expect(await ContractRepository.importText(link('tokyo')), ['tokyo']);
      expect(await ContractRepository.importText(link('house', kind: 'home')), [
        'house',
      ]);

      final contract = await ContractRepository.load();
      expect(contract.nodes, hasLength(6));
      expect(
        (await ContractRepository.listServers()).map((s) => s.group),
        unorderedEquals(['tokyo', 'house']),
      );
      expect(notified, 2);
    });

    test('removing the last server returns to the first-run state', () async {
      await ContractRepository.importText(link('tokyo'));
      await ContractRepository.removeServer('tokyo');
      await expectLater(
        ContractRepository.load(),
        throwsA(isA<NoContractException>()),
      );
    });

    test('a corrupt stored contract returns to first run, not a dead app', () async {
      await SecureStore.saveContract('{"not":"a contract"}');
      await expectLater(
        ContractRepository.load(),
        throwsA(isA<NoContractException>()),
      );
    });

    test('bad input leaves the stored contract untouched', () async {
      await ContractRepository.importText(link('tokyo'));
      final before = await SecureStore.loadContract();
      await expectLater(
        ContractRepository.importText('aurora://v1/damaged!!'),
        throwsA(anything),
      );
      expect(await SecureStore.loadContract(), before);
    });

    test('reset forgets every server', () async {
      await ContractRepository.importText(link('tokyo'));
      await ContractRepository.reset();
      await expectLater(
        ContractRepository.load(),
        throwsA(isA<NoContractException>()),
      );
    });
  });

  AuroraContract contract(int revision, String updated) => AuroraContract(
    version: 1,
    revision: revision,
    updated: updated,
    defaultMode: 'global',
    nodes: const [],
    outboundGroup: OutboundGroup(
      selectorTag: 'proxy',
      selectorMembers: const [],
      selectorDefault: 'auto',
      urltestTag: 'auto',
      urltestMembers: const [],
      urltestUrl: '',
      urltestInterval: '',
    ),
  );

  test('positive revision must strictly increase', () {
    final current = contract(42, '2026-07-19T00:00:00Z');
    expect(
      ContractRepository.isUpgrade(
        current,
        contract(43, '2026-07-19T00:00:01Z'),
      ),
      isTrue,
    );
    expect(ContractRepository.isUpgrade(current, contract(42, '')), isFalse);
    expect(ContractRepository.isUpgrade(current, contract(41, '')), isFalse);
  });

  test('first signed revision must be newer than a dated legacy LKG', () {
    final legacy = contract(0, '2026-07-19T00:00:00Z');
    expect(
      ContractRepository.isUpgrade(legacy, contract(1, '2026-07-19T00:00:01Z')),
      isTrue,
    );
    expect(
      ContractRepository.isUpgrade(legacy, contract(1, '2026-07-18T00:00:00Z')),
      isFalse,
    );
  });
}
