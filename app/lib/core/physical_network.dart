/// Observation of the physical network (the layer beneath the tunnel), shared by the watchdog and auto-reconnect.
///
/// The incident chain that motivated this started with the app knowing nothing
/// about "the physical network went away": when a hotel Wi-Fi dropped, every probe
/// timed out, the watchdog blamed the route family (the UI said "relay
/// unavailable", and switching to direct was equally unavailable), then restarted
/// the tunnel. With no network the restart naturally could not come up, the NE
/// rejected every start with "No network available", three rounds of reconnect
/// budget burned within 40 seconds, and when Wi-Fi came back a minute later nobody
/// reconnected any more (one outage lasted 7 hours). All of these decisions need
/// the same premise: **is there a physical network right now at all**.
///
/// Pure `dart:io`, no Flutter dependency: `app/lib/cli/` may use it too, and unit
/// tests can run it on any machine.
library;

import 'dart:async';
import 'dart:io';

import 'config_compiler.dart' show auroraTunHostAddresses;

/// Signature when no physical interface holds a usable address.
///
/// This is a **separate state** rather than an empty string: the old reading
/// returned "no address" as an empty string, and callers all did
/// `if (signature.isEmpty) return;`, so a Wi-Fi drop followed by a return with the
/// same DHCP lease looked to every consumer as if nothing had happened.
const String physicalNetworkOffline = 'offline';

bool isPhysicalNetworkOnline(String signature) =>
    signature.isNotEmpty && signature != physicalNetworkOffline;

typedef PhysicalNetworkReader = Future<String> Function();

/// Excluding the tunnel interface by name is enough on macOS (`utun*`) but not on
/// Windows, where a wintun adapter can have any name, and Android's VPN interface
/// is merely `tun0`. The address is the only reliable marker, so both exclusions
/// are applied. Addresses are matched exactly against the **whole host address**
/// (from [auroraTunHostAddresses] in `config_compiler.dart`), not by network
/// prefix: 172.19.0.0/24 is a common private range, and dropping by prefix would
/// judge a machine that is plainly online as offline, which is exactly the
/// "never reconnects again" this module exists to eliminate.
///
/// Common local virtual bridges are also dropped by name (Hyper-V/WSL, VMware,
/// VirtualBox, libvirt, Docker, macOS sharing/VM bridges): they hold addresses
/// but have no upstream, and keeping them would produce a false "online". Known
/// blind spot: a virtual NIC with some other name is still counted as a physical
/// network (that is the old behaviour, so no regression).
const _tunnelNamePrefixes = [
  'utun',
  'tun',
  'tap',
  'wg',
  'tailscale',
  'aurora',
  'vethernet',
  'vmnet',
  'vboxnet',
  'virbr',
  'docker',
  'br-',
  'bridge',
  'veth',
];

bool _isTunnelInterface(String name) {
  final lower = name.toLowerCase();
  if (lower == 'lo' || lower == 'lo0') return true;
  return _tunnelNamePrefixes.any(lower.startsWith);
}

bool _isTunnelAddress(String address) {
  final lower = address.toLowerCase();
  return auroraTunHostAddresses.any((host) => host.toLowerCase() == lower);
}

/// Compress the interface list into a stable signature: `name:type:address`
/// joined in lexicographic order; returns [physicalNetworkOffline] when there is
/// no physical address.
String physicalNetworkSignature(List<NetworkInterface> interfaces) {
  final entries = <String>[];
  for (final interface in interfaces) {
    if (_isTunnelInterface(interface.name)) continue;
    for (final address in interface.addresses) {
      if (_isTunnelAddress(address.address)) continue;
      entries.add(
        '${interface.name}:${address.type.name}:${address.address}',
      );
    }
  }
  if (entries.isEmpty) return physicalNetworkOffline;
  entries.sort();
  return entries.join('|');
}

/// Default reading: enumerate the system interfaces. Link-local addresses
/// (169.254.x / fe80::) do not count as usable. A timeout is added: the
/// enumeration itself should never hang, but if it does it would pin the previous
/// conclusion in place.
Future<String> readPhysicalNetworkSignature() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
  ).timeout(const Duration(seconds: 2));
  return physicalNetworkSignature(interfaces);
}

/// Polls the physical-network signature on a timer, and broadcasts the
/// online/offline transition separately from "switched to a different network".
///
/// The first value read is the baseline and does not count as a transition. A
/// failed read does not change the conclusion: interface enumeration is only a
/// hint, and one failure must not turn a machine that is plainly online into
/// offline.
class PhysicalNetworkMonitor {
  PhysicalNetworkMonitor({
    PhysicalNetworkReader? read,
    this.interval = const Duration(seconds: 5),
  }) : _read = read ?? readPhysicalNetworkSignature;

  final PhysicalNetworkReader _read;
  final Duration interval;
  final StreamController<bool> _online = StreamController<bool>.broadcast();
  final StreamController<String> _signatures =
      StreamController<String>.broadcast();
  Timer? _timer;
  String? _signature;
  Future<void>? _inFlight;
  bool _disposed = false;

  /// The last signature observed successfully; null if never observed.
  String? get signature => _signature;

  /// null if never observed, otherwise the latest conclusion.
  bool? get isOnline {
    final signature = _signature;
    return signature == null ? null : isPhysicalNetworkOnline(signature);
  }

  /// The online <-> offline transition, emitted once each time.
  Stream<bool> get onlineChanges => _online.stream;

  /// The signature changed while online (switched Wi-Fi, unplugged a cable and
  /// joined a hotspot). Offline -> online emits once too, because that equally
  /// means "everything concluded before may no longer hold".
  Stream<String> get signatureChanges => _signatures.stream;

  void start() {
    if (_timer != null || _disposed || interval <= Duration.zero) return;
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
    unawaited(poll());
  }

  /// Read once immediately. For callers that want a fresh answer at a critical
  /// moment (before reconnecting); if a read is already in flight, wait for it
  /// instead of taking a value that could be a whole period old.
  Future<void> poll() {
    if (_disposed) return Future.value();
    return _inFlight ??= _pollOnce().whenComplete(() => _inFlight = null);
  }

  Future<void> _pollOnce() async {
    try {
      final signature = await _read();
      if (_disposed || signature.isEmpty) return;
      final previous = _signature;
      _signature = signature;
      if (previous == null || previous == signature) return;
      final wasOnline = isPhysicalNetworkOnline(previous);
      final nowOnline = isPhysicalNetworkOnline(signature);
      if (wasOnline != nowOnline && !_online.isClosed) _online.add(nowOnline);
      if (nowOnline && !_signatures.isClosed) _signatures.add(signature);
    } catch (_) {
      //       // A failed (or timed-out) enumeration does not count as offline.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_online.close());
    unawaited(_signatures.close());
  }
}
