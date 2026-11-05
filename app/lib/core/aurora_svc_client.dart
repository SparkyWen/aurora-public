import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bounded_http.dart';

/// One reading of the helper's state, plus the reason when it is `error`.
class SvcStatus {
  const SvcStatus({required this.state, required this.detail, this.clashProbe});

  final String state;
  final String detail;
  final SvcClashProbe? clashProbe;
}

/// Returned only by authenticated /status for the currently running child.
/// Keep this a class: a record's default toString would expose its secret.
class SvcClashProbe {
  const SvcClashProbe({required this.port, required this.secret});

  final int port;
  final String secret;
}

/// HTTP client for the local aurora-svc privileged helper (spec §4.3).
/// Localhost-only, bearer-token authenticated. Drives sing-box's lifecycle;
/// telemetry comes from [ClashApiClient], not from here.
class AuroraSvcClient {
  AuroraSvcClient({Uri? base, required this.token, http.Client? client})
    : base = base ?? Uri.parse('http://127.0.0.1:53421'),
      _http = client ?? http.Client();

  final Uri base;

  /// Resolved on EVERY request, never captured once.
  ///
  /// The privileged side owns and provisions the shared token, and it can come
  /// up after this object exists (first install, service repair). A client that
  /// snapshots the token at construction keeps sending the pre-install value —
  /// i.e. an empty string — and gets 401 until the app is restarted.
  final String Function() token;

  final http.Client _http;

  // Keep only credential values, not config JSON, to redact late responses
  // across token rotation and consecutive connection attempts.
  final Set<String> _knownSecrets = {};

