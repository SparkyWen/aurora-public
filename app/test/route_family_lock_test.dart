// RouteFamilyLock is the only stateful part of manual family locking, and it is
// where two review findings lived:
//   I2: a reconnect brings a new contract but the locked family is not recomputed;
//   I3: a failed apply is swallowed while the UI already shows "locked".
// ConnectPage depends on platform channels that unit tests cannot reach, so those
// two rules are extracted and tested here.
import 'package:aurora/app/route_family_lock.dart';
import 'package:aurora/core/contract.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _node(String id, String via, {String? detour}) {
  final node = <String, dynamic>{
    'id': id,
    'role': detour == null ? 'primary' : 'exit',
    'protocol': 'shadowsocks-2022',
    'server': '203.0.113.10',
    'port': 8443,
    'via': via,
    'params': const {
      'method': '2022-blake3-aes-128-gcm',
      'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
      'multiplex': true,
    },
  };
  if (detour != null) node['detour'] = detour;
  return node;
}

/// A flat-shape contract: [members] go into both the selector and the urltest.
AuroraContract _flat(
  List<Map<String, dynamic>> nodes, {
  List<String>? urltest,
}) {
  final selectable = nodes
      .where((node) => node['role'] != 'entry')
      .map((node) => node['id'] as String)
      .toList();
  final urltestMembers = urltest ?? selectable;
  return AuroraContract.fromJson({
    'version': 1,
    'nodes': nodes,
    'outbound_group': {
      'selector': {
        'tag': 'proxy',
        'members': ['auto', ...selectable],
        'default': 'auto',
      },
      'urltest': {'tag': 'auto', 'members': urltestMembers},
    },
  });
}

/// Records persist/apply calls and can make one apply fail.
class _Recorder {
  final persisted = <String?>[];
  final applied = <String?>[];
  final changes = <String?>[];
  Object? failWith;

  Future<void> persist(String? family) async => persisted.add(family);

  Future<void> apply(String? family) async {
    applied.add(family);
    final error = failWith;
    if (error != null) {
      failWith = null; // fail only the first apply so the rollback apply can succeed
      throw error;
    }
  }
}

