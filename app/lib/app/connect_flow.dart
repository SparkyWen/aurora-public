import 'dart:async' show Completer, Timer, unawaited;
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, kReleaseMode, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;

import '../core/aurora_bridge.dart';
import '../core/mobile_session_control.dart';
import '../core/aurora_bridge_svc.dart';
import '../core/config_compiler.dart';
import '../core/contract.dart';
import '../core/path_health.dart';
import '../core/route_family.dart';
import '../core/rule_sets.dart';
import '../core/svc_paths.dart';
import '../core/windows_paths.dart';
import '../data/contract_repository.dart';
import '../data/secure_store.dart';
import 'connection_lease_bootstrap.dart';
import 'path_event_log.dart';
import 'vpn_session_supervisor.dart';

/// What [ConnectFlow.compileAndStart] actually started, so UI callers can
/// surface it (contract identity, config hash, MTU, server name).
class ConnectOutcome {
  const ConnectOutcome({
    required this.contract,
    required this.mode,
    required this.pathPreference,
    required this.configId,
  });

  final AuroraContract contract;
  final AuroraMode mode;
  final PathPreference pathPreference;

  /// Full sha256 hex of the compiled sing-box JSON.
  final String configId;
}

/// Marker aurora-svc attaches for "this start ran on an adapter left over from the
///
/// previous run". The Go-side constant of the same name is in
/// `desktop/aurora-svc/main.go` (`staleAdapterToken`); the two must change together —
/// it is a cross-language contract, and changing one side silently disables the
/// translation.
const String staleAdapterFailureToken = 'stale_adapter_adopted';

/// What the platform did with a start request, once we stopped taking
/// `bridge.start()` returning as proof of anything.
enum TunnelStartOutcome {
  /// The tunnel reached `connected`.
  connected,

  /// The platform reported a terminal `disconnected`/`error` instead — the
  /// start was rejected or the engine died on the way up.
  failed,

  /// Neither happened inside the window. Deliberately NOT a failure: a
  /// platform whose status merely lags must behave exactly as it did before
  /// this check existed.
  unknown,
}

/// The connect pipeline (contract refresh → ConfigCompiler → bridge.start),
/// shared by the connect page and the desktop tray so both entry points start
/// the exact same tunnel. Callers run [AuroraBridge.prepare] first — the
/// consent/denial UX differs per entry point.
class ConnectFlow {
  ConnectFlow._();

  static bool _inFlight = false;

  /// True while any entry point is inside [compileAndStart]. The tray and the
  /// window button are separate widgets with separate local guards; this is
  /// the shared backstop that keeps them from racing two `bridge.start` calls
  /// (the NEVPN "config stale" code-4 race).
  static bool get isBusy => _inFlight;

  /// Failure text from a background (tray auto-connect) attempt, for the
  /// window UI to surface. Cleared whenever a connect attempt succeeds.
  static final ValueNotifier<String?> lastBackgroundError =
      ValueNotifier<String?>(null);

  /// Successful manual and background starts share one UI adoption path.
  static final ValueNotifier<ConnectOutcome?> latestOutcome =
      ValueNotifier<ConnectOutcome?>(null);

  /// Full sha256 of the sing-box JSON this device last actually started.
  ///
  /// The diagnostics export (`diagnostics_page.dart`'s `buildSupportBundle`)
  /// needs to answer "which config was this" without ever holding the config
  /// itself — that JSON carries real UUIDs/passwords/keys. Only the digest,
  /// computed once here where the config already exists in memory, is kept
  /// around; the JSON is discarded right after `bridge.start()`.
  static String? lastConfigSha256;

