import 'dart:async';
import 'dart:io' show Platform, SocketException;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'aurora_bridge.dart';
import 'aurora_svc_client.dart';
import 'clash_api_client.dart';
import 'config_compiler.dart' show auroraTunInterfaceName;
import 'svc_paths.dart';

/// Shared [AuroraBridge] implementation for Windows/Linux. It drives the official
/// sing-box executable through a privileged helper (aurora-svc), and all live data
/// is read from sing-box's built-in Clash API. No Flutter platform channel is
/// involved: it is plain Dart HTTP from start to finish, which is why it can be
/// reused unchanged between Windows and Linux; the only difference between the two
/// is folded into [SvcPaths].
///
/// Singleton: the connect flow has to hand the Clash port/secret picked for this
/// connection (already compiled into the config) to the **same** instance that
/// reads the API.
class AuroraBridgeSvc implements AuroraBridge, AuroraStartFailureDetail {
  AuroraBridgeSvc._(
    this.paths, {
    AuroraSvcClient? svc,
    ClashApiClient Function(Uri, String)? clashClientFactory,
  }) : _svc = svc ?? AuroraSvcClient(token: paths.readSvcToken),
       _clashClientFactory =
           clashClientFactory ??
           ((base, secret) => ClashApiClient(base: base, secret: secret));

  /// The platform singleton; see the class comment.
  static AuroraBridgeSvc? _instance;
  static AuroraBridgeSvc forPlatform() => _instance ??= AuroraBridgeSvc._(
    Platform.isWindows ? const WindowsSvcPaths() : const LinuxPaths(),
  );

  /// For unit tests: touches neither the singleton nor the disk. The `token` of
  /// [AuroraSvcClient] is a function reference that is only called when a request is
  /// really made (see the docs in aurora_svc_client.dart), so constructing this
  /// object does not read any file.
  @visibleForTesting
  static AuroraBridgeSvc debugInstance({
    AuroraSvcClient? svc,
    ClashApiClient Function(Uri, String)? clashClientFactory,
  }) => AuroraBridgeSvc._(
    const LinuxPaths(),
    svc: svc,
    clashClientFactory: clashClientFactory,
  );

  final SvcPaths paths;

  /// The Clash API secret compiled into this connection's config; the connect flow writes it before [start].
  String clashSecret = '';

  /// The Clash API port of this connection. 9090 is the default of
  /// Clash/mihomo/v2rayN, and if it is taken sing-box fails to bind and exits
  /// outright, so the connect flow picks a free port every time (see
  /// [pickFreeLoopbackPort]).
  int clashPort = 9090;

  Uri get clashBase => Uri.parse('http://127.0.0.1:$clashPort');

  /// This process's pid, handed to the helper as "who owns this tunnel".
  ///
  /// Only the GUI sets it (see `main.dart`). Once set, however this process goes
  /// away (Quit from the tray, End task in Task Manager, a crash, log-off, the
  /// installer's own `taskkill /IM aurora.exe /F` during an upgrade), the helper
  /// tears the tunnel down with it. Previously only the tray path called stop(), so
  /// every other way of exiting left a sing-box running as SYSTEM, capturing all
  /// routes, with no UI left.
  ///
  /// `aurora-cli` **deliberately does not set it**: it connects and exits, and the
  /// tunnel has to outlive it.
  int? ownerPid;

  final AuroraSvcClient _svc;
  final ClashApiClient Function(Uri, String) _clashClientFactory;
  ClashApiClient? _clash;
  bool _hasClashCoordinates = false;
  Future<void> _lifecycleTail = Future<void>.value();
  int _pendingStarts = 0;

  final _statusCtrl = StreamController<AuroraStatus>.broadcast();
  final _statsCtrl = StreamController<TrafficStat>.broadcast();
  final _groupsCtrl = StreamController<List<OutboundGroupInfo>>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();
  Timer? _poll;
  AuroraStatus _status = AuroraStatus.disconnected;
  String _lastDetail = '';

  /// The most recent failure reason given by the service (sing-box's own last
  /// words).
  ///
  /// This used to be pushed only into [logStream], while `ConnectFlow.describeError`
  /// never reads the log stream, so every start failure was left with just the
  /// useless "the system accepted the request but the core failed to start".
  String? lastFailureDetail;

  @override
  Future<String?> lastStartFailureDetail() async {
    final detail = lastFailureDetail?.trim();
    return detail == null || detail.isEmpty ? null : detail;
  }

  ClashApiClient get _clashClient =>
      _clash ??= _clashClientFactory(clashBase, clashSecret);

  @override
  Future<bool> prepare() async => _svc.installed();

