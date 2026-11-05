/// Route families: how traffic reaches an exit.
///
/// The compiler only emits a `via-<family>` urltest group when there is more than one
/// family, and only for a family with at least one member left after filtering (see
/// `_legacyOutbounds` in `config_compiler.dart`). With one family, `auto` already is
/// that family. `AuroraContract.routeFamilies` reflects what a contract
/// declares, not what the compiled config contains, and the two can differ. The UI
/// must render from the latter: otherwise the user can pick a group that does not
/// exist and `selectOutbound` fails on an unknown tag.
///
/// Pure Dart: no Flutter imports (`app/lib/cli/` depends on this).
library;

import 'config_compiler.dart' show AuroraMode, auroraModeFromString;
import 'contract.dart';

/// Family name of a relay in contracts written by hand or built by the advanced
/// signed-egress tooling. Servers from `install.sh` use their own name as family.
const auroraRelayRouteFamily = 'relay';

/// How an explicit "automatic" choice is stored. It differs from "never chose"
/// (null), which resolves to the default route.
const auroraAutoRouteSelection = 'auto';

/// Families the compiler really emits a group for, in the stable
/// [AuroraContract.routeFamilies] order. A family qualifies when there are at least two
/// families and one of its members is in `outbound_group.urltest.members`, which is
/// exactly the compiler's filter.
List<String> renderableRouteFamilies(AuroraContract contract) {
  if (contract.routeFamilies.length < 2) return const [];
  final urltestMembers = contract.outboundGroup.urltestMembers.toSet();
  final byFamily = contract.nodesByFamily;
  return contract.routeFamilies
      .where(
        (family) => (byFamily[family] ?? const []).any(urltestMembers.contains),
      )
      .toList();
}

/// Filters a restored family with the same rule the control renders by. A family
/// the contract still declares but the compiler no longer emits must not be fed
/// back as "selected": the segments have no such value and the tag never existed.
String? resolveRenderableRouteFamily(String? resolved, AuroraContract contract) {
  if (resolved == null) return null;
  return renderableRouteFamilies(contract).contains(resolved) ? resolved : null;
}

/// Family id to the urltest group tag the compiler emits. `'auto'` is a literal
/// rather than a read of `contract.outboundGroup.urltestTag` so this stays a pure
/// function that `VpnSessionSupervisor` can use without a cycle through
/// `connect_flow.dart`.
String routeFamilyGroupTag(String? family) =>
    family == null ? 'auto' : 'via-$family';

/// Display name for a family, shared by the main screen and the desktop tray.
///
/// `foreign` and `unspecified` have deliberately explicit names: "Direct" promises
/// where traffic exits, and those two are the families that cannot promise it.
/// Servers from `install.sh` use their own name, which is shown as is.
String routeFamilyLabel(String family) {
  if (family == auroraUnspecifiedRouteFamily) return 'Unlabeled route';
  return switch (family) {
    'direct' => 'Direct',
    auroraRelayRouteFamily => 'Relay',
    'cdn' => 'CDN',
    'foreign' => 'Foreign exit',
    _ => family,
  };
}

/// Where the selector should be pointed before the user has chosen anything.
///
/// The GUI and the CLI must compute this with the same rule; otherwise both report
/// "connected" while running over different routes.
class AuroraRouteTarget {
  const AuroraRouteTarget({
    required this.groupTag,
    required this.label,
    required this.isPreferred,
    this.family,
  });

  /// Tag handed to the selector.
  final String groupTag;

  /// Human-readable name; the CLI prints this.
  final String label;

  /// False when the preferred route is missing from this contract and this is the
  /// fallback. Callers must say so rather than imply the preferred route is in use.
  final bool isPreferred;

  /// The family this target locks, or null for automatic selection.
  final String? family;
}

/// Resolves the default route in [contract].
///
/// Both contract shapes must be selected explicitly:
///
/// - A multi-path contract (`paths` present) compiles to a selector defaulting to
///   `fail-closed`, which blocks everything until something chooses a path. The GUI
///   has `PathHealthCoordinator` for that; the CLI must name a path itself.
/// - A flat contract defaults to `auto`, a urltest across every family. With several
///   exits that means the public IP follows whichever is fastest at the moment, so
///   the contract's `default_family` wins when it has one.
AuroraRouteTarget resolveDefaultRouteTarget(AuroraContract contract) {
  final paths = contract.paths;
  if (paths != null) {
    final policy = contract.pathPolicy;
    final ordered = <String>{paths.preferred, ...?policy?.fallbackOrder};
    for (final pathId in ordered) {
      final path = paths.items[pathId];
      if (path == null || !pathId.startsWith('relay')) continue;
      return AuroraRouteTarget(
        groupTag: path.groupTag,
        label: 'relay ($pathId)',
        isPreferred: true,
      );
    }
    final preferred = paths.items[paths.preferred];
    if (preferred != null) {
      return AuroraRouteTarget(
        groupTag: preferred.groupTag,
        label: 'preferred path ${paths.preferred}',
        isPreferred: false,
      );
    }
  }
  final renderable = renderableRouteFamilies(contract);
  for (final family in [contract.defaultFamily, auroraRelayRouteFamily]) {
    if (family != null && renderable.contains(family)) {
      return AuroraRouteTarget(
        groupTag: routeFamilyGroupTag(family),
        label: routeFamilyLabel(family),
        isPreferred: true,
        family: family,
      );
    }
  }
  return AuroraRouteTarget(
    groupTag: contract.outboundGroup.urltestTag,
    label: 'automatic selection',
    isPreferred: true,
  );
}

/// Default mode when nothing is saved: global.
///
/// The GUI and the CLI must land on the same default, so this deliberately does not
/// follow the contract's `default_mode`. A saved choice still wins.
AuroraMode resolveAuroraMode(String? saved, AuroraContract contract) {
  // A multi-path contract only has one compiled form (see `compiledMode`).
  if (contract.paths != null) return AuroraMode.global;
  if (saved == null) return AuroraMode.global;
  return auroraModeFromString(saved);
}

/// The family to lock, or null for automatic selection.
///
/// A [saved] value of `'auto'` is an explicit choice of automatic. Null means the
/// user never chose, so the default route applies. Multi-path contracts take no part
/// in family locking: `PathHealthCoordinator` owns their routing and the UI hides the
/// control.
String? resolveRouteFamilySelection(String? saved, AuroraContract contract) {
  if (contract.paths != null) return null;
  if (saved == auroraAutoRouteSelection) return null;
  final families = contract.routeFamilies;
  if (families.length < 2) return null;
  if (saved == null) return resolveDefaultRouteTarget(contract).family;
  if (!families.contains(saved)) return null;
  return saved;
}
