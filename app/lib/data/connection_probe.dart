import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/bounded_http.dart';
import '../core/config_compiler.dart';
import '../core/path_health.dart';

enum ProbeCategory { ok, dns, tls, timeout, transport, http }

/// Safe TLS evidence, without retaining native errors or request addresses.
enum TlsFailure { certificateValidation, handshakeClosed, handshake }

class ProbeResult {
  const ProbeResult({
    required this.name,
    required this.category,
    this.statusCode,
    this.tlsFailure,
  });

  final String name;
  final ProbeCategory category;
  final int? statusCode;
  final TlsFailure? tlsFailure;

  bool get reachable => category == ProbeCategory.ok;
}

class ConnectionProbeReport {
  const ConnectionProbeReport(this.results, {this.tunnelDnsAnswered});

  final List<ProbeResult> results;

  /// Whether the tunnel's DNS answered for a fresh name ([TunnelDnsProbe]); null =
  /// not measured. Kept out of [results]: the verdict on the three sites ([healthy]
  /// and so on) is also used by the path coordinator, and it says "are the sites
  /// reachable", whereas this says "can new names still be resolved".
  final bool? tunnelDnsAnswered;

  bool get tunnelDnsDead => tunnelDnsAnswered == false;

  /// Local diagnostics only. Names supplied by callers are never serialized;
  /// the built-in endpoints have fixed IDs and everything else is unknown.
  List<Map<String, Object?>> get diagnosticResults => [
    for (final result in results)
      {
        'target': switch (result.name) {
          'Google 204' => 'google_204',
          'Cloudflare 204' => 'cloudflare_204',
          'GitHub assets' => 'github_assets',
          _ => 'unknown',
        },
        'category': result.category.name,
        if (result.category == ProbeCategory.tls && result.tlsFailure != null)
          'tls_failure': result.tlsFailure!.name,
        if (result.statusCode != null) 'status': result.statusCode,
      },
    if (tunnelDnsAnswered != null)
      {
        'target': 'tunnel_dns',
        'category': (tunnelDnsAnswered! ? ProbeCategory.ok : ProbeCategory.dns)
            .name,
      },
  ];

  bool get healthy {
    final independent204 = results.any(
      (result) =>
          (result.name == 'Google 204' || result.name == 'Cloudflare 204') &&
          result.reachable,
    );
    final github = results.any(
      (result) => result.name == 'GitHub assets' && result.reachable,
    );
    return independent204 && github;
  }

  ProbeCategory get category {
    if (healthy) return tunnelDnsDead ? ProbeCategory.dns : ProbeCategory.ok;
    for (final preferred in [
      ProbeCategory.tls,
      ProbeCategory.dns,
      ProbeCategory.timeout,
      ProbeCategory.transport,
      ProbeCategory.http,
    ]) {
      if (results.any((result) => result.category == preferred)) {
        return preferred;
      }
    }
    return ProbeCategory.transport;
  }

  /// HTTP policy/challenge responses are site compatibility signals. They do
  /// not prove that the selected transport is unhealthy.
  bool get compatibilityOnly =>
      !healthy &&
      results.isNotEmpty &&
      !results.any(
        (result) =>
            result.category == ProbeCategory.dns ||
            result.category == ProbeCategory.tls ||
            result.category == ProbeCategory.timeout ||
            result.category == ProbeCategory.transport,
      );

  bool get transportFailure =>
      !healthy &&
      !results.any(
        (result) => result.reachable || result.category == ProbeCategory.http,
      ) &&
      results.any(
        (result) =>
            result.category == ProbeCategory.dns ||
            result.category == ProbeCategory.tls ||
            result.category == ProbeCategory.timeout ||
            result.category == ProbeCategory.transport,
      );

  String get summary {
    if (tunnelDnsDead && results.any((result) => result.reachable)) {
      return 'Tunnel DNS is not answering: sites already open still work, but new sites cannot be resolved';
    }
    if (healthy) return 'Network check passed (HTTPS + GitHub image)';
    if (results.any((result) => result.reachable)) {
      final failed = results
          .where((result) => !result.reachable)
          .map((result) => result.name)
          .join(', ');
      return 'Network reachable, some site checks failed: $failed';
    }
    return switch (category) {
ProbeCategory.dns => 'Network check failed: DNS',
      ProbeCategory.tls => _tlsSummary,
      ProbeCategory.timeout => 'Network check failed: connection timed out',
      ProbeCategory.http => 'Network check failed: HTTP',
      ProbeCategory.transport => 'Network check failed: transport',
      ProbeCategory.ok => 'Network check passed',
    };
  }
}

