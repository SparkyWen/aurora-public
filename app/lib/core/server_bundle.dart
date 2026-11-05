/// The `aurora://v1/...` import link: what `install.sh` prints and the app adds.
///
/// The payload is base64url-encoded compact JSON. It stays compact because it has
/// to fit a QR code on an 80-column terminal, and it describes a server rather
/// than a contract, so one link can be merged with others. Expansion into contract
/// nodes happens here and only here, which keeps the installer free of contract
/// knowledge and gives the GUI and the CLI one implementation. See
/// `docs/contract.md`.
///
/// Pure Dart: no Flutter imports (`app/lib/cli/` depends on this).
library;

import 'dart:convert';

const auroraLinkPrefix = 'aurora://v1/';

const _ss2022Method = '2022-blake3-aes-128-gcm';

final _labelPattern = RegExp(r'^[a-z][a-z0-9-]{0,15}$');
final _hostPattern = RegExp(
  r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
);
final _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Thrown for anything wrong with a link. Messages never quote the payload: it
/// holds credentials and error text ends up on screen and in support bundles.
class AuroraLinkException implements Exception {
  const AuroraLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One parsed `aurora://v1/` link.
sealed class AuroraLink {
  const AuroraLink();

  /// Parses a whole link. The `#name` fragment is cosmetic; the name inside the
  /// payload is the one that counts.
  static AuroraLink parse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(auroraLinkPrefix)) {
      throw const AuroraLinkException('Not an aurora:// link.');
    }
    return _decode(trimmed.substring(auroraLinkPrefix.length).split('#').first);
  }

  /// Parses what the Flutter engine delivers for a deep link: `aurora://v1/<data>`
  /// arrives as the route `/<data>#<name>` because the scheme and host are dropped.
  static AuroraLink parseRoute(String routeName) {
    final path = routeName.split('#').first.split('?').first;
    return _decode(path.startsWith('/') ? path.substring(1) : path);
  }

  static AuroraLink _decode(String encoded) {
    if (encoded.isEmpty || !_base64UrlPattern.hasMatch(encoded)) {
      throw const AuroraLinkException(
        'This link is damaged. Copy the whole line again.',
      );
    }
    final Object? decoded;
    try {
      decoded = json.decode(
        utf8.decode(base64Url.decode(base64.normalize(encoded))),
      );
    } catch (_) {
      throw const AuroraLinkException(
        'This link is damaged. Copy the whole line again.',
      );
    }
    if (decoded is! Map) {
      throw const AuroraLinkException('This link has an unknown format.');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['v'] != 1) {
      throw const AuroraLinkException(
        'This link needs a newer version of Aurora.',
      );
    }
    return switch (map['kind']) {
      'vps' || 'home' || 'relay' => ServerBundle._fromJson(map),
      'delivery' => DeliveryLink._fromJson(map),
      _ => throw const AuroraLinkException('This link has an unknown format.'),
    };
  }
}

/// Points the app at a control plane and pins the key its contracts must carry.
///
/// Importing this is the trust decision: the user chose to paste it, and from
/// then on only contracts signed by [publicKey] are accepted from the network.
class DeliveryLink extends AuroraLink {
  const DeliveryLink({
    required this.url,
    required this.token,
    required this.keyId,
    required this.publicKey,
  });

  final String url;
  final String token;
  final String keyId;
  final String publicKey;

  factory DeliveryLink._fromJson(Map<String, dynamic> j) {
    final url = _string(j, 'url');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const AuroraLinkException('A delivery link must use https.');
    }
    return DeliveryLink(
      url: url,
      token: _string(j, 'token'),
      keyId: _string(j, 'key_id'),
      publicKey: _string(j, 'public_key'),
    );
  }

  String get host => Uri.parse(url).host;
}

/// A server set up by `install.sh`.
///
/// `vps` and `home` are terminal exits: traffic leaves from that machine. `relay`
/// is only a way in: its entries are chained to [exit], so traffic still leaves
/// from the home node and the relay only sees encrypted bytes it can forward to
/// one destination.
class ServerBundle extends AuroraLink {
  const ServerBundle._({
    required this.kind,
    required this.name,
    required this.host,
    required this.reality,
    required this.hysteria2,
    required this.shadowsocks,
    this.cdn,
    this.exit,
  });

  final String kind;
  final String name;
  final String host;
  final Map<String, dynamic> reality;
  final Map<String, dynamic> hysteria2;
  final Map<String, dynamic> shadowsocks;
  final Map<String, dynamic>? cdn;
  final Map<String, dynamic>? exit;

  bool get isRelay => kind == 'relay';

  /// Human-readable summary for the confirmation dialog.
  String get description => isRelay
      ? '$name ($host), forwarding to ${exit!['name']}'
      : '$name ($host)';