  Future<http.Response> _request(
    String method,
    Uri url,
    Duration timeout, {
    String? body,
    bool validate = true,
  }) async {
    final currentToken = token();
    _knownSecrets.add(currentToken);
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $currentToken',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = body;
    final http.Response response;
    try {
      response = await boundedRequest(_http, request, timeout);
    } on TimeoutException {
      throw StateError('svc_${url.path.substring(1)}_timeout');
    }
    if (validate && response.statusCode != 200) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('svc_auth_failed');
      }
      final detail = _safeDetail(_utf8Body(response));
      throw StateError(
        'aurora-svc ${url.path.substring(1)} failed '
        '(${response.statusCode}): $detail',
      );
    }
    return response;
  }

  String _safeDetail(String detail) {
    var safe = detail;
    final secrets = _knownSecrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in secrets) {
      if (secret.isNotEmpty) safe = safe.replaceAll(secret, '<redacted>');
    }
    // Service errors can include sing-box's config validation/log output.
    // Scrub labelled secrets too, including values not sent by this client.
    safe = safe.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer <redacted>',
    );
    safe = safe.replaceAllMapped(
      RegExp(
        r'''(["']?(?:password|uuid|secret|token|private_key)["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>',
    );
    return safe;
  }

  static List<String> _credentials(String configJson) {
    final secrets = <String>[];
    void collect(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (RegExp(
                r'password|uuid|secret|token|private_key',
                caseSensitive: false,
              ).hasMatch('${entry.key}') &&
              entry.value is String) {
            secrets.add(entry.value as String);
          } else {
            collect(entry.value);
          }
        }
      } else if (value is List) {
        value.forEach(collect);
      }
    }

    try {
      collect(jsonDecode(configJson));
    } on FormatException {
      // The service owns config validation; do not include invalid JSON here.
    }
    return secrets;
  }

  /// Hands the compiled sing-box config to the helper.
  ///
  /// The config travels as bytes, not as a path: the helper runs as LocalSystem
  /// and this app runs as the logged-in user, so no filesystem location means
  /// the same thing on both sides (`%APPDATA%` alone differs). The helper writes
  /// what it is given into its own SYSTEM-owned directory and runs that.
  ///
  /// [clashPort]/[clashSecret] are this connection's Clash API coordinates — the
  /// service cannot guess them, they are chosen/compiled in by the app. Field
  /// names below (`clash_probe`/`port`/`secret`) are pinned by HTTP-level tests
  /// on the Go side (desktop/aurora-svc/main_test.go); a mismatch here would
  /// still compile on both sides and just silently take the legacy fixed-delay
  /// path instead of waiting for the tunnel to actually come up. Omitting the
  /// pair entirely (rather than sending nulls) is what selects that legacy path.
  ///
  /// [ownerPid] means "stop this tunnel if that process dies". The GUI sends
  /// its own pid so that quitting — by ANY route, including Task Manager, a
  /// crash, a log-off or the installer's own taskkill during an upgrade — takes
  /// the tunnel with it; before this, only the tray's Quit item stopped it, and
  /// every other exit left a SYSTEM-owned full-capture TUN behind with no
  /// window anywhere to turn it off. `aurora-cli connect` deliberately sends
  /// nothing: it connects and exits on purpose.
  Future<void> start(
    String configJson, {
    int? clashPort,
    String? clashSecret,
    int? ownerPid,
  }) async {
    _knownSecrets.addAll(_credentials(configJson));
    if (clashSecret != null) _knownSecrets.add(clashSecret);
    // The service can spend 45s opening wintun, in addition to check and cleanup.
    // A short generic HTTP timeout would kill otherwise valid Windows starts.
    await _request(
      'POST',
      base.resolve('/start'),
      const Duration(seconds: 90),
      body: jsonEncode({
        'config': configJson,
        if (clashPort != null && clashSecret != null)
          'clash_probe': {'port': clashPort, 'secret': clashSecret},
        'owner_pid': ?ownerPid,
      }),
    );
  }

  Future<void> stop() async {
    await _request('POST', base.resolve('/stop'), const Duration(seconds: 20));
  }

  /// State plus, when the core died, sing-box's own last words.
  ///
  /// [ownerPid] re-claims a tunnel this process did not start — the app
  /// relaunching and adopting a session that outlived it. Sent on the ordinary
  /// 1 Hz poll rather than through an endpoint of its own, so ownership is
  /// re-established within a second of the new process existing without any
  /// extra round trip. The service never blocks on it (see Runner.claimOwner).
  Future<SvcStatus> status({int? ownerPid}) async {
    final url = ownerPid == null
        ? base.resolve('/status')
        : base.resolve('/status?owner_pid=$ownerPid');
    final r = await _request('GET', url, const Duration(seconds: 3));
    try {
      final m = jsonDecode(_utf8Body(r));
      if (m is! Map<String, dynamic> ||
          !const [
            'running',
            'stopped',
            'error',
            'starting',
          ].contains(m['state']) ||
          (m['detail'] != null && m['detail'] is! String)) {
        throw StateError('svc_status_invalid');
      }
      SvcClashProbe? probe;
      final rawProbe = m['clash_probe'];
      if (rawProbe != null) {
        if (m['state'] != 'running' ||
            rawProbe is! Map<String, dynamic> ||
            rawProbe['port'] is! int ||
            (rawProbe['port'] as int) < 1 ||
            (rawProbe['port'] as int) > 65535 ||
            rawProbe['secret'] is! String ||
            (rawProbe['secret'] as String).isEmpty) {
          throw StateError('svc_status_invalid');
        }
        probe = SvcClashProbe(
          port: rawProbe['port'] as int,
          secret: rawProbe['secret'] as String,
        );
        _knownSecrets.add(probe.secret);
      }
      return SvcStatus(
        state: m['state'] as String,
        detail: _safeDetail(m['detail'] as String? ?? ''),
        clashProbe: probe,
      );
    } on FormatException {
      throw StateError('svc_status_invalid');
    }
  }

  /// "running" | "stopped" | "error".
  Future<String> statusState() async => (await status()).state;

  /// True if the service is installed and reachable.
  ///
  /// Any HTTP answer proves it: a 401 means the helper is up but the token is
  /// not provisioned yet, which is a credential problem, not a missing service.
  /// Only a transport failure means "not installed".
  Future<bool> installed() async {
    try {
      await _request(
        'GET',
        base.resolve('/status'),
        const Duration(seconds: 2),
        validate: false,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The privileged side's view of this machine's network — interface table,
  /// whether the TUN device exists, who owns the tunnel, the core's full log
  /// tail. Returns null when the helper cannot be reached or refuses.
  ///
  /// Exists because "shows connected but nothing loads" cannot be diagnosed from inside
  /// the app: the readiness signal is the Clash API answering, which proves the
  /// core started and nothing about whether the OS routes anything through it.
  /// The answer carries no credentials — it is meant to be pasted into a
  /// screenshot as-is.
  Future<String?> diagnose() async {
    try {
      final r = await _request(
        'GET',
        base.resolve('/diagnose'),
        const Duration(seconds: 5),
      );
      return r.statusCode == 200 ? _utf8Body(r) : null;
    } catch (_) {
      return null;
    }
  }

  /// aurora-svc responses are always read as UTF-8, ignoring Content-Type.
  ///
  /// `http.Response.body` decodes as **latin-1** when the response headers carry no
  /// charset. Non-ASCII on this wire is not rare: Windows NIC FriendlyNames are
  /// localized (for example the Chinese names for "Ethernet" and "Wireless Network
  /// Connection"), and failure details carry localized Win32 error strings. Read as
  /// latin-1 they come out as garbage, and the whole point of both is to be shown to
  /// a person or sent back verbatim to the core as an interface name. The server
  /// also declares the charset explicitly (see desktop/aurora-svc/main.go); we do
  /// not rely on it here only because correctness should not hang on one response
  /// header.
  static String _utf8Body(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      return response.body;
    }
  }

  /// The interface names the core would accept for `route.default_interface`,
  /// as the core itself sees them.
  ///
  /// Read from [diagnose] rather than from `NetworkInterface.list()` on
  /// purpose: this list comes from the same OS call sing-box's own interface
  /// monitor uses, so a name picked here is guaranteed to be a name the core
  /// can resolve. Aurora's own TUN, anything that is down, and loopback are
  /// filtered out — none of them can carry the tunnel's outbound.
  Future<List<String>> egressInterfaceCandidates({
    required String tunInterfaceName,
  }) async {
    final body = await diagnose();
    if (body == null) return const [];
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final interfaces = decoded['interfaces'] as List<dynamic>? ?? const [];
      return [
        for (final entry in interfaces.cast<Map<String, dynamic>>())
          if (entry['up'] == true &&
              (entry['name'] as String?)?.isNotEmpty == true &&
              entry['name'] != tunInterfaceName &&
              (entry['addresses'] as List<dynamic>? ?? const []).any(
                (a) => !'$a'.startsWith('127.') && !'$a'.startsWith('::1'),
              ))
            entry['name'] as String,
      ];
    } on FormatException {
      return const [];
    }
  }

  void close() => _http.close();
}
