import '../core/aurora_bridge.dart';
import '../core/contract.dart';
import '../core/path_health.dart';

class PathHealthActivation {
  const PathHealthActivation(this.contract, this.preference);

  final AuroraContract contract;
  final PathPreference preference;
}

/// Prevents path/egress probes from running against the physical interface
/// during NETunnelProvider startup. A compiled connection and an NE connected
/// status may arrive in either order; activation becomes available only after
/// both have arrived, and can be consumed once per connection session.
class PathHealthActivationGate {
  AuroraStatus _status = AuroraStatus.disconnected;
  PathHealthActivation? _pending;
  bool _consumed = false;

  bool get hasPending => _pending != null;

  void register(AuroraContract contract, PathPreference preference) {
    _pending = PathHealthActivation(contract, preference);
    _consumed = false;
  }

  void statusChanged(AuroraStatus status) {
    _status = status;
    if (status == AuroraStatus.disconnected ||
        status == AuroraStatus.disconnecting ||
        status == AuroraStatus.error) {
      _pending = null;
      _consumed = false;
    }
  }

  PathHealthActivation? takeReady() {
    final pending = _pending;
    if (_status != AuroraStatus.connected || pending == null || _consumed) {
      return null;
    }
    _consumed = true;
    return pending;
  }

  void retry() {
    if (_pending != null && _status == AuroraStatus.connected) {
      _consumed = false;
    }
  }
}
