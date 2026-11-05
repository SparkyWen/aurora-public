import 'package:aurora/core/contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dual-path contract', () {
    test('legacy contract leaves every additive path field disabled', () {
      final contract = AuroraContract.fromJson(_legacyContract());

      expect(contract.paths, isNull);
      expect(contract.pathPolicy, isNull);
      expect(contract.egress, isNull);
      expect(contract.defaultMode, 'global');
      expect(contract.outboundGroup.urltestTag, 'auto');
    });

    test('parses paths, health thresholds, and egress identity', () {
      final contract = AuroraContract.fromJson(_dualPathContract());

      expect(contract.paths!.items.keys, orderedEquals(['relay', 'home']));
      expect(contract.paths!.preferred, 'relay');
      expect(contract.paths!.items['relay']!.groupTag, 'relay-auto');
      expect(
        contract.paths!.items['relay']!.members,
        orderedEquals(['home-via-relay-reality']),
      );
      expect(contract.pathPolicy!.mode, 'prefer_relay');
      expect(contract.pathPolicy!.fallback, 'home');
      expect(contract.pathPolicy!.fallbackOrder, ['home']);
      expect(contract.pathPolicy!.health.rollingWindow, 5);
      expect(contract.pathPolicy!.health.minimumSuccessRate, 0.70);
      expect(contract.pathPolicy!.health.hardFailureRounds, 2);
      expect(contract.pathPolicy!.health.performanceFailureRounds, 3);
      expect(contract.pathPolicy!.health.latencyRatio, 2.0);
      expect(contract.pathPolicy!.health.latencyDeltaMs, 250);
      expect(contract.pathPolicy!.health.recoveryRounds, 3);
      expect(
        contract.pathPolicy!.health.recoveryHold,
        const Duration(seconds: 120),
      );
      expect(
        contract.pathPolicy!.health.flapWindow,
        const Duration(seconds: 600),
      );
      expect(contract.pathPolicy!.health.flapThreshold, 2);
      expect(
        contract.pathPolicy!.health.flapCooldown,
        const Duration(seconds: 900),
      );
      expect(contract.egress!.expectedIpv4, '203.0.113.9');
      expect(contract.egress!.expectedCountry, 'US');
      expect(contract.egress!.expectedAsn, 'AS64496');
    });

    test('parses ordered three-path fallback and signed lease metadata', () {
      final contract = AuroraContract.fromJson(_threePathContract());

      expect(
        contract.paths!.items.keys,
        orderedEquals(['relay_public', 'relay_tailnet', 'home']),
      );
      expect(contract.paths!.preferred, 'relay_public');
      expect(contract.pathPolicy!.fallbackOrder, ['relay_tailnet', 'home']);
      expect(contract.pathPolicy!.fallback, 'home');
      expect(contract.egress!.hasSignedLease, isTrue);
      expect(
        contract.egress!.leaseUrl.toString(),
        'https://control.example.net/v2/egress-lease',
      );
      expect(contract.egress!.leaseKeyId, 'home-egress-1');
      expect(contract.egress!.homeName, 'home.example.net');
      expect(contract.egress!.expectedIpv4, '8.8.4.4');
    });

    test('rejects a preferred path not declared in paths', () {
      final json = _dualPathContract();
      (json['paths'] as Map<String, dynamic>)['preferred'] = 'tokyo';

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects identical preferred and fallback paths', () {
      final json = _dualPathContract();
      (json['path_policy'] as Map<String, dynamic>)['fallback'] = 'relay';

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects duplicate path group tags', () {
      final json = _dualPathContract();
      final paths = json['paths'] as Map<String, dynamic>;
      final items = paths['items'] as Map<String, dynamic>;
      (items['home'] as Map<String, dynamic>)['group_tag'] = 'relay-auto';

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty path member list', () {
      final json = _dualPathContract();
      final paths = json['paths'] as Map<String, dynamic>;
      final items = paths['items'] as Map<String, dynamic>;
      (items['relay'] as Map<String, dynamic>)['members'] = <String>[];

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an invalid expected egress IPv4', () {
      final json = _dualPathContract();
      (json['egress'] as Map<String, dynamic>)['expected_ipv4'] = '999.2.3.4';

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects health thresholds outside their safe range', () {
      final json = _dualPathContract();
      final policy = json['path_policy'] as Map<String, dynamic>;
      final health = policy['health'] as Map<String, dynamic>;
      health['min_success_rate'] = 1.1;

      expect(
        () => AuroraContract.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects duplicate, unknown, or inconsistent fallback order', () {
      for (final order in <List<String>>[
        ['relay_tailnet', 'relay_tailnet', 'home'],
        ['unknown', 'home'],
        ['relay_public', 'home'],
        ['home', 'relay_tailnet'],
      ]) {
        final json = _threePathContract();
        (json['path_policy'] as Map<String, dynamic>)['fallback_order'] = order;
        expect(
          () => AuroraContract.fromJson(json),
          throwsA(isA<ArgumentError>()),
          reason: 'unsafe fallback order $order passed',
        );
      }
    });

    test('rejects path members that are missing, repeated, or entry nodes', () {
      final missing = _threePathContract();
      final missingItems =
          ((missing['paths'] as Map)['items'] as Map<String, dynamic>);
      (missingItems['home'] as Map<String, dynamic>)['members'] = ['absent'];
      expect(() => AuroraContract.fromJson(missing), throwsArgumentError);

      final repeated = _threePathContract();
      final repeatedItems =
          ((repeated['paths'] as Map)['items'] as Map<String, dynamic>);
      (repeatedItems['relay_tailnet'] as Map<String, dynamic>)['members'] = [
        'home-via-relay-public-reality',
      ];
      expect(() => AuroraContract.fromJson(repeated), throwsArgumentError);

      final entry = _threePathContract();
      final entryItems =
          ((entry['paths'] as Map)['items'] as Map<String, dynamic>);
      (entryItems['relay_public'] as Map<String, dynamic>)['members'] = [
        'relay-entry-reality',
      ];
      expect(() => AuroraContract.fromJson(entry), throwsArgumentError);
    });

    test('rejects detours that do not reference entry nodes', () {
      final json = _threePathContract();
      final nodes = json['nodes'] as List<Map<String, Object>>;
      final chained = nodes.firstWhere(
        (node) => node['id'] == 'home-via-relay-public-reality',
      );
      chained['detour'] = 'home-reality';
      expect(() => AuroraContract.fromJson(json), throwsArgumentError);
    });

    test('rejects legacy groups that expose relay entry transports', () {
      final json = _threePathContract();
      final group = json['outbound_group'] as Map<String, dynamic>;
      final selector = group['selector'] as Map<String, dynamic>;
      selector['members'] = ['auto', 'home-reality', 'relay-entry-reality'];
      expect(() => AuroraContract.fromJson(json), throwsArgumentError);
    });
  });

  group('route families', () {
    Map<String, dynamic> nodeMap(
      String id, {
      String? via,
      String? detour,
      String role = 'exit',
    }) => {
      'id': id,
      'role': role,
      'protocol': 'shadowsocks-2022',
      'server': 'example.net',
      'port': 2053,
      'via': ?via,
      'detour': ?detour,
      'params': const {'method': '2022-blake3-aes-128-gcm', 'password': 'x'},
    };

    test('explicit via wins', () {
      expect(
        AuroraNode.fromJson(nodeMap('a', via: 'relay', detour: 'entry')).via,
        'relay',
      );
    });

    // C1: having no detour only proves "no relay hop", not "lands at the home
    // node". An overseas exit added to the contract by hand has no detour either.
    // If it were inferred as direct it would sit next to the home node in the
    // "direct" group; when the user pins "direct", sing-box picks the lowest
    // latency, and an overseas VPS seen from China will always beat the home IP, so
    // the exit silently moves overseas while the UI says "direct".
    test('a node with no detour is NOT assumed to be a direct-home exit', () {
      expect(
        AuroraNode.fromJson(nodeMap('a')).via,
        auroraUnspecifiedRouteFamily,
      );
      expect(AuroraNode.fromJson(nodeMap('a')).via, isNot('direct'));
    });

    test('direct is only ever a declared family, never an inferred one', () {
      // The builder writes via:direct on home nodes; that is the only legitimate
      // source of membership in the "direct" group.
      final home = AuroraNode.fromJson(nodeMap('home-ss', via: 'direct'));
      // An overseas exit pasted into the contract by hand: no via and no detour.
      final foreign = AuroraNode.fromJson(nodeMap('sg-vps'));
      final contract = AuroraContract.fromJson({
        'version': 1,
        'nodes': [nodeMap('home-ss', via: 'direct'), nodeMap('sg-vps')],
        'outbound_group': {
          'selector': {
            'tag': 'proxy',
            'members': ['auto', 'home-ss', 'sg-vps'],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-ss', 'sg-vps'],
          },
        },
      });
      expect(home.via, 'direct');
      expect(foreign.via, isNot('direct'));
      expect(contract.nodesByFamily['direct'], ['home-ss']);
      expect(contract.nodesByFamily['direct'], isNot(contains('sg-vps')));
    });

    test('a chained node with no declared family is a relay', () {
      expect(AuroraNode.fromJson(nodeMap('a', detour: 'entry')).via, 'relay');
    });

    test('families are listed in a stable order and exclude entries', () {
      final contract = AuroraContract.fromJson({
        'version': 1,
        'nodes': [
          nodeMap('cdn-edge', via: 'cdn', role: 'entry'),
          nodeMap('home-via-cdn', via: 'cdn', detour: 'cdn-edge'),
          nodeMap('home-ss', via: 'direct'),
          nodeMap('home-via-relay', via: 'relay', detour: 'cdn-edge'),
        ],
        'outbound_group': {
          'selector': {
            'tag': 'proxy',
            'members': ['auto', 'home-ss', 'home-via-relay', 'home-via-cdn'],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-ss', 'home-via-relay', 'home-via-cdn'],
          },
        },
      });
      expect(contract.routeFamilies, ['direct', 'relay', 'cdn']);
      expect(contract.nodesByFamily['direct'], ['home-ss']);
      expect(contract.nodesByFamily['cdn'], ['home-via-cdn']);
      expect(contract.nodesByFamily.containsKey('entry'), isFalse);
    });
  });
}

