import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'aurora_bridge.dart';
import 'bounded_http.dart';

/// Talks to sing-box's Clash API (`experimental.clash_api`). All calls carry the
/// per-connection bearer secret. Only used by the Windows bridge (spec §4.4):
/// the app reads live status / traffic / node delays here and switches nodes,
/// instead of a libbox CommandClient (which is the mobile/macOS path).
class ClashApiClient {
  ClashApiClient({
    required this.base,
    required this.secret,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final Uri base;
  final String secret;
  final http.Client _http;

  Future<http.Response> _request(
    String method,
    Uri url, {
    Duration timeout = const Duration(seconds: 3),
    String? body,
  }) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $secret',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = body;
    final http.Response response;
    try {
      response = await boundedRequest(_http, request, timeout);
    } on TimeoutException {
      throw StateError('clash_request_timeout');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('clash_auth_failed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('clash_request_failed');
    }
    return response;
  }

  static Map<String, dynamic> _json(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

  /// True if the API answers — used by the bridge to derive the connected state.
  Future<bool> ping() async {
    try {
      final r = await _request(
        'GET',
        base.resolve('/version'),
        timeout: const Duration(seconds: 2),
      );
      return r.statusCode == 200;
    } on StateError catch (e) {
      if (e.message == 'clash_auth_failed') rethrow;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// One-shot cumulative traffic snapshot via `/connections`.
  Future<TrafficStat> traffic() async {
    final r = await _request('GET', base.resolve('/connections'));
    final m = _json(r);
    return TrafficStat(
      uplinkTotal: (m['uploadTotal'] as num?)?.toInt() ?? 0,
      downlinkTotal: (m['downloadTotal'] as num?)?.toInt() ?? 0,
    );
  }

  /// Outbound groups shaped like [OutboundGroupInfo]. A "group-like" proxy is one
  /// that carries an `all` member list (Selector/URLTest); delay for each member
  /// is the latest `history` entry. Parsing is pure and unit-tested.
  Future<List<OutboundGroupInfo>> groups() async {
    final r = await _request('GET', base.resolve('/proxies'));
    return parseGroups(_json(r));
  }

  /// Pure JSON → groups transform (separated so it can be tested without HTTP).
  static List<OutboundGroupInfo> parseGroups(Map<String, dynamic> body) {
    final proxies = body['proxies'] as Map<String, dynamic>? ?? const {};
    int delayOf(String name) {
      final p = proxies[name] as Map<String, dynamic>?;
      final hist = (p?['history'] as List?) ?? const [];
      if (hist.isEmpty) return 0;
      return ((hist.last as Map)['delay'] as num?)?.toInt() ?? 0;
    }

    final groups = <OutboundGroupInfo>[];
    proxies.forEach((name, raw) {
      final p = raw as Map<String, dynamic>;
      final type = p['type'] as String? ?? '';
      final all = (p['all'] as List?)?.cast<String>();
      if (all == null) return; // only group-like entries carry "all"
      groups.add(
        OutboundGroupInfo(
          tag: name,
          type: type,
          selected: p['now'] as String? ?? '',
          selectable: type == 'Selector',
          items: all
              .map(
                (t) => OutboundItem(
                  tag: t,
                  type:
                      (proxies[t] as Map<String, dynamic>?)?['type']
                          as String? ??
                      '',
                  delayMs: delayOf(t),
                ),
              )
              .toList(),
        ),
      );
    });
    return groups;
  }

  Future<void> select(String group, String tag) async {
    final endpoint = base.resolve('/proxies/${Uri.encodeComponent(group)}');
    final selected = await _request(
      'PUT',
      endpoint,
      timeout: const Duration(seconds: 5),
      body: jsonEncode({'name': tag}),
    );
    if (selected.statusCode < 200 || selected.statusCode >= 300) {
      throw StateError('selector_command_failed');
    }
    final readback = await _request(
      'GET',
      endpoint,
      timeout: const Duration(seconds: 5),
    );
    if (readback.statusCode != 200) {
      throw StateError('selector_readback_failed');
    }
    final body = _json(readback);
    if (body['now'] != tag) throw StateError('selector_confirmation_mismatch');
  }

  /// Latency-test a group. Returns the min non-zero member delay (ms), 0 if none.
  Future<int> groupDelay(String group) async {
    final url = base
        .resolve('/group/${Uri.encodeComponent(group)}/delay')
        .replace(
          queryParameters: {
            'url': 'http://www.gstatic.com/generate_204',
            'timeout': '5000',
          },
        );
    final r = await _request('GET', url, timeout: const Duration(seconds: 7));
    if (r.statusCode != 200) return 0;
    final m = _json(r);
    final vals = m.values
        .whereType<num>()
        .map((e) => e.toInt())
        .where((d) => d > 0);
    return vals.isEmpty ? 0 : vals.reduce((a, b) => a < b ? a : b);
  }

  void close() => _http.close();
}
