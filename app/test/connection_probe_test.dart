import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';

import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/data/connection_probe.dart';
import 'package:aurora/core/path_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

import 'fixtures/untrusted_tls_fixture.dart';

void main() {
  test('healthy requires an independent 204 and GitHub assets', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient((request) async {
        if (request.url.host == 'www.gstatic.com') {
          return http.Response('', 204);
        }
        if (request.url.host == 'cp.cloudflare.com') {
          return http.Response('blocked', 503);
        }
        return http.Response('png', 200);
      }),
    );
    expect(report.healthy, isTrue);
    expect(report.category, ProbeCategory.ok);
  });

  test('TLS failures are classified without bypassing verification', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient(
        (_) async => throw const HandshakeException('bad cert'),
      ),
    );
    expect(report.healthy, isFalse);
    expect(report.category, ProbeCategory.tls);
  });

  group('TLS failure evidence', () {
    // These cases catch both the misleading certificate diagnosis and TLS
    // exceptions that previously fell through to the generic transport catch.
    for (final (label, error, failure) in <(String, TlsException, TlsFailure)>[
      (
        'handshake closure',
        const HandshakeException('Connection terminated during handshake'),
        TlsFailure.handshakeClosed,
      ),
      (
        'generic handshake',
        const HandshakeException('bad cert'),
        TlsFailure.handshake,
      ),
      (
        'generic TLS protocol error',
        const TlsException('TLS alert'),
        TlsFailure.handshake,
      ),
      (
        'certificate exception',
        const CertificateException('certificate rejected'),
        TlsFailure.certificateValidation,
      ),
      (
        'certificate verification in handshake message',
        const HandshakeException('CERTIFICATE_VERIFY_FAILED: untrusted issuer'),
        TlsFailure.certificateValidation,
      ),
      (
        'certificate verification in native error',
        const HandshakeException(
          'Handshake error in client',
          OSError('CERTIFICATE_VERIFY_FAILED: self signed certificate', 1),
        ),
        TlsFailure.certificateValidation,
      ),
    ]) {
      test('$label stays unhealthy with an evidence-based summary', () async {
        final certificate = failure == TlsFailure.certificateValidation;
        final report = await ConnectionProbeService.run(
          client: MockClient((_) async => throw error),
        );
        expect(report.healthy, isFalse);
        expect(report.category, ProbeCategory.tls);
        expect(report.results.map((r) => r.tlsFailure), everyElement(failure));
        expect(report.transportFailure, isTrue);
        expect(report.compatibilityOnly, isFalse);
        // handshakeClosed is the tunnel closing the relayed socket before the
        // peer ever answered — a proxy-path failure. Calling it a "TLS handshake"
        // failure made the user report "TLS certificate unavailable" for a Wi-Fi drop.
        expect(
          report.summary,
          contains(switch (failure) {
            TlsFailure.certificateValidation => 'TLS certificate validation failed',
            TlsFailure.handshakeClosed => 'proxy path could not connect',
            TlsFailure.handshake => 'TLS handshake',
          }),
        );
        if (!certificate) expect(report.summary, isNot(contains('certificate')));
        if (failure == TlsFailure.handshakeClosed) {
          expect(report.summary, isNot(contains('TLS')));
        }

        final egress = await ConnectionProbeService.runEgress(
          expectedIpv4: '203.0.113.9',
          client: MockClient((_) async => throw error),
        );
        expect(egress.egress, EgressStatus.unknown);
        expect(egress.category, ProbeCategory.tls);
        expect(egress.tlsFailure, failure);
        expect(egress.transportFailure, isTrue);
        expect(egress.compatibilityOnly, isFalse);
      });
    }

    test('raw TLS messages never enter the user-facing summary', () async {
      final report = await ConnectionProbeService.run(
        client: MockClient(
          (_) async => throw const HandshakeException(
            'Connection terminated during handshake '
            'https://secret.example/path?token=fixture-secret 198.51.100.9',
          ),
        ),
      );
      expect(report.summary, contains('proxy path could not connect'));
      for (final sensitive in [
        'secret.example',
        'fixture-secret',
        '198.51.100.9',
      ]) {
        expect(report.summary, isNot(contains(sensitive)));
      }
    });

    test(
      'one TLS failure does not erase independent healthy endpoints',
      () async {
        final report = await ConnectionProbeService.run(
          client: MockClient((request) async {
            if (request.url.host == 'cp.cloudflare.com') {
              throw const CertificateException('certificate rejected');
            }
            return http.Response(
              '',
              request.url.host == 'www.gstatic.com' ? 204 : 200,
            );
          }),
        );
        expect(report.healthy, isTrue);
        expect(report.transportFailure, isFalse);
        expect(report.category, ProbeCategory.ok);
        expect(report.summary, isNot(contains('certificate')));
        expect(
          report.results
              .singleWhere((r) => r.name == 'Cloudflare 204')
              .category,
          ProbeCategory.tls,
        );
      },
    );

    test(
      'verified egress still outweighs another endpoint TLS failure',
      () async {
        final report = await ConnectionProbeService.runEgress(
          expectedIpv4: '203.0.113.9',
          endpoints: [
            Uri.parse('https://a.example'),
            Uri.parse('https://b.example'),
          ],
          client: MockClient((request) async {
            if (request.url.host == 'a.example') {
              throw const HandshakeException(
                'Connection terminated during handshake',
              );
            }
            return http.Response('203.0.113.9', 200);
          }),
        );
        expect(report.egress, EgressStatus.verified);
        expect(report.category, ProbeCategory.ok);
        expect(report.transportFailure, isFalse);
      },
    );

    test(
      'real peer closing TLS handshake is not a certificate failure',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        final listener = server.listen((socket) {
          sockets.add(socket);
          socket.listen((_) => socket.destroy(), onError: (_) {});
        });
        final client = _LocalTlsClient(server.port);
        addTearDown(() async {
          client.close();
          for (final socket in sockets) {
            socket.destroy();
          }
          await listener.cancel();
          await server.close();
        });
        final report = await ConnectionProbeService.run(client: client);
        expect(report.category, ProbeCategory.tls);
        expect(
          report.results.map((r) => r.tlsFailure),
          everyElement(TlsFailure.handshakeClosed),
        );
        expect(report.transportFailure, isTrue);
        expect(report.summary, contains('proxy path could not connect'));
        expect(report.summary, isNot(contains('certificate')));

        final egress = await ConnectionProbeService.runEgress(
          client: client,
          expectedIpv4: '203.0.113.9',
        );
        expect(egress.category, ProbeCategory.tls);
        expect(egress.tlsFailure, TlsFailure.handshakeClosed);
        expect(egress.egress, EgressStatus.unknown);
        expect(egress.transportFailure, isTrue);
      },
    );

    test(
      'real untrusted HTTPS certificate remains rejected by both probes',
      () async {
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          untrustedTlsContext(),
        );
        var acceptedRequests = 0;
        final listener = server.listen((request) {
          acceptedRequests++;
          request.response.statusCode = 204;
          unawaited(request.response.close());
        }, onError: (_) {});
        final client = _LocalTlsClient(server.port);
        addTearDown(() async {
          client.close();
          await listener.cancel();
          await server.close(force: true);
        });
        final report = await ConnectionProbeService.run(client: client);
        expect(report.healthy, isFalse);
        expect(report.category, ProbeCategory.tls);
        expect(
          report.results.map((r) => r.tlsFailure),
          everyElement(TlsFailure.certificateValidation),
        );
        expect(report.transportFailure, isTrue);
        expect(report.summary, contains('TLS certificate validation failed'));

        final egress = await ConnectionProbeService.runEgress(
          client: client,
          expectedIpv4: '203.0.113.9',
        );
        expect(egress.category, ProbeCategory.tls);
        expect(egress.tlsFailure, TlsFailure.certificateValidation);
        expect(egress.egress, EgressStatus.unknown);
        expect(egress.transportFailure, isTrue);
        expect(
          acceptedRequests,
          0,
          reason: 'Untrusted TLS must fail before HTTP',
        );
      },
    );
  });

  test('failed host lookup is classified as DNS', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient(
        (_) async => throw const SocketException('Failed host lookup'),
      ),
    );
    expect(report.category, ProbeCategory.dns);
  });

  test('per-request timeout is classified', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('', 204);
      }),
      perRequestTimeout: const Duration(milliseconds: 1),
      totalBudget: const Duration(seconds: 1),
    );
    expect(report.category, ProbeCategory.timeout);
  });

  test('GitHub HTTP failure makes the report unhealthy', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient((request) async {
        if (request.url.host == 'github.githubassets.com') {
          return http.Response('error', 502);
        }
        return http.Response('', 204);
      }),
    );
    expect(report.healthy, isFalse);
    expect(report.category, ProbeCategory.http);
    expect(report.compatibilityOnly, isTrue);
    expect(report.transportFailure, isFalse);
  });

  test('403 challenge is compatibility information, not path loss', () async {
    final report = await ConnectionProbeService.run(
      client: MockClient((_) async => http.Response('challenge', 403)),
    );
    expect(report.category, ProbeCategory.http);
    expect(report.compatibilityOnly, isTrue);
    expect(report.transportFailure, isFalse);
  });

  test(
    '429 risk throttling is compatibility information, not packet loss',
    () async {
      final report = await ConnectionProbeService.run(
        client: MockClient((_) async => http.Response('slow down', 429)),
      );
      expect(report.category, ProbeCategory.http);
      expect(report.compatibilityOnly, isTrue);
      expect(report.transportFailure, isFalse);
    },
  );

  test('egress probe verifies the signed household IPv4', () async {
    final report = await ConnectionProbeService.runEgress(
      expectedIpv4: '203.0.113.9',
      client: MockClient((_) async => http.Response('203.0.113.9\n', 200)),
    );
    expect(report.egress, EgressStatus.verified);
    expect(report.transportFailure, isFalse);
  });

  test('egress probe uses healthy echo endpoints when one is down', () async {
    final hosts = <String>[];
    final report = await ConnectionProbeService.runEgress(
      expectedIpv4: '203.0.113.9',
      client: MockClient((request) async {
        hosts.add(request.url.host);
        if (hosts.length == 1) throw const SocketException('endpoint down');
        return http.Response('203.0.113.9', 200);
      }),
    );
    expect(hosts.toSet(), hasLength(3));
    expect(report.egress, EgressStatus.verified);
    expect(report.transportFailure, isFalse);
  });

  test('egress probe parses cdn-cgi trace responses', () async {
    var calls = 0;
    final report = await ConnectionProbeService.runEgress(
      expectedIpv4: '203.0.113.9',
      client: MockClient((request) async {
        calls++;
        return http.Response(
          'fl=463f120\nh=www.cloudflare.com\nip=203.0.113.9\nts=1753186000\n',
          200,
        );
      }),
    );
    expect(calls, 3);
    expect(report.egress, EgressStatus.verified);
  });

  test('egress transport failure needs every echo endpoint to fail', () async {
    var calls = 0;
    final report = await ConnectionProbeService.runEgress(
      expectedIpv4: '203.0.113.9',
      client: MockClient((_) async {
        calls++;
        throw const SocketException('all endpoints down');
      }),
    );
    expect(calls, greaterThanOrEqualTo(2));
    expect(report.egress, EgressStatus.unknown);
    expect(report.transportFailure, isTrue);
  });

  test(
    'a reachable challenged endpoint outweighs a dead one for transport',
    () async {
      var calls = 0;
      final report = await ConnectionProbeService.runEgress(
        expectedIpv4: '203.0.113.9',
        client: MockClient((_) async {
          calls++;
          if (calls == 1) throw const SocketException('endpoint down');
          return http.Response('challenge', 403);
        }),
      );
      expect(report.egress, EgressStatus.unknown);
      expect(report.compatibilityOnly, isTrue);
      expect(report.transportFailure, isFalse);
    },
  );

  test(
    'egress mismatch is explicit and HTTP challenge stays unknown',
    () async {
      final mismatch = await ConnectionProbeService.runEgress(
        expectedIpv4: '203.0.113.9',
        client: MockClient((_) async => http.Response('198.51.100.7', 200)),
      );
      expect(mismatch.egress, EgressStatus.mismatch);

      final challenge = await ConnectionProbeService.runEgress(
        expectedIpv4: '203.0.113.9',
        client: MockClient((_) async => http.Response('challenge', 403)),
      );
      expect(challenge.egress, EgressStatus.unknown);
      expect(challenge.compatibilityOnly, isTrue);
      expect(challenge.transportFailure, isFalse);
    },
  );

  test(
    'budget preserves completed endpoint results and probes concurrently',
    () {
      fakeAsync((async) {
        ConnectionProbeReport? report;
        final pending = Completer<http.Response>();
        ConnectionProbeService.run(
          client: MockClient((request) async {
            if (request.url.host == 'cp.cloudflare.com') return pending.future;
            return http.Response(
              '',
              request.url.host == 'www.gstatic.com' ? 204 : 200,
            );
          }),
          perRequestTimeout: const Duration(seconds: 8),
          totalBudget: const Duration(seconds: 5),
        ).then((value) => report = value);
        async.elapse(const Duration(seconds: 5));
        expect(report, isNotNull);
        expect(report!.healthy, isTrue);
        expect(report!.results, hasLength(3));
        expect(
          report!.results
              .singleWhere((r) => r.name == 'Cloudflare 204')
              .category,
          ProbeCategory.timeout,
        );
        pending.complete(http.Response('', 204));
        async.flushMicrotasks();
      });
    },
  );

  test('partial site timeout is described as partial reachability', () {
    const report = ConnectionProbeReport([
      ProbeResult(
        name: 'Google 204',
        category: ProbeCategory.ok,
        statusCode: 204,
      ),
      ProbeResult(name: 'Cloudflare 204', category: ProbeCategory.timeout),
      ProbeResult(name: 'GitHub assets', category: ProbeCategory.timeout),
    ]);
    expect(report.summary, contains('Network reachable'));
    expect(report.summary, contains('GitHub assets'));
    expect(report.healthy, isFalse);
  });

  test('HTTP response plus endpoint outages is not a dead transport', () {
    const report = ConnectionProbeReport([
      ProbeResult(name: 'Google 204', category: ProbeCategory.timeout),
      ProbeResult(
        name: 'Cloudflare 204',
        category: ProbeCategory.http,
        statusCode: 403,
      ),
      ProbeResult(name: 'GitHub assets', category: ProbeCategory.timeout),
    ]);
    expect(report.healthy, isFalse);
    expect(report.transportFailure, isFalse);
  });

  test(
    'egress alternatives finish within one deadline when earlier providers hang',
    () {
      fakeAsync((async) {
        EgressProbeReport? report;
        final pending = Completer<http.Response>();
        ConnectionProbeService.runEgress(
          expectedIpv4: '203.0.113.9',
          endpoints: [
            Uri.parse('https://a.example'),
            Uri.parse('https://b.example'),
            Uri.parse('https://c.example'),
          ],
          client: MockClient(
            (request) async => request.url.host == 'c.example'
                ? http.Response('203.0.113.9', 200)
                : pending.future,
          ),
          timeout: const Duration(seconds: 6),
        ).then((value) => report = value);
        async.elapse(const Duration(seconds: 6));
        expect(report?.egress, EgressStatus.verified);
        pending.complete(http.Response('', 503));
        async.flushMicrotasks();
      });
    },
  );

  test(
    'conflicting egress identities cannot be accepted by response order',
    () async {
      final report = await ConnectionProbeService.runEgress(
        expectedIpv4: '203.0.113.9',
        endpoints: [
          Uri.parse('https://a.example'),
          Uri.parse('https://b.example'),
        ],
        client: MockClient(
          (request) async => http.Response(
            request.url.host == 'a.example' ? '203.0.113.9' : '198.51.100.1',
            200,
          ),
        ),
      );
      expect(report.egress, EgressStatus.mismatch);
    },
  );

  group('goodput', () {
    // Seen on a Windows office network: a relay HY2 leg passed 13 of 18 small
    // requests, but every 3 MB download returned 0 bytes - neither speed-test
    // provider returned a single byte or response header within the deadline. That is
    // not "could not measure", it is a measured zero.
    Future<GoodputSample> measure(
      Future<http.Response> Function(http.Request) handler,
    ) => ConnectionProbeService.runGoodput(
      client: MockClient(handler),
      deadline: const Duration(milliseconds: 50),
    );

    test('no provider answering inside the deadline is a stall', () async {
      final sample = await measure((_) => Completer<http.Response>().future);
      expect(sample.reachable, isFalse);
      expect(sample.stalled, isTrue);
    });

    test('a connection cut before any response is a stall', () async {
      final sample = await measure(
        (_) async => throw const HandshakeException(
          'Connection terminated during handshake',
        ),
      );
      expect(sample.stalled, isTrue);
    });

    test('a provider answering with an error is not a stall', () async {
      // An answer proves the path can carry a response back; a challenge page or rate
      // limit is about the speed-test provider, not the path.
      final sample = await measure(
        (request) => request.url.host == 'speed.cloudflare.com'
            ? Future.value(http.Response('challenge', 403))
            : Completer<http.Response>().future,
      );
      expect(sample.reachable, isFalse);
      expect(sample.stalled, isFalse);
    });

    test('a certificate failure is not a throughput verdict', () async {
      final sample = await measure(
        (_) async => throw const HandshakeException(
          'Handshake error in client',
          OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer'),
        ),
      );
      expect(sample.reachable, isFalse);
      expect(sample.stalled, isFalse);
    });

    test('a connection closed before the headers is a stall', () async {
      // IOClient's wrapping of HttpException.
      final sample = await measure(
        (_) async => throw http.ClientException(
          'Connection closed before full header was received',
        ),
      );
      expect(sample.stalled, isTrue);
    });

    test('a redirect loop is an answer, not a stall', () async {
      final sample = await measure(
        (_) async => throw http.ClientException('Redirect loop detected'),
      );
      expect(sample.stalled, isFalse);
    });

    test('a failed name lookup is not a stall', () async {
      // IOClient throws one object that is both a SocketException and a
      // ClientException; the DNS verdict must win whichever is caught first.
      final sample = await measure(
        (_) async => throw _SocketClientException(
          'Failed host lookup: speed.cloudflare.com',
        ),
      );
      expect(sample.stalled, isFalse);
    });

    test('a measured sample is never a stall', () async {
      final sample = await measure(
        (_) async => http.Response('x' * 1024, 200),
      );
      expect(sample.reachable, isTrue);
      expect(sample.stalled, isFalse);
    });
  });

  group('probe budget', () {
    test('8s per request / 20s total budget - measured TTFB on the China side fluctuates between 0.7 and 6.5s', () {
      expect(
        ConnectionProbeService.defaultPerRequestTimeout,
        const Duration(seconds: 8),
      );
      expect(
        ConnectionProbeService.defaultTotalBudget,
        const Duration(seconds: 20),
      );
    });
  });

  group('tunnel DNS', () {
    // A local UDP socket stands in for the TUN's DNS address; [reply] decides
    // what it sends back for each question it receives.
    Future<(TunnelDnsProbe, List<String>)> probeAgainst(
      List<int>? Function(List<int> query) reply,
    ) async {
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      final names = <String>[];
      server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = server.receive();
        if (datagram == null) return;
        names.add(_questionName(datagram.data));
        final answer = reply(datagram.data);
        if (answer != null) {
          server.send(answer, datagram.address, datagram.port);
        }
      });
      return (
        TunnelDnsProbe(
          InternetAddress.loopbackIPv4,
          port: server.port,
          timeout: const Duration(milliseconds: 300),
        ),
        names,
      );
    }

    test('any NXDOMAIN or NOERROR answer proves the path still resolves', () async {
      for (final rcode in [0, 3]) {
        final (probe, names) = await probeAgainst((q) => _reply(q, rcode));
        expect(await probe.run(), isTrue, reason: 'rcode $rcode');
        // A fresh name each time: no system or core cache can answer for it.
        expect(
          names.single,
          matches(RegExp(r'^aurora-[0-9a-f]{12}\.example\.com$')),
        );
      }
    });

    test('silence, SERVFAIL or a stray reply is no answer', () async {
      final (silent, _) = await probeAgainst((_) => null);
      expect(await silent.run(), isFalse);
      final (servfail, _) = await probeAgainst((q) => _reply(q, 2));
      expect(await servfail.run(), isFalse);
      final (stray, _) = await probeAgainst(
        (q) => _reply(q, 0)..[0] ^= 0xff,
      );
      expect(await stray.run(), isFalse);
      final (echo, _) = await probeAgainst((q) => List.of(q));
      expect(await echo.run(), isFalse, reason: 'a query is not an answer');
    });

    test('one dropped question is asked again before giving up', () async {
      // An upstream exchange that failed fast (the DoH connection was just
      // interrupted by a group change) sends nothing back; a stub resolver
      // would ask again, and so does the probe — same question, same id.
      var seen = 0;
      final (probe, names) = await probeAgainst(
        (q) => ++seen == 1 ? null : _reply(q, 3),
      );
      expect(await probe.run(), isTrue);
      expect(names, hasLength(2));
      expect(names.toSet(), hasLength(1));
    });

    test('names differ between rounds', () async {
      final (probe, names) = await probeAgainst((q) => _reply(q, 3));
      await probe.run();
      await probe.run();
      expect(names, hasLength(2));
      expect(names.toSet(), hasLength(2));
    });

    test('the tunnel DNS address is the host address after the TUN one', () {
      expect(auroraTunDnsServerV4(apple: true), '10.111.222.2');
      expect(auroraTunDnsServerV4(apple: false), '172.19.0.2');
    });

    const reachable = [
      ProbeResult(name: 'Google 204', category: ProbeCategory.ok),
      ProbeResult(name: 'Cloudflare 204', category: ProbeCategory.ok),
      ProbeResult(name: 'GitHub assets', category: ProbeCategory.ok),
    ];

    test('silent DNS behind reachable sites is said out loud', () {
      const report = ConnectionProbeReport(reachable, tunnelDnsAnswered: false);
      expect(report.tunnelDnsDead, isTrue);
      expect(report.category, ProbeCategory.dns);
      expect(report.summary, contains('DNS'));
      expect(report.summary, isNot(contains('passed')));
      expect(
        report.diagnosticResults.last,
        {'target': 'tunnel_dns', 'category': 'dns'},
      );
    });

    test('an answering or unmeasured DNS changes nothing', () {
      for (final answered in [true, null]) {
        final report = ConnectionProbeReport(
          reachable,
          tunnelDnsAnswered: answered,
        );
        expect(report.tunnelDnsDead, isFalse);
        expect(report.healthy, isTrue);
        expect(report.category, ProbeCategory.ok);
        expect(report.summary, contains('passed'));
      }
      expect(
        const ConnectionProbeReport(reachable).diagnosticResults,
        hasLength(3),
      );
    });

    test('run() folds the tunnel DNS answer into the report', () async {
      final (probe, _) = await probeAgainst((_) => null);
      final report = await ConnectionProbeService.run(
        client: MockClient(
          (request) async => http.Response(
            '',
            request.url.host == 'github.githubassets.com' ? 200 : 204,
          ),
        ),
        tunnelDns: probe,
      );
      expect(report.healthy, isTrue);
      expect(report.tunnelDnsAnswered, isFalse);
    });
  });
}

String _questionName(List<int> query) {
  final labels = <String>[];
  var i = 12;
  while (query[i] != 0) {
    labels.add(String.fromCharCodes(query.sublist(i + 1, i + 1 + query[i])));
    i += query[i] + 1;
  }
  return labels.join('.');
}

/// The query echoed back as a response with [rcode] and no answers.
List<int> _reply(List<int> query, int rcode) =>
    List.of(query)
      ..[2] = 0x81
      ..[3] = 0x80 | rcode;

/// Mirrors package:http's private `_ClientSocketException`.
class _SocketClientException extends http.ClientException
    implements SocketException {
  _SocketClientException(super.message);

  @override
  OSError? get osError => null;

  @override
  InternetAddress? get address => null;

  @override
  int? get port => null;
}

// Only replaces the network destination; IOClient and the platform TLS stack
// perform the actual request, certificate checks, and exception propagation.
class _LocalTlsClient extends http.BaseClient {
  _LocalTlsClient(int port)
    : _endpoint = Uri.parse('https://127.0.0.1:$port'),
      _client = IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  final Uri _endpoint;
  final IOClient _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _client.send(http.Request(request.method, _endpoint));

  @override
  void close() => _client.close();
}
