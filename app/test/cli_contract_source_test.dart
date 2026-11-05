import 'dart:convert';
import 'dart:io';

import 'package:aurora/cli/cli_contract_source.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/server_bundle.dart';
import 'package:aurora/data/contract_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server link built the way install.sh prints it (documentation addresses only).
String _link(Map<String, dynamic> bundle) {
  final encoded = base64Url
      .encode(utf8.encode(json.encode(bundle)))
      .replaceAll('=', '');
  return 'aurora://v1/$encoded#${bundle['name']}';
}

Map<String, dynamic> _bundle({
  String name = 'tokyo',
  String host = '203.0.113.10',
}) => {
  'v': 1,
  'kind': 'vps',
  'name': name,
  'host': host,
  'reality': {
    'port': 443,
    'uuid': '00000000-0000-0000-0000-000000000001',
    'pbk': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'sid': '0123456789abcdef',
    'sni': 'www.apple.com',
  },
  'hy2': {
    'port': 443,
    'password': 'hy2-placeholder',
    'sni': 'www.bing.com',
    'spki': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  'ss': {'port': 8443, 'password': 'AAAAAAAAAAAAAAAAAAAAAA=='},
};

void main() {
  late Directory root;
  late Directory installDir;
  late Directory stateDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('aurora-cli-contract');
    installDir = Directory('${root.path}/opt')..createSync(recursive: true);
    stateDir = Directory('${root.path}/state')..createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  String contractJson({required int revision, required String updated}) {
    final raw =
        json.decode(
              File('test/fixtures/contract.sample.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    raw['revision'] = revision;
    raw['updated'] = updated;
    return json.encode(raw);
  }

  void writeEmbedded(String body) {
    final file = File(
      '${installDir.path}/data/flutter_assets/assets/configs/aurora-contract.json',
    )..createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  void writeCached(String body) {
    File('${stateDir.path}/contract.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }

  CliContractSource source({
    Future<String?> Function(DeliveryInfo)? fetch,
    CliContractVerify? verify,
  }) => CliContractSource(
    installDir: installDir,
    stateDir: stateDir,
    fetch: fetch ?? (_) async => null,
    verify: verify ?? (_, _, _) async {},
  );

  test('uses the contract embedded in the install package when it is the only one', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));

    final load = await source().load(refresh: false);

    expect(load.contract.revision, 4);
    expect(load.source, contains('embedded in the install package'));
  });

  test('uses the local cache when it is newer than the embedded contract (the control plane delivered a newer one)', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));
    writeCached(contractJson(revision: 9, updated: '2026-08-03T00:00:00Z'));

    final load = await source().load(refresh: false);

    expect(load.contract.revision, 9);
    expect(load.source, contains('local cache'));
  });

  test('uses the embedded contract when it is newer than the cache (a new package brings new nodes)', () async {
    writeEmbedded(contractJson(revision: 12, updated: '2026-08-04T00:00:00Z'));
    writeCached(contractJson(revision: 9, updated: '2026-08-03T00:00:00Z'));

    final load = await source().load(refresh: false);

    expect(load.contract.revision, 12);
  });

  test('a file given with --contract beats everything and is not refreshed', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));
    final explicit = File('${root.path}/mine.json')
      ..writeAsStringSync(
        contractJson(revision: 77, updated: '2026-01-01T00:00:00Z'),
      );
    var fetched = false;

    final load = await source(
      fetch: (_) async {
        fetched = true;
        return null;
      },
    ).load(explicitPath: explicit.path);

    expect(load.contract.revision, 77);
    expect(fetched, isFalse);
  });

  test('a refresh with a higher revision and a valid signature is used, but not written to disk before connecting', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));
    final fresh = contractJson(revision: 5, updated: '2026-08-05T00:00:00Z');

    final load = await source(fetch: (_) async => fresh).load();

    expect(load.contract.revision, 5);
    expect(load.source, contains('control plane'));
    expect(
      File('${stateDir.path}/contract.json').existsSync(),
      isFalse,
      reason: 'same rule as the GUI: promote to last-known-good only after connecting',
    );

    await load.promote!();

    expect(File('${stateDir.path}/contract.json').existsSync(), isTrue);
  });

  test('a refreshed contract that fails signature verification is never used; falls back to the local one', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));

    final load = await source(
      fetch: (_) async =>
          contractJson(revision: 5, updated: '2026-08-05T00:00:00Z'),
      verify: (_, _, _) async => throw const FormatException('bad signature'),
    ).load();

    expect(load.contract.revision, 4);
  });

  test('a refresh with an older revision is not used (rollback guard)', () async {
    writeEmbedded(contractJson(revision: 9, updated: '2026-08-03T00:00:00Z'));

    final load = await source(
      fetch: (_) async =>
          contractJson(revision: 2, updated: '2026-08-05T00:00:00Z'),
    ).load();

    expect(load.contract.revision, 9);
  });

  test('the first signed revision cannot replace a legacy contract with a newer timestamp', () async {
    writeEmbedded(contractJson(revision: 0, updated: '2026-08-03T00:00:00Z'));

    final load = await source(
      fetch: (_) async =>
          contractJson(revision: 1, updated: '2026-08-01T00:00:00Z'),
    ).load();

    expect(load.contract.revision, 0);
    expect(load.promote, isNull);
  });

  for (final rejectedReason in ['failed signature verification', 'a valid signature on an older revision']) {
    test('default delivery keeps using a valid fallback source when the primary has $rejectedReason', () async {
      final embedded =
          json.decode(
                contractJson(revision: 42, updated: '2026-08-01T00:00:00Z'),
              )
              as Map<String, dynamic>;
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = base64.encode((await keyPair.extractPublicKey()).bytes);
      embedded['delivery'] = {
        'primary': 'https://primary.example/v2/contract',
        'fallbacks': ['https://fallback.example/v2/contract'],
        'signing': {'key_id': 'aurora-key-1', 'public_key': publicKey},
      };
      writeEmbedded(json.encode(embedded));
      Future<String> signed(int revision) async {
        final raw = Map<String, dynamic>.from(embedded);
        raw['revision'] = revision;
        raw['issued_at'] = DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String();
        raw['expires_at'] = DateTime.now()
            .add(const Duration(days: 1))
            .toUtc()
            .toIso8601String();
        final signature = await algorithm.sign(
          utf8.encode(ContractVerifier.canonicalJson(raw)),
          keyPair: keyPair,
        );
        raw['signature'] = {
          'algorithm': 'ed25519',
          'key_id': 'aurora-key-1',
          'value': base64.encode(signature.bytes),
        };
        return json.encode(raw);
      }

      final good = await signed(43);
      final rejected = rejectedReason == 'a valid signature on an older revision'
          ? await signed(41)
          : good.replaceFirst('"revision":43', '"revision":44');
      final client = MockClient((request) async {
        if (request.url.host == 'primary.example') {
          return http.Response(rejected, 200);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(good, 200);
      });
      final loader = CliContractSource(
        installDir: installDir,
        stateDir: stateDir,
        clientVersion: '0.1.3',
        verify: (body, version, _) => ContractVerifier.verifyRemote(
          body,
          clientVersion: version,
          publicKey: publicKey,
        ),
      );

      final load = await http.runWithClient(loader.load, () => client);

      expect(load.contract.revision, 43);
      expect(File('${stateDir.path}/contract.json').existsSync(), isFalse);
      await load.promote!();
      expect(File('${stateDir.path}/contract.json').readAsStringSync(), good);
    });
  }

  test('a refresh that fails entirely (offline) does not affect connecting', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));

    final load = await source(
      fetch: (_) async => throw const SocketException('no route to host'),
    ).load();

    expect(load.contract.revision, 4);
  });

  test('--no-refresh sends no network request at all', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));
    var fetched = false;

    await source(
      fetch: (_) async {
        fetched = true;
        return null;
      },
    ).load(refresh: false);

    expect(fetched, isFalse);
  });

  test('a corrupt cache file is ignored and the embedded contract is used', () async {
    writeEmbedded(contractJson(revision: 4, updated: '2026-08-01T00:00:00Z'));
    writeCached('{ not json');

    final load = await source().load(refresh: false);

    expect(load.contract.revision, 4);
  });

  test('with no contract anywhere, the error says how to add a server', () async {
    await expectLater(
      source().load(refresh: false),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          allOf(contains('No server has been added'), contains('aurora import')),
        ),
      ),
    );
  });

  group('server management', () {
    File cacheFile() => File('${stateDir.path}/contract.json');

    Map<String, dynamic> cachedRaw() =>
        json.decode(cacheFile().readAsStringSync()) as Map<String, dynamic>;

    test('importText writes the cache and listServers reports the server', () {
      final src = source();

      final added = src.importText(_link(_bundle()));

      expect(added, ['tokyo']);
      expect(cacheFile().existsSync(), isTrue);
      final servers = src.listServers();
      expect(servers.map((s) => s.group), ['tokyo']);
      expect(servers.single.host, '203.0.113.10');
      expect(servers.single.nodeCount, greaterThan(0));
    });

    test('the cache written by importText loads back as a contract', () async {
      final src = source();
      src.importText(_link(_bundle()));

      final load = await src.load(refresh: false);

      expect(load.source, 'local cache');
      expect(load.contract.routeFamilies, contains('tokyo'));
    });

    test('importing a second server merges it with the first', () {
      final src = source();
      src.importText(_link(_bundle()));

      final added = src.importText(
        _link(_bundle(name: 'london', host: '198.51.100.20')),
      );

      expect(added, ['london']);
      expect(src.listServers().map((s) => s.group), ['tokyo', 'london']);
    });

    test('importing the same server twice does not duplicate it', () {
      final src = source();
      src.importText(_link(_bundle()));
      src.importText(_link(_bundle()));

      expect(src.listServers().map((s) => s.group), ['tokyo']);
    });

    test('listServers is empty before anything is imported', () {
      expect(source().listServers(), isEmpty);
    });

    test('removeServer drops one server and keeps the rest', () {
      final src = source();
      src.importText(_link(_bundle()));
      src.importText(_link(_bundle(name: 'london', host: '198.51.100.20')));

      expect(src.removeServer('tokyo'), isTrue);

      expect(src.listServers().map((s) => s.group), ['london']);
      expect(cacheFile().existsSync(), isTrue);
    });

    test('removing the last server deletes the cache file', () {
      final src = source();
      src.importText(_link(_bundle()));

      expect(src.removeServer('tokyo'), isTrue);

      expect(cacheFile().existsSync(), isFalse);
      expect(src.listServers(), isEmpty);
    });

    test('removeServer returns false for an unknown name and changes nothing', () {
      final src = source();
      src.importText(_link(_bundle()));
      final before = cacheFile().readAsStringSync();

      expect(src.removeServer('nowhere'), isFalse);

      expect(cacheFile().readAsStringSync(), before);
    });

    test('removeServer returns false when there is no contract at all', () {
      expect(source().removeServer('tokyo'), isFalse);
    });

    test('importing garbage throws AuroraLinkException and leaves the cache untouched', () {
      final src = source();
      src.importText(_link(_bundle()));
      final before = cacheFile().readAsStringSync();

      expect(
        () => src.importText('this is not a link'),
        throwsA(isA<AuroraLinkException>()),
      );

      expect(cacheFile().readAsStringSync(), before);
      expect(cachedRaw()['nodes'], isNotEmpty);
    });

    test('importing garbage with no cache does not create one', () {
      expect(
        () => source().importText('aurora://v1/!!!not-base64!!!'),
        throwsA(isA<AuroraLinkException>()),
      );

      expect(cacheFile().existsSync(), isFalse);
    });
  });
}
