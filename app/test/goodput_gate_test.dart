import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/goodput_gate.dart';
import 'package:flutter_test/flutter_test.dart';

OutboundGroupInfo _group(
  String tag,
  String type,
  String selected,
  List<String> members,
) => OutboundGroupInfo(
  tag: tag,
  type: type,
  selected: selected,
  selectable: type == 'selector',
  items: [
    for (final m in members)
      OutboundItem(tag: m, type: m.startsWith('home') ? 'shadowsocks' : 'urltest', delayMs: 0),
  ],
);

/// The shape the app actually runs: a selector pointing at a urltest group,
/// which in turn picks one concrete node.
List<OutboundGroupInfo> _groups({required String autoPick}) => [
  _group('proxy', 'selector', 'auto', [
    'auto',
    'home-via-relay-public-reality',
    'home-via-relay-public-hy2',
    'home-via-relay-public-ss',
  ]),
  _group('auto', 'urltest', autoPick, [
    'home-via-relay-public-reality',
    'home-via-relay-public-hy2',
    'home-via-relay-public-ss',
  ]),
];

const _candidates = [
  'home-via-relay-public-reality',
  'home-via-relay-public-hy2',
  'home-via-relay-public-ss',
];

void main() {
  final t0 = DateTime.utc(2026, 8, 1, 6);

  group('effectiveNode', () {
    test('follows the selector through a group to the node carrying traffic', () {
      // The selector reports "auto", which is not a node. Recording goodput
      // against "auto" would blame the group forever and never demote the one
      // member that is actually slow.
      expect(
        GoodputGate.effectiveNode(_groups(autoPick: 'home-via-relay-public-hy2'), 'proxy'),
        'home-via-relay-public-hy2',
      );
    });

    test('returns a directly pinned node unchanged', () {
      final groups = [
        _group('proxy', 'selector', 'home-via-relay-public-ss', _candidates),
      ];
      expect(GoodputGate.effectiveNode(groups, 'proxy'), 'home-via-relay-public-ss');
    });

    test('is null when the selector is missing or empty', () {
      expect(GoodputGate.effectiveNode(const [], 'proxy'), isNull);
    });
  });

  group('selectableNodes', () {
    test('excludes group members so we never pin the selector to a group', () {
      // Pinning "auto" would just hand the choice back to the latency-only
      // urltest that picked the bad node in the first place.
      expect(
        GoodputGate.selectableNodes(_groups(autoPick: 'home-via-relay-public-hy2'), 'proxy'),
        _candidates,
      );
    });
  });

  group('candidatesIn', () {
    // A route-family lock exists so the user can pin traffic to one family. A
    // demotion that walks out of that family would be the health check quietly
    // overriding an explicit choice.
    final locked = [
      _group('proxy', 'selector', 'via-relay', [
        'auto',
        'via-relay',
        'home-via-relay-public-reality',
        'home-via-relay-public-hy2',
        'home-ss',
      ]),
      _group('via-relay', 'urltest', 'home-via-relay-public-hy2', [
        'home-via-relay-public-reality',
        'home-via-relay-public-hy2',
      ]),
      _group('auto', 'urltest', 'home-via-relay-public-hy2', [
        'home-via-relay-public-reality',
        'home-via-relay-public-hy2',
        'home-ss',
      ]),
    ];

    test('confines candidates to the locked family', () {
      expect(GoodputGate.candidatesIn(locked, 'via-relay', 'proxy'), [
        'home-via-relay-public-reality',
        'home-via-relay-public-hy2',
      ]);
    });

    test('spans the whole auto group when nothing is locked', () {
      expect(GoodputGate.candidatesIn(locked, 'auto', 'proxy'), [
        'home-via-relay-public-reality',
        'home-via-relay-public-hy2',
        'home-ss',
      ]);
    });

    test('drops members the selector cannot be pinned to', () {
      final groups = [
        _group('proxy', 'selector', 'auto', ['auto', 'home-via-relay-public-ss']),
        _group('auto', 'urltest', 'home-via-relay-public-ss', [
          'home-via-relay-public-ss',
          'home-hy2',
        ]),
      ];
      expect(GoodputGate.candidatesIn(groups, 'auto', 'proxy'), [
        'home-via-relay-public-ss',
      ]);
    });
  });

  group('observe', () {
    /// Feeds [n] measurements and returns the last verdict.
    String? feed(
      GoodputGate gate,
      String node,
      int bytesPerSecond, {
      int n = 1,
      DateTime? from,
      List<String> candidates = _candidates,
    }) {
      String? last;
      for (var i = 0; i < n; i++) {
        last = gate.observe(
          node: node,
          reachable: true,
          bytesPerSecond: bytesPerSecond,
          candidates: candidates,
          at: (from ?? t0).add(Duration(seconds: 20 * i)),
        );
      }
      return last;
    }

    test('a path moving data at or above the floor is left alone', () {
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      expect(feed(gate, 'home-via-relay-public-hy2', 900 * 1024, n: 5), isNull);
    });

    test('one sub-floor sample is recorded but never acted on', () {
      // A single bad number can be congestion, or this probe competing with the
      // user's own download. Tearing down every live connection for it would be
      // worse than the symptom.
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      expect(feed(gate, 'home-via-relay-public-hy2', 2 * 1024), isNull);
    });

    test('demotes a path that answers but cannot carry data', () {
      // The measured failure: hy2 wins urltest on latency (1.02s, the lowest of
      // every path) and then delivers 2 KB/s. Every reachability probe passes,
      // so only a goodput judgement can catch it.
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      expect(
        feed(gate, 'home-via-relay-public-hy2', 2 * 1024, n: 2),
        'home-via-relay-public-reality',
      );
    });

    test('a healthy sample in between resets the count', () {
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      feed(gate, 'home-via-relay-public-hy2', 2 * 1024);
      feed(gate, 'home-via-relay-public-hy2', 900 * 1024);
      expect(feed(gate, 'home-via-relay-public-hy2', 2 * 1024), isNull);
    });

    test('a working path near the low-water mark is never condemned', () {
      // Live samples on a healthy path ranged 52..212 KB/s. None of that may
      // read as failure, or the gate would demote the good path it exists to
      // protect.
      final gate = GoodputGate();
      expect(feed(gate, 'home-via-relay-public-reality', 52 * 1024, n: 6), isNull);
    });

    test('an unreachable probe never demotes anything', () {
      // Absence of evidence is not evidence of slowness: the endpoint itself
      // may be down or challenged. A fully dead path is the watchdog's job.
      final gate = GoodputGate();
      for (var i = 0; i < 4; i++) {
        expect(
          gate.observe(
            node: 'home-via-relay-public-hy2',
            reachable: false,
            bytesPerSecond: 0,
            candidates: _candidates,
            at: t0.add(Duration(seconds: 20 * i)),
          ),
          isNull,
        );
      }
    });

    test('a stall and a watchdog death on the same leg add up', () {
      // Deliberate: the gate keeps one ledger per node for every kind of
      // failure (see observeHardFailure). A leg that stalled a payload and is
      // then confirmed dead by the watchdog is switched away from rather than
      // costing a tunnel restart — on a network where HY2 stalls that is exactly
      // right. The price, if the cause was the core and not the leg, is one
      // more confirmation round before the restart that does fix it.
      final gate = GoodputGate();
      expect(
        gate.observe(
          node: 'home-via-relay-public-hy2',
          reachable: false,
          stalled: true,
          bytesPerSecond: 0,
          candidates: _candidates,
          at: t0,
        ),
        isNull,
      );
      expect(
        gate.observeHardFailure(
          node: 'home-via-relay-public-hy2',
          candidates: _candidates,
          at: t0.add(const Duration(seconds: 40)),
        ),
        'home-via-relay-public-reality',
      );
    });

    test('a leg that stalls every payload is demoted like a throttled one', () {
      // Seen on a Windows office network: most small requests over a relay HY2 leg
      // passed (urltest kept selecting it, the watchdog judged it alive), but every
      // 3 MB download returned 0 bytes, not even response headers. Treating that as
      // "unreachable" would never put it into cooldown: the user stares at pages
      // that will not load while the UI says everything is fine.
      final gate = GoodputGate();
      String? stall(int i) => gate.observe(
        node: 'home-via-relay-public-hy2',
        reachable: false,
        stalled: true,
        bytesPerSecond: 0,
        candidates: _candidates,
        at: t0.add(Duration(seconds: 20 * i)),
      );
      expect(stall(0), isNull, reason: 'one stall is a moment, not a verdict');
      expect(stall(1), 'home-via-relay-public-reality');
    });

    test('a demoted node is not handed back while it is cooling down', () {
      // urltest re-elects the lowest-latency member after every restart, so
      // without a cooldown the gate and the engine would fight in a loop.
      final gate = GoodputGate(
        floorBytesPerSecond: 16 * 1024,
        cooldown: const Duration(minutes: 15),
      );
      feed(gate, 'home-via-relay-public-hy2', 2 * 1024, n: 2);
      expect(
        gate.isCoolingDown('home-via-relay-public-hy2', t0.add(const Duration(minutes: 14))),
        isTrue,
      );
      expect(
        gate.isCoolingDown('home-via-relay-public-hy2', t0.add(const Duration(minutes: 16))),
        isFalse,
      );
    });

    test('skips candidates that are themselves cooling down', () {
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      feed(gate, 'home-via-relay-public-reality', 1024, n: 2);
      expect(
        feed(gate, 'home-via-relay-public-hy2', 1024,
            n: 2, from: t0.add(const Duration(minutes: 1))),
        'home-via-relay-public-ss',
      );
    });

    test('stays put when every alternative is already burnt', () {
      // Switching to a node we just measured as equally dead buys nothing and
      // costs every in-flight connection.
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      for (final node in _candidates) {
        feed(gate, node, 1024, n: 2);
      }
      expect(
        feed(gate, 'home-via-relay-public-hy2', 1024,
            n: 2, from: t0.add(const Duration(minutes: 1))),
        isNull,
      );
    });

    test('a recovered node clears its own cooldown', () {
      final gate = GoodputGate(floorBytesPerSecond: 16 * 1024);
      feed(gate, 'home-via-relay-public-hy2', 1024, n: 2);
      expect(gate.isCoolingDown('home-via-relay-public-hy2', t0), isTrue);
      feed(gate, 'home-via-relay-public-hy2', 900 * 1024,
          from: t0.add(const Duration(minutes: 20)));
      expect(
        gate.isCoolingDown('home-via-relay-public-hy2', t0.add(const Duration(minutes: 20))),
        isFalse,
      );
    });
  });

  group('observeHardFailure', () {
    test('a single hard failure does nothing - one total loss may be a network blip', () {
      final gate = GoodputGate();
      expect(
        gate.observeHardFailure(
          node: 'home-via-relay-public-hy2',
          candidates: _candidates,
          at: t0,
        ),
        isNull,
      );
    });

    test('two consecutive hard failures switch to the next candidate in the family', () {
      final gate = GoodputGate();
      gate.observeHardFailure(
        node: 'home-via-relay-public-hy2',
        candidates: _candidates,
        at: t0,
      );
      final replacement = gate.observeHardFailure(
        node: 'home-via-relay-public-hy2',
        candidates: _candidates,
        at: t0.add(const Duration(seconds: 8)),
      );
      // Take the first node in contract order that is not burnt through; do not rank
      // burnt nodes against each other.
      expect(replacement, 'home-via-relay-public-reality');
    });

    test('when every candidate is burnt through, hold still and leave it to the watchdog restart', () {
      final gate = GoodputGate();
      for (final node in _candidates) {
        gate.observeHardFailure(node: node, candidates: _candidates, at: t0);
        gate.observeHardFailure(
          node: node,
          candidates: _candidates,
          at: t0.add(const Duration(seconds: 8)),
        );
      }
      expect(
        gate.observeHardFailure(
          node: 'home-via-relay-public-hy2',
          candidates: _candidates,
          at: t0.add(const Duration(seconds: 16)),
        ),
        isNull,
      );
    });

    test('one successful goodput measurement clears the hard-failure streak', () {
      final gate = GoodputGate();
      gate.observeHardFailure(
        node: 'home-via-relay-public-hy2',
        candidates: _candidates,
        at: t0,
      );
      gate.observe(
        node: 'home-via-relay-public-hy2',
        reachable: true,
        bytesPerSecond: 400 * 1024,
        candidates: _candidates,
        at: t0.add(const Duration(seconds: 4)),
      );
      expect(
        gate.observeHardFailure(
          node: 'home-via-relay-public-hy2',
          candidates: _candidates,
          at: t0.add(const Duration(seconds: 8)),
        ),
        isNull,
        reason: 'the streak was broken by a successful sample, so the next hard failure must not demote',
      );
    });
  });
}
