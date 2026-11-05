import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/bounded_http.dart';
import '../core/contract.dart';

/// Pulls a fresh contract from the delivery channel, control-plane first.
///
/// This is the discovery bootstrap layer: ask a small discovery endpoint for the
/// currently usable contract origins, then race those together with the
/// contract's primary/fallback URLs. No provider is assumed to be universally
/// reachable.
///
/// Every body is parsed before use. Network/discovery failure returns null so
/// the caller can keep the encrypted/embedded last-known-good contract.
class DeliveryService {
  static Future<String?> fetchFreshContract(
    DeliveryInfo delivery, {
    http.Client? client,
    Duration perUrlTimeout = const Duration(seconds: 5),
    Duration totalBudget = const Duration(seconds: 10),
    Future<bool> Function(String body)? acceptCandidate,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    final clock = Stopwatch()..start();
    Duration remaining() => totalBudget - clock.elapsed;
    try {
      final staticUrls = delivery.fetchUrls;
      // Discovery must leave time for known origins if it stalls. Each
      // subsequent origin still gets its full per-URL timeout, within the
      // shared deadline, regardless of how many other origins are dead.
      final discoveryBudget = staticUrls.isEmpty
          ? remaining()
          : Duration(microseconds: remaining().inMicroseconds ~/ 3);
      final discovered = await _discoverUrls(
        delivery.getDomain,
        c,
        _shorter(perUrlTimeout, discoveryBudget),
      );
      final urls = <String>{...discovered, ...staticUrls};
      if (urls.isEmpty || remaining() <= Duration.zero) return null;
      final winner = Completer<String?>();
      var pending = urls.length;
      final secureDiscovery =
          Uri.tryParse(delivery.getDomain ?? '')?.scheme == 'https';
      for (final url in urls) {
        unawaited(() async {
          try {
            if (remaining() <= Duration.zero) return;
            final uri = secureDiscovery && discovered.contains(url)
                ? _withToken(url, delivery.token)
                : authenticatedUri(url, delivery);
            final resp = await boundedRequest(
              c,
              http.Request('GET', uri)..followRedirects = false,
              _shorter(perUrlTimeout, remaining()),
            );
            if (resp.statusCode != 200 || resp.body.isEmpty) return;
            AuroraContract.fromJson(
              json.decode(resp.body) as Map<String, dynamic>,
            );
            // A parseable but unsigned/expired/old response must not suppress
            // a usable backup. This predicate may read state, never promote it:
            // another origin can finish while verification is still in flight.
            if (acceptCandidate != null &&
                !await acceptCandidate(resp.body).timeout(remaining())) {
              return;
            }
            if (!winner.isCompleted && remaining() > Duration.zero) {
              winner.complete(resp.body);
            }
          } catch (_) {
            // Other candidates remain eligible after network/validation failure.
          } finally {
            if (--pending == 0 && !winner.isCompleted) winner.complete(null);
          }
        }());
      }
      return await winner.future.timeout(remaining(), onTimeout: () => null);
    } finally {
      if (own) c.close();
    }
  }

  static Duration _shorter(Duration left, Duration right) =>
      left < right ? left : right;

  static Future<List<String>> _discoverUrls(
    String? discoveryUrl,
    http.Client client,
    Duration timeout,
  ) async {
    if (discoveryUrl == null ||
        discoveryUrl.isEmpty ||
        timeout <= Duration.zero) {
      return const [];
    }
    final discoveryUri = Uri.tryParse(discoveryUrl);
    if (discoveryUri == null ||
        (discoveryUri.scheme != 'http' && discoveryUri.scheme != 'https')) {
      return const [];
    }
    try {
      final response = await boundedRequest(
        client,
        http.Request('GET', discoveryUri)..followRedirects = false,
        timeout,
      );
      if (response.statusCode != 200 || response.body.isEmpty) return const [];
      final body = json.decode(response.body) as Map<String, dynamic>;
      final domains = (body['domains'] as List?) ?? const [];
      return domains
          .map((value) => _contractUrl(value.toString()))
          .whereType<String>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Attach the current read token only to HTTPS origins already named by the
  /// active trusted contract. A pasted or remembered arbitrary URL is not an
  /// authorization to disclose the current contract's credentials to it.
  static Uri authenticatedUri(String url, DeliveryInfo delivery) {
    final uri = Uri.parse(url);
    final trusted =
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        delivery.fetchUrls.any((value) {
          final known = Uri.tryParse(value);
          return known != null &&
              known.scheme == 'https' &&
              known.host == uri.host &&
              known.port == uri.port;
        });
    return _withToken(url, trusted ? delivery.token : null);
  }

  static String? _contractUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/v2/contract') || path.endsWith('.json')) {
      return uri.toString();
    }
    return uri.replace(path: '$path/v2/contract').toString();
  }

  /// Adds `?token=` if the contract carries one and the URL doesn't already.
  ///
  /// Never attaches the token to a non-`https` URL: the contract read token
  /// gates node credentials on the Worker, and this runs at connect bootstrap
  /// BEFORE the tunnel is up (often on hostile hotel/café Wi-Fi). Sending it in
  /// cleartext would let an on-path observer replay it and pull the full
  /// contract. A tokenless http fetch simply 401s and the loop falls through.
  static Uri _withToken(String url, String? token) {
    final uri = Uri.parse(url);
    if (token == null ||
        token.isEmpty ||
        uri.scheme != 'https' ||
        uri.queryParameters.containsKey('token')) {
      return uri;
    }
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'token': token},
    );
  }
}