  @override
  Future<void> start(String configJson) async {
    final session = _beginSession();
    final base = clashBase;
    final secret = clashSecret;
    final port = clashPort;
    lastFailureDetail = null;
    _lastDetail = '';
    _setStatus(AuroraStatus.connecting);
    _pendingStarts++;
    try {
      await _enqueueLifecycle(() async {
        // A queued start superseded before dispatch has no side effect to undo.
        if (session != _session) return;
        await _svc.start(
          configJson,
          clashPort: port,
          clashSecret: secret,
          ownerPid: ownerPid,
        );
      });
    } catch (e) {
      // Leaving the state at connecting after a rejected start would strand the UI
      // halfway; the reason that was thrown is shown by the connect flow, and a copy is
      // also kept here for readers that do not go through the exception path (for
      // example opening the diagnostics page later) to see "why the client thinks this
      // start failed".
      if (session == _session) {
        _publishDetail('$e');
        _setStatus(AuroraStatus.error);
      }
      rethrow;
    } finally {
      _pendingStarts--;
    }
    if (session != _session) return;
    // Rebuild the Clash client from this connection's port/secret instead of reusing the instance left from the last connection.
    _clash?.close();
    _clash = _clashClientFactory(base, secret);
    _hasClashCoordinates = true;
    _startPolling();
  }

  @override
  Future<void> stop() async {
    final session = _beginSession();
    _setStatus(AuroraStatus.disconnecting);
    final drainStarts = _pendingStarts > 0;
    // Interrupt a running readiness wait immediately. The response alone is
    // insufficient: an earlier /start might still be in HTTP body/dispatch.
    Object? firstError;
    StackTrace? firstStack;
    final interrupt = _svc.stop().catchError((Object error, StackTrace stack) {
      firstError = error;
      firstStack = stack;
    });
    try {
      await _enqueueLifecycle(() async {
        await interrupt;
        if (drainStarts) {
          // All earlier startup requests have now settled. New starts queue
          // behind this final stop, so cleanup cannot kill a newer connection.
          await _svc.stop();
        } else if (firstError != null) {
          Error.throwWithStackTrace(firstError!, firstStack!);
        }
      });
    } catch (e) {
      if (session == _session) {
        _publishDetail('$e');
        _setStatus(AuroraStatus.error);
        // A rejected/timed-out stop proves nothing about the tunnel. Continue
        // observing it, so repair/recovery does not leave the UI frozen.
        _startPolling();
      }
      rethrow;
    }
    if (session != _session) return;
    _clash?.close();
    _clash = null;
    _hasClashCoordinates = false;
    _setStatus(AuroraStatus.disconnected);
    _statsCtrl.add(const TrafficStat());
  }

  @override
  Future<AuroraStatus> status() async {
    // A stop is not confirmed until its late-start cleanup barrier completes.
    if (_status == AuroraStatus.disconnecting) return _status;
    // While replacement /start is pending, a helper snapshot or a still-live
    // old controller cannot establish readiness for the new configuration.
    if (_pendingStarts > 0) return _status;
    final session = _session;
    var clash = _clash;
    try {
      // An app restart adopts the surviving tunnel through this owner claim.
      final s = await _svc.status(ownerPid: ownerPid);
      if (session != _session || !identical(clash, _clash)) return _status;
      _publishDetail(s.detail);
      if (s.state == 'starting') {
        _observeStarting();
        return AuroraStatus.connecting;
      }
      _adoptSession(s.clashProbe);
      if (s.state == 'running') {
        _startPolling();
        if (!_hasClashCoordinates) {
          _publishDetail('svc_session_unavailable');
          _setStatus(AuroraStatus.error);
          return AuroraStatus.error;
        }
        clash = _clashClient;
        final up = await clash.ping();
        if (session != _session || !identical(clash, _clash)) return _status;
        _setStatus(up ? AuroraStatus.connected : AuroraStatus.connecting);
        return _status;
      }
      return s.state == 'error'
          ? AuroraStatus.error
          : AuroraStatus.disconnected;
    } catch (e) {
      if (session != _session || !identical(clash, _clash)) return _status;
      _publishDetail('$e');
      final coreUp = await _coreSurvivedStatusFailure(e, clash);
      if (session != _session || !identical(clash, _clash)) return _status;
      if (coreUp) {
        _setStatus(AuroraStatus.connected);
        return AuroraStatus.connected;
      }
      _setStatus(AuroraStatus.error);
      rethrow;
    }
  }

  @override
  Stream<AuroraStatus> statusStream() => _statusCtrl.stream;

  /// Carries the helper's failure detail (sing-box's own last words) so that after
  /// the core dies it can be diagnosed without digging through the log file.
  @override
  Stream<String> logStream() => _logCtrl.stream;

  @override
  Future<TrafficStat> queryStats() => _clashClient.traffic();

  @override
  Stream<TrafficStat> statsStream() => _statsCtrl.stream;

  @override
  Stream<List<OutboundGroupInfo>> groupsStream() => _groupsCtrl.stream;

  @override
  Future<void> selectOutbound(String group, String tag) =>
      _clashClient.select(group, tag);

  @override
  Future<void> urlTest(String group) async {
    await _clashClient.groupDelay(group);
  }

  @override
  Future<void> openVpnSettings() async {
    /* n/a on desktop */
  }