Map<String, dynamic> _legacyContract() => {
  'version': 1,
  'profile': {'default_mode': 'global'},
  'nodes': [
    {
      'id': 'home-reality',
      'role': 'primary',
      'protocol': 'vless-reality',
      'server': '203.0.113.7',
      'port': 443,
      'params': <String, dynamic>{},
    },
  ],
  'outbound_group': {
    'selector': {
      'tag': 'proxy',
      'members': ['auto', 'home-reality'],
      'default': 'auto',
    },
    'urltest': {
      'tag': 'auto',
      'members': ['home-reality'],
      'url': 'https://www.gstatic.com/generate_204',
      'interval': '3m',
    },
  },
};

Map<String, dynamic> _dualPathContract() {
  final json = _legacyContract();
  (json['nodes'] as List<Map<String, Object>>).addAll(<Map<String, Object>>[
    {
      'id': 'relay-entry-reality',
      'role': 'entry',
      'protocol': 'vless-reality',
      'server': '198.51.100.8',
      'port': 443,
      'params': <String, dynamic>{},
    },
    {
      'id': 'home-via-relay-reality',
      'role': 'primary',
      'protocol': 'shadowsocks-2022',
      'server': '100.64.0.26',
      'port': 8388,
      'detour': 'relay-entry-reality',
      'params': <String, dynamic>{},
    },
  ]);
  json['paths'] = {
    'preferred': 'relay',
    'items': {
      'relay': {
        'group_tag': 'relay-auto',
        'members': ['home-via-relay-reality'],
      },
      'home': {
        'group_tag': 'home-auto',
        'members': ['home-reality'],
      },
    },
  };
  json['path_policy'] = {
    'mode': 'prefer_relay',
    'fallback': 'home',
    'health': {
      'rolling_window': 5,
      'min_success_rate': 0.70,
      'hard_fail_rounds': 2,
      'performance_fail_rounds': 3,
      'latency_ratio': 2.0,
      'latency_delta_ms': 250,
      'recovery_success_rounds': 3,
      'recovery_stable_seconds': 120,
      'flap_window_seconds': 600,
      'flap_limit': 2,
      'flap_cooldown_seconds': 900,
    },
  };
  json['egress'] = {
    'expected_ipv4': '203.0.113.9',
    'expected_country': 'US',
    'expected_asn': 'AS64496',
  };
  return json;
}