extension on ConnectionProbeReport {
  /// The three kinds of TLS evidence mean three different things, and the wording
  /// must not mix them:
  ///
  /// - certificate validation failed: someone really did swap the certificate in
  ///   the middle, and it must be refused;
  /// - handshake closed: the socket was closed before the peer said anything. Over
  ///   the TUN the peer is sing-box, which accepted the connection, failed to dial
  ///   the remote end, and then closed the local one. That means the **proxy path**
  ///   was not established (network dropped, entry unreachable) and has nothing to
  ///   do with TLS or certificates. Reporting a dropped Wi-Fi as "TLS certificate
  ///   unavailable" because the failure happened in the TLS handshake misled users;
  /// - any other handshake failure: the protocol layer genuinely cannot agree.
  String get _tlsSummary {
    final failures = results
        .where((result) => result.category == ProbeCategory.tls)
        .map((result) => result.tlsFailure)
        .toList();
    if (failures.contains(TlsFailure.certificateValidation)) {
      return 'Network check failed: TLS certificate validation failed';
    }
    if (failures.isNotEmpty &&
        failures.every((f) => f == TlsFailure.handshakeClosed)) {
      return 'Network check failed: proxy path could not connect (connection closed before the peer answered)';
    }
    return 'Network check failed: TLS handshake';
  }
}

class EgressProbeReport {
  const EgressProbeReport({
    required this.egress,
    required this.category,
    this.compatibilityOnly = false,
    this.transportFailure = false,
    this.tlsFailure,
  });

  final EgressStatus egress;
  final ProbeCategory category;
  final bool compatibilityOnly;
  final bool transportFailure;
  final TlsFailure? tlsFailure;
}

/// One bulk-transfer measurement over the active path.
class GoodputSample {
  const GoodputSample({
    required this.bytes,
    required this.elapsed,
    required this.reachable,
    this.stalled = false,
  });

  /// Bytes that actually arrived before the deadline.
  final int bytes;
  final Duration elapsed;

  /// The endpoint answered. False means the measurement never happened, which
  /// is not the same as "the path is slow" and must not be read as one.
  final bool reachable;

  /// No provider answered at all: every attempt ran out its deadline or was cut
  /// off before a response arrived. That is a measurement — of zero — not the
  /// absence of one. An answer of any kind (a challenge, a 503) proves the path
  /// carried a response back and says nothing about its speed; silence from
  /// two independent providers through a path the watchdog just proved alive
  /// is the path. A Hysteria2 leg has been seen passing most small requests while
  /// returning nothing, not even headers, on every 3 MB download, so a gate that
  /// treated silence as "no data" never saw it.
  final bool stalled;

  static const unreachable = GoodputSample(
    bytes: 0,
    elapsed: Duration.zero,
    reachable: false,
  );

  static const stall = GoodputSample(
    bytes: 0,
    elapsed: Duration.zero,
    reachable: false,
    stalled: true,
  );

  int get bytesPerSecond {
    final micros = elapsed.inMicroseconds;
    if (micros <= 0 || bytes <= 0) return 0;
    return bytes * Duration.microsecondsPerSecond ~/ micros;
  }
}

class ConnectionProbeService {
  static const _targets = <(String, String, bool)>[
    ('Google 204', 'https://www.gstatic.com/generate_204', true),
    ('Cloudflare 204', 'https://cp.cloudflare.com/generate_204', true),
    (
      'GitHub assets',
      'https://github.githubassets.com/favicons/favicon.png',
      false,
    ),
  ];

  /// Timeout of a single probe request.
  ///
  /// It used to be 4s. Measured: a healthy relay path on a throttling carrier had
  /// TTFB of 0.66-1.59s, going direct to the home node 1.2-3.8s, and a CDN front up
  /// to 6.5s. 4s judged healthy paths as timeout, the UI popped up "Network check
  /// failed: connection timed out", and the watchdog recorded a dead on top of it.
  static const defaultPerRequestTimeout = Duration(seconds: 8);

  /// Upper bound for a whole probe round. Independent endpoints run concurrently,
  /// each request's full response is bound by the remaining budget, and one site
  /// timing out does not wipe out the successes already obtained.
  static const defaultTotalBudget = Duration(seconds: 20);

