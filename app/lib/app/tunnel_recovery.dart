import 'dart:async';

import '../core/aurora_bridge.dart';
import '../core/mobile_session_control.dart';
import '../data/secure_store.dart';
import 'connect_flow.dart';
import 'vpn_session_supervisor.dart';

/// Mobile recovery only reloads an existing native session in the foreground.
/// Desktop recovery owns the confirmed stop/wait/start sequence; ConnectFlow
/// still owns desktop compilation and its bounded initial retry.
class TunnelRecovery {
  TunnelRecovery({
    required this.bridge,
    this._connect,
    VpnSessionSupervisor? supervisor,
    bool Function()? canRecover,
    this.stopTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 500),
  }) : _canRecover = canRecover ?? (() => true),
       _supervisor = supervisor ?? VpnSessionSupervisor.instance;

  final AuroraBridge bridge;
  final VpnSessionSupervisor _supervisor;
  final Future<void> Function()? _connect;
  final bool Function() _canRecover;
  final Duration stopTimeout;
  final Duration pollInterval;
  bool _restarting = false;
  int _cancelGeneration = 0;
  bool get isBusy => _restarting;

  void cancel() => _cancelGeneration++;

  Future<bool> restart({bool allowStopped = false}) async {
    if (_restarting || ConnectFlow.isBusy || !_canRecover()) return false;
    if (usesMobileSessionRecovery(bridge)) return _reloadMobile();
    final generation = _cancelGeneration;
    bool cancelled() => generation != _cancelGeneration;
    _restarting = true;
    var acted = false;
    try {
      final status = await bridge.status().timeout(stopTimeout);
      // The handler is queued by the watchdog: a user may have disconnected
      // or started a manual attempt before it gets to run.
      final eligible = allowStopped
          ? status == AuroraStatus.disconnected || status == AuroraStatus.error
          : status == AuroraStatus.connected;
      if (!eligible || ConnectFlow.isBusy || cancelled() || !_canRecover()) {
        return false;
      }
      acted = true;
      if (status != AuroraStatus.disconnected) {
        final clock = Stopwatch()..start();
        await bridge.stop().timeout(stopTimeout);
        while (true) {
          final remaining = stopTimeout - clock.elapsed;
          if (remaining <= Duration.zero) {
            throw TimeoutException('recovery_stop');
          }
          final status = await bridge.status().timeout(remaining);
          // A failed status/control request says nothing about the live tunnel.
          // Only confirmed disconnection permits a replacement start.
          if (status == AuroraStatus.disconnected) break;
          await Future<void>.delayed(
            remaining < pollInterval ? remaining : pollInterval,
          );
        }
      }
      // Teardown can outlive the mobile app's foreground eligibility.
      // Finishing the old stop does not authorize a replacement connection.
      if (cancelled() || ConnectFlow.isBusy || !_canRecover()) return acted;
      await (_connect?.call() ?? _connectTunnel(cancelled));
      if (cancelled()) return acted;
      ConnectFlow.lastBackgroundError.value = null;
    } catch (error) {
      if (cancelled()) return acted;
      ConnectFlow.lastBackgroundError.value = error is TimeoutException
          ? 'Automatic recovery could not confirm the tunnel is down; disconnect manually and reconnect'
          : 'Automatic reconnect failed: ${ConnectFlow.describeError(error)}';
    } finally {
      _restarting = false;
    }
    return acted;
  }

  Future<bool> _reloadMobile() async {
    final generation = _cancelGeneration;
    bool manualCancelled() => generation != _cancelGeneration;
    var terminal = false;
    bool cancelled() => manualCancelled() || terminal;
    _restarting = true;
    var acted = false;
    final subscription = bridge.statusStream().listen((status) {
      // In-place reload never stops the system VPN. Any terminal transition
      // invalidates the result, including a user selecting another VPN.
      if (status == AuroraStatus.disconnected ||
          status == AuroraStatus.disconnecting ||
          status == AuroraStatus.error) {
        terminal = true;
      }
    }, onError: (_) {});
    try {
      final control = bridge as AuroraMobileSessionControl;
      final snapshot = await control.sessionSnapshot().timeout(stopTimeout);
      if (cancelled() ||
          !_canRecover() ||
          ConnectFlow.isBusy ||
          snapshot.status != AuroraStatus.connected ||
          snapshot.sessionId == null) {
        return false;
      }
      acted = true;
      final result = await _supervisor.reloadMobileSession(
        bridge,
        snapshot.sessionId!,
        isCancelled: cancelled,
        canReload: () => _canRecover() && !ConnectFlow.isBusy,
        nativeTimeout: stopTimeout,
      );
      // A native failure can terminate NE before its requiresReconnect reply.
      // Terminal status forbids activation, but does not hide that actionable
      // result. A newer explicit user intent still owns the UI completely.
      if (manualCancelled()) return acted;
      if (result == MobileReloadResult.requiresReconnect) {
        ConnectFlow.lastBackgroundError.value = 'The current VPN core cannot be recovered safely; disconnect manually and reconnect';
        return acted;
      }
      if (terminal) return acted;
      if (result == MobileReloadResult.reloaded) {
        ConnectFlow.lastBackgroundError.value = null;
      } else {
        return false;
      }
    } catch (_) {
      if (!cancelled()) {
        ConnectFlow.lastBackgroundError.value = 'The current VPN core cannot be recovered safely; disconnect manually and reconnect';
      }
    } finally {
      await subscription.cancel();
      _restarting = false;
    }
    return acted;
  }

  Future<void> _connectTunnel(bool Function() isCancelled) async {
    if (!await bridge.prepare()) throw StateError('VPN permission denied');
    final outcome = await ConnectFlow.compileAndStart(
      bridge,
      isCancelled: isCancelled,
    );
    if (isCancelled()) return;
    final contract = outcome.contract;
    if (contract.paths != null && contract.pathPolicy != null) return;
    // Recovery also runs while the connect page is hidden. Respect the same
    // stored family preference without depending on that widget to apply it.
    final family = ConnectFlow.resolveRouteFamily(
      await SecureStore.loadRouteFamily(),
      contract,
    );
    if (isCancelled()) return;
    VpnSessionSupervisor.instance.setRouteFamily(family);
    final target = ConnectFlow.routeFamilyTagToApply(
      contract: contract,
      status: await bridge.status(),
      routeFamily: family,
    );
    if (isCancelled()) return;
    if (target != null) {
      await bridge.selectOutbound(contract.outboundGroup.selectorTag, target);
    }
  }
}
