// Smoke test for the Aurora app shell. The connect flow itself is exercised on a
// device (platform channels aren't available in unit tests); compiler logic is
// covered in config_compiler_test.dart.
import 'package:aurora/main.dart';
import 'package:aurora/features/connect/connect_page.dart';
import 'package:aurora/features/nodes/nodes_page.dart';
import 'package:aurora/app/path_health_coordinator.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/path_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds with the Aurora title', (tester) async {
    await tester.pumpWidget(const AuroraApp());
    expect(find.text('Aurora'), findsOneWidget);
  });

  testWidgets('path panel defaults to automatic relay and can choose home', (
    tester,
  ) async {
    var preference = PathPreference.auto;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PathPreferenceControl(
            preference: preference,
            enabled: true,
            onChanged: (value) => preference = value,
          ),
        ),
      ),
    );

    expect(find.text('Auto (relay first)'), findsOneWidget);
    expect(find.text('Home (direct)'), findsOneWidget);
    expect(find.textContaining('Force relay'), findsNothing);
    await tester.tap(find.text('Home (direct)'));
    expect(preference, PathPreference.homeDirect);
  });

  testWidgets('path status explains fallback and verified home egress', (
    tester,
  ) async {
    const snapshot = PathHealthSnapshot(
      preference: PathPreference.auto,
      state: AuroraPathState.homeFallback,
      selectedGroup: 'home-auto',
      activeNode: 'home-hy2',
      reasonCode: PathReason.relayHardFailure,
      egressVerified: true,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PathStatusView(snapshot: snapshot)),
      ),
    );

    expect(find.textContaining('Home (direct)'), findsOneWidget);
    expect(find.textContaining('demoted automatically'), findsOneWidget);
    expect(find.textContaining('Home exit verified'), findsOneWidget);
    expect(find.textContaining('home-hy2'), findsOneWidget);
  });

  testWidgets('blocked status says traffic is blocked without stopping TUN', (
    tester,
  ) async {
    const snapshot = PathHealthSnapshot(
      preference: PathPreference.auto,
      state: AuroraPathState.homeBlocked,
      selectedGroup: '',
      reasonCode: PathReason.homeUnavailable,
      egressVerified: false,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PathStatusView(snapshot: snapshot)),
      ),
    );

    expect(find.textContaining('blocked inside the TUN'), findsOneWidget);
    expect(find.textContaining('stopped'), findsNothing);
    expect(find.textContaining('failed closed'), findsOneWidget);
  });

  testWidgets('three-path panel shows path, protocol, lease and recovery', (
    tester,
  ) async {
    for (final (state, label) in [
      (AuroraPathState.relayPublic, 'Relay to home (public)'),
      (AuroraPathState.relayTailnet, 'Relay to home (Tailnet)'),
      (AuroraPathState.homeDirect, 'Home (direct)'),
    ]) {
      final snapshot = PathHealthSnapshot(
        preference: PathPreference.auto,
        state: state,
        selectedPath: 'test-path',
        selectedGroup: 'test-auto',
        activeNode: 'reality',
        reasonCode: PathReason.pathHealthy,
        egressVerified: true,
        p50Ms: 220,
        p95Ms: 310,
        jitterMs: 90,
        leaseHealth: LeaseHealth.valid,
        leaseKeyId: 'home-egress-1',
        leaseSequence: 123456,
        leaseExpiresAt: DateTime.utc(2026, 7, 22, 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PathStatusView(snapshot: snapshot)),
        ),
      );
      expect(find.textContaining(label), findsOneWidget);
      expect(find.textContaining('Protocol: reality'), findsOneWidget);
      expect(find.textContaining('Lease: Valid'), findsOneWidget);
      expect(find.textContaining('p50 220 ms'), findsOneWidget);
    }

    const recovering = PathHealthSnapshot(
      preference: PathPreference.auto,
      state: AuroraPathState.recovering,
      selectedPath: 'relay_tailnet',
      selectedGroup: 'relay-tailnet-auto',
      reasonCode: PathReason.pathRecovered,
      egressVerified: true,
      recoveryRounds: 2,
      leaseHealth: LeaseHealth.refreshing,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PathStatusView(snapshot: recovering)),
      ),
    );
    expect(find.textContaining('Recovery progress: 2'), findsOneWidget);
    expect(find.textContaining('Lease: Refreshing'), findsOneWidget);
  });

  test('nodes expose only three household path groups and hide entries', () {
    final groups = visibleHouseholdPathGroups([
      group('proxy', const []),
      group('relay-public-auto', const ['home-via-relay-public-reality']),
      group('relay-tailnet-auto', const ['home-via-relay-tailnet-reality']),
      group('home-auto', const ['home-reality']),
      group('relay-entry-reality', const ['relay-entry-reality']),
    ]);

    expect(groups.map((item) => item.tag), [
      'relay-public-auto',
      'relay-tailnet-auto',
      'home-auto',
    ]);
    expect(
      groups.expand((item) => item.items).map((item) => item.tag),
      isNot(contains('relay-entry-reality')),
    );
  });

  test('single-path contract falls back to the plain auto urltest group', () {
    final groups = visibleHouseholdPathGroups([
      group('proxy', const []),
      group('auto', const ['home-reality', 'home-hy2', 'home-ss']),
    ]);

    expect(groups.map((item) => item.tag), ['auto']);
    expect(groups.single.items.map((item) => item.tag), [
      'home-reality',
      'home-hy2',
      'home-ss',
    ]);
  });

  test('family groups are visible alongside the household path groups', () {
    final groups = [
      const OutboundGroupInfo(
        tag: 'proxy',
        type: 'Selector',
        selected: 'auto',
        selectable: true,
        items: [],
      ),
      const OutboundGroupInfo(
        tag: 'auto',
        type: 'URLTest',
        selected: 'home-ss',
        selectable: false,
        items: [],
      ),
      const OutboundGroupInfo(
        tag: 'via-relay',
        type: 'URLTest',
        selected: 'home-via-relay',
        selectable: false,
        items: [],
      ),
    ];
    final visible = visibleHouseholdPathGroups(groups).map((g) => g.tag).toList();
    expect(visible, containsAll(['auto', 'via-relay']));
    expect(visible, isNot(contains('proxy')));
  });

  test('a family group is labelled by its family', () {
    expect(householdPathLabel('via-relay'), 'Relay');
  });

  testWidgets('the family control lists auto plus every family', (tester) async {
    String? picked = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RouteFamilyControl(
          families: const ['direct', 'relay', 'cdn'],
          selected: null,
          enabled: true,
          onChanged: (value) => picked = value,
        ),
      ),
    ));
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Relay'), findsOneWidget);
    expect(find.text('CDN'), findsOneWidget);

    await tester.tap(find.text('Relay'));
    await tester.pumpAndSettle();
    expect(picked, 'relay');
  });

  testWidgets('an unknown family shows its raw id', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RouteFamilyControl(
          families: const ['direct', 'tokyo'],
          selected: 'tokyo',
          enabled: true,
          onChanged: (_) {},
        ),
      ),
    ));
    expect(find.text('tokyo'), findsOneWidget);
  });

  // Review flagged this as unverified: resolveRenderableRouteFamily should
  // already keep _routeFamily from ever landing on a value outside the
  // rendered families, but it's worth pinning down what SegmentedButton
  // itself does if that guard were ever bypassed — a silent "nothing
  // highlighted" is fine, a debug assertion crashing the page is not.
  testWidgets(
    'a selected value absent from the rendered families does not crash the '
    'control (SegmentedButton just shows nothing highlighted)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RouteFamilyControl(
              families: const ['direct', 'relay'],
              selected: 'cdn',
              enabled: true,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // No segment is shown as selected, but the control still renders its
      // full segment set instead of e.g. throwing during build.
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('Relay'), findsOneWidget);
    },
  );
}

OutboundGroupInfo group(String tag, List<String> members) => OutboundGroupInfo(
  tag: tag,
  type: 'urltest',
  selected: members.firstOrNull ?? '',
  selectable: false,
  items: [
    for (final member in members)
      OutboundItem(tag: member, type: 'proxy', delayMs: 100),
  ],
);