Map<String, dynamic> _threePathContract() {
  final json = _dualPathContract();
  final nodes = json['nodes'] as List<Map<String, Object>>;
  final publicNode = nodes.firstWhere(
    (node) => node['id'] == 'home-via-relay-reality',
  );
  publicNode['id'] = 'home-via-relay-public-reality';
  publicNode['server'] = 'home.example.net';
  publicNode['port'] = 2053;
  nodes.add({
    'id': 'home-via-relay-tailnet-reality',
    'role': 'primary',
    'protocol': 'shadowsocks-2022',
    'server': '100.64.0.26',
    'port': 8388,
    'detour': 'relay-entry-reality',
    'params': <String, dynamic>{},
  });
  json['paths'] = {
    'preferred': 'relay_public',
    'items': {
      'relay_public': {
        'group_tag': 'relay-public-auto',
        'members': ['home-via-relay-public-reality'],
      },
      'relay_tailnet': {
        'group_tag': 'relay-tailnet-auto',
        'members': ['home-via-relay-tailnet-reality'],
      },
      'home': {
        'group_tag': 'home-auto',
        'members': ['home-reality'],
      },
    },
  };
  final policy = json['path_policy'] as Map<String, dynamic>;
  policy['fallback_order'] = ['relay_tailnet', 'home'];
  json['egress'] = {
    'bootstrap_ipv4': '8.8.4.4',
    'lease_url': 'https://control.example.net/v2/egress-lease',
    'lease_key_id': 'home-egress-1',
    'lease_public_key': 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
    'home_name': 'home.example.net',
    'expected_country': 'US',
    'expected_asn': 'AS64496',
  };
  return json;
}