  /// Human-readable text for connect failures. Core errors are deliberately
  /// redacted codes; translate the known ones instead of echoing them raw.
  static String describeError(Object error) {
    if (error is NoContractException) return 'Add a server first.';
    if (error is PlatformException) {
      // Security puts OSStatus in details, not in the platform error code.
      // Known migration failures have safe messages independent of native text.
      return switch (error.code) {
        'keychain_migration' when error.details == -25308 =>
          'Unlock the current user\'s keychain, then try connecting again',
        'keychain_migration_timeout' =>
            'Timed out waiting for the Mac keychain; try connecting again later',
        'keychain_migration' ||
        'keychain_migration_incomplete' ||
        'keychain_migration_arguments' =>
            'Mac keychain setup failed; try again, and export diagnostics if it keeps failing',
        _ => '$error',
      };
    }
    if (error is StateError) {
      // The start failure carries the extension's own reason after a colon;
      // keep it attached — it is the difference between "Disconnected" and knowing
      // the core could not bind its command port.
      if (error.message.startsWith('tunnel_start_failed: ')) {
        final reason = error.message.substring('tunnel_start_failed: '.length);
        return 'Tunnel failed to start: ${_explainStartFailure(reason)}';
      }
      return switch (error.message) {
        'lease_auth_failed' =>
            'Exit lease authentication failed; refresh the contract in Settings. If it still fails, the control plane read credential needs updating',
        'svc_auth_failed' =>
            'Authentication with the local Aurora service failed; repair or reinstall the Aurora service and try again',
        'svc_session_unavailable' =>
            'Cannot recover control info for the existing tunnel; disconnect and reconnect. If it still fails, repair the Aurora service',
        'svc_status_invalid' =>
            'The local Aurora service returned an invalid status; restart the service and try again',
        'svc_start_timeout' =>
            'Timed out waiting for the local Aurora service to start; disconnect and try again',
        'svc_stop_timeout' =>
            'Timed out waiting for the local Aurora service to stop; the tunnel is not confirmed down, try disconnecting again',
        'svc_status_timeout' =>
            'Status query to the local Aurora service timed out; check that the service is running',
        'clash_auth_failed' =>
            'Core control interface authentication failed; disconnect and reconnect',
        'clash_request_failed' =>
            'Cannot read control info from the local core; try again later',
        'clash_request_timeout' =>
            'Core control interface timed out; try again later',
        'lease_bootstrap_failed' =>
            'Cannot get an exit lease from the control plane (the network may not be ready yet); try again later',
        'connect_in_flight' => 'A connection is already in progress; please wait',
        'tunnel_start_failed' =>
            'Tunnel failed to start (the system accepted the request, but the core did not come up)',
        'VPN permission denied' => 'VPN permission denied',
        'selector_confirmation_timeout' =>
            'The core did not confirm the route selection in time (can happen right after an upgrade or when the system is busy); try again',
        'selector_readback_failed' =>
            'Reading back the core route selection failed; try again',
        _ => '$error',
      };
    }
    return '$error';
  }

