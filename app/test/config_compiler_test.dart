import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _load(String name) =>
    json.decode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final contract = AuroraContract.fromJson(_load('contract.sample.json'));
  final dualContract = AuroraContract.fromJson(
    _load('contract.dual-path.sample.json'),
  );
  final threePathContract = AuroraContract.fromJson(
    _load('path-contract.json'),
  );

  test('parses the contract', () {
    expect(contract.version, 1);
    expect(contract.defaultMode, 'smart');
    expect(contract.nodes.length, 3);
    expect(contract.nodes.first.protocol, 'vless-reality');
    expect(contract.outboundGroup.urltestMembers.length, 3);
    expect(contract.network.mtu, 1400);
    expect(contract.network.ipv6Mode, AuroraIpv6Mode.block);
    expect(contract.network.suppressHttpsRecord, isFalse);
  });

  test('DoH keeps one reusable connection, answers cached, via the proxy', () {
    // No `Connection: close`: every cache miss would pay its own TLS handshake
    // across China→relay→home→1.1.1.1, and the burst of misses right after each
    // (re)start timed out the watchdog's first probe in 3 of 8 cold starts on a
    // test device. See docs/reliability-notes.md.
    for (final source in [contract, dualContract, threePathContract]) {
      for (final platform in AuroraPlatform.values) {
        for (final mode in AuroraMode.values) {
          final config = ConfigCompiler.compile(
            source,
            mode: mode,
            platform: platform,
          );
          final dns = config['dns'] as Map;
          final proxy = (dns['servers'] as List).cast<Map>().singleWhere(
            (server) => server['tag'] == 'dns-proxy',
          );
          expect(proxy['type'], 'https');
          expect(proxy['detour'], 'proxy');
          expect(proxy.containsKey('headers'), isFalse);
          expect(proxy['tls'], isNull);
          expect(dns['disable_cache'], isNot(true));
        }
      }
    }
  });

  test('Shadowsocks never rides sing-mux; its UDP stays inside TCP', () {
    // sing-mux dials a new session while holding the client-wide lock, and
    // with default options every stream that finds no idle session dials one.
    // On a test device one such dial hung for 9 minutes: every new
    // connection through that leg and the DoH dial queued behind it, and
    // whole-machine DNS stayed dead after the watchdog moved off the leg.
    // Every sample contract still asks for `multiplex: true` (older clients
    // read it), so this pins that the compiler ignores it. udp_over_tcp is what
    // mux used to give UDP for free: the relay entry only relays TCP to home.
    for (final source in [contract, dualContract, threePathContract]) {
      expect(
        source.nodes.where((n) => n.params['multiplex'] == true),
        isNotEmpty,
      );
      for (final platform in AuroraPlatform.values) {
        for (final mode in AuroraMode.values) {
          final config = ConfigCompiler.compile(
            source,
            mode: mode,
            platform: platform,
          );
          final shadowsocks = (config['outbounds'] as List)
              .cast<Map>()
              .where((o) => o['type'] == 'shadowsocks')
              .toList();
          expect(shadowsocks, isNotEmpty);
          for (final outbound in shadowsocks) {
            expect(outbound.containsKey('multiplex'), isFalse,
                reason: '${outbound['tag']}');
            expect(outbound['udp_over_tcp'], isTrue,
                reason: '${outbound['tag']}');
          }
        }
      }
    }
  });

  test('parses explicit network policy', () {
    final json = _load('contract.sample.json');
    json['network'] = {
      'mtu': 1380,
      'ipv6_mode': 'native',
      'suppress_https_rr': true,
    };
    final parsed = AuroraContract.fromJson(json);
    expect(parsed.network.mtu, 1380);
    expect(parsed.network.ipv6Mode, AuroraIpv6Mode.native);
    expect(parsed.network.suppressHttpsRecord, isTrue);
  });

  test('rejects invalid network policy values', () {
    final badMtu = _load('contract.sample.json');
    badMtu['network'] = {'mtu': 1200};
    expect(() => AuroraContract.fromJson(badMtu), throwsArgumentError);

    final badIpv6 = _load('contract.sample.json');
    badIpv6['network'] = {'ipv6_mode': 'maybe'};
    expect(() => AuroraContract.fromJson(badIpv6), throwsArgumentError);
  });

  test('mode parser uses contract value and safe fallback', () {
    expect(auroraModeFromString('global'), AuroraMode.global);
    expect(auroraModeFromString('smart'), AuroraMode.smart);
    expect(auroraModeFromString('typo'), AuroraMode.smart);
    expect(auroraModeFromString(null), AuroraMode.smart);
  });

  test('global config matches gold-standard structure', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    expect(out, equals(_load('expected-global.json')));
  });

  test('smart config matches gold-standard structure', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.smart,
      platform: AuroraPlatform.android,
    );
    expect(out, equals(_load('expected-smart.json')));
  });

  test('dual-path config emits selector, path groups, nodes, then direct', () {
    final out = ConfigCompiler.compile(
      dualContract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final outbounds = (out['outbounds'] as List).cast<Map>();

    expect(
      outbounds.map((outbound) => outbound['tag']),
      orderedEquals([
        'proxy',
        'relay-auto',
        'home-auto',
        ...dualContract.nodes.map((node) => node.id),
        'fail-closed',
        'direct',
      ]),
    );
    expect(outbounds[0]['outbounds'], ['relay-auto', 'home-auto', 'fail-closed']);
    expect(outbounds[0]['default'], 'fail-closed');
    expect(outbounds[0]['interrupt_exist_connections'], isTrue);
    expect(outbounds[1]['outbounds'], [
      'home-via-relay-reality',
      'home-via-relay-hy2',
      'home-via-relay-ss',
    ]);
    expect(outbounds[2]['outbounds'], ['home-reality', 'home-hy2', 'home-ss']);
    expect(
      outbounds.firstWhere((outbound) => outbound['tag'] == 'fail-closed'),
      {'type': 'block', 'tag': 'fail-closed'},
    );
  });

  test('dual-path global config matches the reviewed fixture', () {
    final out = ConfigCompiler.compile(
      dualContract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    expect(out, equals(_load('expected-dual-path-global.json')));
  });

  test('three-path topology is ordered and strictly household-only', () {
    final out = ConfigCompiler.compile(
      threePathContract,
      mode: AuroraMode.smart,
      platform: AuroraPlatform.android,
    );
    final outbounds = (out['outbounds'] as List).cast<Map>();
    expect(outbounds.take(4).map((outbound) => outbound['tag']), [
      'proxy',
      'relay-public-auto',
      'relay-tailnet-auto',
      'home-auto',
    ]);
    expect(outbounds.first['outbounds'], [
      'relay-public-auto',
      'relay-tailnet-auto',
      'home-auto',
      'fail-closed',
    ]);
    expect(outbounds.first['default'], 'fail-closed');
    expect(outbounds.first['interrupt_exist_connections'], isTrue);

    final urltests = outbounds.where((item) => item['type'] == 'urltest');
    expect(urltests, hasLength(3));
    expect(urltests.expand((item) => item['outbounds'] as List), hasLength(9));
    final entries = outbounds.where(
      (item) => (item['tag'] as String).startsWith('relay-entry-'),
    );
    expect(entries, hasLength(3));
    final selectable = <String>{
      ...List<String>.from(outbounds.first['outbounds'] as List),
      ...urltests.expand(
        (item) => List<String>.from(item['outbounds'] as List),
      ),
    };
    expect(selectable.where((tag) => tag.startsWith('relay-entry-')), isEmpty);
    expect(selectable, isNot(contains('direct')));

    for (final suffix in ['reality', 'hy2', 'ss']) {
      final public = outbounds.firstWhere(
        (item) => item['tag'] == 'home-via-relay-public-$suffix',
      );
      expect(public['type'], 'shadowsocks');
      expect(public['server'], 'home.example.net');
      expect(public['server_port'], 2053);
      expect(public['detour'], 'relay-entry-$suffix');
      final tailnet = outbounds.firstWhere(
        (item) => item['tag'] == 'home-via-relay-tailnet-$suffix',
      );
      expect(tailnet['type'], 'shadowsocks');
      expect(tailnet['server'], '100.64.0.26');
      expect(tailnet['server_port'], 8388);
      expect(tailnet['detour'], 'relay-entry-$suffix');
    }
    expect((out['route'] as Map)['final'], 'proxy');
    expect((out['route'] as Map).containsKey('rule_set'), isFalse);
  });

  test('dual-path config never persists the fail-closed selector', () {
    final out = ConfigCompiler.compile(
      dualContract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.ios,
    );
    final cacheFile = ((out['experimental'] as Map)['cache_file'] as Map);

    expect(cacheFile['enabled'], isFalse);
  });

  test(
    'dual-path contracts never emit public direct routing in either mode',
    () {
      for (final mode in AuroraMode.values) {
        final out = ConfigCompiler.compile(
          dualContract,
          mode: mode,
          platform: AuroraPlatform.android,
        );
        final routeRules = ((out['route'] as Map)['rules'] as List).cast<Map>();
        final directRules = routeRules.where(
          (rule) => rule['outbound'] == 'direct',
        );
        expect(directRules, hasLength(1));
        expect(directRules.single['ip_is_private'], isTrue);
        expect((out['route'] as Map).containsKey('rule_set'), isFalse);

        final dnsRules = ((out['dns'] as Map)['rules'] as List).cast<Map>();
        expect(
          dnsRules.where((rule) => rule['server'] == 'dns-direct'),
          isEmpty,
        );
        final dnsServers = ((out['dns'] as Map)['servers'] as List).cast<Map>();
        expect(dnsServers.map((server) => server['tag']), ['dns-proxy']);
        expect(
          ((out['route'] as Map)['default_domain_resolver'] as Map)['server'],
          'dns-proxy',
        );
      }
    },
  );

  test('relay home-exit nodes detour through their matching hidden entries', () {
    final out = ConfigCompiler.compile(
      dualContract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final outbounds = (out['outbounds'] as List).cast<Map>();

    for (final suffix in ['reality', 'hy2', 'ss']) {
      final home = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'home-via-relay-$suffix',
      );
      expect(home['server'], '100.64.0.26');
      expect(home['server_port'], 8388);
      expect(home['detour'], 'relay-entry-$suffix');
    }
    final pathMembers = <String>{
      ...List<String>.from(outbounds[0]['outbounds'] as List),
      ...List<String>.from(outbounds[1]['outbounds'] as List),
      ...List<String>.from(outbounds[2]['outbounds'] as List),
    };
    expect(pathMembers.where((tag) => tag.startsWith('relay-entry-')), isEmpty);
    expect(pathMembers, isNot(contains('direct')));
  });

  group('dual-path topology guards', () {
    void expectRejected(Map<String, dynamic> json) {
      expect(
        () => ConfigCompiler.compile(
          AuroraContract.fromJson(json),
          mode: AuroraMode.global,
          platform: AuroraPlatform.android,
        ),
        throwsArgumentError,
      );
    }

    Map<String, dynamic> pathItem(Map<String, dynamic> json, String path) =>
        (((json['paths'] as Map<String, dynamic>)['items']
                as Map<String, dynamic>)[path]
            as Map<String, dynamic>);

    Map<String, dynamic> node(Map<String, dynamic> json, String id) =>
        (json['nodes'] as List).cast<Map<String, dynamic>>().firstWhere(
          (candidate) => candidate['id'] == id,
        );

    test('rejects an unknown path member', () {
      final json = _load('contract.dual-path.sample.json');
      (pathItem(json, 'relay')['members'] as List).add('missing');
      expectRejected(json);
    });

    test('rejects a member assigned to both paths', () {
      final json = _load('contract.dual-path.sample.json');
      (pathItem(json, 'relay')['members'] as List).add('home-reality');
      expectRejected(json);
    });

    test('rejects path group collisions with selector and node tags', () {
      final selectorCollision = _load('contract.dual-path.sample.json');
      pathItem(selectorCollision, 'relay')['group_tag'] = 'proxy';
      expectRejected(selectorCollision);

      final nodeCollision = _load('contract.dual-path.sample.json');
      pathItem(nodeCollision, 'relay')['group_tag'] = 'home-reality';
      expectRejected(nodeCollision);
    });

    test('rejects entry and direct as final path members', () {
      final entry = _load('contract.dual-path.sample.json');
      pathItem(entry, 'relay')['members'] = ['relay-entry-reality'];
      expectRejected(entry);

      final direct = _load('contract.dual-path.sample.json');
      (pathItem(direct, 'home')['members'] as List).add('direct');
      expectRejected(direct);
    });

    test('rejects self and multi-node detour loops', () {
      final selfLoop = _load('contract.dual-path.sample.json');
      node(selfLoop, 'relay-entry-reality')['detour'] = 'relay-entry-reality';
      expectRejected(selfLoop);

      final twoNodeLoop = _load('contract.dual-path.sample.json');
      node(twoNodeLoop, 'relay-entry-reality')['detour'] = 'relay-entry-hy2';
      node(twoNodeLoop, 'relay-entry-hy2')['detour'] = 'relay-entry-reality';
      expectRejected(twoNodeLoop);
    });

    test('rejects relay home exits detouring to non-entry nodes', () {
      final json = _load('contract.dual-path.sample.json');
      node(json, 'home-via-relay-reality')['detour'] = 'home-reality';
      expectRejected(json);
    });

    test('rejects a home-direct path member carrying an relay detour', () {
      final json = _load('contract.dual-path.sample.json');
      node(json, 'home-reality')['detour'] = 'relay-entry-reality';
      expectRejected(json);
    });

    test('rejects legacy groups that expose a chained relay member', () {
      final json = _load('contract.dual-path.sample.json');
      final outbound = json['outbound_group'] as Map<String, dynamic>;
      final selector = outbound['selector'] as Map<String, dynamic>;
      final urltest = outbound['urltest'] as Map<String, dynamic>;
      selector['members'] = ['auto', 'home-via-relay-reality'];
      urltest['members'] = ['home-via-relay-reality'];
      expectRejected(json);
    });
  });

  test('AAAA queries are answered empty in IPv4-only mode', () {
    // The TUN owns the IPv6 default route (anti-leak) but the exits have no
    // working IPv6, so any client that gets an AAAA (or an HTTPS record with
    // ipv6hint/ECH) dials into a black hole — images fail to load and TLS
    // surfaces as connection failures. dns.strategy=ipv4_only does NOT filter
    // relayed answers; only an explicit predefined rule does.
    for (final mode in AuroraMode.values) {
      final out = ConfigCompiler.compile(
        contract,
        mode: mode,
        platform: AuroraPlatform.android,
      );
      final rules = ((out['dns'] as Map)['rules'] as List?) ?? const [];
      expect(
        rules.isNotEmpty &&
            (rules.first as Map)['action'] == 'predefined' &&
            ((rules.first as Map)['query_type'] as List).length == 1 &&
            ((rules.first as Map)['query_type'] as List).contains('AAAA'),
        isTrue,
        reason: '$mode must filter AAAA as the first dns rule',
      );
      // Browsers' built-in DoH bypasses hijack-dns, so the route-layer reject
      // is the anti-leak/black-hole backstop for any learned IPv6 destination.
      // It must be a non-degrading pre-match reject: after sniff, sing-box can
      // only close the accepted connection (Chromium won't fall back); without
      // no_drop, 50 parallel attempts turn reject into a silent black hole.
      final routeRules = ((out['route'] as Map)['rules'] as List);
      expect(routeRules.first, {
        'ip_version': 6,
        'action': 'reject',
        'method': 'default',
        'no_drop': true,
      }, reason: '$mode must reject IPv6 before sniffing');
      expect((routeRules[1] as Map)['action'], 'sniff');
    }
  });

  test('HTTPS RR suppression is opt-in', () {
    final json = _load('contract.sample.json');
    json['network'] = {'suppress_https_rr': true};
    final configured = AuroraContract.fromJson(json);
    final out = ConfigCompiler.compile(
      configured,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final first = (((out['dns'] as Map)['rules'] as List).first as Map);
    expect((first['query_type'] as List).toSet(), {'AAAA', 'HTTPS'});
  });

  test('native IPv6 mode keeps AAAA and IPv6 routes', () {
    final json = _load('contract.sample.json');
    json['network'] = {'ipv6_mode': 'native'};
    final configured = AuroraContract.fromJson(json);
    final out = ConfigCompiler.compile(
      configured,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final dnsRules = ((out['dns'] as Map)['rules'] as List?) ?? const [];
    expect(
      dnsRules.where((r) => (r as Map).containsKey('query_type')),
      isEmpty,
    );
    final routeRules = ((out['route'] as Map)['rules'] as List);
    expect(routeRules.where((r) => (r as Map)['ip_version'] == 6), isEmpty);
  });

  test('local-only names are answered on-device, never via the proxy DoH', () {
    // Seen in a real core log: Bonjour `lb._dns-sd._udp.<subnet>.in-addr.arpa`,
    // reverse lookups of the TUN's own address and `.local` names all went to
    // dns-proxy — each one a round trip through three hops, and each one
    // hanging alongside real queries when the path degraded. None of them can
    // have an answer out there.
    for (final mode in AuroraMode.values) {
      for (final platform in [AuroraPlatform.android, AuroraPlatform.ios]) {
        final out = ConfigCompiler.compile(
          contract,
          mode: mode,
          platform: platform,
        );
        final rules = (out['dns'] as Map)['rules'] as List;
        final local =
            rules.firstWhere((r) => (r as Map)['rcode'] == 'NXDOMAIN') as Map;
        expect(local['action'], 'predefined');
        final suffixes = List<String>.from(local['domain_suffix'] as List);
        expect(suffixes, containsAll(['.local', '10.in-addr.arpa']));
        // The TUN subnets of every platform and Tailscale's CGNAT range.
        bool covered(String name) => suffixes.any(
          (suffix) => name == suffix || name.endsWith('.$suffix'),
        );
        expect(covered('1.0.19.172.in-addr.arpa'), isTrue);
        expect(covered('1.222.111.10.in-addr.arpa'), isTrue);
        expect(covered('5.0.64.100.in-addr.arpa'), isTrue);
        expect(covered('lb._dns-sd._udp.0.232.23.10.in-addr.arpa'), isTrue);
        expect(covered('8.e.f.ip6.arpa'), isTrue);
        expect(covered('9.1.2.3.4.in-addr.arpa'), isFalse);
        expect(
          List<String>.from(local['domain_keyword'] as List),
          contains('_dns-sd._udp'),
        );
        // Public reverse lookups still resolve normally.
        expect(suffixes, isNot(contains('in-addr.arpa')));
        expect(suffixes, isNot(contains('arpa')));
      }
    }
  });

  test('dns-direct never carries a detour (1.13 would FATAL otherwise)', () {
    for (final mode in AuroraMode.values) {
      final out = ConfigCompiler.compile(
        contract,
        mode: mode,
        platform: AuroraPlatform.android,
      );
      final servers = (out['dns'] as Map)['servers'] as List;
      final direct = servers.firstWhere((s) => s['tag'] == 'dns-direct') as Map;
      expect(direct.containsKey('detour'), isFalse);
    }
  });

  test('iOS uses the small NE-friendly TUN subnet', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.ios,
    );
    final address = ((out['inbounds'] as List).first as Map)['address'] as List;
    expect(address.first, '10.111.222.1/24');
  });

  test('all TUN platforms use the contract MTU; mixed does not', () {
    for (final platform in [
      AuroraPlatform.android,
      AuroraPlatform.ios,
      AuroraPlatform.windows,
    ]) {
      final out = ConfigCompiler.compile(
        contract,
        mode: AuroraMode.global,
        platform: platform,
      );
      final inbound = (out['inbounds'] as List).first as Map;
      expect(inbound['mtu'], 1400, reason: '$platform');
    }
    final desktop = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.desktop,
    );
    expect(
      ((desktop['inbounds'] as List).first as Map).containsKey('mtu'),
      isFalse,
    );
  });

  // ---- IPv6 kill-switch on the svc desktops (from a leak audit) ------------

  // sing-tun only installs its WFP "block ipv6" filter when the TUN has NO IPv6
  // address (`if len(t.options.Inet6Address) == 0` in tun_windows.go's Start).
  // Handing it one while the contract says ipv6_mode=block therefore silently
  // disabled the only kernel-level backstop we had: route rules can only reject
  // IPv6 that ENTERED the tunnel, and on-link v6, an interface swap, or an app
  // bound to the physical adapter's own address never does.
  group('with IPv6 blocked the desktop TUN must not carry a v6 address', () {
    for (final platform in [AuroraPlatform.windows, AuroraPlatform.linux]) {
      test('$platform TUN has only a v4 address', () {
        final out = ConfigCompiler.compile(
          contract, // the sample contract defaults to ipv6_mode=block
          mode: AuroraMode.global,
          platform: platform,
        );
        final address =
            ((out['inbounds'] as List).first as Map)['address'] as List;
        expect(address, ['172.19.0.1/30']);
      });
    }

    test('when the contract asks for native, the v6 address stays', () {
      final json = _load('contract.sample.json');
      json['network'] = {'mtu': 1400, 'ipv6_mode': 'native'};
      final out = ConfigCompiler.compile(
        AuroraContract.fromJson(json),
        mode: AuroraMode.global,
        platform: AuroraPlatform.windows,
      );
      final address =
          ((out['inbounds'] as List).first as Map)['address'] as List;
      expect(address, ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
    });

    // Mobile does not use sing-tun's Windows implementation: the interface is
    // created by VpnService / NEPacketTunnelProvider, and this change must not
    // touch those two already-verified paths.
    test('mobile is unaffected', () {
      for (final platform in [AuroraPlatform.android, AuroraPlatform.ios]) {
        final out = ConfigCompiler.compile(
          contract,
          mode: AuroraMode.global,
          platform: platform,
        );
        final address =
            ((out['inbounds'] as List).first as Map)['address'] as List;
        expect(address.length, 2, reason: '$platform');
      }
    });
  });

  // ---- Egress interface ("I want traffic to leave only over Wi-Fi, but it seems
  // to leak onto the wired link") ----

  group('route.default_interface', () {
    test('with no choice it stays auto_detect_interface', () {
      final route = ConfigCompiler.compile(
        contract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.windows,
      )['route'] as Map;
      expect(route['auto_detect_interface'], isTrue);
      expect(route.containsKey('default_interface'), isFalse);
    });

    // The two fields are mutually exclusive: the sing-box docs say
    // default_interface has no effect while auto_detect_interface is on, so
    // writing both pins nothing.
    test('a chosen interface is pinned and auto_detect_interface is dropped', () {
      final route = ConfigCompiler.compile(
        contract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.windows,
        defaultInterface: 'WLAN',
      )['route'] as Map;
      expect(route['default_interface'], 'WLAN');
      expect(route.containsKey('auto_detect_interface'), isFalse);
    });

    test('empty or blank counts as no choice', () {
      for (final value in ['', '   ']) {
        final route = ConfigCompiler.compile(
          contract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.windows,
          defaultInterface: value,
        )['route'] as Map;
        expect(route['auto_detect_interface'], isTrue, reason: '"$value"');
        expect(route.containsKey('default_interface'), isFalse);
      }
    });
  });

  test('unknown protocol is rejected', () {
    final bad = AuroraContract(
      version: 1,
      defaultMode: 'global',
      nodes: [
        AuroraNode(
          id: 'x',
          role: 'primary',
          protocol: 'wireguard',
          server: '203.0.113.10',
          port: 1,
          params: const {},
        ),
      ],
      outboundGroup: contract.outboundGroup,
    );
    expect(
      () => ConfigCompiler.compile(
        bad,
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      ),
      throwsArgumentError,
    );
  });

  test('AuroraNode parses an optional detour field', () {
    final n = AuroraNode.fromJson({
      'id': 'home-via-reality',
      'role': 'exit',
      'protocol': 'shadowsocks-2022',
      'server': '100.64.0.26',
      'port': 8388,
      'detour': 'us-reality',
      'params': {'method': '2022-blake3-aes-128-gcm', 'password': 'x'},
    });
    expect(n.detour, 'us-reality');
  });

  test('AuroraNode detour defaults to null when absent', () {
    expect(contract.nodes.first.detour, isNull);
  });

  AuroraContract chainedContract() => AuroraContract(
    version: 1,
    defaultMode: 'global',
    nodes: [
      AuroraNode(
        id: 'us-reality',
        role: 'entry',
        protocol: 'vless-reality',
        server: '198.51.100.60',
        port: 443,
        params: const {
          'uuid': 'u',
          'flow': 'xtls-rprx-vision',
          'sni': 's',
          'public_key': 'k',
          'short_id': 'i',
          'fingerprint': 'chrome',
        },
      ),
      AuroraNode(
        id: 'home-via-reality',
        role: 'exit',
        protocol: 'shadowsocks-2022',
        server: '100.64.0.26',
        port: 8388,
        detour: 'us-reality',
        params: const {'method': '2022-blake3-aes-128-gcm', 'password': 'p'},
      ),
    ],
    outboundGroup: OutboundGroup(
      selectorTag: 'proxy',
      selectorMembers: const ['auto', 'home-via-reality'],
      selectorDefault: 'auto',
      urltestTag: 'auto',
      urltestMembers: const ['home-via-reality'],
      urltestUrl: 'https://www.gstatic.com/generate_204',
      urltestInterval: '3m',
    ),
  );

  test('detour is emitted only on the chained outbound', () {
    final out = ConfigCompiler.compile(
      chainedContract(),
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final obs = (out['outbounds'] as List).cast<Map>();
    final home = obs.firstWhere((o) => o['tag'] == 'home-via-reality');
    expect(home['detour'], 'us-reality');
    final us = obs.firstWhere((o) => o['tag'] == 'us-reality');
    expect(us.containsKey('detour'), isFalse);
  });

  test('fail-closed proxy group excludes direct and entry nodes', () {
    final out = ConfigCompiler.compile(
      chainedContract(),
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final obs = (out['outbounds'] as List).cast<Map>();
    final proxy = obs.firstWhere((o) => o['tag'] == 'proxy');
    final members = List<String>.from(proxy['outbounds'] as List);
    expect(members, contains('home-via-reality'));
    expect(members, isNot(contains('direct')));
    expect(members, isNot(contains('us-reality')));
  });

  test('compiler tightens legacy selector by removing direct', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final selector = (out['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == 'proxy',
    );
    expect(selector['outbounds'], isNot(contains('direct')));
  });

  test('unknown or empty group members fail loud', () {
    AuroraContract withMembers(List<String> selector, List<String> urltest) =>
        AuroraContract(
          version: contract.version,
          defaultMode: contract.defaultMode,
          nodes: contract.nodes,
          outboundGroup: OutboundGroup(
            selectorTag: 'proxy',
            selectorMembers: selector,
            selectorDefault: 'auto',
            urltestTag: 'auto',
            urltestMembers: urltest,
            urltestUrl: 'https://www.gstatic.com/generate_204',
            urltestInterval: '3m',
          ),
        );

    expect(
      () => ConfigCompiler.compile(
        withMembers(['auto', 'missing'], ['missing']),
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      ),
      throwsArgumentError,
    );
    expect(
      () => ConfigCompiler.compile(
        withMembers(['direct'], const []),
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      ),
      throwsArgumentError,
    );
  });

  test('Hy2 emits a base64 SPKI pin and does not emit insecure', () {
    final json = _load('contract.sample.json');
    final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
    final params = Map<String, dynamic>.from(nodes[1]['params'] as Map);
    params
      ..remove('insecure')
      ..['certificate_public_key_sha256'] =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    nodes[1]['params'] = params;
    final configured = AuroraContract.fromJson(json);
    final out = ConfigCompiler.compile(
      configured,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final hy2 = (out['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['type'] == 'hysteria2',
    );
    final tls = hy2['tls'] as Map;
    expect(tls['certificate_public_key_sha256'], [
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    ]);
    expect(tls.containsKey('insecure'), isFalse);
  });

  test('Hy2 accepts a pinned PEM certificate', () {
    final json = _load('contract.sample.json');
    final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
    final params = Map<String, dynamic>.from(nodes[1]['params'] as Map);
    params
      ..remove('insecure')
      ..remove('certificate_public_key_sha256')
      ..['certificate'] =
          '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----';
    nodes[1]['params'] = params;
    final configured = AuroraContract.fromJson(json);
    final out = ConfigCompiler.compile(
      configured,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final hy2 = (out['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['type'] == 'hysteria2',
    );
    expect((hy2['tls'] as Map)['certificate'], [
      '-----BEGIN CERTIFICATE-----',
      'TEST',
      '-----END CERTIFICATE-----',
    ]);
  });

  test('Hy2 insecure is legacy explicit opt-in, never the default', () {
    final legacyJson = _load('contract.sample.json');
    final legacyNodes = (legacyJson['nodes'] as List)
        .cast<Map<String, dynamic>>();
    final legacyParams =
        Map<String, dynamic>.from(legacyNodes[1]['params'] as Map)
          ..remove('certificate_public_key_sha256')
          ..['insecure'] = true;
    legacyNodes[1]['params'] = legacyParams;
    final legacy = ConfigCompiler.compile(
      AuroraContract.fromJson(legacyJson),
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final legacyHy2 = (legacy['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['type'] == 'hysteria2',
    );
    expect((legacyHy2['tls'] as Map)['insecure'], isTrue);

    final json = _load('contract.sample.json');
    final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
    final params = Map<String, dynamic>.from(nodes[1]['params'] as Map)
      ..remove('certificate_public_key_sha256')
      ..remove('insecure');
    nodes[1]['params'] = params;
    final secureByDefault = ConfigCompiler.compile(
      AuroraContract.fromJson(json),
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final secureHy2 = (secureByDefault['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect((secureHy2['tls'] as Map).containsKey('insecure'), isFalse);
  });

  Map<String, dynamic> hy2With(Map<String, dynamic> extra) {
    final json = _load('contract.dual-path.sample.json');
    final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
    final entry = nodes.firstWhere((n) => n['id'] == 'relay-entry-hy2');
    final params = Map<String, dynamic>.from(entry['params'] as Map)
      ..remove('server_ports')
      ..remove('hop_interval')
      ..addAll(extra);
    entry['params'] = params;
    final out = ConfigCompiler.compile(
      AuroraContract.fromJson(json),
      mode: AuroraMode.global,
      platform: AuroraPlatform.ios,
    );
    return (out['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
      (o) => o['tag'] == 'relay-entry-hy2',
    );
  }

  test('Hy2 hops ports exactly as the contract lists them', () {
    final hopping = hy2With({
      'server_ports': ['443:443', '20000:29999'],
      'hop_interval': '10s',
    });
    expect(hopping['server_ports'], ['443:443', '20000:29999']);
    expect(hopping['hop_interval'], '10s');
    expect(hopping['server_port'], 443);

    final still = hy2With(const {});
    expect(still.containsKey('server_ports'), isFalse);
    expect(still.containsKey('hop_interval'), isFalse);
  });

  test('Hy2 refuses hop settings sing-box would misread', () {
    for (final bad in <Map<String, dynamic>>[
      {'server_ports': '443:443'},
      {'server_ports': <String>[]},
      {'server_ports': ['443']},
      {'server_ports': ['0:10']},
      {'server_ports': ['29999:20000']},
      {'server_ports': ['443:70000']},
      {'server_ports': ['a:b']},
      {'server_ports': ['443:443'], 'hop_interval': 'fast'},
      {'server_ports': ['443:443'], 'hop_interval': '0s'},
      {'hop_interval': '10s'},
    ]) {
      expect(() => hy2With(bad), throwsArgumentError, reason: '$bad');
    }
  });

  test('detour to an unknown node id throws', () {
    final bad = AuroraContract(
      version: 1,
      defaultMode: 'global',
      nodes: [
        AuroraNode(
          id: 'home',
          role: 'exit',
          protocol: 'shadowsocks-2022',
          server: '203.0.113.9',
          port: 8388,
          detour: 'nope',
          params: const {'method': '2022-blake3-aes-128-gcm', 'password': 'p'},
        ),
      ],
      outboundGroup: contract.outboundGroup,
    );
    expect(
      () => ConfigCompiler.compile(
        bad,
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      ),
      throwsArgumentError,
    );
  });

  test('a CGNAT (100.64/10) server without detour throws', () {
    final bad = AuroraContract(
      version: 1,
      defaultMode: 'global',
      nodes: [
        AuroraNode(
          id: 'home',
          role: 'exit',
          protocol: 'shadowsocks-2022',
          server: '100.64.0.26',
          port: 8388, // no detour
          params: const {'method': '2022-blake3-aes-128-gcm', 'password': 'p'},
        ),
      ],
      outboundGroup: contract.outboundGroup,
    );
    expect(
      () => ConfigCompiler.compile(
        bad,
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      ),
      throwsArgumentError,
    );
  });

  test('a public server without detour is allowed', () {
    // the existing syd sample contract has no CGNAT servers → compiles fine
    ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
  });

  test('desktop platform emits a local mixed inbound (no TUN)', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.desktop,
    );
    final inbound = (out['inbounds'] as List).first as Map;
    expect(inbound['type'], 'mixed');
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['listen_port'], 2080);
  });

  test('windows platform emits Android-style TUN + clash_api', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.windows,
      clashApiSecret: 'sekret123',
    );
    final inbound = (out['inbounds'] as List).first as Map;
    expect(inbound['type'], 'tun');
    expect((inbound['address'] as List).first, '172.19.0.1/30');
    final clash = (out['experimental'] as Map)['clash_api'] as Map;
    expect(clash['external_controller'], '127.0.0.1:9090');
    expect(clash['secret'], 'sekret123');
  });

  test('non-windows platforms never emit clash_api', () {
    final out = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    expect((out['experimental'] as Map).containsKey('clash_api'), isFalse);
  });

  test('clashApiSecret is rejected on non-windows platforms', () {
    expect(
      () => ConfigCompiler.compile(
        contract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.ios,
        clashApiSecret: 'x',
      ),
      throwsArgumentError,
    );
  });

  group('vless-ws-tls (CDN-fronted)', () {
    // A CDN-fronted node is the only shape that survives an IP-level block of
    // every origin: the client dials a Cloudflare anycast address, which no
    // censor can blocklist wholesale. It is VLESS over WebSocket over ordinary
    // TLS — no REALITY, and no `flow` (Vision is incompatible with WebSocket).
    Map<String, dynamic> cdnContract({Map<String, dynamic>? params}) {
      final json = _load('contract.sample.json');
      json['nodes'] = [
        {
          'id': 'cdn-edge',
          'name': 'CDN front',
          'role': 'primary',
          'protocol': 'vless-ws-tls',
          'server': 'cdn.example.com',
          'port': 2053,
          'params':
              params ??
              {
                'uuid': '00000000-0000-0000-0000-000000000009',
                'sni': 'cdn.example.com',
                'path': '/aurora',
              },
        },
      ];
      json['outbound_group'] = {
        'selector': {
          'tag': 'proxy',
          'members': ['auto', 'cdn-edge'],
          'default': 'auto',
        },
        'urltest': {
          'tag': 'auto',
          'members': ['cdn-edge'],
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '3m',
        },
      };
      return json;
    }

    Map<String, dynamic> compileCdn({Map<String, dynamic>? params}) {
      final out = ConfigCompiler.compile(
        AuroraContract.fromJson(cdnContract(params: params)),
        mode: AuroraMode.global,
        platform: AuroraPlatform.desktop,
      );
      return (out['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == 'cdn-edge');
    }

    test('compiles to a vless outbound carrying a websocket transport', () {
      final node = compileCdn();
      expect(node['type'], 'vless');
      expect(node['server'], 'cdn.example.com');
      expect(node['server_port'], 2053);
      expect(node['uuid'], '00000000-0000-0000-0000-000000000009');
      final transport = node['transport'] as Map;
      expect(transport['type'], 'ws');
      expect(transport['path'], '/aurora');
    });

    test('uses plain TLS with uTLS and never REALITY or Vision flow', () {
      final node = compileCdn();
      final tls = node['tls'] as Map;
      expect(tls['enabled'], isTrue);
      expect(tls['server_name'], 'cdn.example.com');
      expect((tls['utls'] as Map)['enabled'], isTrue);
      // REALITY would defeat the point: the CDN terminates TLS, so the client
      // must present an ordinary handshake the CDN can serve.
      expect(tls.containsKey('reality'), isFalse);
      // xtls-rprx-vision cannot ride WebSocket; sing-box rejects the pair.
      expect(node.containsKey('flow'), isFalse);
    });

    test('sends the fronting Host header when it differs from the SNI', () {
      final node = compileCdn(
        params: {
          'uuid': '00000000-0000-0000-0000-000000000009',
          'sni': 'cdn.example.com',
          'path': '/aurora',
          'host': 'fronted.example.com',
        },
      );
      final headers = (node['transport'] as Map)['headers'] as Map;
      expect(headers['Host'], 'fronted.example.com');
    });

    test('defaults the websocket path when the contract omits it', () {
      final node = compileCdn(
        params: {
          'uuid': '00000000-0000-0000-0000-000000000009',
          'sni': 'cdn.example.com',
        },
      );
      expect((node['transport'] as Map)['path'], '/');
    });

    // The message is asserted, not just the type: every unsupported protocol
    // also throws ArgumentError, so a type-only expectation would pass even
    // when vless-ws-tls is not implemented at all.
    test('rejects a node with no uuid', () {
      expect(
        () => compileCdn(params: {'sni': 'cdn.example.com', 'path': '/a'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('uuid'),
          ),
        ),
      );
    });

    test('rejects a node with no sni to validate the CDN cert against', () {
      expect(
        () => compileCdn(
          params: {
            'uuid': '00000000-0000-0000-0000-000000000009',
            'path': '/a',
          },
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('sni'),
          ),
        ),
      );
    });
  });

  group('route family groups (legacy/flat shape)', () {
    // Shaped after contract.sample.json with only nodes / outbound_group replaced:
    // these tests only care how the per-family urltest is emitted and do not need
    // the dns/route skeleton assertions.
    Map<String, dynamic> familyContractJson({
      required List<Map<String, dynamic>> nodes,
      required Map<String, dynamic> outboundGroup,
    }) {
      final json = _load('contract.sample.json');
      json['nodes'] = nodes;
      json['outbound_group'] = outboundGroup;
      return json;
    }

    final relayEntry = {
      'id': 'relay-entry', 'name': 'relay entry', 'role': 'entry',
      'protocol': 'vless-reality', 'server': '198.51.100.8', 'port': 443,
      'params': {
        'uuid': '00000000-0000-0000-0000-000000000001',
        'flow': 'xtls-rprx-vision',
        'sni': 'www.microsoft.com',
        'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'short_id': '89abcdef',
        'fingerprint': 'chrome',
      },
    };
    // The builder writes via:direct on home nodes. "Direct" is always declared by
    // the contract, never inferred by the client from "has no detour"; see
    // auroraUnspecifiedRouteFamily in contract.dart.
    final homeReality = {
      'id': 'home-reality', 'name': 'Home REALITY', 'role': 'primary',
      'via': 'direct',
      'protocol': 'vless-reality', 'server': '203.0.113.10', 'port': 443,
      'params': {
        'uuid': '00000000-0000-0000-0000-000000000002',
        'flow': 'xtls-rprx-vision',
        'sni': 'www.microsoft.com',
        'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'short_id': '0123abcd',
        'fingerprint': 'chrome',
      },
    };
    final homeSs = {
      'id': 'home-ss', 'name': 'Home SS2022', 'role': 'backup',
      'via': 'direct',
      'protocol': 'shadowsocks-2022', 'server': '203.0.113.10', 'port': 8443,
      'params': {
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'multiplex': true,
      },
    };
    // Explicit via: structurally this is a relay (it has a detour), but its path to
    // the home node belongs to the relay family, not to a generic relay. With the
    // family written in the contract the compiler has nothing to guess.
    final homeViaRelay = {
      'id': 'home-via-relay', 'name': 'Home via relay', 'role': 'exit',
      'protocol': 'shadowsocks-2022', 'server': '100.64.0.26', 'port': 8388,
      'detour': 'relay-entry', 'via': 'relay',
      'params': {
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'multiplex': true,
      },
    };

    final multiFamilyContract = AuroraContract.fromJson(
      familyContractJson(
        nodes: [relayEntry, homeReality, homeSs, homeViaRelay],
        outboundGroup: {
          'selector': {
            'tag': 'proxy',
            'members': ['auto', 'home-reality', 'home-ss', 'home-via-relay'],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-reality', 'home-ss', 'home-via-relay'],
            'url': 'https://www.gstatic.com/generate_204',
            'interval': '3m',
          },
        },
      ),
    );

    final singleFamilyContract = AuroraContract.fromJson(
      familyContractJson(
        nodes: [homeReality, homeSs],
        outboundGroup: {
          'selector': {
            'tag': 'proxy',
            'members': ['auto', 'home-reality', 'home-ss'],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-reality', 'home-ss'],
            'url': 'https://www.gstatic.com/generate_204',
            'interval': '3m',
          },
        },
      ),
    );

    // A colliding node whose id equals the family tag via-relay that will be
    // emitted later: compilation must fail loudly instead of quietly generating a
    // urltest that points at itself.
    final collidingContract = AuroraContract.fromJson(
      familyContractJson(
        nodes: [
          relayEntry,
          homeReality,
          homeSs,
          homeViaRelay,
          {
            'id': 'via-relay', 'name': 'Colliding node', 'role': 'backup',
            'protocol': 'shadowsocks-2022', 'server': '203.0.113.11',
            'port': 8443,
            'params': {
              'method': '2022-blake3-aes-128-gcm',
              'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
              'multiplex': true,
            },
          },
        ],
        outboundGroup: {
          'selector': {
            'tag': 'proxy',
            'members': [
              'auto',
              'home-reality',
              'home-ss',
              'home-via-relay',
              'via-relay',
            ],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-reality', 'home-ss', 'home-via-relay', 'via-relay'],
            'url': 'https://www.gstatic.com/generate_204',
            'interval': '3m',
          },
        },
      ),
    );

    test('a multi-family contract gets one urltest per family', () {
      final compiled = ConfigCompiler.compile(
        multiFamilyContract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.ios,
      );
      final outbounds = compiled['outbounds'] as List;
      Map<String, dynamic> byTag(String tag) => outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == tag);

      expect(byTag('via-direct')['type'], 'urltest');
      expect(byTag('via-direct')['outbounds'], ['home-reality', 'home-ss']);
      expect(byTag('via-relay')['outbounds'], ['home-via-relay']);
      expect(byTag('auto')['outbounds'], [
        'home-reality',
        'home-ss',
        'home-via-relay',
      ]);

      final selector = byTag('proxy');
      expect(selector['outbounds'], [
        'auto',
        'via-direct',
        'via-relay',
        'home-reality',
        'home-ss',
        'home-via-relay',
      ]);
      expect(selector['default'], 'auto');
    });

    test(
      'via-* family groups cap the interval to 60s',
      () {
        // A single-family contract (contract.sample.json) never reaches the
        // familyGroups.add branch: via-* groups are emitted only when
        // routeFamilies.length > 1. A dead leg in the relay family is kicked out
        // precisely by this urltest group, so the field must be asserted here
        // rather than asserting only on auto and assuming via-* is covered.
        //
        // Whether old connections are interrupted is not asserted here; see the
        // two tests below ('selector ... interrupts old connections' and
        // 'urltest groups ... never interrupt old connections'). An earlier
        // release once emitted interrupt_exist_connections here too, which is
        // exactly the regression this file guards against, so do not add it back
        // in this test.
        final compiled = ConfigCompiler.compile(
          multiFamilyContract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.ios,
        );
        final outbounds = (compiled['outbounds'] as List)
            .cast<Map<String, dynamic>>();
        final familyGroups = outbounds.where(
          (o) => (o['tag'] as String).startsWith('via-'),
        );
        expect(familyGroups, isNotEmpty);
        for (final group in familyGroups) {
          expect(
            group['interval'],
            '60s',
            reason: '${group['tag']} urltest interval is not capped to 60s',
          );
        }
      },
    );

    test(
      'selector (proxy) reselection interrupts old connections: a deliberate decision, not latency noise',
      () {
        // A selector change comes from an explicit decision such as the user
        // manually locking a route family or GoodputGate demoting a leg on a
        // health verdict; it is not routine. Interrupting old connections is
        // right: otherwise established connections stay pinned to the member that
        // was just judged unhealthy.
        final compiled = ConfigCompiler.compile(
          multiFamilyContract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.ios,
        );
        final outbounds = (compiled['outbounds'] as List)
            .cast<Map<String, dynamic>>();
        final selector = outbounds.firstWhere((o) => o['tag'] == 'proxy');
        expect(selector['type'], 'selector');
        expect(
          selector['interrupt_exist_connections'],
          isTrue,
          reason: 'old connections were not interrupted after the selector changed: '
              'they would stay pinned to the member judged unhealthy',
        );
      },
    );

    test(
      'urltest groups (auto/via-*/dual path) never interrupt old connections (regression guard)',
      () {
        // An earlier release also added interrupt_exist_connections to every
        // urltest group, reasoning that "after a re-election old connections must
        // not stay pinned to a dead member". That only holds when the
        // *currently selected member is really unreachable*. But urltest elects
        // purely by latency ranking: whenever a sibling is occasionally faster
        // within the tolerance (50ms) it triggers a reselection, and nearly all
        // of those are jitter, not faults. Adding interrupt there means every bit
        // of latency noise kicks out all existing connections.
        //
        // Observed on a real device (after the same change had tightened the
        // urltest interval to 60s): the via-relay group kept flapping its election
        // between reality/ss/hy2, and hy2 kept winning on the fastest handshake
        // while carrying 0KB/s throughput. interrupt turned that into
        // "connections drop and recover", which is exactly the user report this
        // contract fixes.
        //
        // Only a selector change is a deliberate decision (the user locks a route
        // family / GoodputGate demotes), so only the selector should interrupt old
        // connections; see the test above.
        final compiled = ConfigCompiler.compile(
          multiFamilyContract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.ios,
        );
        final outbounds = (compiled['outbounds'] as List)
            .cast<Map<String, dynamic>>();
        final urltestGroups = outbounds.where((o) => o['type'] == 'urltest');
        expect(urltestGroups, isNotEmpty);
        for (final group in urltestGroups) {
          expect(
            group.containsKey('interrupt_exist_connections'),
            isFalse,
            reason: '${group['tag']} only ranks by latency and must not interrupt '
                'existing connections',
          );
        }

        // The same goes for the dual-path topology: urltest groups such as
        // relay-auto / home-auto must not carry it either.
        final dualCompiled = ConfigCompiler.compile(
          dualContract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.android,
        );
        final dualUrltestGroups = (dualCompiled['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .where((o) => o['type'] == 'urltest');
        expect(dualUrltestGroups, isNotEmpty);
        for (final group in dualUrltestGroups) {
          expect(
            group.containsKey('interrupt_exist_connections'),
            isFalse,
            reason: '${group['tag']} only ranks by latency and must not interrupt '
                'existing connections',
          );
        }
      },
    );

    // C1: the client-side line of defence. The builder writes via:"foreign" on an
    // overseas exit, but the builder can be bypassed (a hand-pasted contract), and
    // such a node has neither via nor detour. It must never fall into via-direct,
    // otherwise when the user locks Direct, sing-box picks the lowest latency
    // inside the group, an overseas VPS wins against the home node as seen from
    // inside China, and the exit ends up overseas.
    test('an unlabelled foreign exit never lands in the via-direct group', () {
      final handPastedForeignExit = {
        'id': 'sg-vps', 'name': 'Singapore VPS', 'role': 'relay',
        'protocol': 'shadowsocks-2022', 'server': '198.51.100.77', 'port': 8443,
        'params': {
          'method': '2022-blake3-aes-128-gcm',
          'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
          'multiplex': true,
        },
      };
      final compiled = ConfigCompiler.compile(
        AuroraContract.fromJson(
          familyContractJson(
            nodes: [relayEntry, homeReality, homeSs, homeViaRelay, handPastedForeignExit],
            outboundGroup: {
              'selector': {
                'tag': 'proxy',
                'members': [
                  'auto',
                  'home-reality',
                  'home-ss',
                  'home-via-relay',
                  'sg-vps',
                ],
                'default': 'auto',
              },
              'urltest': {
                'tag': 'auto',
                'members': ['home-reality', 'home-ss', 'home-via-relay', 'sg-vps'],
                'url': 'https://www.gstatic.com/generate_204',
                'interval': '3m',
              },
            },
          ),
        ),
        mode: AuroraMode.global,
        platform: AuroraPlatform.ios,
      );
      final outbounds = (compiled['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      final direct = outbounds.firstWhere((o) => o['tag'] == 'via-direct');
      expect(direct['outbounds'], ['home-reality', 'home-ss']);
      expect(direct['outbounds'], isNot(contains('sg-vps')));
      // It is still selectable (that is what allow_foreign_egress in the contract
      // means), it just forms a family of its own and does not appear under
      // "Direct" in the UI.
      final unspecified = outbounds.firstWhere(
        (o) => o['tag'] == 'via-$auroraUnspecifiedRouteFamily',
      );
      expect(unspecified['outbounds'], ['sg-vps']);
    });

    test('a single-family contract gets no family groups', () {
      final compiled = ConfigCompiler.compile(
        singleFamilyContract,
        mode: AuroraMode.global,
        platform: AuroraPlatform.ios,
      );
      final tags = (compiled['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags.where((t) => t.toString().startsWith('via-')), isEmpty);
    });

    test('a family tag colliding with a node id is fatal', () {
      expect(
        () => ConfigCompiler.compile(
          collidingContract,
          mode: AuroraMode.global,
          platform: AuroraPlatform.ios,
        ),
        throwsArgumentError,
      );
    });
  });

  group('urltest interval cap', () {
    test('3m is capped to 60s: a dead leg costs at most a minute, not three', () {
      expect(ConfigCompiler.capUrltestInterval('3m'), '60s');
    });

    test('an interval below the cap follows the contract; the compiler only tightens', () {
      expect(ConfigCompiler.capUrltestInterval('30s'), '30s');
    });

    test('an unparsable interval falls back to the cap instead of passing through to the core', () {
      expect(ConfigCompiler.capUrltestInterval('nonsense'), '60s');
      expect(ConfigCompiler.capUrltestInterval(''), '60s');
    });
  });

  // Regression note: this file used to have a group('interrupt_exist_connections',
  // ...) asserting that "every selector or urltest group must interrupt old
  // connections". That assertion was itself what let the regression through
  // (selector and urltest have different reselection semantics, see above). It is
  // now split into two more precise tests inside group('route family groups
  // (legacy/flat shape)', ...), right next to the multiFamilyContract they reuse:
  //   - 'selector (proxy) reselection interrupts old connections: ...'
  //   - 'urltest groups (auto/via-*/dual path) never interrupt old connections ...'
  // Do not add the "unified assertion" back here; that is exactly the regression
  // this file guards against.

  group('linux platform', () {
    AuroraContract flat() => AuroraContract.fromJson(
      jsonDecode(File('test/fixtures/contract.sample.json').readAsStringSync())
          as Map<String, dynamic>,
    );

    test('linux TUN matches windows and both have a fixed interface name', () {
      final linux = ConfigCompiler.compile(
        flat(),
        mode: AuroraMode.global,
        platform: AuroraPlatform.linux,
        clashApiSecret: 'deadbeef',
        clashApiPort: 41234,
      );
      final windows = ConfigCompiler.compile(
        flat(),
        mode: AuroraMode.global,
        platform: AuroraPlatform.windows,
        clashApiSecret: 'deadbeef',
        clashApiPort: 41234,
      );
      expect(linux['inbounds'], equals(windows['inbounds']));
      final tun = (linux['inbounds'] as List).first as Map<String, dynamic>;
      // Without a fixed name there is nothing to wait on until it disappears; see
      // waitForTunnelGone in aurora-svc.
      expect(tun['interface_name'], 'aurora0');
    });

    test('mobile writes no interface name: the platform creates it, so renaming is pointless and risky', () {
      final android = ConfigCompiler.compile(
        flat(),
        mode: AuroraMode.global,
        platform: AuroraPlatform.android,
      );
      final tun = (android['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun.containsKey('interface_name'), isFalse);
    });

    test('the Clash API port varies per connection and is no longer fixed at 9090', () {
      final cfg = ConfigCompiler.compile(
        flat(),
        mode: AuroraMode.global,
        platform: AuroraPlatform.linux,
        clashApiSecret: 'deadbeef',
        clashApiPort: 41234,
      );
      final api =
          ((cfg['experimental'] as Map)['clash_api'] as Map<String, dynamic>);
      expect(api['external_controller'], '127.0.0.1:41234');
      expect(api['secret'], 'deadbeef');
    });

    test('non-svc platforms still reject clashApiSecret', () {
      expect(
        () => ConfigCompiler.compile(
          flat(),
          mode: AuroraMode.global,
          platform: AuroraPlatform.android,
          clashApiSecret: 'deadbeef',
        ),
        throwsArgumentError,
      );
    });
  });
}
