// renderableRouteFamilies is the cross-check between "what the contract
// declares" and "what the compiler actually emits" (config_compiler_test.dart
// covers the compiler side; this covers the UI-facing filter in isolation).
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/route_family.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> node({
    required String id,
    required String role,
    required String via,
  }) => {
    'id': id,
    'role': role,
    'protocol': 'shadowsocks-2022',
    'server': '203.0.113.1',
    'port': 8443,
    'via': via,
    'params': <String, dynamic>{},
  };

  test(
    'a family whose members are all absent from urltest is dropped from the '
    'renderable list even though the contract declares three families',
    () {
      final contract = AuroraContract.fromJson({
        'version': 1,
        'nodes': [
          node(id: 'home-reality', role: 'primary', via: 'direct'),
          node(id: 'home-ss', role: 'backup', via: 'direct'),
          node(id: 'home-via-relay', role: 'exit', via: 'relay'),
          // A node declaring the cdn family, which urltest.members below
          // deliberately leaves out: the family exists in the contract but the
          // compiler's filtering leaves it an empty group.
          node(id: 'home-via-cdn', role: 'exit', via: 'cdn'),
        ],
        'outbound_group': {
          'selector': {
            'tag': 'proxy',
            'members': [
              'auto',
              'home-reality',
              'home-ss',
              'home-via-relay',
              'home-via-cdn',
            ],
            'default': 'auto',
          },
          'urltest': {
            'tag': 'auto',
            'members': ['home-reality', 'home-ss', 'home-via-relay'],
          },
        },
      });

      // The contract really declares three families, which is why the UI cannot use
      // routeFamilies directly.
      expect(contract.routeFamilies, ['direct', 'relay', 'cdn']);
      // But the cdn family has no member in the legacy urltest, so the compiler never
      // emits a via-cdn group and the list the UI renders must not contain it.
      expect(renderableRouteFamilies(contract), ['direct', 'relay']);
    },
  );

  test('a family present in urltest survives the filter', () {
    final contract = AuroraContract.fromJson({
      'version': 1,
      'nodes': [
        node(id: 'home-reality', role: 'primary', via: 'direct'),
        node(id: 'home-via-relay', role: 'exit', via: 'relay'),
      ],
      'outbound_group': {
        'selector': {
          'tag': 'proxy',
          'members': ['auto', 'home-reality', 'home-via-relay'],
          'default': 'auto',
        },
        'urltest': {
          'tag': 'auto',
          'members': ['home-reality', 'home-via-relay'],
        },
      },
    });

    expect(renderableRouteFamilies(contract), ['direct', 'relay']);
  });

  // Family names are the app's promise to the user about where traffic exits.
  // "Direct" means the exit is the home node; the two families below cannot promise
  // that, so their names must read differently at a glance and never blur into
  // "Direct".
  group('routeFamilyLabel', () {
    test('the built-in families each have a name', () {
      expect(routeFamilyLabel('direct'), 'Direct');
      expect(routeFamilyLabel('relay'), 'Relay');
      expect(routeFamilyLabel('cdn'), 'CDN');
    });

    test('a user-named server family is shown as its own name', () {
      expect(routeFamilyLabel('tokyo'), 'tokyo');
    });

    test('a foreign exit and an unlabeled exit are never called "Direct"', () {
      for (final family in ['foreign', auroraUnspecifiedRouteFamily]) {
        final label = routeFamilyLabel(family);
        expect(label, isNot('Direct'));
        expect(label, isNot(family), reason: 'must not hand the raw id to the user');
        expect(label, isNotEmpty);
      }
      expect(routeFamilyLabel('foreign'), 'Foreign exit');
      expect(routeFamilyLabel(auroraUnspecifiedRouteFamily), 'Unlabeled route');
    });
  });

  group('resolveRenderableRouteFamily', () {
    // Reuses the contract above where the cdn family is declared but filtered out of
    // urltest. The saved-choice restore path (ConnectFlow.resolveRouteFamily) only
    // checked that the family was still in routeFamilies, not that the compiler
    // would actually emit a group for it.
    final contractWithUnrenderableCdn = AuroraContract.fromJson({
      'version': 1,
      'nodes': [
        node(id: 'home-reality', role: 'primary', via: 'direct'),
        node(id: 'home-via-relay', role: 'exit', via: 'relay'),
        node(id: 'home-via-cdn', role: 'exit', via: 'cdn'),
      ],
      'outbound_group': {
        'selector': {
          'tag': 'proxy',
          'members': ['auto', 'home-reality', 'home-via-relay', 'home-via-cdn'],
          'default': 'auto',
        },
        'urltest': {
          'tag': 'auto',
          'members': ['home-reality', 'home-via-relay'],
        },
      },
    });

    test('null (already auto) stays null', () {
      expect(
        resolveRenderableRouteFamily(null, contractWithUnrenderableCdn),
        isNull,
      );
    });

    test('a renderable family passes through unchanged', () {
      expect(
        resolveRenderableRouteFamily('relay', contractWithUnrenderableCdn),
        'relay',
      );
    });

    test(
      'a family the contract still declares but the compiler would never '
      'emit a group for degrades to null, not the dangling id',
      () {
        // cdn is in routeFamilies (still declared) but not in
        // renderableRouteFamilies (an empty group after filtering).
        // resolveRenderableRouteFamily must close that gap; otherwise `selected`
        // would hand RouteFamilyControl a value missing from its segments, and the
        // tag _applyRouteFamily computes was never emitted by the compiler.
        expect(contractWithUnrenderableCdn.routeFamilies, contains('cdn'));
        expect(
          renderableRouteFamilies(contractWithUnrenderableCdn),
          isNot(contains('cdn')),
        );
        expect(
          resolveRenderableRouteFamily('cdn', contractWithUnrenderableCdn),
          isNull,
        );
      },
    );
  });
}