  /// Turns the core's or service's own wording into what the user can do next,
  /// **and keeps the original text**.
  ///
  /// Keeping the original is not verbosity: when we cannot get this machine's logs
  /// remotely, the line in the user's screenshot is all the evidence there is. The
  /// translation only tells them where to look first.
  static String _explainStartFailure(String reason) {
    final lower = reason.toLowerCase();
    // The NE's verdict is the most specific and the most common: when Wi-Fi dropped
    // or no IP was obtained it rejects start outright and the extension process never
    // launches. That is not a core problem and needs nothing from the user — desktop
    // auto-reconnect waits for the network to return (DesktopConnectionRecovery).
    // "Reconnects automatically" can only be honoured on desktop (DesktopConnectionRecovery
    // is only built in the desktop shell); this text is shared with iOS, where the user
    // has to tap again.
    final autoReconnect =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (lower.contains('no_network_available')) {
      return 'No usable network on this device (Wi-Fi disconnected or no IP address). '
          '${autoReconnect ? 'It will reconnect automatically when the network returns; no action needed.' : 'Reconnect when the network returns.'}'
          '\nOriginal message: $reason';
    }
    if (lower.contains('unrecoverable_network_change')) {
      return 'The local network changed during connect (switched Wi-Fi / replugged a cable). '
          '${autoReconnect ? 'Retrying automatically.' : 'Please connect again.'}\nOriginal message: $reason';
    }
    // First: this is more specific than anything below. aurora-svc only attaches this
    // marker when the wait timed out and the core never reported the interface up
    // (desktop/aurora-svc/ready.go).
    if (lower.contains('tun_interface_never_up')) {
      return 'Windows could not create the virtual adapter in time. The wintun step is a device install; '
          'security software blocking it, or a previous adapter still stuck in the system, can keep it from ever finishing. '
          'Restarting the machine usually fixes it; if it keeps happening, temporarily turn off the security software\'s network protection and connect again.'
          '\nOriginal message: $reason';
    }
    // The user tapped disconnect while connecting: aurora-svc aborts that start (see
    // Runner.abortStart), so /start returns 500. This is not a fault.
    if (lower.contains('start_cancelled')) {
      return 'This connection was interrupted by a disconnect while it was being set up. Connect again if you still need it.';
    }
    if (lower.contains('address already in use') ||
        lower.contains('only one usage of each socket')) {
      return 'A local port is in use by another program (common when Clash / v2rayN / mihomo is also installed). '
          'Close it and try again.\nOriginal message: $reason';
    }
    if (lower.contains('config rejected by sing-box') ||
        lower.contains('decode config')) {
      return 'The core rejected this configuration, usually because the contract and core versions do not match. '
          'Refresh the contract in Settings and try again.\nOriginal message: $reason';
    }
    if (lower.contains('wintun') || lower.contains('required file missing')) {
      return 'The installation is missing files it needs to run. Please reinstall.\nOriginal message: $reason';
    }
    if (lower.contains('previous tunnel is still up') ||
        lower.contains('interface aurora0')) {
      return 'The previous tunnel has not been fully torn down. Disconnect and connect again; if it keeps happening, restart the machine.'
          '\nOriginal message: $reason';
    }
    // aurora-svc no longer refuses to start because "the previous adapter is still there" (see
    // desktop/aurora-svc/preflight.go) — it starts anyway with that leftover in place, because this
    // very start is what clears it. The marker only
    // says the start began from a dirty slate; the failure has another cause, so do not send the user off to restart.
    if (lower.contains(staleAdapterFailureToken)) {
      return 'This connection started on a virtual adapter left over from the previous run; the failure reason is on the next line. '
          'Connecting again usually works.\nOriginal message: $reason';
    }
    // Reaching here means the core reported the interface up (otherwise the branch above would have matched),
    // so this is not an adapter problem: the core did not answer on its control port in time. Sending the user to restart the machine would be wasted effort.
    if (lower.contains('tunnel_not_ready')) {
      return 'The core started but did not answer on its control port in time, usually because another proxy program holds the port. '
          'Try again; if it keeps happening, close Clash / v2rayN / mihomo or similar and connect again.'
          '\nOriginal message: $reason';
    }
    return reason;
  }

  /// How long a start gets to prove itself before we stop watching. Generous:
  /// a `unknown` verdict costs nothing, a premature one would break connects.
  static const tunnelUpTimeout = Duration(seconds: 25);

  /// A `disconnected` seen sooner than this after start is the stale pre-start
  /// value, not a verdict — `startVPNTunnel()` returns before NE has moved the
  /// session off `disconnected`. After it, `disconnected` means the start died.
  static const _startSettleGrace = Duration(seconds: 2);

