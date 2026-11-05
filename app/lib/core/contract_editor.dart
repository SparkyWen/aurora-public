/// Builds and edits a contract from imported servers.
///
/// The contract stays the app's single source of truth. Servers are not stored
/// separately: each node carries the `group` of the server it came from, so
/// adding, replacing and removing servers are all plain edits of one document.
///
/// Pure Dart: no Flutter imports (`app/lib/cli/` depends on this).
library;

import 'dart:convert';

import 'contract.dart';
import 'link_parser.dart';
import 'server_bundle.dart';

/// Group assigned to plain `vless://`-style links and nodes without one.
const auroraImportedGroup = 'imported';

/// One imported server as shown in the server list.
class ContractServer {
  const ContractServer({
    required this.group,
    required this.host,
    required this.nodeCount,
  });

  final String group;
  final String host;
  final int nodeCount;
}

/// What pasted text turned out to contain.
class ImportPlan {
  const ImportPlan({this.contractJson, this.delivery, this.added = const []});

  /// The full contract to store, when the text was applied locally.
  final String? contractJson;

  /// A control plane to fetch from. The caller has the network; this module does not.
  final DeliveryLink? delivery;

  /// Names of the servers this import added or replaced.
  final List<String> added;
}

class ContractEditor {
  ContractEditor._();

  /// Works out what [text] means against the [currentJson] contract (if any).
  ///
  /// Accepts a whole contract JSON document (replaces everything), `aurora://`
  /// links and plain share links (merged, one per line).
  ///
  /// Throws [AuroraLinkException] with a message fit to show the user.
  static ImportPlan plan(String? currentJson, String text, {DateTime? now}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const AuroraLinkException('Paste a link first.');
    }
    if (trimmed.startsWith('{')) {
      return _planWholeContract(trimmed);
    }

