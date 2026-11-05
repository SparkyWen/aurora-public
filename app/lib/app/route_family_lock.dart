import '../core/contract.dart';
import '../core/route_family.dart';
import 'connect_flow.dart';

/// State machine for manually locking the route family (only for flat-shape contracts; the paths of a paths-shape contract are managed by
/// `PathHealthCoordinator`, and there is no "family lock" there).
///
/// It is its own class rather than scattered through `ConnectPage`, for the same reason as `ConnectFlow.routeFamilyTagToApply`
/// being a pure function: both rules here must hold at several entry points at once (cold start reading the saved value /
/// reconnect getting a new contract / the user manually switching family), while `ConnectPage` depends on platform channels that unit tests
/// cannot reach — rules scattered in the page are rules without coverage. The two holes found in final review leaked exactly this way: a reconnect that swapped the
/// contract without recomputing the family, and a failed push being swallowed while the UI already showed "locked".
class RouteFamilyLock {
  RouteFamilyLock({
    required this.persist,
    required this.apply,
    required this.onChanged,
  });

  /// Persist. null (automatic) is left to the caller to decide whether to clear the key or write a placeholder.
  final Future<void> Function(String? family) persist;

  /// Push to the core. **Failure must throw**, otherwise there is no basis for the rollback decision.
  final Future<void> Function(String? family) apply;

  /// Notifies the UI to repaint after the family value changes.
  final void Function() onChanged;

  String? _family;
  bool _adopted = false;

  /// The currently locked family, null = automatic.
  String? get family => _family;

  /// Must be recomputed every time the contract is replaced. The family may have vanished from the contract (that route was taken down), or it may
  /// still be in the contract while the compiled output no longer emits a `via-<family>` group (the member was removed from the legacy urltest).
  /// Without recomputing: no segment of the control is highlighted; when only one family is left the control disappears altogether while the hint still says
  /// "you can switch to Auto", leaving the user no control to unlock with; and the pushed tag does not exist in the compiled output either,
  /// so the selector stays on the old cache_file value — the UI shows locked while it actually runs automatic.
  ///
  /// When [candidate] is null the current value is kept (reconnect path), and cold start passes it in from the saved value. A downgrade is **not**
  /// persisted: a contract temporarily missing a route should not erase the user's choice, and it should still be locked when the route returns.
  String? adopt(AuroraContract contract, [String? candidate]) {
    // null is both the initial absence of a saved preference and the resolved
    // value of explicit auto. Only the first adoption may use the default.
    final saved = candidate ?? (_adopted ? _family ?? 'auto' : null);
    _family = resolveRenderableRouteFamily(
      ConnectFlow.resolveRouteFamily(saved, contract),
      contract,
    );
    _adopted = true;
    return _family;
  }

  /// User switches family: persist first, then push. If the push fails, state, saved value and core are all rolled back to the original value together, and the
  /// error is handed back to the caller to display.
  ///
  /// It must not be swallowed: the UI has already switched to the new family before the push, so swallowing means the UI shows the new family while the core
  /// is still on the old one, with no hint at all. "The user can tap again" does not hold either — the equality
  /// early return at the top would eat the second tap, because the UI state is already the target value.
  Future<Object?> change(String? family) async {
    final previous = _family;
    if (previous == family) return null;
    _family = family;
    onChanged();
    var selectionAttempted = false;
    try {
      await persist(family);
      selectionAttempted = true;
      await apply(family);
      return null;
    } catch (error) {
      _family = previous;
      onChanged();
      try {
        await persist(previous);
      } catch (_) {
        // Preserve the original failure and still restore the live selector.
      }
      // A failure may also be "sent but the read-back confirmation never came" (selector_confirmation_timeout),
      // and the core may no longer be where it was; explicitly pressing the original family back is what makes the UI agree with the core. If this
      // fails too there is nothing else to do, and the error reported to the user is the first one.
      try {
        if (selectionAttempted) await apply(previous);
      } catch (_) {}
      return error;
    }
  }
}
