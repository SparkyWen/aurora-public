import 'dart:convert';

/// Parses `vless://` / `hysteria2://` / `ss://` share links (the `links.txt`
/// format the VPS emits) into an Aurora contract JSON map the ConfigCompiler
/// understands. Lines starting with `#` and blanks are ignored.
class LinkParser {
  /// The nodes in [text], tagged with the `imported` group and route family.
  ///
  /// A plain share link says nothing about where its traffic exits, so these are
  /// kept apart from servers set up by `install.sh` rather than guessed into a
  /// family they might not belong to.
  static List<Map<String, dynamic>> parseNodes(String text) {
    final nodes = <Map<String, dynamic>>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final node = _parseNode(line);
      if (node != null) {
        nodes.add({...node, 'group': 'imported', 'via': 'imported'});
      }
    }
    return nodes;
  }

  /// Returns a contract-shaped map, or null if no node lines parsed.
  static Map<String, dynamic>? parseToContract(String text) {
    final nodes = parseNodes(text);
    if (nodes.isEmpty) return null;
    final ids = nodes.map((n) => n['id'] as String).toList();
    return {
      'version': 1,
      'profile': {'name': 'Aurora', 'default_mode': 'smart'},
      'network': {
        'mtu': 1400,
        'ipv6_mode': 'block',
        'suppress_https_rr': false,
      },
      'nodes': nodes,
      'outbound_group': {
        'selector': {
          'tag': 'proxy',
          'members': ['auto', ...ids],
          'default': 'auto',
        },
        'urltest': {
          'tag': 'auto',
          'members': ids,
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '3m',
        },
      },
    };
  }

  static Map<String, dynamic>? _parseNode(String line) {
    final uri = Uri.tryParse(line);
    if (uri == null || uri.host.isEmpty) return null;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : uri.scheme;
    final id = _slug(name);
    final q = uri.queryParameters;
    switch (uri.scheme) {
      case 'vless':
        return {
          'id': id,
          'name': name,
          'role': 'primary',
          'protocol': 'vless-reality',
          'server': uri.host,
          'port': uri.port,
          'params': {
            'uuid': uri.userInfo,
            'flow': q['flow'] ?? 'xtls-rprx-vision',
            'sni': q['sni'],
            'public_key': q['pbk'],
            'short_id': q['sid'],
            'fingerprint': q['fp'] ?? 'chrome',
          },
        };
      case 'hysteria2':
      case 'hy2':
        return {
          'id': id,
          'name': name,
          'role': 'fast',
          'protocol': 'hysteria2',
          'server': uri.host,
          'port': uri.port,
          'params': {
            'password': uri.userInfo,
            'sni': q['sni'],
            'insecure': q['insecure'] == '1' || q['insecure'] == 'true',
            'alpn': (q['alpn'] ?? 'h3').split(','),
          },
        };
      case 'ss':
        final (method, password) = _decodeSsUserInfo(uri.userInfo);
        if (method == null) return null;
        return {
          'id': id,
          'name': name,
          'role': 'backup',
          'protocol': 'shadowsocks-2022',
          'server': uri.host,
          'port': uri.port,
          'params': {'method': method, 'password': password, 'multiplex': true},
        };
      default:
        return null;
    }
  }

  /// SIP002 userinfo is base64url(method:password); some clients send it raw.
  static (String?, String?) _decodeSsUserInfo(String userInfo) {
    String candidate;
    try {
      candidate = utf8.decode(base64.decode(_b64pad(userInfo)));
    } catch (_) {
      candidate = Uri.decodeComponent(userInfo);
    }
    final i = candidate.indexOf(':');
    if (i < 0) return (null, null);
    return (candidate.substring(0, i), candidate.substring(i + 1));
  }

  static String _b64pad(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return t;
  }

  static String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