void main() {
  late _Recorder recorder;
  late RouteFamilyLock lock;

  setUp(() {
    recorder = _Recorder();
    lock = RouteFamilyLock(
      persist: recorder.persist,
      apply: recorder.apply,
      onChanged: () => recorder.changes.add(null),
    );
  });

  final threeFamilies = _flat([
    _node('home-reality', 'direct'),
    _node('home-ss', 'direct'),
    _node('home-via-relay', 'relay', detour: 'relay-entry'),
    _node('home-via-cdn', 'cdn', detour: 'cdn-edge'),
    {..._node('relay-entry', 'relay'), 'role': 'entry'},
    {..._node('cdn-edge', 'cdn'), 'role': 'entry'},
  ]);

  group('adopt (recomputed every time the contract is replaced)', () {
    test('cold start: a saved family still in the contract is locked', () {
      expect(lock.adopt(threeFamilies, 'cdn'), 'cdn');
      expect(lock.family, 'cdn');
    });

    test('saved auto resolves to automatic', () {
      expect(lock.adopt(threeFamilies, 'auto'), isNull);
    });

    test('explicit auto stays automatic after the contract is re-adopted on reconnect', () {
      lock.adopt(threeFamilies, 'auto');
      expect(lock.adopt(threeFamilies), isNull);
    });

    test('switching back to auto manually is not undone by a reconnect', () async {
      lock.adopt(threeFamilies, 'relay');
      await lock.change(null);
      expect(lock.adopt(threeFamilies), isNull);
    });

    test('nothing saved: locks the default relay family (same as the command line)', () {
      expect(lock.adopt(threeFamilies, null), 'relay');
    });

    // I2: on reconnect, loadWithRefresh inside compileAndStart may swap in a
    // different contract. Without recomputing: no segment of the control is
    // highlighted; with a single family left the control disappears entirely while
    // the hint still says "can switch to Auto", so the user has no control to
    // unlock with; and the via-cdn group is absent from the compiled output, so the
    // selector stays on the stale cache_file value, meaning the UI shows locked
    // while the core actually runs automatic.
    test('new contract after reconnect lacks the family: falls back to automatic', () {
      lock.adopt(threeFamilies, 'cdn');
      final withoutCdn = _flat([
        _node('home-reality', 'direct'),
        _node('home-via-relay', 'relay', detour: 'relay-entry'),
        {..._node('relay-entry', 'relay'), 'role': 'entry'},
      ]);

      expect(lock.adopt(withoutCdn), isNull);
      expect(lock.family, isNull);
    });

    test('new contract has one family left (the control would vanish): falls back to automatic', () {
      lock.adopt(threeFamilies, 'relay');
      final homeOnly = _flat([
        _node('home-reality', 'direct'),
        _node('home-ss', 'direct'),
      ]);

      expect(lock.adopt(homeOnly), isNull);
    });

    test('contract still declares the family but the compiled output no longer emits its group: falls back to automatic', () {
      lock.adopt(threeFamilies, 'cdn');
      // The cdn members are removed from the legacy urltest: after the compiler
      // filters, the group is empty and via-cdn is not emitted.
      final cdnNotRenderable = _flat(
        [
          _node('home-reality', 'direct'),
          _node('home-via-relay', 'relay', detour: 'relay-entry'),
          _node('home-via-cdn', 'cdn', detour: 'cdn-edge'),
          {..._node('relay-entry', 'relay'), 'role': 'entry'},
          {..._node('cdn-edge', 'cdn'), 'role': 'entry'},
        ],
        urltest: ['home-reality', 'home-via-relay'],
      );

      expect(cdnNotRenderable.routeFamilies, contains('cdn'));
      expect(lock.adopt(cdnNotRenderable), isNull);
    });

    test('new contract still has the family: stays locked', () {
      lock.adopt(threeFamilies, 'relay');
      expect(lock.adopt(threeFamilies), 'relay');
    });

    // A contract that is temporarily missing a route must not erase the user's
    // choice: the downgrade happens in memory only.
    test('downgrade is not persisted', () {
      lock.adopt(threeFamilies, 'cdn');
      lock.adopt(_flat([_node('home-reality', 'direct')]));
      expect(recorder.persisted, isEmpty);
    });
  });

  group('change (an apply failure must be visible)', () {
    test('a save failure returns the original error, restores the UI and does not apply the new family', () async {
      final failure = StateError('secure_store_unavailable');
      final failing = RouteFamilyLock(
        persist: (family) async {
          recorder.persisted.add(family);
          if (family == 'relay') throw failure;
        },
        apply: recorder.apply,
        onChanged: () {},
      );
      failing.adopt(threeFamilies, 'direct');
      expect(await failing.change('relay'), same(failure));
      expect(failing.family, 'direct');
      expect(recorder.applied, isNot(contains('relay')));
    });

    test('a failed rollback save still restores the core and does not overwrite the first error', () async {
      final failure = StateError('selector_confirmation_timeout');
      final failing = RouteFamilyLock(
        persist: (family) async {
          if (family == 'direct') throw StateError('secure_store_unavailable');
        },
        apply: (family) async {
          recorder.applied.add(family);
          if (family == 'relay') throw failure;
        },
        onChanged: () {},
      );
      failing.adopt(threeFamilies, 'direct');
      expect(await failing.change('relay'), same(failure));
      expect(failing.family, 'direct');
      expect(recorder.applied, ['relay', 'direct']);
    });

    test('success: persists and applies, no error', () async {
      // Start from an explicit auto. With nothing saved (null) the default is relay,
      // and change('relay') would then hit the "already this family" early return,
      // so persisting and applying would never be exercised.
      lock.adopt(threeFamilies, 'auto');

      expect(await lock.change('relay'), isNull);
      expect(lock.family, 'relay');
      expect(recorder.persisted, ['relay']);
      expect(recorder.applied, ['relay']);
    });

    // "Back to auto" persists null at this layer; the page (connect_page's
    // _persistRouteFamily) then writes it as an explicit 'auto'. Because a default
    // route exists, a cleared key means "never chose", and the next launch would
    // be pulled back to the default family.
    test('switching back to auto persists null', () async {
      lock.adopt(threeFamilies, 'relay');
      expect(await lock.change(null), isNull);
      expect(recorder.persisted, [null]);
    });

    test('selecting the current family does nothing', () async {
      lock.adopt(threeFamilies, 'relay');
      expect(await lock.change('relay'), isNull);
      expect(recorder.applied, isEmpty);
      expect(recorder.persisted, isEmpty);
    });

    // I3: selectOutbound's contract is "return only after reading back the
    // confirmation, throw if it cannot be proven"; right after an upgrade or on a
    // busy system it throws selector_confirmation_timeout. Swallowing it would show
    // "relay" in the UI while the core is still on "direct", and "tap again" would
    // be eaten by the equality early return at the top of change() because the UI
    // state already equals the target, leaving the user no way to correct it.
    test('apply failure: state, saved value and core roll back together and the error goes to the caller', () async {
      lock.adopt(threeFamilies, 'direct');
      recorder.failWith = StateError('selector_confirmation_timeout');

      final error = await lock.change('relay');

      expect(error, isA<StateError>());
      expect(lock.family, 'direct', reason: 'the UI must return to the family that is actually in effect');
      expect(recorder.persisted, ['relay', 'direct'], reason: 'the saved value must roll back too');
      expect(recorder.applied, [
        'relay',
        'direct',
      ], reason: 'the failure may be "sent but not confirmed on read-back", so the '
          'previous family must be explicitly re-applied to the core');
    });

    test('after a rollback, selecting the same family again is not swallowed by the equality early return', () async {
      lock.adopt(threeFamilies, 'direct');
      recorder.failWith = StateError('selector_confirmation_timeout');
      await lock.change('relay');

      expect(await lock.change('relay'), isNull, reason: 'this time it must really retry');
      expect(lock.family, 'relay');
    });

    test('the rollback also notifies the UI (once for the switch, once for the revert)', () async {
      lock.adopt(threeFamilies, 'direct');
      recorder.failWith = StateError('boom');
      await lock.change('relay');
      expect(recorder.changes, hasLength(2));
    });

    test('a failed re-apply during rollback does not mask the first error', () async {
      final always = RouteFamilyLock(
        persist: recorder.persist,
        apply: (family) async => throw StateError('selector_readback_failed'),
        onChanged: () {},
      );
      always.adopt(threeFamilies, 'direct');

      final error = await always.change('relay');
      expect(error, isA<StateError>());
      expect((error as StateError).message, 'selector_readback_failed');
      expect(always.family, 'direct');
    });
  });
}