  factory ServerBundle._fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String;
    final name = _label(_string(j, 'name'));
    final host = _host(_string(j, 'host'));
    final reality = _section(j, 'reality');
    final hysteria2 = _section(j, 'hy2');
    final shadowsocks = _section(j, 'ss');
    _port(reality);
    _string(reality, 'uuid');
    _string(reality, 'pbk');
    _string(reality, 'sid');
    _string(reality, 'sni');
    _port(hysteria2);
    _string(hysteria2, 'password');
    _string(hysteria2, 'sni');
    _string(hysteria2, 'spki');
    _port(shadowsocks);
    _string(shadowsocks, 'password');
    Map<String, dynamic>? cdn;
    if (j['cdn'] != null) {
      cdn = _section(j, 'cdn');
      _host(_string(cdn, 'host'));
      _port(cdn);
      _string(cdn, 'uuid');
      _string(cdn, 'path');
    }
    Map<String, dynamic>? exit;
    if (kind == 'relay') {
      exit = _section(j, 'exit');
      _label(_string(exit, 'name'));
      _host(_string(exit, 'host'));
      _port(exit);
      _string(exit, 'password');
    }
    return ServerBundle._(
      kind: kind,
      name: name,
      host: host,
      reality: reality,
      hysteria2: hysteria2,
      shadowsocks: shadowsocks,
      cdn: cdn,
      exit: exit,
    );
  }

  List<Map<String, dynamic>> toNodes() {
    final transports = <String, Map<String, dynamic>>{
      'reality': _realityNode(),
      'hy2': _hysteria2Node(),
      'ss': _shadowsocksNode(),
      'cdn': ?_cdnNode(),
    };
    if (!isRelay) {
      return [
        for (final MapEntry(key: suffix, value: node) in transports.entries)
          {
            ...node,
            'id': '$name-$suffix',
            'name': '$name ${_title(suffix)}',
            'role': switch (suffix) {
              'hy2' => 'fast',
              'ss' => 'backup',
              _ => 'primary',
            },
            'via': name,
            'group': name,
          },
      ];
    }
    final target = exit!;
    final exitName = target['name'] as String;
    return [
      for (final MapEntry(key: suffix, value: node) in transports.entries) ...[
        // Never selectable: an entry only gets you in. A relay that could be an
        // exit would quietly move your public IP while the UI still looked fine.
        {
          ...node,
          'id': '$name-entry-$suffix',
          'name': '$name entry ${_title(suffix)}',
          'role': 'entry',
          'group': name,
        },
        {
          'id': '$exitName-via-$name-$suffix',
          'name': '$exitName via $name ${_title(suffix)}',
          'role': 'exit',
          'via': name,
          'group': name,
          'protocol': 'shadowsocks-2022',
          'server': target['host'],
          'port': target['port'],
          'detour': '$name-entry-$suffix',
          'params': {'method': _ss2022Method, 'password': target['password']},
        },
      ],
    ];
  }

  Map<String, dynamic> _realityNode() => {
    'protocol': 'vless-reality',
    'server': host,
    'port': reality['port'],
    'params': {
      'uuid': reality['uuid'],
      'flow': 'xtls-rprx-vision',
      'sni': reality['sni'],
      'public_key': reality['pbk'],
      'short_id': reality['sid'],
      'fingerprint': 'chrome',
    },
  };

  Map<String, dynamic> _hysteria2Node() {
    final port = hysteria2['port'];
    return {
      'protocol': 'hysteria2',
      'server': host,
      'port': port,
      'params': {
        'password': hysteria2['password'],
        'sni': hysteria2['sni'],
        'alpn': ['h3'],
        'certificate_public_key_sha256': hysteria2['spki'],
        // Source-port hopping on the one port known to be open. Some carriers
        // throttle UDP per flow, and a new source port is a new flow. Never list
        // ports nobody has verified from outside: the client hops blindly, so one
        // blocked port becomes a periodic outage.
        'server_ports': ['$port:$port'],
        'hop_interval': '10s',
      },
    };
  }

  Map<String, dynamic> _shadowsocksNode() => {
    'protocol': 'shadowsocks-2022',
    'server': host,
    'port': shadowsocks['port'],
    'params': {'method': _ss2022Method, 'password': shadowsocks['password']},
  };

  Map<String, dynamic>? _cdnNode() {
    final value = cdn;
    if (value == null) return null;
    return {
      'protocol': 'vless-ws-tls',
      'server': value['host'],
      'port': value['port'],
      'params': {
        'uuid': value['uuid'],
        'sni': value['host'],
        'path': value['path'],
        'fingerprint': 'chrome',
      },
    };
  }

  static String _title(String suffix) => switch (suffix) {
    'reality' => 'REALITY',
    'hy2' => 'Hysteria2',
    'ss' => 'Shadowsocks',
    'cdn' => 'CDN',
    _ => suffix,
  };
}

String _string(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! String || value.isEmpty) {
    throw AuroraLinkException('This link is incomplete (missing $key).');
  }
  return value;
}

Map<String, dynamic> _section(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! Map) {
    throw AuroraLinkException('This link is incomplete (missing $key).');
  }
  return Map<String, dynamic>.from(value);
}

void _port(Map<String, dynamic> j) {
  final value = j['port'];
  if (value is! int || value < 1 || value > 65535) {
    throw const AuroraLinkException('This link has an invalid port.');
  }
}

String _label(String value) {
  if (!_labelPattern.hasMatch(value)) {
    throw const AuroraLinkException('This link has an invalid server name.');
  }
  return value;
}

String _host(String value) {
  if (!_hostPattern.hasMatch(value)) {
    throw const AuroraLinkException('This link has an invalid address.');
  }
  return value;
}