  static Future<ConnectionProbeReport> run({
    http.Client? client,
    Duration perRequestTimeout = defaultPerRequestTimeout,
    Duration totalBudget = defaultTotalBudget,
    TunnelDnsProbe? tunnelDns,
  }) async {
    final ownClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final dns = tunnelDns?.run();
      final results = await _runAll(
        activeClient,
        perRequestTimeout < totalBudget ? perRequestTimeout : totalBudget,
      );
      return ConnectionProbeReport(results, tunnelDnsAnswered: await dns);
    } finally {
      if (ownClient) activeClient.close();
    }
  }

  /// The round the watchdog uses: besides the three sites, also ask the tunnel's DNS
  /// directly. Only call this on platforms where the GUI process has a tunnel (the
  /// NE on iOS/macOS, the TUN elsewhere).
  static Future<ConnectionProbeReport> runThroughTunnel() => run(
    tunnelDns: TunnelDnsProbe(
      InternetAddress(
        auroraTunDnsServerV4(apple: Platform.isIOS || Platform.isMacOS),
      ),
    ),
  );

  /// Independent IP-echo services. A single provider being slow or throttled
  /// must never read as path degradation. Probe them together under one deadline;
  /// any confirmed mismatch wins over matches so response order cannot hide it.
  static final List<Uri> _egressEndpoints = [
    Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'),
    Uri.parse('https://api.ipify.org'),
    Uri.parse('https://checkip.amazonaws.com'),
  ];

  /// Verify that the active path still exits through the signed household IP.
  /// The observed address is never returned to callers or logs.
  static Future<EgressProbeReport> runEgress({
    required String expectedIpv4,
    http.Client? client,
    Uri? endpoint,
    List<Uri>? endpoints,
    Duration timeout = defaultPerRequestTimeout,
  }) async {
    final targets = endpoint != null
        ? [endpoint]
        : (endpoints ?? _egressEndpoints);
    final ownClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final reports = await Future.wait([
        for (final target in targets)
          _egressAttempt(activeClient, target, expectedIpv4, timeout),
      ]);
      for (final status in [EgressStatus.mismatch, EgressStatus.verified]) {
        for (final report in reports) {
          if (report.egress == status) return report;
        }
      }
      // An HTTP challenge demonstrates reachability even if other providers
      // timed out, but it cannot verify the exit identity.
      for (final report in reports) {
        if (report.compatibilityOnly) return report;
      }
      return reports.firstOrNull ??
          const EgressProbeReport(
            egress: EgressStatus.unknown,
            category: ProbeCategory.transport,
            transportFailure: true,
          );
    } finally {
      if (ownClient) activeClient.close();
    }
  }

  /// Endpoints that will stream an arbitrary number of bytes on demand. Two
  /// providers so one being down or challenged does not read as a slow path.
  static const _goodputEndpoints = <String>[
    'https://speed.cloudflare.com/__down?bytes=',
    'https://fsn1-speed.hetzner.com/__down?bytes=',
  ];

  /// Measure how fast the active path can actually move data.
  ///
  /// Reads the response as a stream and stops at whichever comes first, the
  /// byte target or the deadline — so a path delivering 2 KB/s costs [deadline]
  /// rather than the minutes a buffered download would take. The rate is
  /// computed from what arrived, which is exactly the quantity that every
  /// tiny-payload probe in this file is blind to.
  static Future<GoodputSample> runGoodput({
    http.Client? client,
    Uri? endpoint,
    int targetBytes = 512 * 1024,
    Duration deadline = const Duration(seconds: 8),
  }) async {
    final ownClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final targets = endpoint != null
          ? [endpoint]
          : [
              for (final base in _goodputEndpoints)
                Uri.parse('$base$targetBytes'),
            ];
      var stalled = true;
      for (final target in targets) {
        final sample = await _goodputAttempt(
          activeClient,
          target,
          targetBytes,
          deadline,
        );
        if (sample.reachable) return sample;
        stalled = stalled && sample.stalled;
      }
      return stalled ? GoodputSample.stall : GoodputSample.unreachable;
    } finally {
      if (ownClient) activeClient.close();
    }
  }

  static Future<GoodputSample> _goodputAttempt(
    http.Client client,
    Uri endpoint,
    int targetBytes,
    Duration deadline,
  ) async {
    final clock = Stopwatch()..start();
    var received = 0;
    try {
      final response = await client
          .send(http.Request('GET', endpoint))
          .timeout(deadline);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return GoodputSample.unreachable;
      }
      final done = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      subscription = response.stream.listen(
        (chunk) {
          received += chunk.length;
          if (received >= targetBytes) {
            unawaited(subscription.cancel());
            finish();
          }
        },
        onDone: finish,
        onError: (_) => finish(),
        cancelOnError: true,
      );
      final remaining = deadline - clock.elapsed;
      try {
        if (remaining <= Duration.zero) {
          await subscription.cancel();
        } else {
          await done.future.timeout(remaining);
        }
      } on TimeoutException {
        // Expected on a throttled path: keep whatever arrived, that IS the
        // measurement. Cancelling here is what bounds the probe's cost.
        await subscription.cancel();
      }
      clock.stop();
      // Bytes arrived, so the path is reachable even if the rate is terrible —
      // which is precisely the case this whole probe exists to catch.
      return GoodputSample(
        bytes: received,
        elapsed: clock.elapsed,
        reachable: true,
      );
    } on TimeoutException {
      return GoodputSample.stall;
    } on TlsException catch (error) {
      // A certificate failure says who answered, not how fast the path is.
      return _classifyTlsFailure(error) == TlsFailure.certificateValidation
          ? GoodputSample.unreachable
          : GoodputSample.stall;
    } on SocketException catch (error) {
      final message = error.message.toLowerCase();
      final isDns =
          message.contains('host lookup') ||
          message.contains('name or service');
      return isDns ? GoodputSample.unreachable : GoodputSample.stall;
    } on http.ClientException catch (error) {
      // IOClient wraps every HttpException this way. "Connection closed …" is
      // the path giving out; anything else (a redirect loop, a malformed
      // reply) is an answer.
      return error.message.toLowerCase().contains('connection closed')
          ? GoodputSample.stall
          : GoodputSample.unreachable;
    } catch (_) {
      return GoodputSample.unreachable;
    }
  }

  static Future<EgressProbeReport> _egressAttempt(
    http.Client client,
    Uri endpoint,
    String expectedIpv4,
    Duration timeout,
  ) async {
    try {
      final response = await boundedRequest(
        client,
        http.Request('GET', endpoint),
        timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return const EgressProbeReport(
          egress: EgressStatus.unknown,
          category: ProbeCategory.http,
          compatibilityOnly: true,
        );
      }
      final observed = _extractIpv4(response.body);
      if (observed == null) {
        return const EgressProbeReport(
          egress: EgressStatus.unknown,
          category: ProbeCategory.http,
          compatibilityOnly: true,
        );
      }
      return EgressProbeReport(
        egress: observed == expectedIpv4
            ? EgressStatus.verified
            : EgressStatus.mismatch,
        category: ProbeCategory.ok,
      );
    } on TlsException catch (error) {
      return EgressProbeReport(
        egress: EgressStatus.unknown,
        category: ProbeCategory.tls,
        transportFailure: true,
        tlsFailure: _classifyTlsFailure(error),
      );
    } on TimeoutException {
      return const EgressProbeReport(
        egress: EgressStatus.unknown,
        category: ProbeCategory.timeout,
        transportFailure: true,
      );
    } on SocketException {
      return const EgressProbeReport(
        egress: EgressStatus.unknown,
        category: ProbeCategory.transport,
        transportFailure: true,
      );
    } catch (_) {
      return const EgressProbeReport(
        egress: EgressStatus.unknown,
        category: ProbeCategory.transport,
        transportFailure: true,
      );
    }
  }

  /// Accepts either a bare-IP body (ipify, checkip) or key=value trace lines
  /// (cdn-cgi/trace). Returns null when no IPv4 answer is present.
  static String? _extractIpv4(String body) {
    final trimmed = body.trim();
    if (_isIpv4(trimmed)) return trimmed;
    for (final line in trimmed.split('\n')) {
      if (line.startsWith('ip=')) {
        final candidate = line.substring(3).trim();
        return _isIpv4(candidate) ? candidate : null;
      }
    }
    return null;
  }

  static Future<List<ProbeResult>> _runAll(
    http.Client client,
    Duration timeout,
  ) => Future.wait([
    for (final (name, url, expects204) in _targets)
      _probeTarget(client, name, Uri.parse(url), expects204, timeout),
  ]);

  static Future<ProbeResult> _probeTarget(
    http.Client client,
    String name,
    Uri uri,
    bool expects204,
    Duration timeout,
  ) async {
    try {
      final response = await boundedRequest(
        client,
        http.Request('GET', uri),
        timeout,
      );
      final accepted = expects204
          ? response.statusCode == 204
          : response.statusCode >= 200 && response.statusCode < 400;
      return ProbeResult(
        name: name,
        category: accepted ? ProbeCategory.ok : ProbeCategory.http,
        statusCode: response.statusCode,
      );
    } on TlsException catch (error) {
      return ProbeResult(
        name: name,
        category: ProbeCategory.tls,
        tlsFailure: _classifyTlsFailure(error),
      );
    } on TimeoutException {
      return ProbeResult(name: name, category: ProbeCategory.timeout);
    } on SocketException catch (error) {
      final isDns =
          error.message.toLowerCase().contains('host lookup') ||
          error.message.toLowerCase().contains('name or service');
      return ProbeResult(
        name: name,
        category: isDns ? ProbeCategory.dns : ProbeCategory.transport,
      );
    } catch (_) {
      return ProbeResult(name: name, category: ProbeCategory.transport);
    }
  }
}

