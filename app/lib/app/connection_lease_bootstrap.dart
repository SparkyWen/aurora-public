import 'package:flutter/foundation.dart' show debugPrint;

import '../core/contract.dart';
import '../data/egress_lease_repository.dart';

typedef LeaseBootstrapRefresh =
    Future<void> Function(EgressPolicy policy, DeliveryInfo delivery);

/// Seeds a verified signed-lease LKG before NetworkExtension installs the TUN.
///
/// Three-path configs deliberately start on `fail-closed`. Fetching the first
/// lease only after that selector is active would route the Worker request into
/// the block outbound and deadlock first connection. A failed bootstrap aborts
/// before [AuroraBridge.start], leaving the physical network unchanged.
///
/// The stored lease is expired whenever the app was closed longer than the
/// lease validity (≤125 min), so a cold launch always needs this network
/// round-trip — which races the physical link coming up (auto-connect fires at
/// launch; an idle phone hotspot takes seconds to wake its data path). Retry
/// transient failures before declaring the control plane unreachable.
abstract final class ConnectionLeaseBootstrap {
  /// Growing gaps so even instant failures ("no route to host" while the link
  /// is still down) keep probing across that wake window instead of burning
  /// all attempts in the first seconds, while a genuinely dead control plane
  /// still fails in bounded time (~12s fast-fail, ~32s all-timeouts).
  static const List<Duration> _defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 6),
  ];

  static Future<void> prepare(
    AuroraContract contract, {
    LeaseBootstrapRefresh? refresh,
    List<Duration>? retryDelays,
  }) async {
    final policy = contract.egress;
    if (policy == null || !policy.hasSignedLease) return;

    final delays = retryDelays ?? _defaultRetryDelays;
    for (var attempt = 0; ; attempt++) {
      EgressLeaseRepository? repository;
      final perform =
          refresh ??
          (EgressPolicy candidate, DeliveryInfo delivery) async {
            repository = EgressLeaseRepository();
            await repository!.refresh(candidate, delivery);
          };
      try {
        await perform(policy, contract.delivery);
        return;
      } catch (error) {
        // Exceptions may embed an authenticated URL. Keep diagnostics categorical.
        final authFailed =
            error is StateError && error.message == 'lease_auth_failed';
        debugPrint(
          'lease bootstrap attempt ${attempt + 1} failed: '
          '${authFailed ? 'lease_auth_failed' : 'lease_refresh_failed'}',
        );
        if (authFailed) throw StateError('lease_auth_failed');
        final permanent =
            error is StateError && error.message == 'lease_policy_invalid';
        if (permanent || attempt >= delays.length) {
          throw StateError('lease_bootstrap_failed');
        }
      } finally {
        await repository?.close();
      }
      await Future<void>.delayed(delays[attempt]);
    }
  }
}
