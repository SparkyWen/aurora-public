import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/route_family.dart';
import 'package:flutter_test/flutter_test.dart';

/// A flat contract (route families are told apart by `via`), the common shape.
AuroraContract flatContract({
  List<String> families = const ['direct', 'relay', 'cdn'],
}) {
  final nodes = [
    for (final family in families)
      AuroraNode(
        id: 'home-via-$family',
        role: 'proxy',
        protocol: 'hysteria2',
        server: 'example.invalid',
        port: 443,
        params: const {},
        via: family,
      ),
  ];
  final ids = nodes.map((node) => node.id).toList();
  return AuroraContract(
    version: 1,
    revision: 3,
    updated: '2026-08-04T00:00:00Z',
    defaultMode: 'smart',
    nodes: nodes,
    outboundGroup: OutboundGroup(
      selectorTag: 'proxy',
      selectorMembers: ['auto', ...ids],
      selectorDefault: 'auto',
      urltestTag: 'auto',
      urltestMembers: ids,
      urltestUrl: 'https://www.gstatic.com/generate_204',
      urltestInterval: '60s',
    ),
  );
}

/// A three-path contract (relay_public / relay_tailnet / home); the selector
/// defaults to fail-closed.
AuroraContract pathContract() => AuroraContract.fromJson(
  json.decode(File('test/fixtures/path-contract.json').readAsStringSync())
      as Map<String, dynamic>,
);

void main() {
  _defaultsGroup();

  test('flat contract: the default lands on the via-relay group', () {
    final target = resolveDefaultRouteTarget(flatContract());

    expect(target.groupTag, 'via-relay');
    expect(target.isPreferred, isTrue);
  });

  test('path contract: the default lands on the preferred relay_public group', () {
    final target = resolveDefaultRouteTarget(pathContract());

    expect(target.groupTag, 'relay-public-auto');
    expect(target.isPreferred, isTrue);
  });

  test('a contract with no relay falls back to automatic selection', () {
    final target = resolveDefaultRouteTarget(flatContract(families: ['direct']));

    expect(target.groupTag, 'auto');
    expect(target.label, 'automatic selection');
    // Automatic selection is a normal default for a contract with no relay.
    expect(target.isPreferred, isTrue);
  });

  test('a declared default_family wins over the relay family', () {
    final base = flatContract();
    final contract = AuroraContract(
      version: base.version,
      revision: base.revision,
      updated: base.updated,
      defaultMode: base.defaultMode,
      nodes: base.nodes,
      outboundGroup: base.outboundGroup,
      defaultFamily: 'cdn',
    );

    final target = resolveDefaultRouteTarget(contract);

    expect(target.groupTag, 'via-cdn');
    expect(target.family, 'cdn');
    expect(target.label, 'CDN');
    expect(target.isPreferred, isTrue);
  });

  test('a default_family the compiler would not emit is skipped for relay', () {
    final base = flatContract();
    final contract = AuroraContract(
      version: base.version,
      revision: base.revision,
      updated: base.updated,
      defaultMode: base.defaultMode,
      nodes: base.nodes,
      outboundGroup: base.outboundGroup,
      defaultFamily: 'nowhere',
    );

    expect(resolveDefaultRouteTarget(contract).groupTag, 'via-relay');
  });

  test('a path contract without a relay path warns that it is not preferred', () {
    final raw =
        json.decode(File('test/fixtures/path-contract.json').readAsStringSync())
            as Map<String, dynamic>;
    // Rename the two relay paths so that no path id starts with "relay".
    final paths = (raw['paths'] as Map).cast<String, dynamic>();
    final items = (paths['items'] as Map).cast<String, dynamic>();
    items['alpha'] = items.remove('relay_public');
    items['beta'] = items.remove('relay_tailnet');
    paths['preferred'] = 'alpha';
    raw['path_policy'] = {
      ...(raw['path_policy'] as Map).cast<String, dynamic>(),
      'fallback': 'home',
      'fallback_order': ['beta', 'home'],
    };
    final contract = AuroraContract.fromJson(raw);

    final target = resolveDefaultRouteTarget(contract);

    expect(target.label, 'preferred path alpha');
    expect(target.isPreferred, isFalse);
  });

  test('a declared relay family that the compiler would not emit falls back to auto', () {
    // renderableRouteFamilies requires a family's members to intersect
    // urltest.members. Without an intersection the compiler skips the whole family,
    // so selecting via-relay would fail because the tag does not exist.
    final contract = flatContract();
    final crippled = AuroraContract(
      version: contract.version,
      revision: contract.revision,
      updated: contract.updated,
      defaultMode: contract.defaultMode,
      nodes: contract.nodes,
      outboundGroup: OutboundGroup(
        selectorTag: 'proxy',
        selectorMembers: const ['auto', 'home-via-direct'],
        selectorDefault: 'auto',
        urltestTag: 'auto',
        urltestMembers: const ['home-via-direct'],
        urltestUrl: 'https://www.gstatic.com/generate_204',
        urltestInterval: '60s',
      ),
    );

    final target = resolveDefaultRouteTarget(crippled);

    expect(target.groupTag, 'auto');
    expect(target.isPreferred, isTrue);
  });
}

/// The default target when nothing is saved: the GUI and the command line must land
/// on the same place, which is global mode on the relay family when there is one.
void _defaultsGroup() {
  group('defaults', () {
    test('with no saved mode the default is global, not the contract default_mode', () {
      expect(
        ConnectFlow.resolveMode(null, flatContract()),
        AuroraMode.global,
      );
    });

    test('a saved mode still wins over the default', () {
      expect(
        ConnectFlow.resolveMode('smart', flatContract()),
        AuroraMode.smart,
      );
    });

    test('with no saved route the relay family is locked by default', () {
      expect(ConnectFlow.resolveRouteFamily(null, flatContract()), 'relay');
    });

    test('with no saved route the contract default_family is locked', () {
      final base = flatContract();
      final contract = AuroraContract(
        version: base.version,
        revision: base.revision,
        updated: base.updated,
        defaultMode: base.defaultMode,
        nodes: base.nodes,
        outboundGroup: base.outboundGroup,
        defaultFamily: 'cdn',
      );

      expect(ConnectFlow.resolveRouteFamily(null, contract), 'cdn');
    });

    test('an explicitly saved "auto" stays automatic and is not taken back by the default', () {
      // This is what lets "switch back to automatic" be expressed at all: the saved
      // value must be able to say "I chose automatic", otherwise clearing it would
      // return to the default relay family.
      expect(ConnectFlow.resolveRouteFamily('auto', flatContract()), isNull);
    });

    test('without a relay family the default is automatic, not a missing group', () {
      expect(
        ConnectFlow.resolveRouteFamily(null, flatContract(families: ['direct'])),
        isNull,
      );
    });

    test('path contracts take no part in family locking (the path coordinator owns them)', () {
      expect(ConnectFlow.resolveRouteFamily(null, pathContract()), isNull);
    });
  });
}
