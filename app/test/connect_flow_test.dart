import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/connect_flow.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/aurora_bridge_svc.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/core/route_family.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancelled connection never begins preparation or retries', () async {
    await expectLater(
      ConnectFlow.compileAndStart(
        StatusScriptBridge(const []),
        isCancelled: () => true,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'reason', 'start_cancelled'),
      ),
    );
    expect(ConnectFlow.isBusy, isFalse);
  });

  AuroraContract contract(String defaultMode) => AuroraContract(
    version: 1,
    revision: 1,
    updated: '2026-07-19T00:00:00Z',
    defaultMode: defaultMode,
    nodes: const [],
    outboundGroup: OutboundGroup(
      selectorTag: 'proxy',
      selectorMembers: const [],
      selectorDefault: 'auto',
      urltestTag: 'auto',
      urltestMembers: const [],
      urltestUrl: '',
      urltestInterval: '',
    ),
  );

  test('persisted mode wins over the contract default', () {
    expect(
      ConnectFlow.resolveMode('global', contract('smart')),
      AuroraMode.global,
    );
    expect(
      ConnectFlow.resolveMode('smart', contract('global')),
      AuroraMode.smart,
    );
  });

  // The default no longer follows the contract's default_mode: the GUI and the
  // command line must land on the same default (global mode), see
  // route_target_test.dart.
  test('no persisted mode defaults to global regardless of the contract', () {
    expect(
      ConnectFlow.resolveMode(null, contract('global')),
      AuroraMode.global,
    );
    expect(ConnectFlow.resolveMode(null, contract('smart')), AuroraMode.global);
  });

  test('unknown persisted values degrade to smart', () {
    expect(
      ConnectFlow.resolveMode('bogus', contract('global')),
      AuroraMode.smart,
    );
  });

  test('dual-path preference defaults to automatic relay and persists home', () {
    final dual = dualContract();

    expect(ConnectFlow.resolveMode('smart', dual), AuroraMode.global);

    expect(ConnectFlow.resolvePathPreference(null, dual), PathPreference.auto);
    expect(
      ConnectFlow.resolvePathPreference('home-direct', dual),
      PathPreference.homeDirect,
    );
    expect(
      ConnectFlow.resolvePathPreference('bogus', dual),
      PathPreference.auto,
    );
    expect(ConnectFlow.initialPathGroup(PathPreference.auto, dual), 'relay-auto');
    expect(
      ConnectFlow.initialPathGroup(PathPreference.homeDirect, dual),
      'home-auto',
    );
  });

  test('legacy contracts ignore a persisted path preference', () {
    final legacy = contract('global');
    expect(
      ConnectFlow.resolvePathPreference('home-direct', legacy),
      PathPreference.auto,
    );
    expect(ConnectFlow.initialPathGroup(PathPreference.auto, legacy), isNull);
  });

  test(
    'three-tier automatic starts at relay public and manual starts at home',
    () {
      final three = AuroraContract.fromJson(
        jsonDecode(File('test/fixtures/path-contract.json').readAsStringSync())
            as Map<String, dynamic>,
      );

      expect(
        ConnectFlow.initialPathGroup(PathPreference.auto, three),
        'relay-public-auto',
      );
      expect(
        ConnectFlow.initialPathGroup(PathPreference.homeDirect, three),
        'home-auto',
      );
    },
  );

  test('connect attempts are mutually exclusive across entry points', () async {
    final gate = Completer<String>();
    final first = ConnectFlow.runExclusive(() => gate.future);

    expect(ConnectFlow.isBusy, isTrue);
    await expectLater(
      ConnectFlow.runExclusive(() async => 'second'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'connect_in_flight',
        ),
      ),
    );

    gate.complete('first');
    expect(await first, 'first');
    expect(ConnectFlow.isBusy, isFalse);
    expect(await ConnectFlow.runExclusive(() async => 'third'), 'third');
  });

  test('the guard releases even when the attempt throws', () async {
    await expectLater(
      ConnectFlow.runExclusive<void>(() async => throw Exception('boom')),
      throwsA(isA<Exception>()),
    );
    expect(ConnectFlow.isBusy, isFalse);
  });

  test('known connect error codes map to readable text', () {
    expect(
      ConnectFlow.describeError(StateError('lease_bootstrap_failed')),
      contains('exit lease'),
    );
    expect(
      ConnectFlow.describeError(StateError('connect_in_flight')),
      contains('please wait'),
    );
    expect(
      ConnectFlow.describeError(StateError('selector_confirmation_timeout')),
      contains('route selection'),
    );
    expect(ConnectFlow.describeError(Exception('boom')), contains('boom'));
  });

  test('locked Mac keychain explains the action without native detail', () {
    final text = ConnectFlow.describeError(
      PlatformException(
        code: 'keychain_migration',
        message: 'private-native-detail',
        details: -25308,
      ),
    );
    expect(text, 'Unlock the current user\'s keychain, then try connecting again');
    expect(text, isNot(contains('private-native-detail')));
  });

  test('Mac keychain timeout explains that preparation is still pending', () {
    final text = ConnectFlow.describeError(
      PlatformException(
        code: 'keychain_migration_timeout',
        message: 'private-native-detail',
      ),
    );
    expect(text, 'Timed out waiting for the Mac keychain; try connecting again later');
    expect(text, isNot(contains('private-native-detail')));
  });

  test('other Mac keychain preparation failures do not guess a lock cause', () {
    for (final code in [
      'keychain_migration',
      'keychain_migration_incomplete',
      'keychain_migration_arguments',
    ]) {
      final text = ConnectFlow.describeError(
        PlatformException(
          code: code,
          message: 'private-native-detail',
          details: -50,
        ),
      );
      expect(
        text,
        'Mac keychain setup failed; try again, and export diagnostics if it '
        'keeps failing',
      );
      expect(text, isNot(contains('Unlock')));
      expect(text, isNot(contains('private-native-detail')));
    }
  });

  // `bridge.start()` returning only means the platform ACCEPTED the request.
  // Once it kept returning fine while the macOS extension died on EADDRINUSE at
  // every single start, so the app logged `connect_ok` eight times in a row and
  // the user watched "Connecting" fall back to "Disconnected" with no reason
  // given anywhere. Reaching `connected` is the only proof of a start.
  group('awaiting the tunnel to actually come up', () {
    test('connecting then connected is a success', () async {
      final bridge = StatusScriptBridge([
        AuroraStatus.connecting,
        AuroraStatus.connected,
      ]);
      expect(
        await ConnectFlow.awaitTunnelUp(bridge),
        TunnelStartOutcome.connected,
      );
    });

    test('connecting then disconnected is a definite failure', () async {
      final bridge = StatusScriptBridge([
        AuroraStatus.connecting,
        AuroraStatus.disconnected,
      ]);
      expect(
        await ConnectFlow.awaitTunnelUp(bridge),
        TunnelStartOutcome.failed,
      );
    });

    test('an error status after connecting is a definite failure', () async {
      final bridge = StatusScriptBridge([
        AuroraStatus.connecting,
        AuroraStatus.error,
      ]);
      expect(
        await ConnectFlow.awaitTunnelUp(bridge),
        TunnelStartOutcome.failed,
      );
    });

    // The pre-start value is still `disconnected` for a moment after start()
    // returns. Treating that as a failure would break every healthy connect.
    test('a leading disconnected before connecting is not a failure', () async {
      final bridge = StatusScriptBridge([
        AuroraStatus.disconnected,
        AuroraStatus.connecting,
        AuroraStatus.connected,
      ]);
      expect(
        await ConnectFlow.awaitTunnelUp(bridge),
        TunnelStartOutcome.connected,
      );
    });

    // A platform whose status simply lags must keep behaving as it did before
    // this check existed — ambiguity is never escalated into a failure.
    test('silence within the window is unknown, not failed', () async {
      final bridge = StatusScriptBridge([]);
      expect(
        await ConnectFlow.awaitTunnelUp(
          bridge,
          timeout: const Duration(milliseconds: 50),
        ),
        TunnelStartOutcome.unknown,
      );
    });

    test('a start failure is described with the extension reason', () {
      const logTail = '''
[ext] startTunnel: config from providerConfiguration (4814 bytes)
[ext] LibboxSetup ok
[ext] startTunnel FAILED, releasing command server: listen command server: listen tcp 127.0.0.1:42813: bind: address already in use
''';
      expect(
        ConnectFlow.extractStartFailureReason(logTail),
        contains('address already in use'),
      );
    });

    test('no failure line in the log yields no reason', () {
      expect(
        ConnectFlow.extractStartFailureReason('[ext] LibboxSetup ok\n'),
        isNull,
      );
    });

    test('tunnel_start_failed maps to readable text', () {
      expect(
        ConnectFlow.describeError(StateError('tunnel_start_failed')),
        contains('Tunnel failed to start'),
      );
    });
  });

  group('route family preference', () {
    // Build nodes with the main constructor instead of fromJson: these tests only
    // care how routeFamilies is derived, and do not need the rest of a valid
    // contract (profile, delivery and so on).
    AuroraNode viaNode({
      required String id,
      required String via,
      String? detour,
    }) => AuroraNode(
      id: id,
      role: detour == null ? 'primary' : 'exit',
      protocol: 'shadowsocks-2022',
      server: '203.0.113.10',
      port: 8443,
      detour: detour,
      via: via,
      params: const {
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'multiplex': true,
      },
    );

    final multiFamilyContract = AuroraContract(
      version: 1,
      revision: 1,
      defaultMode: 'global',
      nodes: [
        viaNode(id: 'home-direct', via: 'direct'),
        viaNode(id: 'home-via-relay', via: 'relay', detour: 'relay-entry'),
      ],
      outboundGroup: OutboundGroup(
        selectorTag: 'proxy',
        selectorMembers: const ['auto', 'home-direct', 'home-via-relay'],
        selectorDefault: 'auto',
        urltestTag: 'auto',
        urltestMembers: const ['home-direct', 'home-via-relay'],
        urltestUrl: '',
        urltestInterval: '',
      ),
    );

    final singleFamilyContract = AuroraContract(
      version: 1,
      revision: 1,
      defaultMode: 'global',
      nodes: [viaNode(id: 'home-direct', via: 'direct')],
      outboundGroup: OutboundGroup(
        selectorTag: 'proxy',
        selectorMembers: const ['auto', 'home-direct'],
        selectorDefault: 'auto',
        urltestTag: 'auto',
        urltestMembers: const ['home-direct'],
        urltestUrl: '',
        urltestInterval: '',
      ),
    );

    test('a saved family that the contract still has is honoured', () {
      expect(ConnectFlow.resolveRouteFamily('relay', multiFamilyContract), 'relay');
    });

    test('an explicit auto is represented as null', () {
      expect(
        ConnectFlow.resolveRouteFamily('auto', multiFamilyContract),
        isNull,
      );
    });

    test('nothing persisted defaults to the relay family', () {
      expect(ConnectFlow.resolveRouteFamily(null, multiFamilyContract), 'relay');
    });

    test('a family the contract no longer has degrades to auto', () {
      expect(
        ConnectFlow.resolveRouteFamily('relay', singleFamilyContract),
        isNull,
      );
    });

    // I4: the saved value is one key shared across contract shapes. Paths in a
    // paths-shaped contract are managed by PathHealthCoordinator and the UI shows
    // no family control at all. If a 'relay' saved in a flat session is not
    // blocked here, it takes effect in a paths session: the failure text becomes
    // "Connected · relay unavailable" (same for the tray), the delivered via-relay
    // is written by the native side into desiredSelections and overrides the
    // coordinator's replay target, and the UI has no control to switch back to
    // automatic.
    test('a paths-shaped contract never honours a saved family', () {
      final json =
          jsonDecode(
                File('test/fixtures/path-contract.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      // Realistic shape: the relay builder writes via:relay on home-via-relay-*
      // and home-* are direct.
      for (final node in (json['nodes'] as List).cast<Map<String, dynamic>>()) {
        node['via'] = (node['id'] as String).contains('-via-relay-')
            ? 'relay'
            : 'direct';
      }
      final pathsContract = AuroraContract.fromJson(json);

      // The check is only meaningful if the premise holds: this contract's node
      // table really does split into two families.
      expect(pathsContract.paths, isNotNull);
      expect(pathsContract.routeFamilies, containsAll(['direct', 'relay']));
      expect(ConnectFlow.resolveRouteFamily('relay', pathsContract), isNull);
      expect(ConnectFlow.resolveRouteFamily('direct', pathsContract), isNull);
    });

    test('the group tag for auto is the plain urltest group', () {
      expect(routeFamilyGroupTag(null), 'auto');
      expect(routeFamilyGroupTag('relay'), 'via-relay');
    });

    // routeFamilyTagToApply is the single judgment both cold-start paths must
    // share (status-transition and "already connected by the time init
    // finished" — a real race, since bridge.status() is one platform call
    // while init awaits contract + three secure-store reads + package info).
    // A prior version of this feature only called it from the transition
    // path, so a manually-locked family silently never got re-applied when
    // the app reopened onto an already-connected tunnel.
    group('routeFamilyTagToApply', () {
      test('nothing to apply before a contract is loaded', () {
        expect(
          ConnectFlow.routeFamilyTagToApply(
            contract: null,
            status: AuroraStatus.connected,
            routeFamily: 'relay',
          ),
          isNull,
        );
      });

      test('nothing to apply while not connected', () {
        for (final status in [
          AuroraStatus.disconnected,
          AuroraStatus.connecting,
          AuroraStatus.disconnecting,
          AuroraStatus.error,
        ]) {
          expect(
            ConnectFlow.routeFamilyTagToApply(
              contract: multiFamilyContract,
              status: status,
              routeFamily: 'relay',
            ),
            isNull,
          );
        }
      });

      test('connected + auto applies the contract urltest tag literally', () {
        expect(
          ConnectFlow.routeFamilyTagToApply(
            contract: multiFamilyContract,
            status: AuroraStatus.connected,
            routeFamily: null,
          ),
          multiFamilyContract.outboundGroup.urltestTag,
        );
      });

      test('connected + a locked family applies its via- group', () {
        expect(
          ConnectFlow.routeFamilyTagToApply(
            contract: multiFamilyContract,
            status: AuroraStatus.connected,
            routeFamily: 'relay',
          ),
          'via-relay',
        );
      });
    });
  });

  group('a start failure must say why', () {
    test('the last line from the svc bridge is carried into the error text', () async {
      final bridge = AuroraBridgeSvc.debugInstance();
      bridge.debugPublishDetail(
        'FATAL start service: listen tcp 127.0.0.1:9090: bind: address already in use',
      );
      expect(
        await ConnectFlow.startFailureReason(bridge),
        contains('address already in use'),
      );
    });

    test('a disconnect reason reported by the platform bridge beats log inference', () async {
      // The NE rejected a start with "No network available" 16 times, and every
      // time the UI said only "the core did not come up". That sends the user off
      // to investigate the core when the real cause was that Wi-Fi had dropped.
      // The trailing text is the Chinese-locale NEVPNConnectionErrorDomain
      // description ("VPN session disconnected because the device is not
      // connected to a network"), kept as escapes as localized test data.
      final bridge = _DetailBridge(
        'ne_disconnect[no_network_available] (NEVPNConnectionErrorDomain 2): '
        'VPN\u4f1a\u8bdd\u5df2\u65ad\u5f00\u8fde\u63a5\uff0c\u56e0\u4e3a\u8bbe\u5907\u672a\u63a5\u5165\u7f51\u7edc\u3002',
      );
      final reason = await ConnectFlow.startFailureReason(bridge);
      expect(reason, contains('no_network_available'));
      final message = ConnectFlow.describeError(
        StateError('tunnel_start_failed: $reason'),
      );
      expect(message, contains('No usable network'));
      expect(message, isNot(contains('the core did not come up')));
      expect(
        ConnectFlow.isRetryableStartFailure(
          StateError('tunnel_start_failed: $reason'),
        ),
        isTrue,
      );
    });

    test('a bridge without disconnect reasons leaves the existing inference alone', () async {
      final bridge = _DetailBridge(null);
      expect(await ConnectFlow.startFailureReason(bridge), isNull);
    });

    test('a port conflict is translated into one actionable sentence', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: FATAL start service: listen tcp 127.0.0.1:9090: '
          'bind: address already in use',
        ),
      );
      expect(message, contains('port'));
      expect(
        message,
        contains('address already in use'),
        reason: 'the original core text must stay attached after translation, '
            'otherwise the next occurrence cannot be located',
      );
    });

    test('a configuration rejected by the core has its own text', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: config rejected by sing-box: '
          'FATAL decode config: unknown field bogus',
        ),
      );
      expect(message, contains('configuration'));
    });

    // Observed on Windows: every connect ended at
    // "aurora-svc start failed (500): tunnel_not_ready after 12s", with
    // sing-box's own "open interface take too much time to finish" at the tail.
    // That is not "the core did not come up": the core was alive, and Windows
    // did not finish creating the wintun virtual adapter (a device install) in
    // time. The two kinds of giving up need two different next steps.
    test('adapter never created: gives an actionable Windows fix', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: aurora-svc start failed (500): '
          'tunnel_not_ready after 45s: tun_interface_never_up: '
          'warn inbound/tun[tun-in]: open interface take too much time to finish!',
        ),
      );
      expect(message, contains('virtual adapter'));
      expect(message, contains('Restarting the machine'),
          reason: 'a stuck device node is only fixed by a restart or turning off '
              'security software, so the text has to say so');
      expect(
        message,
        contains('open interface take too much time'),
        reason: 'the original core text must stay attached after translation',
      );
    });

    test('adapter was created but the core never answered: do not blame the adapter', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: aurora-svc start failed (500): '
          'tunnel_not_ready after 45s: '
          'info inbound/tun[tun-in]: started at aurora0',
        ),
      );
      expect(
        message,
        isNot(contains('virtual adapter')),
        reason: 'the adapter is already up; sending the user to restart or turn '
            'off security software would be a wasted trip',
      );
      expect(message, contains('started at aurora0'));
    });

    // When a connect is slow and the user taps Disconnect, aurora-svc aborts that
    // start and /start reports 500. That is not a fault, so do not dump a raw
    // technical line in the user's face.
    test('a connection interrupted by the user\'s own disconnect gets plain language', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: aurora-svc start failed (500): '
          'start_cancelled: stopped while the tunnel was still coming up',
        ),
      );
      expect(message, contains('disconnect'));
    });

    test('an unrecognized reason is attached verbatim, not swallowed', () {
      final message = ConnectFlow.describeError(
        StateError('tunnel_start_failed: some failure never seen before'),
      );
      expect(message, contains('some failure never seen before'));
    });

    // aurora-svc no longer refuses to start because "the previous adapter is
    // still there"; it starts anyway on top of the leftover and attaches this
    // marker on failure (desktop/aurora-svc/preflight.go). The text must not send
    // the user off to restart: the next start itself is what clears the leftover.
    test('a failure on a leftover adapter does not send the user to restart', () {
      final message = ConnectFlow.describeError(
        StateError(
          'tunnel_start_failed: aurora-svc start failed (500): '
          'sing-box exited: exit status 1 [$staleAdapterFailureToken]',
        ),
      );
      expect(message, contains('Connecting again'));
      expect(message, isNot(contains('estart the machine')));
    });
  });

  // ---- One-off failures retry themselves ("disconnect and reconnect fixes it") ----

  group('whether to retry on its own', () {
    // The report: "occasionally a 500 error appears, but disconnecting and
    // reconnecting usually fixes it". If the right next step is "connect again",
    // the user should not have to be the one doing it.
    for (final reason in [
      'tunnel_start_failed: tunnel_not_ready after 45s: …',
      'aurora-svc start failed (500): sing-box exited: exit status 1',
      'a previous tunnel is still up (interface aurora0)',
      'boom [$staleAdapterFailureToken]',
    ]) {
      test('retries: $reason', () {
        expect(ConnectFlow.isRetryableStartFailure(StateError(reason)), isTrue);
      });
    }

    // Conversely, a failure that would be identical a hundred times over must not
    // retry, and the start the user interrupted with their own disconnect
    // least of all: reconnecting it would work against the user.
    for (final reason in [
      'tunnel_start_failed: start_cancelled: stopped while coming up',
      'tunnel_start_failed: config rejected by sing-box: bad json',
      'tunnel_start_failed: required file missing: wintun.dll',
      'VPN permission denied',
      'lease_bootstrap_failed',
    ]) {
      test('does not retry: $reason', () {
        expect(
          ConnectFlow.isRetryableStartFailure(StateError(reason)),
          isFalse,
        );
      });
    }

    test('a completely unrecognized failure does not retry', () {
      expect(
        ConnectFlow.isRetryableStartFailure(StateError('some failure never seen before')),
        isFalse,
      );
    });
  });
}

