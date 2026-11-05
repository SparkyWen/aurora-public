import 'dart:convert';
import 'dart:io' show gzip;

import 'package:aurora/cli/cli_app.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/contract_editor.dart';
import 'package:aurora/core/route_family.dart';
import 'package:aurora/core/server_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

const _spki = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
final _clock = DateTime.utc(2026, 11, 5, 12);

Map<String, dynamic> _bundle({
  String kind = 'vps',
  String name = 'tokyo',
  String host = '203.0.113.10',
  Map<String, dynamic>? exit,
  Map<String, dynamic>? cdn,
}) => {
  'v': 1,
  'kind': kind,
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
    'spki': _spki,
  },
  'ss': {'port': 8443, 'password': 'AAAAAAAAAAAAAAAAAAAAAA=='},
  'exit': ?exit,
  'cdn': ?cdn,
};

String _link(Map<String, dynamic> bundle) {
  final encoded = base64Url
      .encode(utf8.encode(json.encode(bundle)))
      .replaceAll('=', '');
  return 'aurora://v1/$encoded#${bundle['name']}';
}

const _homeExit = {
  'name': 'house',
  'host': 'home.example.net',
  'port': 2053,
  'password': 'BBBBBBBBBBBBBBBBBBBBBB==',
};

AuroraContract _contract(String contractJson) =>
    AuroraContract.fromJson(json.decode(contractJson) as Map<String, dynamic>);

String _plan(String? current, String text) =>
    ContractEditor.plan(current, text, now: _clock).contractJson!;

