import 'dart:async';

import '../core/aurora_bridge.dart';
import '../core/physical_network.dart';
import 'connect_flow.dart';
import 'path_event_log.dart';
import 'tunnel_recovery.dart';

/// Keeps an explicitly requested desktop connection alive after child/service
/// failure. A short-lived successful start still belongs to the same outage.
///
/// A field incident exposed a blind spot in this class: it only watched the tunnel
/// state, not the physical network. When hotel Wi-Fi dropped, the watchdog tore the tunnel down and reconnected, the NE rejected every start with
/// "No network available", the three rounds of [_delays] burned out within 40 seconds,
/// and then it stopped — Wi-Fi came back a minute later, nobody reconnected, and the user stayed offline for 7 hours.
/// So now it watches the physical network itself: no network means wait (no budget burned, no red text), and as soon as the network is back
/// the budget is refunded and it tries again immediately.
class DesktopConnectionRecovery {
  DesktopConnectionRecovery({
    required this.bridge,
    required this.recovery,
    PhysicalNetworkReader? physicalNetworkSignature,
    Duration networkPollInterval = const Duration(seconds: 5),
    PathEventLog? pathEventLog,
  }) : _network = PhysicalNetworkMonitor(
         read: physicalNetworkSignature,
         interval: networkPollInterval,
       ),
       _pathEventLog = pathEventLog ?? PathEventLog.instance;

  static DesktopConnectionRecovery? active;
  final AuroraBridge bridge;
  final TunnelRecovery recovery;
  final PhysicalNetworkMonitor _network;
  final PathEventLog _pathEventLog;
  static const _delays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  /// First reconnect delay after the network returns: give the system a moment to settle routes/DNS. The NE can still
  /// answer "No network available" in the first second or two after the interface is satisfied.
  static const _networkReturnDelay = Duration(seconds: 2);

  static const _waitingForNetworkMessage =
      'No usable network (Wi-Fi disconnected or no IP address); it will reconnect automatically when the network returns';

  StreamSubscription<AuroraStatus>? _subscription;
  StreamSubscription<bool>? _onlineSubscription;
  StreamSubscription<String>? _signatureSubscription;
  Timer? _retry;
  Timer? _stable;
  AuroraStatus? _status;
  bool _wanted = false;
  bool _manualPending = false;
  bool _inFlight = false;
  bool _disposed = false;
  bool _waitingForNetwork = false;
  int _generation = 0;
  int _attempts = 0;

  void start() {
    if (_subscription != null || _disposed) return;
    _subscription = bridge.statusStream().listen(_observe, onError: (_) {});
    _onlineSubscription = _network.onlineChanges.listen(_onOnlineChanged);
    _signatureSubscription = _network.signatureChanges.listen(
      (_) => _onNetworkReturned(),
    );
    _network.start();
    final generation = _generation;
    unawaited(
      bridge
          .status()
          .then((status) {
            if (!_disposed && generation == _generation) _observe(status);
          })
          .catchError((Object _) {}),
    );
  }

  bool Function() beginConnection() {
    stopRequested();
    _wanted = true;
    _manualPending = true;
    _attempts = 0;
    final generation = _generation;
    return () => _disposed || generation != _generation;
  }

  void endConnection({AuroraStatus? status}) {
    _manualPending = false;
    if (status != null) _observe(status);
    if (_status == AuroraStatus.connected) {
      _observe(AuroraStatus.connected);
    } else {
      _schedule();
    }
  }

  Future<bool> restartForWatchdog() async {
    if (!_wanted || _manualPending || _inFlight || _disposed) return false;
    return recovery.restart();
  }

  void stopRequested() {
    _generation++;
    _wanted = false;
    _manualPending = false;
    _retry?.cancel();
    _retry = null;
    _stable?.cancel();
    _stable = null;
    _clearWaitingForNetwork();
    recovery.cancel();
  }

  void _observe(AuroraStatus status) {
    if (_disposed) return;
    _status = status;
    if (status == AuroraStatus.connected) {
      _retry?.cancel();
      _retry = null;
      _clearWaitingForNetwork();
      if (_wanted) {
        _stable ??= Timer(const Duration(seconds: 120), () {
          _stable = null;
          if (_wanted && _status == AuroraStatus.connected) _attempts = 0;
        });
      }
      return;
    }
    _stable?.cancel();
    _stable = null;
    _schedule();
  }

