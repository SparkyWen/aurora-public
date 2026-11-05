import 'dart:async';
import 'dart:convert';

import 'package:aurora/core/aurora_svc_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:53421');

  // The service runs as LocalSystem and the app as the logged-in user, so a
  // filesystem path means two different things on the two sides of this call —
  // which is exactly how every /start came back
  // "403 config path outside allowed dir". The config travels as bytes now.
  test('start() posts the config itself, never a path', () async {
    var hit = false;
    final mock = MockClient((req) async {
      hit = true;
      expect(req.url.path, '/start');
      expect(req.headers['Authorization'], 'Bearer tok');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['config'], '{"log":{"level":"info"}}');
      expect(body.containsKey('configPath'), isFalse);
      return http.Response('', 200);
    });
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    await c.start('{"log":{"level":"info"}}');
    expect(hit, isTrue);
  });

  // The token is provisioned by the privileged side, which may only come up
  // after the app has already built this client (fresh install, service
  // repair). A token captured at construction time answers 401 forever.
  test('every request re-reads the token', () async {
    final seen = <String?>[];
    var current = '';
    final mock = MockClient((req) async {
      seen.add(req.headers['Authorization']);
      return http.Response(jsonEncode({'state': 'stopped'}), 200);
    });
    final c = AuroraSvcClient(base: base, token: () => current, client: mock);

    await c.statusState();
    current = 'provisioned-later';
    await c.statusState();

    expect(seen, ['Bearer ', 'Bearer provisioned-later']);
  });

  // aurora-svc's handler decodes this into a Go struct tagged `json:"clash_probe"`
  // with `Port int json:"port"` / `Secret string json:"secret"` (desktop/aurora-svc/
  // ready.go) — a name mismatch on either side compiles fine but silently falls
  // back to the legacy fixed-delay path instead of waiting for the real tunnel.
  test(
    'start() sends clash_probe using the exact field names aurora-svc decodes',
    () async {
      Map<String, dynamic>? body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 200);
      });
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await c.start('{}', clashPort: 41234, clashSecret: 'deadbeef');
      expect(body!['clash_probe'], {'port': 41234, 'secret': 'deadbeef'});
    },
  );

  // Omitting clash_probe entirely (not e.g. sending nulls) is what makes the
  // service take its legacy settle-delay path — see TestHandleStartWithoutClash-
  // ProbeTakesTheLegacyPath in desktop/aurora-svc/main_test.go.
  test('start() omits clash_probe when no port/secret were given', () async {
    Map<String, dynamic>? body;
    final mock = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 200);
    });
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    await c.start('{}');
    expect(body!.containsKey('clash_probe'), isFalse);
  });

  test('start() throws carrying the service reason', () async {
    final mock = MockClient(
      (_) async =>
          http.Response('sing-box exited immediately: FATAL bad tun', 500),
    );
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    await expectLater(
      c.start('{}'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FATAL bad tun'),
        ),
      ),
    );
  });

  test('status() exposes state and the failure detail', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/status');
      return http.Response(
        jsonEncode({'state': 'error', 'detail': 'exit status 1: bind: in use'}),
        200,
      );
    });
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    final s = await c.status();
    expect(s.state, 'error');
    expect(s.detail, contains('bind: in use'));
  });

  test(
    'status() rejects a malformed body instead of claiming stopped',
    () async {
      final mock = MockClient((_) async => http.Response('not json', 200));
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await expectLater(
        c.status(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'svc_status_invalid',
          ),
        ),
      );
    },
  );

  test('installed() false when svc unreachable', () async {
    final mock = MockClient((_) async => throw http.ClientException('refused'));
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    expect(await c.installed(), isFalse);
  });

  // A reachable service with no token yet is installed — it is answering. The
  // app must not read 401 as "not installed" and send the user off to reinstall
  // a service that is running fine.
  test('installed() true even before the token is provisioned', () async {
    final mock = MockClient((_) async => http.Response('unauthorized', 401));
    final c = AuroraSvcClient(base: base, token: () => '', client: mock);
    expect(await c.installed(), isTrue);
  });

  test('installed() true on 200', () async {
    final mock = MockClient(
      (_) async => http.Response(jsonEncode({'state': 'stopped'}), 200),
    );
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    expect(await c.installed(), isTrue);
  });

  test(
    'status sanitizes the token used for a pending request after rotation',
    () async {
      final response = Completer<http.Response>();
      var token = 'previous-secret-token';
      final c = AuroraSvcClient(
        token: () => token,
        client: MockClient((_) => response.future),
      );
      final status = c.status();
      token = 'new-secret-token';
      response.complete(
        http.Response(
          '{"state":"error","detail":"rejected previous-secret-token"}',
          200,
        ),
      );
      expect((await status).detail, isNot(contains('previous-secret-token')));
    },
  );

  for (final code in [401, 403]) {
    for (final operation in ['start', 'stop', 'status']) {
      test('$operation rejects HTTP $code as authentication failure', () async {
        var calls = 0;
        final c = AuroraSvcClient(
          token: () => 'svc-private-token',
          client: MockClient((_) async {
            calls++;
            return http.Response('unauthorized svc-private-token', code);
          }),
        );
        final request = switch (operation) {
          'start' => c.start('{}'),
          'stop' => c.stop(),
          _ => c.status(),
        };
        await expectLater(
          request,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'svc_auth_failed',
            ),
          ),
        );
        expect(calls, 1, reason: 'Do not replay lifecycle commands');
      });
    }
  }

  for (final body in [
    '{}',
    '[]',
    '{"state":"unknown"}',
    '{"state":12}',
    '{"state":"running","detail":[]}',
  ]) {
    test('status rejects invalid service schema $body', () async {
      final c = AuroraSvcClient(
        token: () => 'tok',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        c.status(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'svc_status_invalid',
          ),
        ),
      );
    });
  }

  test(
    'stop rejects a service error instead of confirming disconnection',
    () async {
      final c = AuroraSvcClient(
        token: () => 'tok',
        client: MockClient((_) async => http.Response('stop failed', 500)),
      );
      await expectLater(c.stop(), throwsA(isA<StateError>()));
    },
  );

  test(
    'start failure preserves Chinese while removing sent credentials',
    () async {
      final c = AuroraSvcClient(
        token: () => 'svc-secret-value',
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              // Chinese Windows "Access is denied." plus secrets that must be scrubbed.
              '\u62d2\u7edd\u8bbf\u95ee\u3002 svc-secret-value '
              'clash-secret-value node-password-value '
              'password="another-secret"',
            ),
            500,
          ),
        ),
      );
      await expectLater(
        c.start(
          '{"outbounds":[{"password":"node-password-value"}]}',
          clashPort: 43210,
          clashSecret: 'clash-secret-value',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('\u62d2\u7edd\u8bbf\u95ee\u3002'),
              isNot(contains('svc-secret-value')),
              isNot(contains('clash-secret-value')),
              isNot(contains('node-password-value')),
              isNot(contains('another-secret')),
            ),
          ),
        ),
      );
    },
  );

  for (final operation in ['start', 'stop', 'status']) {
    test('$operation times out when the service never answers', () {
      fakeAsync((clock) {
        final c = AuroraSvcClient(
          token: () => 'tok',
          client: MockClient((_) => Completer<http.Response>().future),
        );
        Object? error;
        final request = switch (operation) {
          'start' => c.start('{}'),
          'stop' => c.stop(),
          _ => c.status(),
        };
        request.then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        clock.elapse(const Duration(minutes: 2));
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'svc_${operation}_timeout',
          ),
        );
        c.close();
      });
    });
  }

  // ---- Tunnel owner (the tunnel must not outlive the app that started it) ----

  // The field name is a cross-language contract: aurora-svc decodes it into
  // `OwnerPid int json:"owner_pid"` (desktop/aurora-svc/main.go). If the names
  // drift both sides still compile, but the tunnel has no owner any more, which
  // brings the original bug back unchanged.
  group('tunnel owner', () {
    test('start() sends this process pid under the field name aurora-svc knows', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 200);
      });
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await c.start('{}', ownerPid: 4242);
      expect(body!['owner_pid'], 4242);
    });

    // The command line deliberately does not claim the tunnel: it connects and
    // exits, and the tunnel must outlive it. Sending a 0 or a null field is not an
    // option either: the Go side would read 0 as "no owner", but sending it
    // explicitly leaves a special case in the protocol that both sides must
    // remember. So the field is simply omitted.
    test('without a pid the field is absent entirely', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 200);
      });
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await c.start('{}');
      expect(body!.containsKey('owner_pid'), isFalse);
    });

    // When a restarted app adopts a tunnel that outlived its previous owner,
    // ownership has to move with it. That rides on the once-per-second status
    // poll, so the pid is a query parameter rather than a separate endpoint.
    test('status() carries the pid in the query to re-claim the tunnel', () async {
      Uri? seen;
      final mock = MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode({'state': 'running'}), 200);
      });
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await c.status(ownerPid: 5252);
      expect(seen!.path, '/status');
      expect(seen!.queryParameters['owner_pid'], '5252');
    });

    test('status() without a pid sends no query', () async {
      Uri? seen;
      final mock = MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode({'state': 'stopped'}), 200);
      });
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      await c.status();
      expect(seen!.hasQuery, isFalse);
    });
  });

  // ---- /diagnose ("shows connected but nothing loads") ----

  group('egress interface candidates', () {
    // Deliberately `Response.bytes` with **no charset header**: that is what
    // aurora-svc looked like before it was fixed, and it is the kind of response
    // the http package decodes as latin-1. On a Chinese-locale Windows the NIC
    // names are natively localized (\u4ee5\u592a\u7f51 is "Ethernet"), and read as
    // latin-1 they come out as garbage. The user picks a name from this list and
    // it is sent back to the core as the interface name, and the core can never
    // find a garbled name.
    http.Response diagnoseResponse(List<Map<String, dynamic>> interfaces) =>
        http.Response.bytes(
          utf8.encode(jsonEncode({'interfaces': interfaces})),
          200,
        );

    test('keeps only interfaces that are up, have a non-loopback address and are not Aurora\'s own', () async {
      final mock = MockClient(
        (_) async => diagnoseResponse([
          {
            'name': 'Loopback',
            'up': true,
            'addresses': ['127.0.0.1/8', '::1/128'],
          },
          {
            'name': '\u4ee5\u592a\u7f51', // Chinese "Ethernet"
            'up': true,
            'addresses': ['192.168.1.5/24'],
          },
          {
            'name': 'WLAN',
            'up': true,
            'addresses': ['10.0.0.9/24'],
          },
          // Chinese "Bluetooth Network Connection", down, so filtered out.
          {'name': '\u84dd\u7259\u7f51\u7edc\u8fde\u63a5', 'up': false, 'addresses': []},
          {
            'name': 'aurora0',
            'up': true,
            'addresses': ['172.19.0.1/30'],
          },
        ]),
      );
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      expect(await c.egressInterfaceCandidates(tunInterfaceName: 'aurora0'), [
        '\u4ee5\u592a\u7f51',
        'WLAN',
      ]);
    });

    test('unreachable service gives an empty list instead of throwing', () async {
      final mock = MockClient((_) async => throw http.ClientException('nope'));
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      expect(
        await c.egressInterfaceCandidates(tunInterfaceName: 'aurora0'),
        isEmpty,
      );
    });

    test('a body of the wrong shape also gives an empty list', () async {
      final mock = MockClient((_) async => http.Response('not json', 200));
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      expect(
        await c.egressInterfaceCandidates(tunInterfaceName: 'aurora0'),
        isEmpty,
      );
    });

    test('diagnose() returns null on a non-200 response', () async {
      final mock = MockClient((_) async => http.Response('nope', 401));
      final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
      expect(await c.diagnose(), isNull);
    });
  });

  // The same trap is worse on /status: failure details carry a localized Win32
  // error string, and that sentence is the only thing on the whole failure path
  // that tells the user where to look. The escaped text is a Chinese Windows
  // "Access is denied." message.
  test('/status detail is read as UTF-8, not the latin-1 the missing charset implies', () async {
    final mock = MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(
          jsonEncode({'state': 'error', 'detail': '\u62d2\u7edd\u8bbf\u95ee\u3002'}),
        ),
        200,
      ),
    );
    final c = AuroraSvcClient(base: base, token: () => 'tok', client: mock);
    expect((await c.status()).detail, '\u62d2\u7edd\u8bbf\u95ee\u3002');
  });
}
