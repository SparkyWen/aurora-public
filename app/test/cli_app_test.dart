import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/cli/cli_app.dart';
import 'package:aurora/cli/cli_contract_source.dart';
import 'package:aurora/cli/cli_options.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/contract.dart';
import 'package:flutter_test/flutter_test.dart';

/// An `aurora://` link as install.sh prints it (documentation addresses only).
String _link(String name, String host) {
  final bundle = {
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
  final encoded = base64Url
      .encode(utf8.encode(json.encode(bundle)))
      .replaceAll('=', '');
  return 'aurora://v1/$encoded#$name';
}

/// A real flat contract (it passes the compiler's validation) with route family
/// labels added: the same set of exit nodes, where `via` says how traffic reaches
/// the home node.
AuroraContract familyContract({List<String> vias = const ['direct', 'relay', 'cdn']}) {
  final raw =
      json.decode(File('test/fixtures/contract.sample.json').readAsStringSync())
          as Map<String, dynamic>;
  final nodes = (raw['nodes'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < nodes.length; i++) {
    nodes[i]['via'] = vias[i % vias.length];
  }
  return AuroraContract.fromJson(raw);
}

class _FakeBridge implements AuroraBridge {
  _FakeBridge({this.statuses = const [AuroraStatus.connected]});

  /// The statuses returned in order. The last one is repeated forever.
  final List<AuroraStatus> statuses;
  int _reads = 0;

  bool installed = true;
  bool statusThrows = false;
  String? startedConfig;
  bool stopped = false;
  final selections = <(String, String)>[];
  Object? startError;

  @override
  Future<bool> prepare() async => installed;

  @override
  Future<void> start(String configJson) async {
    if (startError != null) throw startError!;
    startedConfig = configJson;
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<AuroraStatus> status() async {
    if (statusThrows) throw const SocketException('connection refused');
    final index = _reads < statuses.length ? _reads : statuses.length - 1;
    _reads++;
    return statuses[index];
  }

  @override
  Future<void> selectOutbound(String group, String tag) async =>
      selections.add((group, tag));

  @override
  Stream<AuroraStatus> statusStream() => const Stream<AuroraStatus>.empty();

  @override
  Stream<String> logStream() => const Stream<String>.empty();

  @override
  Future<TrafficStat> queryStats() async => const TrafficStat();

  @override
  Stream<TrafficStat> statsStream() => const Stream<TrafficStat>.empty();

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() =>
      const Stream<List<OutboundGroupInfo>>.empty();

  @override
  Future<void> urlTest(String group) async {}

  @override
  Future<void> openVpnSettings() async {}
}

void main() {
  _pathContractLines();

  late List<String> printed;

  AuroraCliApp app(
    _FakeBridge bridge, {
    AuroraContract? contract,
    String source = 'test contract',
    CliContractSource? contractSource,
  }) {
    printed = [];
    return AuroraCliApp(
      bridge: bridge,
      loadContract: () async =>
          CliContractLoad(contract ?? familyContract(), source),
      out: printed.add,
      pollInterval: Duration.zero,
      contractSource: contractSource,
    );
  }

  String output() => printed.join('\n');

  group('connect', () {
    test('by default connects in global mode on the relay family: compiles a global config and points the selector at via-relay', () async {
      final bridge = _FakeBridge();

      final code = await app(bridge).run(parseAuroraCliArgs(const []));

      expect(code, 0);
      // Without this push, a flat contract's selector stays on the cross-family
      // auto (the lowest-latency node may be direct or CDN), and a three-path
      // contract stays on the fail-closed block-all. Neither is the relay route
      // the default promises.
      expect(bridge.selections, [('proxy', 'via-relay')]);

      final config =
          json.decode(bridge.startedConfig!) as Map<String, dynamic>;
      final rules = (config['route'] as Map)['rules'] as List;
      // Global mode does not depend on the geosite rule sets (the command line
      // cannot unpack the .srs files from Flutter assets).
      expect(json.encode(rules), isNot(contains('geosite-cn')));
      expect(output(), contains('Relay'));
      expect(output(), contains('Contract: test contract'));
    });

    test('--line auto really uses automatic selection and names no family', () async {
      final bridge = _FakeBridge();

      final code = await app(bridge).run(parseAuroraCliArgs(const ['--line=auto']));

      expect(code, 0);
      expect(bridge.selections, [('proxy', 'auto')]);
    });

    test('--line naming a family the contract lacks is refused instead of connecting elsewhere', () async {
      final bridge = _FakeBridge();

      final code = await app(bridge).run(parseAuroraCliArgs(const ['--line=jp']));

      expect(code, 2);
      expect(bridge.startedConfig, isNull, reason: 'must not start the tunnel');
      expect(output(), contains('jp'));
      expect(output(), contains('Available'));
    });

    test('a contract with no relay still connects, via automatic selection with no warning', () async {
      final bridge = _FakeBridge();
      final noRelay = familyContract(vias: const ['direct']);

      final code = await app(bridge, contract: noRelay).run(
        parseAuroraCliArgs(const []),
      );

      expect(code, 0);
      expect(output(), contains('automatic selection'));
      expect(output(), isNot(contains('Note:')));
      expect(bridge.selections, [('proxy', 'auto')]);
    });

    test('a tunnel that never comes up exits non-zero', () async {
      final bridge = _FakeBridge(statuses: const [AuroraStatus.error]);

      final code = await app(bridge).run(
        parseAuroraCliArgs(const ['--timeout=1']),
      );

      expect(code, isNot(0));
      expect(bridge.selections, isEmpty, reason: 'must not push a route selection when not connected');
    });

    test('a start refused by the service prints the reason as is', () async {
      final bridge = _FakeBridge()
        ..startError = StateError(
          'aurora-svc start failed (500): config rejected by sing-box',
        );

      final code = await app(bridge).run(parseAuroraCliArgs(const []));

      expect(code, isNot(0));
      expect(output(), contains('config rejected by sing-box'));
    });
  });

  test('disconnect stops the tunnel', () async {
    final bridge = _FakeBridge();

    final code = await app(bridge).run(parseAuroraCliArgs(const ['disconnect']));

    expect(code, 0);
    expect(bridge.stopped, isTrue);
  });

  test('status --json prints machine-readable state', () async {
    final bridge = _FakeBridge();

    final code = await app(bridge).run(
      parseAuroraCliArgs(const ['status', '--json']),
    );

    expect(code, 0);
    expect(json.decode(output())['state'], 'connected');
  });

  test('a usage error prints the reason, exits with code 2 and leaves the tunnel alone', () async {
    final bridge = _FakeBridge();

    final code = await app(bridge).run(parseAuroraCliArgs(const ['--wat']));

    expect(code, 2);
    expect(output(), contains('--wat'));
    expect(bridge.startedConfig, isNull);
  });

  test('when the service is not running, says what to do instead of a raw connection error', () async {
    final bridge = _FakeBridge()..installed = false;

    final code = await app(bridge).run(parseAuroraCliArgs(const []));

    expect(code, isNot(0));
    expect(bridge.startedConfig, isNull);
    expect(output(), contains('aurora-svc'));
    expect(output(), contains('systemctl'));
  });

  test('status also explains an unreachable service in plain words', () async {
    final bridge = _FakeBridge()..statusThrows = true;

    final code = await app(bridge).run(parseAuroraCliArgs(const ['status']));

    expect(code, isNot(0));
    expect(output(), contains('aurora-svc'));
  });

  test('help prints usage and exits normally', () async {
    final bridge = _FakeBridge();

    final code = await app(bridge).run(parseAuroraCliArgs(const ['help']));

    expect(code, 0);
    expect(output(), contains('aurora'));
    expect(output(), contains('aurora import'));
  });

  test('version prints the installed version', () async {
    printed = [];
    final cli = AuroraCliApp(
      bridge: _FakeBridge(),
      loadContract: () async => CliContractLoad(familyContract(), 'test contract'),
      out: printed.add,
      version: '1.2.3',
    );

    final code = await cli.run(parseAuroraCliArgs(const ['version']));

    expect(code, 0);
    expect(output(), 'aurora 1.2.3');
  });

  group('server management verbs', () {
    late Directory root;
    late CliContractSource source;

    setUp(() {
      root = Directory.systemTemp.createTempSync('aurora-cli-app');
      source = CliContractSource(
        installDir: Directory('${root.path}/opt'),
        stateDir: Directory('${root.path}/state'),
        fetch: (_) async => null,
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    Future<int> run(List<String> args) => app(
      _FakeBridge(),
      contractSource: source,
    ).run(parseAuroraCliArgs(args));

    test('import adds a server, then servers lists it', () async {
      expect(await run(['import', _link('tokyo', '203.0.113.10')]), 0);
      expect(output(), contains('Added: tokyo'));
      expect(output(), contains('aurora connect'));

      expect(await run(['servers']), 0);
      expect(output(), contains('tokyo'));
      expect(output(), contains('203.0.113.10'));
    });

    test('servers with nothing imported says how to add one', () async {
      expect(await run(['servers']), 0);
      expect(output(), contains('No servers yet'));
      expect(output(), contains('aurora import'));
    });

    test('remove deletes a server', () async {
      await run(['import', _link('tokyo', '203.0.113.10')]);

      expect(await run(['remove', 'tokyo']), 0);
      expect(output(), contains('Removed tokyo.'));

      expect(await run(['servers']), 0);
      expect(output(), contains('No servers yet'));
    });

    test('remove of an unknown name is a usage error', () async {
      expect(await run(['remove', 'nowhere']), 2);
      expect(output(), contains('No server named "nowhere"'));
    });

    test('import of garbage is a usage error and adds nothing', () async {
      expect(await run(['import', 'not a link']), 2);
      expect(output(), contains('Could not add that'));

      expect(await run(['servers']), 0);
      expect(output(), contains('No servers yet'));
    });

    test('import without a link is a usage error', () async {
      expect(await run(['import']), 2);
      expect(output(), contains('import needs a link'));
    });

    test('remove without a name is a usage error', () async {
      expect(await run(['remove']), 2);
      expect(output(), contains('remove needs a server name'));
    });

    test('an import link is not parsed as options', () {
      final options = parseAuroraCliArgs(const ['import', 'aurora://v1/abc--x#t']);

      expect(options.error, isNull);
      expect(options.verb, AuroraCliVerb.import);
      expect(options.arguments, ['aurora://v1/abc--x#t']);
    });
  });

  test('server verbs without a contract source report that they are unavailable', () async {
    for (final args in [
      ['servers'],
      ['import', 'aurora://v1/x'],
      ['remove', 'tokyo'],
    ]) {
      final code = await app(_FakeBridge()).run(parseAuroraCliArgs(args));

      expect(code, 1, reason: args.first);
      expect(output(), contains('not available'));
    }
  });
}

/// `--line` resolution under a three-path contract. In such a contract the relay is
/// called relay_public / relay_tailnet, and users should not have to remember those
/// ids.
void _pathContractLines() {
  AuroraContract pathContract() => AuroraContract.fromJson(
    json.decode(File('test/fixtures/path-contract.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  group('route resolution for a three-path contract', () {
    test('--line relay lands on the preferred relay path, not whichever comes first in items', () {
      final target = resolveCliRouteTarget('relay', pathContract())!;

      expect(target.groupTag, 'relay-public-auto');
      expect(target.isPreferred, isTrue);
    });

    test('--line can name a specific path', () {
      expect(
        resolveCliRouteTarget('home', pathContract())!.groupTag,
        'home-auto',
      );
    });

    test('--line auto in such a contract means the preferred path, not the urltest auto', () {
      // The selector members of such a contract are only the path groups plus
      // fail-closed; there is no `auto` tag at all, so pushing it would always fail.
      final target = resolveCliRouteTarget('auto', pathContract())!;

      expect(target.groupTag, 'relay-public-auto');
    });

    test('a path that does not exist is still null', () {
      expect(resolveCliRouteTarget('jp', pathContract()), isNull);
    });
  });
}