AuroraContract dualContract() => AuroraContract(
  version: 1,
  revision: 2,
  defaultMode: 'global',
  nodes: const [],
  outboundGroup: OutboundGroup(
    selectorTag: 'proxy',
    selectorMembers: const ['auto'],
    selectorDefault: 'auto',
    urltestTag: 'auto',
    urltestMembers: const [],
    urltestUrl: '',
    urltestInterval: '',
  ),
  paths: AuroraPaths(
    preferred: 'relay',
    items: {
      'relay': AuroraPathDefinition(groupTag: 'relay-auto', members: const ['relay']),
      'home': AuroraPathDefinition(
        groupTag: 'home-auto',
        members: const ['home'],
      ),
    },
  ),
  pathPolicy: AuroraPathPolicy(
    mode: 'prefer_relay',
    fallback: 'home',
    fallbackOrder: const ['home'],
    health: const PathHealthPolicy(
      rollingWindow: 5,
      minimumSuccessRate: .7,
      hardFailureRounds: 2,
      performanceFailureRounds: 3,
      latencyRatio: 2,
      latencyDeltaMs: 250,
      recoveryRounds: 3,
      recoveryHold: Duration(seconds: 120),
      flapWindow: Duration(minutes: 10),
      flapThreshold: 2,
      flapCooldown: Duration(minutes: 15),
    ),
  ),
  egress: const EgressPolicy(
    expectedIpv4: '203.0.113.9',
    expectedCountry: 'US',
    expectedAsn: 'AS64496',
  ),
);

/// Replays a fixed status script, the way a platform emits transitions after
/// `start()` is accepted. Every other member is unreachable in these tests.
class StatusScriptBridge implements AuroraBridge {
  StatusScriptBridge(this._script);

  final List<AuroraStatus> _script;

  @override
  Stream<AuroraStatus> statusStream() async* {
    for (final status in _script) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield status;
    }
    // Then stay silent, like a platform that has nothing further to report.
    await Completer<void>().future;
  }

  @override
  Future<AuroraStatus> status() async => AuroraStatus.disconnected;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

class _DetailBridge implements AuroraBridge, AuroraStartFailureDetail {
  _DetailBridge(this.detail);

  final String? detail;

  @override
  Future<String?> lastStartFailureDetail() async => detail;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