  bool get _needsRecovery =>
      _status == AuroraStatus.disconnected || _status == AuroraStatus.error;

  void _onOnlineChanged(bool online) {
    if (_disposed) return;
    if (online) {
      _onNetworkReturned();
      return;
    }
    // Network is gone: cancel the queued retry. Let the one already running fail by itself — after it runs into
    // the NE's rejection it returns to _schedule, and then it is handled as "no network".
    _retry?.cancel();
    _retry = null;
    if (_wanted && !_manualPending && _needsRecovery) _markWaitingForNetwork();
  }

  /// The network came back, or changed to a different one: the earlier conclusion that "reconnecting is useless" is void.
  void _onNetworkReturned() {
    if (_disposed || !_wanted || _manualPending) return;
    final wasWaiting = _waitingForNetwork;
    final wasExhausted = _attempts >= _delays.length;
    _attempts = 0;
    _clearWaitingForNetwork();
    if (!_needsRecovery || _inFlight || _retry != null) return;
    if (wasWaiting || wasExhausted) {
      unawaited(_pathEventLog.record('recovery_rearmed_by_network'));
    }
    final generation = _generation;
    _retry = Timer(_networkReturnDelay, () {
      _retry = null;
      if (generation == _generation) unawaited(_restore(generation));
    });
  }

  void _markWaitingForNetwork() {
    // The message is (re)asserted every time: an attempt that was in flight
    // when the network dropped overwrites it with its own failure text, and
    // that text must not stick for the rest of the outage.
    ConnectFlow.lastBackgroundError.value = _waitingForNetworkMessage;
    if (_waitingForNetwork) return;
    _waitingForNetwork = true;
    unawaited(_pathEventLog.record('recovery_waiting_for_network'));
  }

  void _clearWaitingForNetwork() {
    if (!_waitingForNetwork) return;
    _waitingForNetwork = false;
    if (ConnectFlow.lastBackgroundError.value == _waitingForNetworkMessage) {
      ConnectFlow.lastBackgroundError.value = null;
    }
  }

  void _schedule() {
    if (_disposed ||
        !_wanted ||
        _manualPending ||
        _inFlight ||
        _retry != null ||
        !_needsRecovery) {
      return;
    }
    // Do not queue when it is known there is no network: every start would only be rejected by the NE with "No network
    // available", burning the budget for nothing. Wait for PhysicalNetworkMonitor to report the network back.
    if (_network.isOnline == false) {
      _markWaitingForNetwork();
      return;
    }
    if (_attempts >= _delays.length) {
      ConnectFlow.lastBackgroundError.value =
          'Automatic recovery failed repeatedly and retries are paused; check the network or the Aurora service, then connect manually';
      return;
    }
    final generation = _generation;
    _retry = Timer(_delays[_attempts], () {
      _retry = null;
      if (generation == _generation) unawaited(_restore(generation));
    });
  }

  Future<void> _restore(int generation) async {
    if (_disposed || !_wanted || _manualPending || !_needsRecovery) return;
    if (ConnectFlow.isBusy || recovery.isBusy) {
      _schedule();
      return;
    }
    // Look once more right before going: polling has a 5-second gap, so do not run into
    // the NE's rejection with an expired "online". With no conclusion yet (first read not finished), go ahead as before.
    if (_network.isOnline != null) {
      await _network.poll();
      if (_disposed || generation != _generation) return;
      if (_network.isOnline == false) {
        _schedule();
        return;
      }
    }
    _inFlight = true;
    _attempts++;
    try {
      await recovery.restart(allowStopped: true);
      if (_disposed || generation != _generation) return;
      try {
        final status = await bridge.status().timeout(
          const Duration(seconds: 3),
        );
        if (!_disposed && generation == _generation) _observe(status);
      } catch (_) {
        // The next bounded attempt can observe a restarted helper.
      }
    } finally {
      _inFlight = false;
      // A new manual attempt may have failed while the cancelled old stop was
      // draining. Only the current intent decides whether recovery is needed.
      _schedule();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopRequested();
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_onlineSubscription?.cancel());
    _onlineSubscription = null;
    unawaited(_signatureSubscription?.cancel());
    _signatureSubscription = null;
    _network.dispose();
    if (identical(active, this)) active = null;
  }
}