  /// Waits for the platform to actually bring the tunnel up.
  ///
  /// Watches the status STREAM and polls `status()` alongside it: the stream is
  /// the timely signal but we subscribe after `start()` has already been
  /// issued, so a transition can land before anyone is listening. During an earlier
  /// incident the extension threw ~2ms into `startTunnel`, which is
  /// exactly the window a stream-only watcher misses.
  @visibleForTesting
  static Future<TunnelStartOutcome> awaitTunnelUp(
    AuroraBridge bridge, {
    Duration timeout = tunnelUpTimeout,
  }) async {
    final startedAt = DateTime.now();
    final settled = Completer<TunnelStartOutcome>();
    var sawConnecting = false;

    void observe(AuroraStatus status) {
      if (settled.isCompleted) return;
      switch (status) {
        case AuroraStatus.connected:
          settled.complete(TunnelStartOutcome.connected);
        case AuroraStatus.connecting:
        case AuroraStatus.disconnecting:
          sawConnecting = true;
        case AuroraStatus.disconnected:
        case AuroraStatus.error:
          // Only a verdict once the platform has demonstrably left its
          // pre-start state, or enough time has passed that it cannot still
          // be sitting in it.
          if (sawConnecting ||
              DateTime.now().difference(startedAt) >= _startSettleGrace) {
            settled.complete(TunnelStartOutcome.failed);
          }
      }
    }

    final subscription = bridge.statusStream().listen(observe, onError: (_) {});
    final poller = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      try {
        observe(await bridge.status());
      } catch (_) {
        // Polling is a backstop; a failing query must not decide the outcome.
      }
    });
    try {
      return await settled.future.timeout(
        timeout,
        onTimeout: () => TunnelStartOutcome.unknown,
      );
    } finally {
      poller.cancel();
      // NOT awaited: cancelling a subscription to a generator that is parked on
      // an await does not complete until that generator does, so awaiting it
      // would hand the connect pipeline the very unbounded wait this function
      // exists to remove. We are done listening either way.
      unawaited(subscription.cancel());
    }
  }

  /// Pulls the reason out of the macOS extension's breadcrumb log so a failed
  /// start can name itself instead of leaving the user at a bare "Disconnected".
  ///
  /// The extension runs as root and the app as the user, so their App Group
  /// containers do not resolve to the same directory — `/tmp/aurora-ext.log`
  /// (root-owned, world-readable, written on purpose for this) is the one file
  /// both sides can see.
  @visibleForTesting
  static String? extractStartFailureReason(String logTail) {
    const marker = 'startTunnel FAILED, releasing command server: ';
    final line = const LineSplitter()
        .convert(logTail)
        .lastWhere((l) => l.contains(marker), orElse: () => '');
    if (line.isEmpty) return null;
    final reason = line.substring(line.indexOf(marker) + marker.length).trim();
    return reason.isEmpty ? null : reason;
  }

  static const _extensionLogPath = '/tmp/aurora-ext.log';

  /// Why a failed start failed.
  ///
  /// The two platform families keep this sentence in different places: the macOS
  /// extension runs as root and the app as the user, and their App Group containers
  /// are different directories, so the convention is `/tmp/aurora-ext.log`;
  /// aurora-svc on Windows/Linux returns it to the app through `/status`'s `detail`,
  /// and [AuroraBridgeSvc] keeps it in `lastFailureDetail`.
  ///
  /// It used to read only the macOS one, so every Windows failure ended up as just "the core did not come up".
  ///
  /// Later the platform's own verdict was added: when the NE rejects a start with
  /// "No network available", the extension process is never launched and the log has
  /// nothing — only `NEVPNConnection.fetchLastDisconnectError` knows. So ask the bridge
  /// ([AuroraStartFailureDetail]) first, and fall back to the log.
  @visibleForTesting
  static Future<String?> startFailureReason(AuroraBridge bridge) async {
    if (bridge is AuroraStartFailureDetail) {
      // No intersection-type promotion in Dart: the capability interface is
      // not a subtype of AuroraBridge, so the cast has to be explicit.
      final source = bridge as AuroraStartFailureDetail;
      try {
        final detail = (await source.lastStartFailureDetail())?.trim();
        if (detail != null && detail.isNotEmpty) return detail;
      } catch (_) {
        // The native side had no answer: fall through to inference below.
      }
    }
    if (bridge is AuroraBridgeSvc) return null;
    if (!Platform.isMacOS) return null;
    try {
      final file = File(_extensionLogPath);
      if (!file.existsSync()) return null;
      return extractStartFailureReason(file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Future<T> runExclusive<T>(Future<T> Function() body) async {
    if (_inFlight) throw StateError('connect_in_flight');
    _inFlight = true;
    try {
      return await body();
    } finally {
      _inFlight = false;
    }
  }

  /// The compiler platform for the current OS. macOS reuses the iOS NE path
  /// (same libbox, same small subnet); Windows drives the official binary.
  static AuroraPlatform get platform {
    if (Platform.isIOS || Platform.isMacOS) return AuroraPlatform.ios;
    if (Platform.isWindows) return AuroraPlatform.windows;
    if (Platform.isLinux) return AuroraPlatform.linux;
    return AuroraPlatform.android;
  }

  // Dev hook: debug Android builds write a box.log to the app-private dir so
  // routing can be inspected. The path is Android-specific; on iOS the
  // PacketTunnel extension already redirects the core's stderr to the App Group
  // container, so we keep config-level file logging off (info level).
  static String? get debugLogPath {
    if (kReleaseMode || Platform.isIOS) return null;
    // Linux, like macOS/Windows, has no writable Android-only path — without this
    // branch, desktop Linux would hand sing-box's file log an Android sandbox path.
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return null;
    return '/data/data/com.aurora.aurora/files/box.log';
  }

  /// The user's persisted mode choice when there is one, else global.
  /// [saved] is the raw string from [SecureStore.loadMode].
  ///
  /// With no saved choice the default comes from [resolveAuroraMode] (not the
  /// contract's `default_mode`), so the GUI and the command line land on the same
  /// default. The contract's `default_mode` is still parsed and shown, it just does not decide the
  /// first-launch mode: if the two entry points followed different sources, the user would
  /// see "Connected" on both and yet be on different routes.
  static AuroraMode resolveMode(String? saved, AuroraContract contract) =>
      resolveAuroraMode(saved, contract);

  /// Path preference is additive: legacy contracts ignore any stored value.
  /// Automatic always means the contract's signed preferred path (relay today).
  static PathPreference resolvePathPreference(
    String? saved,
    AuroraContract contract,
  ) {
    if (contract.paths == null || contract.pathPolicy == null) {
      return PathPreference.auto;
    }
    return saved == 'home-direct'
        ? PathPreference.homeDirect
        : PathPreference.auto;
  }

  static String pathPreferenceStorageValue(PathPreference preference) =>
      preference == PathPreference.homeDirect ? 'home-direct' : 'auto';

  /// A saved family only counts if it still exists in the current contract; if the contract
  /// changed (say a route was migrated away) fall back to automatic, no error. A single-family
  /// contract has nothing to choose, so it is always automatic.
  ///
  /// paths-shaped contracts are always automatic (symmetric with [resolvePathPreference]): their
  /// paths are managed by `PathHealthCoordinator`, there is no "manual family lock" and the UI
  /// shows no family control. The saved value is one key shared across contract shapes, so
  /// an unguarded `relay` saved in a flat session would take effect in a paths session: the failure
  /// text would become "Connected · relay unavailable" (same for the tray), and a delivered
  /// `via-relay` would be written by the native side into desiredSelections, overriding the
  /// coordinator's replay target, with no control in the UI to switch back to automatic.
  /// When nothing was ever saved ([saved] is null) the default comes from
  /// [resolveRouteFamilySelection], same as the command line. An **explicitly** saved `'auto'` is
  /// still automatic, which is why "switch back to automatic" must write `'auto'` rather than clear
  /// the key (see `_persistRouteFamily` in `connect_page.dart`): once cleared, the default would
  /// take over and the UI could never express "I want automatic".
  static String? resolveRouteFamily(String? saved, AuroraContract contract) =>
      resolveRouteFamilySelection(saved, contract);

  /// Whether to explicitly push the family selection to the selector right now, and to which tag —
  /// a pure decision that touches no instance state. It is extracted because it must give the same
  /// answer on both cold-start paths: one is the moment the status flips to connected, the other is
  /// the UI finishing init and finding that `bridge.status()` had already reported connected
  /// (`bridge.status()` is a single platform call, while UI init awaits contract loading + several
  /// storage reads + package info, so which finishes first is not defined). Calling it on only one
  /// path would miss the explicit push on the other, leaving the selector on the stale value cached by
  /// cache_file — exactly the "locked family was not re-pushed" bug, replayed on the cold-start
  /// path. Both paths must call it rather than each re-deciding.
  static String? routeFamilyTagToApply({
    required AuroraContract? contract,
    required AuroraStatus status,
    required String? routeFamily,
  }) {
    if (contract == null || status != AuroraStatus.connected) return null;
    // null (automatic) uses the contract's own legacy urltest tag, not the literal 'auto'
    // from routeFamilyGroupTag(null) — the two happen to be equal, but here we follow the contract,
    // for the same reason as the comment on routeFamilyGroupTag in route_family.dart.
    return routeFamily == null
        ? contract.outboundGroup.urltestTag
        : routeFamilyGroupTag(routeFamily);
  }

  static String? initialPathGroup(
    PathPreference preference,
    AuroraContract contract,
  ) {
    final paths = contract.paths;
    final policy = contract.pathPolicy;
    if (paths == null || policy == null) return null;
    final pathId = preference == PathPreference.homeDirect
        ? policy.fallback
        : paths.preferred;
    return paths.items[pathId]?.groupTag;
  }

  /// Compiles the freshest contract and starts the tunnel. When [mode] is null
  /// (tray path, no mode UI) the persisted choice / contract default is used.
  /// Throws `StateError('connect_in_flight')` when another attempt is running.
  static Future<ConnectOutcome> compileAndStart(
    AuroraBridge bridge, {
    AuroraMode? mode,
    PathPreference? pathPreference,
    bool Function()? isCancelled,
  }) => runExclusive(() async {
    try {
      final outcome = await _startOnceRetrying(
        bridge,
        mode: mode,
        pathPreference: pathPreference,
        isCancelled: isCancelled,
      );
      latestOutcome.value = outcome;
      unawaited(PathEventLog.instance.record('connect_ok'));
      return outcome;
    } catch (error) {
      unawaited(
        PathEventLog.instance.record('connect_failed', {
          'error': describeError(error),
        }),
      );
      rethrow;
    }
  });

  /// Which start failures are worth one more try on our own, instead of first putting the user in front of a wall of red text.
  ///
  /// These failures are one-offs: the previous wintun adapter was not fully gone yet, or the adapter
  /// was built too slowly to make the readiness window. The correct next step is "connect again", so
  /// the user should not have to do it.
  ///
  /// Conversely, failures that would repeat a hundred times must **not** be retried (config rejected by the core, missing files in the install), nor the start the user interrupted with disconnect — reconnecting that fights the user.
  @visibleForTesting
  static bool isRetryableStartFailure(Object error) {
    final text = '$error'.toLowerCase();
    const terminal = [
      'start_cancelled',
      'config rejected',
      'required file missing',
      'permission denied',
      'lease_bootstrap_failed',
    ];
    if (terminal.any(text.contains)) return false;
    const transient = [
      staleAdapterFailureToken,
      'tunnel_not_ready',
      'previous tunnel is still up',
      'tunnel_start_failed',
      'sing-box exited',
    ];
    return transient.any(text.contains);
  }

  /// Delay between retries. Long enough for aurora-svc to wait out the previous adapter (its own
  /// tunnelTeardownBudget is 5s), short enough that the user does not think the UI is stuck.
  static const retryDelay = Duration(seconds: 3);

  /// **Only one retry** — a deliberate cap.
  ///
  /// The worst case is `tunnel_not_ready`: aurora-svc waits the full 45s before giving up, so a retry
  /// means the user watches "Connecting" for nearly 95 seconds. It is still worth it: the core that
  /// timed out was killed halfway through creating the adapter, which has most likely been built and
  /// left in place, and the next start simply adopts it (see desktop/aurora-svc/preflight.go). So
  /// this one retry is the one most likely to succeed. More would only drag the time out.
  ///
  /// Watchdog recovery and the window buttons both reuse this single retry. The desktop connection
  /// intent controller has its own bounded backoff budget for unexpected disconnects, and does not stack an unconditional tray start retry on top.

  static Future<ConnectOutcome> _startOnceRetrying(
    AuroraBridge bridge, {
    AuroraMode? mode,
    PathPreference? pathPreference,
    bool Function()? isCancelled,
  }) async {
    try {
      return await _compileAndStart(
        bridge,
        mode: mode,
        pathPreference: pathPreference,
        isCancelled: isCancelled,
      );
    } catch (error) {
      _checkCancellation(isCancelled);
      // A mobile terminal status cannot distinguish a core failure from a
      // user choosing another VPN. End this attempt; only a new user action
      // may acquire a replacement system VPN. Desktop keeps its bounded retry.
      if (usesMobileSessionRecovery(bridge) ||
          !isRetryableStartFailure(error)) {
        rethrow;
      }
      unawaited(
        PathEventLog.instance.record('connect_retry', {
          'error': describeError(error),
        }),
      );
      // Stop first: the failed attempt may have left a half-built core/adapter, and a plain start would run into it.
      try {
        await bridge.stop();
      } catch (_) {
        // It never came up in the first place, so failing to stop it is expected.
      }
      await Future<void>.delayed(retryDelay);
      return await _compileAndStart(
        bridge,
        mode: mode,
        pathPreference: pathPreference,
        isCancelled: isCancelled,
      );
    }
  }

  static Future<ConnectOutcome> _compileAndStart(
    AuroraBridge bridge, {
    AuroraMode? mode,
    PathPreference? pathPreference,
    bool Function()? isCancelled,
  }) async {
    _checkCancellation(isCancelled);
    // Pull fresh nodes from the control plane first (reachable without the
    // tunnel); falls back to the stored/embedded contract if unreachable.
    final contract = await ContractRepository.loadWithRefresh();
    // Seed the signed Lease while the physical route is still available. The
    // compiled three-path selector starts fail-closed, so doing this after
    // bridge.start() would block its own first Lease request.
    await ConnectionLeaseBootstrap.prepare(contract);
    mode = resolveMode(mode?.name ?? await SecureStore.loadMode(), contract);
    pathPreference ??= resolvePathPreference(
      await SecureStore.loadPathPreference(),
      contract,
    );
    final ruleSetPaths = mode == AuroraMode.smart
        ? await RuleSets.ensureExtracted()
        : const <String, String>{};
    // On Windows/Linux, this connection's Clash API secret and port are compiled into the config and
    // handed to the bridge that reads the API. The port is picked fresh each time: 9090 is the default
    // of Clash/mihomo/v2rayN, and when it is taken sing-box fails to bind and exits outright.
    final usesSvc = Platform.isWindows || Platform.isLinux;
    String? clashSecret;
    var clashPort = 9090;
    // The egress NIC the user pinned. Only meaningful on svc desktops: on mobile the system provides the
    // underlying interface, and the macOS NE ignores this field. Empty / never saved = follow the system default route (the old behaviour).
    String? defaultInterface;
    if (usesSvc) {
      clashSecret = WindowsPaths.randomSecret();
      clashPort = await pickFreeLoopbackPort();
      final bridgeSvc = AuroraBridgeSvc.forPlatform();
      bridgeSvc.clashSecret = clashSecret;
      bridgeSvc.clashPort = clashPort;
      defaultInterface = (await SecureStore.loadEgressInterface())?.trim();
    }
    final config = ConfigCompiler.compile(
      contract,
      mode: mode,
      platform: platform,
      ruleSetPaths: ruleSetPaths,
      debugLogPath: debugLogPath,
      clashApiSecret: clashSecret,
      clashApiPort: clashPort,
      defaultInterface: defaultInterface,
    );
    final configJson = json.encode(config);
    final configId = sha256.convert(utf8.encode(configJson)).toString();
    lastConfigSha256 = configId;
    _checkCancellation(isCancelled);
    await bridge.start(configJson);
    // start() returning only means the platform ACCEPTED the request. Treating
    // that as success is how eight consecutive failed starts got logged as
    // `connect_ok` while the user watched "Connecting" fall back
    // to "Disconnected" with no reason anywhere (see docs/reliability-notes.md).
    final outcome = await awaitTunnelUp(bridge);
    _checkCancellation(isCancelled);
    if (outcome == TunnelStartOutcome.failed) {
      final reason = await startFailureReason(bridge);
      unawaited(
        PathEventLog.instance.record('tunnel_start_failed', {
          'reason': ?reason,
        }),
      );
      throw StateError(
        reason == null ? 'tunnel_start_failed' : 'tunnel_start_failed: $reason',
      );
    }
    if (outcome == TunnelStartOutcome.unknown) {
      unawaited(PathEventLog.instance.record('tunnel_up_unconfirmed'));
    }
    lastBackgroundError.value = null;
    final pathGroup = initialPathGroup(pathPreference, contract);
    if (pathGroup != null) {
      // The compiled selector also defaults to fail-closed. Repeat the choice
      // explicitly so attaching to an already-running core cannot inherit a
      // previous candidate while the supervisor performs egress verification.
      await bridge.selectOutbound(
        contract.outboundGroup.selectorTag,
        auroraFailClosedOutboundTag,
      );
    }
    // Every contract shape attaches the supervisor: three-path contracts get
    // the coordinator, and ALL sessions get the data-path watchdog. Before
    // this, a home-direct tunnel had no health monitoring at all — a wedged
    // engine kept showing "connected" with zero connectivity until a manual
    // reconnect.
    await VpnSessionSupervisor.instance.attach(
      bridge,
      contract,
      pathPreference,
    );
    _checkCancellation(isCancelled);
    return ConnectOutcome(
      contract: contract,
      mode: mode,
      pathPreference: pathPreference,
      configId: configId,
    );
  }

  static void _checkCancellation(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw StateError('start_cancelled');
  }
}