/// Whether the DNS inside the tunnel still answers: send a fresh-name A query
/// straight to the DNS address inside the TUN.
///
/// The watchdog's three sites go through the system resolver with fixed names that
/// always sit in the system cache. Once a stuck DoH dial blocked every DNS query
/// for 8 minutes while the three sites stayed reachable: the watchdog judged the
/// tunnel alive, the UI said normal, and no new site would open. Each round uses
/// a new name, which neither the system nor the core cache can answer; any
/// answer, NXDOMAIN included, proves that this resolution path is still moving.
class TunnelDnsProbe {
  TunnelDnsProbe(
    this.server, {
    this.port = 53,
    this.timeout = ConnectionProbeService.defaultPerRequestTimeout,
    Random? random,
  }) : _random = random ?? Random.secure();

  final InternetAddress server;
  final int port;
  final Duration timeout;
  final Random _random;

  /// true = answered NOERROR/NXDOMAIN within the deadline; false = asked but got no
  /// answer, or an answer such as SERVFAIL; null = the local UDP socket could not be
  /// opened or sent on. That is a local problem and proves nothing, so it must not
  /// be used to declare the tunnel dead.
  Future<bool?> run() async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return null;
    }
    final id = _random.nextInt(0x10000);
    final label = List.generate(
      6,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final query = _query(id, 'aurora-$label.example.com');
    final answered = Completer<bool?>();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null || answered.isCompleted) return;
      final rcode = _responseCode(datagram.data, id);
      if (rcode != null) answered.complete(rcode == 0 || rcode == 3);
    });
    bool send() {
      try {
        return socket.send(query, server, port) > 0;
      } catch (_) {
        return false;
      }
    }

    // A quick upstream failure (for example a group switch having just cut the DoH
    // connection) makes the core send no reply; like an ordinary resolver, ask again
    // after a while, same question and same id. If it is truly stuck, both queries
    // queue behind the same in-flight one and the conclusion is unchanged.
    final retry = Timer(timeout ~/ 2, () {
      if (!answered.isCompleted) send();
    });
    try {
      if (!send()) return null;
      return await answered.future.timeout(timeout, onTimeout: () => false);
    } finally {
      retry.cancel();
      socket.close();
    }
  }

  static Uint8List _query(int id, String name) {
    final bytes = BytesBuilder()
      // id, RD, one question, nothing else
      ..add([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in name.split('.')) {
      bytes
        ..addByte(label.length)
        ..add(label.codeUnits);
    }
    // root, QTYPE A, QCLASS IN
    bytes.add([0, 0, 1, 0, 1]);
    return bytes.toBytes();
  }

  /// RCODE of a response to [id]; null for anything that is not one.
  static int? _responseCode(Uint8List data, int id) {
    if (data.length < 12) return null;
    if ((data[0] << 8 | data[1]) != id) return null;
    if (data[2] & 0x80 == 0) return null;
    return data[3] & 0x0f;
  }
}

TlsFailure _classifyTlsFailure(TlsException error) {
  // Dart reports failed verification either as CertificateException or as a
  // HandshakeException with BoringSSL's reason in message/osError. A generic
  // handshake failure, including peer closure, is not certificate evidence.
  if (error is CertificateException ||
      error.message.contains('CERTIFICATE_VERIFY_FAILED') ||
      (error.osError?.message.contains('CERTIFICATE_VERIFY_FAILED') ?? false)) {
    return TlsFailure.certificateValidation;
  }
  if (error is HandshakeException &&
      error.message.contains('Connection terminated during handshake')) {
    return TlsFailure.handshakeClosed;
  }
  return TlsFailure.handshake;
}

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
    final parsed = int.tryParse(part);
    return parsed != null && parsed >= 0 && parsed <= 255;
  });
}
