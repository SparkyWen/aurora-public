import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/aurora_bridge_svc.dart';
import 'package:aurora/core/aurora_svc_client.dart';
import 'package:aurora/core/clash_api_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adopting a starting helper waits without guessing core coordinates', () {
    fakeAsync((clock) {
      var ready = false;
      var coreRequests = 0;
      final bridge = bridgeWithHttp(
        (request) async => http.Response(
          request.url.path == '/status'
              ? ready
                    ? '{"state":"running","clash_probe":{"port":41234,"secret":"new-session"}}'
                    : '{"state":"starting"}'
              : '',
          200,
        ),
        clash: (request) async {
          coreRequests++;
          return http.Response('{}', 200);
        },
      );
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      AuroraStatus? observed;
      bridge.status().then((value) => observed = value);
      clock.flushMicrotasks();
      expect(observed, AuroraStatus.connecting);
      clock.elapse(const Duration(seconds: 2));
      expect(coreRequests, 0);
      expect(states, [AuroraStatus.connecting]);
      ready = true;
      clock.elapse(const Duration(seconds: 1));
      expect(states.last, AuroraStatus.connected);
      expect(coreRequests, greaterThan(0));
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  for (final poll in [false, true]) {
    test(
      'helper starting invalidates the previous core on ${poll ? 'poll' : 'status'}',
      () {
        fakeAsync((clock) {
          var starting = false;
          var unavailable = false;
          var coreRequests = 0;
          final bridge = bridgeWithHttp(
            (request) async {
              if (request.url.path == '/status') {
                if (unavailable) throw const SocketException('helper busy');
                return http.Response(
                  starting
                      ? '{"state":"starting"}'
                      : '{"state":"running","clash_probe":{"port":41234,"secret":"previous-session"}}',
                  200,
                );
              }
              return http.Response('', 200);
            },
            clash: (request) async {
              coreRequests++;
              return http.Response('{}', 200);
            },
          );
          final states = <AuroraStatus>[];
          bridge.statusStream().listen(states.add);
          bridge.status();
          clock.flushMicrotasks();
          expect(states.last, AuroraStatus.connected);
          final before = coreRequests;
          starting = true;
          if (poll) {
            clock.elapse(const Duration(seconds: 1));
          } else {
            bridge.status();
            clock.flushMicrotasks();
          }
          expect(states.last, AuroraStatus.connecting);
          expect(coreRequests, before);
          unavailable = true;
          clock.elapse(const Duration(seconds: 1));
          expect(states.last, AuroraStatus.error);
          expect(
            coreRequests,
            before,
            reason: 'A stale core cannot override the last starting snapshot',
          );
          bridge.stop();
          clock.flushMicrotasks();
        });
      },
    );
  }

  for (final helperFails in [false, true]) {
    test(
      'a pending replacement never adopts the previous core (helper failure=$helperFails)',
      () {
        fakeAsync((clock) {
          var replacing = false;
          final started = Completer<void>();
          final bridge = bridgeWithHttp((request) async {
            if (request.url.path == '/start') {
              await started.future;
            } else if (request.url.path == '/status') {
              if (replacing && helperFails) {
                throw const SocketException('helper busy');
              }
              return http.Response(
                '{"state":"running","clash_probe":{"port":41234,"secret":"previous-secret"}}',
                200,
              );
            }
            return http.Response('', 200);
          });
          bridge.status();
          clock.flushMicrotasks();
          replacing = true;
          bridge.clashPort = 42345;
          bridge.clashSecret = 'replacement-secret';
          bridge.start('{}');
          clock.flushMicrotasks();
          AuroraStatus? observed;
          bridge.status().then((value) => observed = value);
          clock.flushMicrotasks();
          expect(
            observed,
            AuroraStatus.connecting,
            reason: 'Only the replacement startup can confirm its session',
          );
          expect(bridge.clashPort, 42345);
          started.complete();
          clock.flushMicrotasks();
          bridge.stop();
          clock.flushMicrotasks();
        });
      },
    );
  }

  for (final poll in [false, true]) {
    test(
      'healthy core survives a transient ${poll ? 'poll' : 'status'} failure',
      () {
        fakeAsync((clock) {
          var unavailable = false;
          final bridge = bridgeWithHttp((request) async {
            if (request.url.path == '/status') {
              if (unavailable) {
                throw const SocketException('service temporarily busy');
              }
              return http.Response(
                '{"state":"running","clash_probe":{"port":41234,"secret":"session-secret"}}',
                200,
              );
            }
            return http.Response('', 200);
          });
          final states = <AuroraStatus>[];
          bridge.statusStream().listen(states.add);
          bridge.status();
          clock.flushMicrotasks();
          if (poll) clock.elapse(const Duration(seconds: 1));
          expect(states, contains(AuroraStatus.connected));
          unavailable = true;
          Object? failure;
          AuroraStatus? observed;
          if (poll) {
            clock.elapse(const Duration(seconds: 1));
          } else {
            bridge.status().then<void>(
              (value) => observed = value,
              onError: (Object error) => failure = error,
            );
            clock.flushMicrotasks();
            expect(failure, isNull);
            expect(observed, AuroraStatus.connected);
          }
          expect(
            states,
            isNot(contains(AuroraStatus.error)),
            reason:
                'A responding authenticated core must not lose its supervisor',
          );
          expect(
            bridge.lastFailureDetail,
            contains('service temporarily busy'),
          );
          bridge.stop();
          clock.flushMicrotasks();
        });
      },
    );
  }

  test('service authentication failure is visible even with a healthy core', () {
    fakeAsync((clock) {
      var rejected = false;
      final bridge = bridgeWithHttp((request) async {
        if (request.url.path == '/status') {
          if (rejected) return http.Response('unauthorized', 401);
          return http.Response(
            '{"state":"running","clash_probe":{"port":41234,"secret":"session-secret"}}',
            200,
          );
        }
        return http.Response('', 200);
      });
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.status();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      rejected = true;
      clock.elapse(const Duration(seconds: 1));
      expect(states.last, AuroraStatus.error);
      expect(bridge.lastFailureDetail, contains('svc_auth_failed'));
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  test('unreachable helper and core still report loss of control', () {
    fakeAsync((clock) {
      var unavailable = false;
      final bridge = bridgeWithHttp(
        (request) async {
          if (request.url.path == '/status') {
            if (unavailable) throw const SocketException('helper unavailable');
            return http.Response(
              '{"state":"running","clash_probe":{"port":41234,"secret":"session-secret"}}',
              200,
            );
          }
          return http.Response('', 200);
        },
        clash: (_) async {
          if (unavailable) throw const SocketException('core unavailable');
          return http.Response('{}', 200);
        },
      );
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.status();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      unavailable = true;
      clock.elapse(const Duration(seconds: 1));
      expect(states.last, AuroraStatus.error);
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  test('late fallback core ping cannot resurrect a manually stopped session', () {
    fakeAsync((clock) {
      var unavailable = false;
      final fallbackPing = Completer<http.Response>();
      final bridge = bridgeWithHttp(
        (request) async {
          if (request.url.path == '/status') {
            if (unavailable) throw const SocketException('helper unavailable');
            return http.Response(
              '{"state":"running","clash_probe":{"port":41234,"secret":"session-secret"}}',
              200,
            );
          }
          return http.Response('', 200);
        },
        clash: (_) async =>
            unavailable ? fallbackPing.future : http.Response('{}', 200),
      );
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.status();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      unavailable = true;
      clock.elapse(const Duration(seconds: 1));
      bridge.stop();
      clock.flushMicrotasks();
      expect(states.last, AuroraStatus.disconnected);
      fallbackPing.complete(http.Response('{}', 200));
      clock.flushMicrotasks();
      expect(states.last, AuroraStatus.disconnected);
    });
  });

  test('stop drains a late start before confirming disconnection', () {
    fakeAsync((clock) {
      final lateStart = Completer<void>();
      var running = false;
      var stops = 0;
      var stopCompleted = false;
      final bridge = bridgeWithHttp((request) async {
        if (request.url.path == '/start') {
          await lateStart.future;
          running = true;
        } else if (request.url.path == '/stop') {
          stops++;
          running = false;
        }
        return http.Response('', 200);
      });
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.start('{}');
      clock.flushMicrotasks();
      bridge.stop().then((_) {
        stopCompleted = true;
      });
      clock.flushMicrotasks();
      expect(stops, 1, reason: 'Stop must immediately cancel readiness');
      expect(
        stopCompleted,
        isFalse,
        reason: 'A delayed start can still launch',
      );
      expect(states.last, AuroraStatus.disconnecting);
      lateStart.complete();
      clock.flushMicrotasks();
      expect(stops, 2, reason: 'Drain then stop the late startup');
      expect(running, isFalse);
      expect(stopCompleted, isTrue);
      expect(states.last, AuroraStatus.disconnected);
    });
  });

  test(
    'a newer start waits for old startup cleanup and cannot be killed by it',
    () {
      fakeAsync((clock) {
        final lateStart = Completer<void>();
        final cleanup = Completer<void>();
        final events = <String>[];
        var running = '';
        var stops = 0;
        final bridge = bridgeWithHttp((request) async {
          if (request.url.path == '/start') {
            final config = jsonDecode(request.body)['config'] as String;
            events.add('start:$config');
            if (config == 'old') await lateStart.future;
            running = config;
          } else if (request.url.path == '/stop') {
            stops++;
            events.add('stop:$stops');
            if (stops == 2) await cleanup.future;
            running = '';
          }
          return http.Response('', 200);
        });
        bridge.start('old');
        clock.flushMicrotasks();
        bridge.stop();
        clock.flushMicrotasks();
        bridge.start('new');
        clock.flushMicrotasks();
        expect(events, ['start:old', 'stop:1']);
        lateStart.complete();
        clock.flushMicrotasks();
        expect(events, ['start:old', 'stop:1', 'stop:2']);
        cleanup.complete();
        clock.flushMicrotasks();
        expect(events, ['start:old', 'stop:1', 'stop:2', 'start:new']);
        expect(running, 'new');
        bridge.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'late startup cleanup failure remains visible and keeps observation alive',
    () {
      fakeAsync((clock) {
        final lateStart = Completer<void>();
        var stops = 0;
        var observations = 0;
        final bridge = bridgeWithHttp((request) async {
          if (request.url.path == '/start') await lateStart.future;
          if (request.url.path == '/stop' && ++stops == 2) {
            return http.Response('unauthorized', 401);
          }
          if (request.url.path == '/status') {
            observations++;
            return http.Response('unauthorized', 401);
          }
          return http.Response('', 200);
        });
        final states = <AuroraStatus>[];
        bridge.statusStream().listen(states.add);
        bridge.start('{}');
        clock.flushMicrotasks();
        Object? stopError;
        bridge.stop().then<void>(
          (_) {},
          onError: (Object error) {
            stopError = error;
          },
        );
        clock.flushMicrotasks();
        lateStart.complete();
        clock.flushMicrotasks();
        expect(stopError, isA<StateError>());
        expect(states.last, AuroraStatus.error);
        expect(states, isNot(contains(AuroraStatus.disconnected)));
        clock.elapse(const Duration(seconds: 1));
        expect(observations, greaterThan(0));
        bridge.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'an old controller authentication failure cannot replace an adopted session',
    () {
      fakeAsync((clock) {
        var port = 41234;
        var oldPings = 0;
        final oldPing = Completer<http.Response>();
        final bridge = bridgeWithHttp(
          (request) async => http.Response(
            request.url.path == '/status'
                ? '{"state":"running","clash_probe":{"port":$port,"secret":"session-$port"}}'
                : '',
            200,
          ),
          clash: (request) async {
            if (request.url.port == 41234 &&
                request.url.path == '/version' &&
                ++oldPings > 1) {
              return oldPing.future;
            }
            return http.Response('{}', 200);
          },
        );
        final states = <AuroraStatus>[];
        bridge.statusStream().listen(states.add);
        bridge.status();
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        port = 42345;
        bridge.status();
        clock.flushMicrotasks();
        oldPing.complete(http.Response('unauthorized', 401));
        clock.flushMicrotasks();
        expect(states, isNot(contains(AuroraStatus.error)));
        expect(bridge.lastFailureDetail, isNot(contains('clash_auth_failed')));
        bridge.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('an older helper status cannot restore obsolete session coordinates', () {
    fakeAsync((clock) {
      var calls = 0;
      final oldStatus = Completer<http.Response>();
      final bridge = bridgeWithHttp((request) async {
        if (request.url.path != '/status') return http.Response('', 200);
        calls++;
        if (calls == 2) return oldStatus.future;
        final port = calls == 1 ? 41234 : 42345;
        return http.Response(
          '{"state":"running","clash_probe":{"port":$port,"secret":"session-$port"}}',
          200,
        );
      });
      bridge.status();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      bridge.status();
      clock.flushMicrotasks();
      expect(bridge.clashPort, 42345);
      oldStatus.complete(
        http.Response(
          '{"state":"running","clash_probe":{"port":41234,"secret":"session-41234"}}',
          200,
        ),
      );
      clock.flushMicrotasks();
      expect(bridge.clashPort, 42345);
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  test('a relaunched app adopts the running tunnel port and secret', () async {
    final bridge = bridgeWithHttp(
      (request) async => http.Response(
        request.url.path == '/status'
            ? '{"state":"running","clash_probe":{"port":41234,"secret":"live-session-secret"}}'
            : '',
        200,
      ),
      clash: (request) async => http.Response(
        '{}',
        request.url.port == 41234 &&
                request.headers['Authorization'] == 'Bearer live-session-secret'
            ? 200
            : 401,
      ),
    );
    try {
      expect(await bridge.status(), AuroraStatus.connected);
    } finally {
      await bridge.stop();
    }
  });

  test('poll adopts rotated coordinates and ignores old in-flight telemetry', () {
    fakeAsync((clock) {
      var port = 41234;
      final oldTraffic = Completer<http.Response>();
      final bridge = bridgeWithHttp(
        (request) async => http.Response(
          request.url.path == '/status'
              ? '{"state":"running","clash_probe":{"port":$port,"secret":"session-$port"}}'
              : '',
          200,
        ),
        clash: (request) async {
          if (request.headers['Authorization'] !=
                  'Bearer session-${request.url.port}' ||
              (request.url.port != 41234 && request.url.port != 42345)) {
            return http.Response('unauthorized', 401);
          }
          if (request.url.path == '/connections') {
            if (request.url.port == 41234) return oldTraffic.future;
            return http.Response('{"uploadTotal":222}', 200);
          }
          return http.Response('{}', 200);
        },
      );
      final totals = <int>[];
      bridge.statsStream().listen((s) => totals.add(s.uplinkTotal));
      bridge.status();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      port = 42345;
      bridge.status();
      clock.flushMicrotasks();
      oldTraffic.complete(http.Response('{"uploadTotal":999}', 200));
      clock.flushMicrotasks();
      expect(totals, isEmpty, reason: 'The old child no longer owns telemetry');
      clock.elapse(const Duration(seconds: 1));
      expect(totals, [222]);
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'legacy status without coordinates cannot adopt an unrelated open API',
    () async {
      final bridge = bridgeWithHttp(
        (request) async => http.Response(
          request.url.path == '/status' ? '{"state":"running"}' : '',
          200,
        ),
        // Another process on default port 9090 answering is not our tunnel.
        clash: (_) async => http.Response('{}', 200),
      );
      try {
        expect(await bridge.status(), AuroraStatus.error);
        expect(bridge.lastFailureDetail, 'svc_session_unavailable');
      } finally {
        await bridge.stop();
      }
    },
  );

  test('a legacy helper keeps the coordinates supplied by this connection', () {
    fakeAsync((clock) {
      final bridge =
          bridgeWithHttp(
              (request) async => http.Response(
                request.url.path == '/status' ? '{"state":"running"}' : '',
                200,
              ),
              clash: (request) async => http.Response(
                '{}',
                request.url.port == 41234 &&
                        request.headers['Authorization'] ==
                            'Bearer local-session-secret'
                    ? 200
                    : 401,
              ),
            )
            ..clashPort = 41234
            ..clashSecret = 'local-session-secret';
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.start('{}');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(states.last, AuroraStatus.connected);
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  test('stop failure reports error and resumes service observation', () {
    fakeAsync((clock) {
      var stopFails = true;
      var statusCalls = 0;
      final bridge = bridgeWithHttp((request) async {
        if (request.url.path == '/stop' && stopFails) {
          return http.Response('unauthorized', 401);
        }
        if (request.url.path == '/status') {
          statusCalls++;
          return http.Response('{"state":"running"}', 200);
        }
        return http.Response('', 200);
      });
      final states = <AuroraStatus>[];
      bridge.statusStream().listen(states.add);
      bridge.start('{}');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      expect(states.last, AuroraStatus.connected);
      final observedBeforeStop = statusCalls;
      Object? error;
      bridge.stop().then<void>(
        (_) {},
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      expect(error, isA<StateError>());
      expect(states.last, AuroraStatus.error);
      expect(states, isNot(contains(AuroraStatus.disconnected)));
      expect(bridge.lastFailureDetail, contains('svc_auth_failed'));
      clock.elapse(const Duration(seconds: 1));
      expect(statusCalls, greaterThan(observedBeforeStop));
      stopFails = false;
      bridge.stop();
      clock.flushMicrotasks();
    });
  });

  for (final restart in [false, true]) {
    test(
      'old status response cannot overwrite ${restart ? 'new session' : 'stop'}',
      () {
        fakeAsync((clock) {
          final oldStatus = Completer<http.Response>();
          var polls = 0;
          final bridge = bridgeWithHttp((request) async {
            if (request.url.path == '/status') {
              polls++;
              if (polls == 1) return oldStatus.future;
              return http.Response('{"state":"running"}', 200);
            }
            return http.Response('', 200);
          });
          final states = <AuroraStatus>[];
          bridge.statusStream().listen(states.add);
          bridge.start('{}');
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 1));
          bridge.stop();
          clock.flushMicrotasks();
          if (restart) {
            bridge.start('{"new":true}');
            clock.flushMicrotasks();
            clock.elapse(const Duration(seconds: 1));
            expect(
              states.last,
              AuroraStatus.connected,
              reason: 'An old in-flight request must not block a new poll',
            );
          }
          oldStatus.complete(
            http.Response(
              '{"state":"error","detail":"old session failed"}',
              200,
            ),
          );
          clock.flushMicrotasks();
          expect(
            states.last,
            restart ? AuroraStatus.connected : AuroraStatus.disconnected,
          );
          expect(
            bridge.lastFailureDetail,
            isNot(contains('old session failed')),
          );
          bridge.stop();
          clock.flushMicrotasks();
        });
      },
    );
  }

  test('old traffic result cannot repopulate stats after stop', () {
    fakeAsync((clock) {
      final oldTraffic = Completer<http.Response>();
      final bridge = bridgeWithHttp(
        (request) async => http.Response(
          request.url.path == '/status' ? '{"state":"running"}' : '',
          200,
        ),
        clash: (request) async => request.url.path == '/connections'
            ? oldTraffic.future
            : http.Response('{}', 200),
      );
      final totals = <int>[];
      bridge.statsStream().listen((stats) => totals.add(stats.uplinkTotal));
      bridge.start('{}');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      bridge.stop();
      clock.flushMicrotasks();
      expect(totals, [0]);
      oldTraffic.complete(http.Response('{"uploadTotal":999}', 200));
      clock.flushMicrotasks();
      expect(totals, [0]);
    });
  });

  test('the failure reason from the service is kept, not lost by only going into the log stream', () {
    final bridge = AuroraBridgeSvc.debugInstance();
    expect(bridge.lastFailureDetail, isNull);
    bridge.debugPublishDetail(
      'FATAL start service: listen tcp 127.0.0.1:9090: '
      'bind: address already in use',
    );
    expect(
      bridge.lastFailureDetail,
      contains('address already in use'),
      // This line used to go only into logStream, and ConnectFlow.describeError never
      // read it, so Windows users saw only the useless "the core failed to start".
    );
  });

  test('the Clash port follows each connection', () {
    final bridge = AuroraBridgeSvc.debugInstance();
    bridge.clashPort = 41234;
    expect(bridge.clashBase.toString(), 'http://127.0.0.1:41234');
  });
}

AuroraBridgeSvc bridgeWithHttp(
  Future<http.Response> Function(http.Request) service, {
  Future<http.Response> Function(http.Request)? clash,
}) => AuroraBridgeSvc.debugInstance(
  svc: AuroraSvcClient(token: () => 'svc-token', client: MockClient(service)),
  clashClientFactory: (base, secret) => ClashApiClient(
    base: base,
    secret: secret,
    client: MockClient(clash ?? (_) async => http.Response('{}', 200)),
  ),
);