    final bundles = <ServerBundle>[];
    final plainLines = <String>[];
    for (final raw in const LineSplitter().convert(trimmed)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith(auroraLinkPrefix)) {
        final link = AuroraLink.parse(line);
        switch (link) {
          case DeliveryLink():
            return ImportPlan(delivery: link);
          case ServerBundle():
            bundles.add(link);
        }
      } else {
        plainLines.add(line);
      }
    }
    final plainNodes = LinkParser.parseNodes(plainLines.join('\n'));
    if (bundles.isEmpty && plainNodes.isEmpty) {
      throw const AuroraLinkException(
        'No server found. Expected a link printed by install.sh.',
      );
    }

    final updated = merge(
      currentJson == null ? null : _decode(currentJson),
      bundles: bundles,
      plainNodes: plainNodes,
      now: now,
    );
    return ImportPlan(
      contractJson: json.encode(updated),
      added: [
        ...bundles.map((bundle) => bundle.name),
        if (plainNodes.isNotEmpty) auroraImportedGroup,
      ],
    );
  }

  static ImportPlan _planWholeContract(String text) {
    try {
      AuroraContract.fromJson(_decode(text));
    } catch (_) {
      // Parser errors can quote the document, which holds node credentials.
      throw const AuroraLinkException('That is not a valid Aurora contract.');
    }
    return ImportPlan(contractJson: text);
  }

  /// Adds servers to [current], replacing any with the same name so re-importing
  /// after `aurora-node rotate` simply updates the credentials.
  static Map<String, dynamic> merge(
    Map<String, dynamic>? current, {
    List<ServerBundle> bundles = const [],
    List<Map<String, dynamic>> plainNodes = const [],
    DateTime? now,
  }) {
    if (current != null && current['paths'] != null) {
      // A multi-path contract ties its nodes to a health policy. Merging into it
      // would silently produce a contract that policy never described.
      throw const AuroraLinkException(
        'Your current contract uses advanced path routing, which cannot be '
        'merged. Remove all servers first, or edit the contract directly.',
      );
    }
    final contract = current == null
        ? _skeleton()
        : Map<String, dynamic>.from(current);
    var nodes = [
      for (final node in (contract['nodes'] as List? ?? const []))
        Map<String, dynamic>.from(node as Map),
    ];
    for (final bundle in bundles) {
      nodes = [
        ...nodes.where((node) => groupOf(node) != bundle.name),
        ...bundle.toNodes(),
      ];
    }
    if (plainNodes.isNotEmpty) {
      final incoming = plainNodes.map((node) => node['id']).toSet();
      nodes = [
        ...nodes.where((node) => !incoming.contains(node['id'])),
        ...plainNodes,
      ];
    }
    contract['nodes'] = nodes;
    _rebuildGroups(contract);

    final profile = Map<String, dynamic>.from(
      contract['profile'] as Map? ?? const {},
    );
    // A relay exists because the direct path to the home node was unreliable,
    // so it becomes the default route. Otherwise the first server added stays
    // the default, so adding a second exit never silently moves the public IP.
    for (final bundle in bundles) {
      if (bundle.isRelay || profile['default_family'] == null) {
        profile['default_family'] = bundle.name;
      }
    }
    contract['profile'] = profile;
    _touch(contract, now);
    return contract;
  }

  /// Removes one server. Returns null when nothing is left, which means the app
  /// is back to its first-run state.
  static Map<String, dynamic>? removeServer(
    Map<String, dynamic> current,
    String group, {
    DateTime? now,
  }) {
    final contract = Map<String, dynamic>.from(current);
    final nodes = [
      for (final node in (contract['nodes'] as List? ?? const []))
        Map<String, dynamic>.from(node as Map),
    ].where((node) => groupOf(node) != group).toList();
    if (nodes.where((node) => node['role'] != 'entry').isEmpty) return null;
    contract['nodes'] = nodes;
    _rebuildGroups(contract);
    final profile = Map<String, dynamic>.from(
      contract['profile'] as Map? ?? const {},
    );
    if (profile['default_family'] == group) profile.remove('default_family');
    contract['profile'] = profile;
    _touch(contract, now);
    return contract;
  }

  static List<ContractServer> listServers(Map<String, dynamic> contract) {
    final counts = <String, int>{};
    final hosts = <String, String>{};
    for (final raw in (contract['nodes'] as List? ?? const [])) {
      final node = Map<String, dynamic>.from(raw as Map);
      final group = groupOf(node);
      counts[group] = (counts[group] ?? 0) + 1;
      // Entries hold the address a relay is reached at; a chained exit would
      // show the home node's address instead.
      if (node['detour'] == null) {
        hosts.putIfAbsent(group, () => '${node['server']}');
      }
    }
    return [
      for (final group in counts.keys)
        ContractServer(
          group: group,
          host: hosts[group] ?? '',
          nodeCount: counts[group]!,
        ),
    ];
  }

  static String groupOf(Map<String, dynamic> node) =>
      (node['group'] as String?) ??
      (node['via'] as String?) ??
      auroraImportedGroup;

  static Map<String, dynamic> _skeleton() => {
    'version': 1,
    'profile': {'name': 'Aurora', 'default_mode': 'global'},
    'network': {'mtu': 1400, 'ipv6_mode': 'block', 'suppress_https_rr': false},
    'nodes': <Map<String, dynamic>>[],
  };

  static void _rebuildGroups(Map<String, dynamic> contract) {
    final exits = [
      for (final node in contract['nodes'] as List)
        if ((node as Map)['role'] != 'entry') node['id'] as String,
    ];
    contract['outbound_group'] = {
      'selector': {
        'tag': 'proxy',
        'members': ['auto', ...exits],
        'default': 'auto',
      },
      'urltest': {
        'tag': 'auto',
        'members': exits,
        'url': 'https://www.gstatic.com/generate_204',
        'interval': '3m',
      },
    };
  }

  static void _touch(Map<String, dynamic> contract, DateTime? now) {
    final clock = (now ?? DateTime.now()).toUtc();
    contract['revision'] = clock.millisecondsSinceEpoch;
    contract['updated'] = clock.toIso8601String();
  }

  static Map<String, dynamic> _decode(String text) =>
      Map<String, dynamic>.from(json.decode(text) as Map);
}
