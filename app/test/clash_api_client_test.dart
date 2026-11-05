import 'dart:async';
import 'dart:convert';

import 'package:aurora/core/clash_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:9090');

  test(
    'ping reports invalid credentials instead of indefinite connecting',
    () async {
      final c = ClashApiClient(
        base: base,
        secret: 's',
        client: MockClient((_) async => http.Response('unauthorized', 401)),
      );
      await expectLater(
        c.ping(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'clash_auth_failed',
          ),
        ),
      );
    },
  );

  for (final operation in ['traffic', 'groups', 'delay', 'select']) {
    test('$operation reports authentication failure before parsing', () async {
      final c = ClashApiClient(
        base: base,
        secret: 'clash-private-secret',
        client: MockClient((_) async => http.Response('unauthorized', 401)),
      );
      final request = switch (operation) {
        'traffic' => c.traffic(),
        'groups' => c.groups(),
        'select' => c.select('proxy', 'node'),
        _ => c.groupDelay('proxy'),
      };
      await expectLater(
        request,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'clash_auth_failed',
          ),
        ),
      );
    });

    test('$operation times out when the API never answers', () {
      fakeAsync((clock) {
        final c = ClashApiClient(
          base: base,
          secret: 's',
          client: MockClient((_) => Completer<http.Response>().future),
        );
        Object? error;
        final request = switch (operation) {
          'traffic' => c.traffic(),
          'groups' => c.groups(),
          'select' => c.select('proxy', 'node'),
          _ => c.groupDelay('proxy'),
        };
        request.then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        clock.elapse(const Duration(seconds: 10));
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'clash_request_timeout',
          ),
        );
        c.close();
      });
    });
  }

  test(
    'HTTP errors cannot become empty groups or zero traffic/delay',
    () async {
      final c = ClashApiClient(
        base: base,
        secret: 's',
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      await expectLater(c.traffic(), throwsA(isA<StateError>()));
      await expectLater(c.groups(), throwsA(isA<StateError>()));
      await expectLater(c.groupDelay('proxy'), throwsA(isA<StateError>()));
    },
  );

  test('groups() parses selector + items with delays', () async {
    final mock = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer s3cret');
      expect(req.url.path, '/proxies');
      return http.Response(
        jsonEncode({
          'proxies': {
            'proxy': {
              'type': 'Selector',
              'now': 'home-via-reality',
              'all': ['home-via-reality', 'home-via-hy2'],
            },
            'home-via-reality': {
              'type': 'Shadowsocks',
              'history': [
                {'time': 't', 'delay': 231},
              ],
            },
            'home-via-hy2': {'type': 'Shadowsocks', 'history': []},
          },
        }),
        200,
      );
    });
    final c = ClashApiClient(base: base, secret: 's3cret', client: mock);
    final groups = await c.groups();
    final proxy = groups.firstWhere((g) => g.tag == 'proxy');
    expect(proxy.type, 'Selector');
    expect(proxy.selected, 'home-via-reality');
    expect(proxy.selectable, isTrue);
    final item = proxy.items.firstWhere((i) => i.tag == 'home-via-reality');
    expect(item.delayMs, 231);
    final untested = proxy.items.firstWhere((i) => i.tag == 'home-via-hy2');
    expect(untested.delayMs, 0);
  });

  test('parseGroups ignores plain (non-group) proxies', () {
    final groups = ClashApiClient.parseGroups({
      'proxies': {
        'direct': {'type': 'Direct'},
        'proxy': {
          'type': 'Selector',
          'now': 'a',
          'all': ['a'],
        },
        'a': {'type': 'Shadowsocks', 'history': []},
      },
    });
    expect(groups.map((g) => g.tag), ['proxy']);
  });

  test('traffic() reads cumulative totals from /connections', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/connections');
      return http.Response(
        jsonEncode({'uploadTotal': 111, 'downloadTotal': 222}),
        200,
      );
    });
    final c = ClashApiClient(base: base, secret: 's3cret', client: mock);
    final t = await c.traffic();
    expect(t.uplinkTotal, 111);
    expect(t.downlinkTotal, 222);
  });

  test('select() PUTs the chosen name', () async {
    var requests = 0;
    final mock = MockClient((req) async {
      requests++;
      expect(req.url.path, '/proxies/proxy');
      if (req.method == 'PUT') {
        expect(jsonDecode(req.body)['name'], 'home-via-hy2');
        return http.Response('', 204);
      }
      expect(req.method, 'GET');
      return http.Response(jsonEncode({'now': 'home-via-hy2'}), 200);
    });
    final c = ClashApiClient(base: base, secret: 's3cret', client: mock);
    await c.select('proxy', 'home-via-hy2');
    expect(requests, 2);
  });

  test('select() rejects failed PUT and mismatched readback', () async {
    final rejected = ClashApiClient(
      base: base,
      secret: 's3cret',
      client: MockClient((_) async => http.Response('', 500)),
    );
    await expectLater(
      rejected.select('proxy', 'home-via-hy2'),
      throwsA(isA<StateError>()),
    );

    final mismatched = ClashApiClient(
      base: base,
      secret: 's3cret',
      client: MockClient(
        (req) async => req.method == 'PUT'
            ? http.Response('', 204)
            : http.Response(jsonEncode({'now': 'home-via-reality'}), 200),
      ),
    );
    await expectLater(
      mismatched.select('proxy', 'home-via-hy2'),
      throwsA(isA<StateError>()),
    );
  });

  test('groupDelay() returns min non-zero member delay', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/group/proxy/delay');
      return http.Response(
        jsonEncode({'home-via-reality': 231, 'home-via-hy2': 180}),
        200,
      );
    });
    final c = ClashApiClient(base: base, secret: 's3cret', client: mock);
    expect(await c.groupDelay('proxy'), 180);
  });

  test('ping() true on 200, false on throw', () async {
    final ok = ClashApiClient(
      base: base,
      secret: 's',
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(await ok.ping(), isTrue);
    final bad = ClashApiClient(
      base: base,
      secret: 's',
      client: MockClient((_) async => throw http.ClientException('refused')),
    );
    expect(await bad.ping(), isFalse);
  });
}
