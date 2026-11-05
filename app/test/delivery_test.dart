import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/contract.dart';
import 'package:aurora/data/contract_verifier.dart';
import 'package:aurora/data/delivery.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _validContract = '''
{
  "version": 1,
  "profile": { "default_mode": "smart" },
  "nodes": [
    { "id": "n1", "protocol": "shadowsocks-2022", "server": "203.0.113.4", "port": 8443,
      "params": { "method": "2022-blake3-aes-128-gcm", "password": "x" } }
  ],
  "outbound_group": {
    "selector": { "tag": "proxy", "members": ["auto","n1"], "default": "auto" },
    "urltest": { "tag": "auto", "members": ["n1"] }
  }
}
''';

void main() {
  group('DeliveryInfo', () {
    test('parses delivery block and orders fetch urls primary-first', () {
      final d = DeliveryInfo.fromJson({
        'primary': 'https://cp.example/v2/contract',
        'fallbacks': ['http://203.0.113.4:8088/c.json', 'tailscale:/aurora/c.json'],
        'token': 'tok123',
      });
      // tailscale: is dropped; primary comes first.
      expect(d.fetchUrls, [
        'https://cp.example/v2/contract',
        'http://203.0.113.4:8088/c.json',
      ]);
      expect(d.token, 'tok123');
    });

    test('missing delivery block -> empty, no fetch urls', () {
      final c = AuroraContract.fromJson(
        json.decode(_validContract) as Map<String, dynamic>,
      );
      expect(c.delivery.fetchUrls, isEmpty);
    });
  });

  group('DeliveryService.fetchFreshContract', () {
    test(
      'hung discovery and primary cannot starve a healthy fallback',
      () async {
        final client = MockClient((request) async {
          if (request.url.host == 'live.example') {
            return http.Response(_validContract, 200);
          }
          return Completer<http.Response>().future;
        });
        final body = await DeliveryService.fetchFreshContract(
          const DeliveryInfo(
            getDomain: 'https://bootstrap.example/v2/get_domain',
            primary: 'https://dead.example/v2/contract',
            fallbacks: ['https://live.example/v2/contract'],
          ),
          client: client,
          perUrlTimeout: const Duration(milliseconds: 60),
          totalBudget: const Duration(milliseconds: 100),
        );
        expect(body, _validContract);
      },
    );

    test('a request cannot outlive the total delivery budget', () async {
      final elapsed = Stopwatch()..start();
      final body = await DeliveryService.fetchFreshContract(
        const DeliveryInfo(primary: 'https://dead.example/v2/contract'),
        client: MockClient((_) => Completer<http.Response>().future),
        perUrlTimeout: const Duration(milliseconds: 400),
        totalBudget: const Duration(milliseconds: 40),
      );
      expect(body, isNull);
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 200)));
    });

    test('races discovered endpoints with the static primary', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add('${req.url.host}${req.url.path}');
        if (req.url.path == '/v2/get_domain') {
          return http.Response(
            '{"ok":1,"domains":["https://live.example"]}',
            200,
          );
        }
        if (req.url.host == 'live.example') {
          return http.Response(_validContract, 200);
        }
        return http.Response('dead', 500);
      });
      final body = await DeliveryService.fetchFreshContract(
        const DeliveryInfo(
          getDomain: 'https://bootstrap.example/v2/get_domain',
          primary: 'https://static.example/v2/contract',
          token: 'tok123',
        ),
        client: client,
      );
      expect(body, isNotNull);
      expect(
        hits,
        containsAll([
          'bootstrap.example/v2/get_domain',
          'live.example/v2/contract',
          'static.example/v2/contract',
        ]),
      );
    });

    test(
      'discovery accepts a complete contract URL and de-duplicates it',
      () async {
        var contractHits = 0;
        final client = MockClient((req) async {
          if (req.url.path == '/v2/get_domain') {
            return http.Response(
              '{"domains":["https://same.example/v2/contract"]}',
              200,
            );
          }
          contractHits++;
          return http.Response(_validContract, 200);
        });
        final body = await DeliveryService.fetchFreshContract(
          const DeliveryInfo(
            getDomain: 'https://bootstrap.example/v2/get_domain',
            primary: 'https://same.example/v2/contract',
          ),
          client: client,
        );
        expect(body, isNotNull);
        expect(contractHits, 1);
      },
    );

    test('failed discovery falls back to the static primary', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.host);
        if (req.url.host == 'bootstrap.example') {
          return http.Response('nope', 503);
        }
        return http.Response(_validContract, 200);
      });
      final body = await DeliveryService.fetchFreshContract(
        const DeliveryInfo(
          getDomain: 'https://bootstrap.example/v2/get_domain',
          primary: 'https://static.example/v2/contract',
        ),
        client: client,
      );
      expect(body, isNotNull);
      expect(hits, ['bootstrap.example', 'static.example']);
    });

    test('returns body from primary and appends the token', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(_validContract, 200);
      });
      final body = await DeliveryService.fetchFreshContract(
        DeliveryInfo(
          primary: 'https://cp.example/v2/contract',
          token: 'tok123',
        ),
        client: client,
      );
      expect(body, isNotNull);
      expect(seen!.queryParameters['token'], 'tok123');
    });

    test('falls through to the next url when the first fails', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.host);
        if (req.url.host == 'dead.example') return http.Response('nope', 500);
        return http.Response(_validContract, 200);
      });
      final body = await DeliveryService.fetchFreshContract(
        DeliveryInfo(
          primary: 'https://dead.example/c',
          fallbacks: const ['https://live.example/c'],
        ),
        client: client,
      );
      expect(body, isNotNull);
      expect(hits, ['dead.example', 'live.example']);
    });

    test('rejects a 200 body that is not a valid contract', () async {
      final client = MockClient(
        (req) async => http.Response('{"garbage":1}', 200),
      );
      final body = await DeliveryService.fetchFreshContract(
        DeliveryInfo(primary: 'https://cp.example/c'),
        client: client,
      );
      expect(body, isNull);
    });

    test('no fetchable urls -> null without any request', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final body = await DeliveryService.fetchFreshContract(
        DeliveryInfo(fallbacks: const ['tailscale:/only']),
        client: client,
      );
      expect(body, isNull);
      expect(called, isFalse);
    });

    for (final rejectedReason in ['invalid signature', 'older revision']) {
      test(
        '$rejectedReason cannot win over a verified newer fallback',
        () async {
          final algorithm = Ed25519();
          final keyPair = await algorithm.newKeyPair();
          final publicKey = base64.encode(
            (await keyPair.extractPublicKey()).bytes,
          );
          Future<String> signed(int revision) async {
            final raw = json.decode(_validContract) as Map<String, dynamic>;
            raw['revision'] = revision;
            raw['issued_at'] = DateTime.now()
                .subtract(const Duration(minutes: 1))
                .toUtc()
                .toIso8601String();
            raw['expires_at'] = DateTime.now()
                .add(const Duration(days: 1))
                .toUtc()
                .toIso8601String();
            final signature = await algorithm.sign(
              utf8.encode(ContractVerifier.canonicalJson(raw)),
              keyPair: keyPair,
            );
            raw['signature'] = {
              'algorithm': 'ed25519',
              'key_id': 'aurora-key-1',
              'value': base64.encode(signature.bytes),
            };
            return json.encode(raw);
          }

          final good = await signed(43);
          final rejected = rejectedReason == 'older revision'
              ? await signed(41)
              : good.replaceFirst('"revision":43', '"revision":44');
          final body = await DeliveryService.fetchFreshContract(
            const DeliveryInfo(
              primary: 'https://primary.example/v2/contract',
              fallbacks: ['https://fallback.example/v2/contract'],
            ),
            client: MockClient((request) async {
              if (request.url.host == 'primary.example') {
                return http.Response(rejected, 200);
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
              return http.Response(good, 200);
            }),
            acceptCandidate: (body) async {
              await ContractVerifier.verifyRemote(
                body,
                clientVersion: '0.1.3',
                publicKey: publicKey,
              );
              return (json.decode(body)['revision'] as int) > 42;
            },
          );
          expect(body, good);
        },
      );
    }
    test(
      'a validation finishing after the deadline cannot return a candidate',
      () async {
        final validation = Completer<bool>();
        final body = await DeliveryService.fetchFreshContract(
          const DeliveryInfo(primary: 'https://primary.example/v2/contract'),
          client: MockClient((_) async => http.Response(_validContract, 200)),
          totalBudget: const Duration(milliseconds: 40),
          acceptCandidate: (_) => validation.future,
        );
        expect(body, isNull);
        validation.complete(true);
        await Future<void>.delayed(Duration.zero);
      },
    );

    test(
      'HTTP discovery cannot disclose a read token to a new HTTPS origin',
      () async {
        Uri? discoveredRequest;
        final body = await DeliveryService.fetchFreshContract(
          const DeliveryInfo(
            getDomain: 'http://bootstrap.example/v2/get_domain',
            token: 'test-read-token',
          ),
          client: MockClient((request) async {
            if (request.url.host == 'bootstrap.example') {
              return http.Response(
                '{"domains":["https://injected.example"]}',
                200,
              );
            }
            discoveredRequest = request.url;
            return http.Response(_validContract, 200);
          }),
        );
        expect(body, _validContract);
        expect(
          discoveredRequest!.queryParameters.containsKey('token'),
          isFalse,
        );
      },
    );

    test(
      'a redirect cannot carry a delivery query token to another endpoint',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = http.Client();
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        var redirectedRequests = 0;
        server.listen((request) async {
          if (request.uri.path == '/contract') {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              'location',
              '/untrusted?token=test-explicit-token',
            );
          } else {
            redirectedRequests++;
            request.response.write(_validContract);
          }
          await request.response.close();
        });
        final body = await DeliveryService.fetchFreshContract(
          DeliveryInfo(
            primary:
                'http://127.0.0.1:${server.port}/contract?token=test-explicit-token',
          ),
          client: client,
        );
        expect(body, isNull);
        expect(redirectedRequests, 0);
      },
    );
  });
}