void main() {
  group('AuroraLink.parse', () {
    test('reads the gzip-compressed form that install.sh prints', () {
      final bundle = _bundle();
      final encoded = base64Url
          .encode(gzip.encode(utf8.encode(json.encode(bundle))))
          .replaceAll('=', '');
      final parsed = AuroraLink.parse('aurora://v1/$encoded#tokyo');
      expect((parsed as ServerBundle).name, bundle['name']);
    });

    test('refuses a link no real server could produce', () {
      expect(
        () => AuroraLink.parse('aurora://v1/${'A' * 5000}'),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('calls damaged gzip damaged', () {
      final bytes = gzip.encode(utf8.encode('{"v":1}')).sublist(0, 12);
      final encoded = base64Url.encode(bytes).replaceAll('=', '');
      expect(
        () => AuroraLink.parse('aurora://v1/$encoded'),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('reads a link as install.sh writes it', () {
      final link = AuroraLink.parse(_link(_bundle())) as ServerBundle;
      expect(link.name, 'tokyo');
      expect(link.host, '203.0.113.10');
      expect(link.isRelay, isFalse);
    });

    test('tolerates surrounding whitespace from a terminal copy', () {
      expect(AuroraLink.parse('  ${_link(_bundle())}\n'), isA<ServerBundle>());
    });

    test('a deep link route decodes to the same server', () {
      final link = _link(_bundle());
      final route = '/${link.substring(auroraLinkPrefix.length)}';
      expect(
        (AuroraLink.parseRoute(route) as ServerBundle).name,
        (AuroraLink.parse(link) as ServerBundle).name,
      );
    });

    test('refuses anything that is not ours', () {
      expect(
        () => AuroraLink.parse('https://example.com'),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('refuses a truncated link', () {
      final link = _link(_bundle());
      expect(
        () => AuroraLink.parse(link.substring(0, 40)),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('asks for an upgrade on a future link version', () {
      expect(
        () => AuroraLink.parse(_link({..._bundle(), 'v': 2})),
        throwsA(
          isA<AuroraLinkException>().having(
            (e) => e.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });

    test('rejects a bad name, host or port', () {
      for (final bad in [
        _bundle(name: 'Has Spaces'),
        _bundle(host: 'not a host'),
        {
          ..._bundle(),
          'ss': {'port': 70000, 'password': 'x'},
        },
      ]) {
        expect(
          () => AuroraLink.parse(_link(bad)),
          throwsA(isA<AuroraLinkException>()),
        );
      }
    });

    test('error messages never quote credentials', () {
      final broken = {
        ..._bundle(),
        'hy2': {'port': 443, 'password': 'super-secret-value'},
      };
      try {
        AuroraLink.parse(_link(broken));
        fail('expected a failure');
      } on AuroraLinkException catch (error) {
        expect(error.message, isNot(contains('super-secret-value')));
      }
    });

    test('a delivery link must use https', () {
      expect(
        () => AuroraLink.parse(
          _link({
            'v': 1,
            'kind': 'delivery',
            'name': 'cp',
            'url': 'http://cp.example.com/v2/contract',
            'token': 't',
            'key_id': 'k',
            'public_key': 'p',
          }),
        ),
        throwsA(isA<AuroraLinkException>()),
      );
    });
  });

  group('expansion into contract nodes', () {
    test('an exit server becomes three selectable exits in its own family', () {
      final contract = _contract(_plan(null, _link(_bundle())));
      expect(contract.nodes.map((n) => n.id), [
        'tokyo-reality',
        'tokyo-hy2',
        'tokyo-ss',
      ]);
      expect(contract.nodes.every((n) => n.role != 'entry'), isTrue);
      expect(contract.nodesByFamily.keys, ['tokyo']);
      expect(contract.outboundGroup.urltestMembers, hasLength(3));
    });

    test('hysteria2 pins the certificate and never disables validation', () {
      final contract = _contract(_plan(null, _link(_bundle())));
      final hy2 = contract.nodes.firstWhere((n) => n.protocol == 'hysteria2');
      expect(hy2.params['certificate_public_key_sha256'], _spki);
      expect(hy2.params['insecure'], isNull);
    });

    test('hysteria2 only hops the source port on the verified port', () {
      final contract = _contract(_plan(null, _link(_bundle())));
      final hy2 = contract.nodes.firstWhere((n) => n.protocol == 'hysteria2');
      expect(hy2.params['server_ports'], ['443:443']);
      expect(hy2.params['hop_interval'], '10s');
    });

    test('a relay entry is never selectable, only its chained exits are', () {
      final contract = _contract(
        _plan(null, _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit))),
      );
      final entries = contract.nodes.where((n) => n.role == 'entry');
      final exits = contract.nodes.where((n) => n.role != 'entry');
      expect(entries.map((n) => n.id), [
        'edge-entry-reality',
        'edge-entry-hy2',
        'edge-entry-ss',
      ]);
      for (final exit in exits) {
        expect(exit.server, 'home.example.net');
        expect(exit.port, 2053);
        expect(exit.detour, startsWith('edge-entry-'));
        expect(exit.protocol, 'shadowsocks-2022');
      }
      expect(
        contract.outboundGroup.selectorMembers.where(
          (member) => member.contains('-entry-'),
        ),
        isEmpty,
      );
    });

    test('a CDN entry is added when present', () {
      final contract = _contract(
        _plan(
          null,
          _link(
            _bundle(
              cdn: {
                'host': 'cdn.example.com',
                'port': 2083,
                'uuid': '00000000-0000-0000-0000-000000000002',
                'path': '/abc',
              },
            ),
          ),
        ),
      );
      final cdn = contract.nodes.firstWhere((n) => n.id == 'tokyo-cdn');
      expect(cdn.protocol, 'vless-ws-tls');
      expect(cdn.server, 'cdn.example.com');
    });

    test('shadowsocks never carries multiplex through to the compiled config', () {
      final contract = _contract(_plan(null, _link(_bundle())));
      final config = ConfigCompiler.compile(
        contract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      );
      final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
        (o) => o['tag'] == 'tokyo-ss',
      );
      expect(outbound.containsKey('multiplex'), isFalse);
      expect(outbound['udp_over_tcp'], isTrue);
    });
  });

  group('merging servers', () {
    test('a second server joins the first instead of replacing it', () {
      final one = _plan(null, _link(_bundle()));
      final two = _plan(one, _link(_bundle(kind: 'home', name: 'house')));
      final contract = _contract(two);
      expect(contract.routeFamilies, unorderedEquals(['tokyo', 'house']));
      expect(contract.outboundGroup.urltestMembers, hasLength(6));
    });

    test('importing the same name again updates it in place', () {
      final one = _plan(null, _link(_bundle()));
      final rotated = _plan(one, _link(_bundle(host: '203.0.113.99')));
      final contract = _contract(rotated);
      expect(contract.nodes, hasLength(3));
      expect(contract.nodes.first.server, '203.0.113.99');
    });

    test('several links can be pasted at once', () {
      final text = '${_link(_bundle())}\n${_link(_bundle(kind: 'home', name: 'house'))}';
      final plan = ContractEditor.plan(null, text, now: _clock);
      expect(plan.added, ['tokyo', 'house']);
    });

    test('plain share links are kept in their own family', () {
      final contract = _contract(
        _plan(
          _plan(null, _link(_bundle())),
          'ss://${base64.encode(utf8.encode('2022-blake3-aes-128-gcm:AAAA'))}'
          '@198.51.100.5:8388#friend',
        ),
      );
      expect(contract.routeFamilies, containsAll(['tokyo', 'imported']));
    });

    test('merging bumps the revision so it wins over older copies', () {
      final merged = json.decode(_plan(null, _link(_bundle()))) as Map;
      expect(merged['revision'], _clock.millisecondsSinceEpoch);
    });

    test('an advanced path contract is refused rather than half merged', () {
      expect(
        () => ContractEditor.merge(
          {'paths': <String, dynamic>{}, 'nodes': <dynamic>[]},
          bundles: [AuroraLink.parse(_link(_bundle())) as ServerBundle],
        ),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('nothing recognizable is an error, not an empty contract', () {
      expect(
        () => ContractEditor.plan(null, 'hello world'),
        throwsA(isA<AuroraLinkException>()),
      );
      expect(
        () => ContractEditor.plan(null, '   '),
        throwsA(isA<AuroraLinkException>()),
      );
    });

    test('an invalid contract document is refused without quoting it', () {
      expect(
        () => ContractEditor.plan(null, '{"password":"super-secret"}'),
        throwsA(
          isA<AuroraLinkException>().having(
            (e) => e.message,
            'message',
            isNot(contains('super-secret')),
          ),
        ),
      );
    });
  });

  group('default route', () {
    test('one server has no family lock: automatic within that server', () {
      final contract = _contract(_plan(null, _link(_bundle())));
      expect(resolveRouteFamilySelection(null, contract), isNull);
    });

    // What a route resolves to is handed to the selector of the compiled config, and an
    // unknown tag fails the connection after the tunnel is already up. With one server,
    // which is everyone at first, the compiler emits no `via-*` group at all.
    test('every route that can be chosen exists in the compiled config', () {
      final one = _plan(null, _link(_bundle()));
      final two = _plan(one, _link(_bundle(kind: 'home', name: 'house')));
      final three = _plan(
        two,
        _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
      );
      for (final contractJson in [one, two, three]) {
        final contract = _contract(contractJson);
        final compiled = ConfigCompiler.compile(
          contract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.linux,
        );
        final selector = (compiled['outbounds'] as List).cast<Map<String, dynamic>>().singleWhere(
          (outbound) => outbound['tag'] == contract.outboundGroup.selectorTag,
        );
        final selectable = (selector['outbounds'] as List).cast<String>();

        expect(selectable, contains(resolveDefaultRouteTarget(contract).groupTag));
        for (final line in [null, auroraAutoRouteSelection, ...contract.routeFamilies]) {
          final target = resolveCliRouteTarget(line, contract);
          expect(target, isNotNull, reason: '--line $line');
          expect(selectable, contains(target!.groupTag), reason: '--line $line');
        }
        for (final family in renderableRouteFamilies(contract)) {
          expect(selectable, contains(routeFamilyGroupTag(family)));
        }
      }
    });

    test('adding a second exit does not move the public IP', () {
      final one = _plan(null, _link(_bundle()));
      final two = _plan(one, _link(_bundle(kind: 'home', name: 'house')));
      expect(resolveRouteFamilySelection(null, _contract(two)), 'tokyo');
    });

    test('a relay becomes the default, because it exists to be used', () {
      final one = _plan(null, _link(_bundle(kind: 'home', name: 'house')));
      final two = _plan(
        one,
        _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
      );
      expect(resolveRouteFamilySelection(null, _contract(two)), 'edge');
    });

    test('a saved choice wins over the default', () {
      final one = _plan(null, _link(_bundle(kind: 'home', name: 'house')));
      final two = _plan(
        one,
        _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
      );
      expect(resolveRouteFamilySelection('house', _contract(two)), 'house');
      expect(
        resolveRouteFamilySelection(auroraAutoRouteSelection, _contract(two)),
        isNull,
      );
    });

    test('a default pointing at a removed server falls back to automatic', () {
      final one = _plan(null, _link(_bundle(kind: 'home', name: 'house')));
      final two = _plan(
        one,
        _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
      );
      final removed = ContractEditor.removeServer(
        json.decode(two) as Map<String, dynamic>,
        'edge',
      )!;
      expect(
        resolveRouteFamilySelection(null, _contract(json.encode(removed))),
        isNull,
      );
    });
  });

  group('removing servers', () {
    test('removing a relay also removes its entries and chained exits', () {
      final one = _plan(null, _link(_bundle(kind: 'home', name: 'house')));
      final two = _plan(
        one,
        _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
      );
      final removed = ContractEditor.removeServer(
        json.decode(two) as Map<String, dynamic>,
        'edge',
      )!;
      final contract = AuroraContract.fromJson(removed);
      expect(contract.nodes.map((n) => n.id), [
        'house-reality',
        'house-hy2',
        'house-ss',
      ]);
    });

    test('removing the last server returns the app to first run', () {
      final only = json.decode(_plan(null, _link(_bundle()))) as Map<String, dynamic>;
      expect(ContractEditor.removeServer(only, 'tokyo'), isNull);
    });

    test('the server list reports the address a relay is reached at', () {
      final contract = json.decode(
        _plan(null, _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit))),
      ) as Map<String, dynamic>;
      final servers = ContractEditor.listServers(contract);
      expect(servers.single.group, 'edge');
      expect(servers.single.host, '203.0.113.10');
    });
  });

  test('every shape the installer can emit compiles for every platform', () {
    for (final link in [
      _link(_bundle()),
      _link(_bundle(kind: 'home', name: 'house', host: 'home.example.net')),
      _link(_bundle(kind: 'relay', name: 'edge', exit: _homeExit)),
    ]) {
      final contract = _contract(_plan(null, link));
      for (final platform in AuroraPlatform.values) {
        expect(
          () => ConfigCompiler.compile(
            contract,
            mode: AuroraMode.global,
            platform: platform,
            clashApiSecret: platform.usesClashApi ? 'secret' : null,
          ),
          returnsNormally,
        );
      }
    }
  });
}