  // ---- Polling loop: derive state from the Clash API; feed traffic/groups into streams ----
  Future<void> _enqueueLifecycle(Future<void> Function() action) {
    final operation = _lifecycleTail.then((_) => action());
    // Return errors to the caller while keeping the queue usable for repair.
    _lifecycleTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  int _session = 0;

  int _beginSession() {
    _poll?.cancel();
    _poll = null;
    return ++_session;
  }

  void _startPolling() {
    if (_poll != null) return;
    final session = _session;
    // The guard belongs to this poll loop. An old pending request must neither
    // block the next session nor clear its guard when it eventually returns.
    var inFlight = false;
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (inFlight || session != _session) return;
      inFlight = true;
      var clash = _clash;
      try {
        final s = await _svc.status(ownerPid: ownerPid);
        if (session != _session || !identical(clash, _clash)) return;
        _publishDetail(s.detail);
        if (s.state == 'starting') {
          _observeStarting();
          return;
        }
        if (s.state == 'error') {
          _setStatus(AuroraStatus.error);
          return;
        }
        if (s.state == 'stopped') {
          _setStatus(AuroraStatus.disconnected);
          return;
        }
        _adoptSession(s.clashProbe);
        if (!_hasClashCoordinates) {
          _publishDetail('svc_session_unavailable');
          _setStatus(AuroraStatus.error);
          return;
        }
        clash = _clashClient;
        final up = await clash.ping();
        if (session != _session || !identical(clash, _clash)) return;
        _setStatus(up ? AuroraStatus.connected : AuroraStatus.connecting);
        if (up) {
          try {
            final traffic = await clash.traffic();
            if (session != _session || !identical(clash, _clash)) return;
            _statsCtrl.add(traffic);
            final groups = await clash.groups();
            if (session != _session || !identical(clash, _clash)) return;
            _groupsCtrl.add(groups);
          } catch (e) {
            if (session != _session || !identical(clash, _clash)) return;
            if (e is StateError && e.message == 'clash_auth_failed') {
              _publishDetail('$e');
              _setStatus(AuroraStatus.error);
            }
            // Transient telemetry failures retry on the next bounded tick.
          }
        }
      } catch (e) {
        if (session != _session || !identical(clash, _clash)) return;
        _publishDetail('$e');
        final coreUp = await _coreSurvivedStatusFailure(e, clash);
        if (session != _session || !identical(clash, _clash)) return;
        _setStatus(coreUp ? AuroraStatus.connected : AuroraStatus.error);
      } finally {
        inFlight = false;
      }
    });
  }

  /// A failed helper observation does not prove its child stopped. Confirm
  /// with the already authenticated session's core before publishing error:
  /// that status tears down path supervision and restarts path verification.
  /// Authentication and malformed responses are never treated as transport
  /// noise, and an unknown/stopped session must not probe a guessed port.
  Future<bool> _coreSurvivedStatusFailure(
    Object error,
    ClashApiClient? clash,
  ) async {
    final transportFailure =
        error is SocketException ||
        error is http.ClientException ||
        (error is StateError && error.message == 'svc_status_timeout');
    if (!transportFailure ||
        !_hasClashCoordinates ||
        clash == null ||
        (_status != AuroraStatus.connected &&
            _status != AuroraStatus.connecting)) {
      return false;
    }
    try {
      return await clash.ping();
    } catch (_) {
      return false;
    }
  }

  void _observeStarting() {
    // A replacement has not passed the helper's readiness check. Coordinates
    // from the previous child cannot establish readiness for this one, even
    // if that old controller still responds during teardown.
    _clash?.close();
    _clash = null;
    _hasClashCoordinates = false;
    _setStatus(AuroraStatus.connecting);
    _startPolling();
  }

  void _adoptSession(SvcClashProbe? probe) {
    // Old helpers omit the field. A connection we just started still has its
    // own coordinates; a new client must never guess that an old 9090 API is it.
    if (probe == null) return;
    _hasClashCoordinates = true;
    if (_clash != null &&
        clashPort == probe.port &&
        clashSecret == probe.secret) {
      return;
    }
    clashPort = probe.port;
    clashSecret = probe.secret;
    _clash?.close();
    _clash = _clashClientFactory(clashBase, clashSecret);
  }

  void _publishDetail(String detail) {
    if (detail.isEmpty || detail == _lastDetail) return;
    _lastDetail = detail;
    lastFailureDetail = detail;
    _logCtrl.add(detail);
  }

  @visibleForTesting
  void debugPublishDetail(String detail) => _publishDetail(detail);

  /// The machine's network situation as the helper sees it (interface table,
  /// whether the TUN exists, who owns the tunnel, the full tail of the core log).
  /// The diagnostics page and the support bundle use it to answer "shows connected
  /// but nothing loads"; that cannot be seen from inside the app, because the
  /// criterion for "connected" is merely that the Clash API answered.
  Future<String?> diagnose() => _svc.diagnose();

  /// Physical NICs that can be pinned as the egress; the names come from the same list the core itself sees.
  Future<List<String>> egressInterfaceCandidates() =>
      _svc.egressInterfaceCandidates(tunInterfaceName: auroraTunInterfaceName);

  void _setStatus(AuroraStatus s) {
    if (s == _status) return;
    _status = s;
    _statusCtrl.add(s);
  }
}
