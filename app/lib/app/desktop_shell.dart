import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/aurora_bridge.dart';
import '../core/route_family.dart';
import '../core/windows_paths.dart';
import 'connect_flow.dart';
import 'desktop_connection_recovery.dart';
import 'tunnel_recovery.dart';
import 'vpn_session_supervisor.dart';

/// Native host channel for app-lifecycle actions.
///
/// Only macOS's `MainFlutterWindow` implements it — that platform needs it,
/// because the VPN session belongs to a NetworkExtension whose teardown runs on
/// the app's real terminate path. Windows and Linux have no handler and never
/// did (their runners are the stock Flutter templates), so [AuroraTray._quit]
/// always takes its window-close fallback there. That is correct rather than
/// merely tolerable on those two: the tunnel lives in aurora-svc, a separate
/// privileged process, and it is stopped explicitly before this call and again
/// by the service itself when this process disappears (see `main.dart`'s
/// ownerPid). Do not read this constant as evidence of a Windows handler.
const MethodChannel _desktopChannel = MethodChannel('aurora/desktop');

/// True on the desktop targets that use the tray/window/autostart shell.
bool get isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Runs one desktop-shell setup step and **is guaranteed not to throw**. Returns whether the step actually worked.
///
/// It exists because of a real incident: `tray_manager`'s Linux implementation has only
/// four methods — destroy/setIcon/setTitle/setContextMenu — and `setToolTip` throws
/// `MissingPluginException`; that exception went from `AuroraTray.init` through
/// `initDesktopShell` and through the await in `main()`, so `runApp` never ran —
/// the user saw a window that opened but was **completely black** (Ubuntu).
///
/// The tray, window decoration and login item are all nice-to-haves; none is worth "the app won't open".
Future<bool> desktopShellStep(String what, Future<void> Function() step) async {
  try {
    await step();
    return true;
  } on MissingPluginException catch (error) {
    // The platform does not implement this capability: not an error, just absent.
    debugPrint('desktop shell: $what is unavailable on this platform ($error)');
    return false;
  } catch (error) {
    debugPrint('desktop shell: $what failed: $error');
    return false;
  }
}

/// Wire up window_manager + a tray/menu-bar icon whose menu drives [bridge], and
/// register the app as a login item. Call once from main() before runApp on
/// desktop. No-op on mobile so those builds never touch the desktop plugins.
///
/// Every step goes through [desktopShellStep]: a failing step only costs a decoration and must never
/// hand the caller (`main()`, which awaits this before `runApp`) an exception.
Future<void> initDesktopShell(AuroraBridge bridge) async {
  if (!isDesktop) return;
  // Older Windows builds left a compiled config — real credentials in plain
  // text — under %APPDATA%\Aurora. Nothing reads it now; drop it on sight.
  if (Platform.isWindows) {
    await desktopShellStep(
      'clean up legacy leftover config',
      () async => WindowsPaths.removeLegacyUserConfig(),
    );
  }
  final windowReady = await desktopShellStep(
    'window manager init',
    windowManager.ensureInitialized,
  );
  if (windowReady) {
    const options = WindowOptions(
      size: Size(420, 720),
      minimumSize: Size(360, 600),
      center: true,
      title: 'Aurora',
    );
    await desktopShellStep(
      'show main window',
      () => windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
      }),
    );
  }

  final tray = AuroraTray(bridge);
  DesktopConnectionRecovery.active = tray.connections;
  tray.connections.start();
  final trayReady = await tray.init();

  // Close-to-tray only holds when the tray icon was actually installed. Intercepting close without one
  // would leave the app a process that is neither visible nor reachable once the window closes.
  if (windowReady && trayReady) {
    await desktopShellStep(
      'intercept window close to hide to tray',
      () => windowManager.setPreventClose(true),
    );
  }

  // Data-path watchdog recovery: a confirmed-dead tunnel is stopped and
  // reconnected through the same headless pipeline as the tray. This is the
  // automated version of the manual stop+connect that reliably un-wedges the
  // engine after physical-network churn (hotel Wi-Fi / hotspot flaps).
  VpnSessionSupervisor.instance.tunnelRestartHandler = () =>
      tray.restartTunnel();
  VpnSessionSupervisor.instance.cancelTunnelRestartHandler =
      tray.cancelRecovery;

  // Requirement: the app only runs when opened manually, and quitting closes everything; so no
  // autostart, and any leftover login item is actively unregistered at startup. No exception may block
  // app startup — main() awaits this before runApp, and an uncaught exception leaves the window black.
  try {
    await DesktopAutostart.ensureDisabled();
  } catch (e) {
    debugPrint('DesktopAutostart.ensureDisabled failed: $e');
  }

  // Opening the app manually = connect with the last-used mode. Skipped if already connected (the UI restarted and took over a live tunnel).
  unawaited(tray.autoConnectOnLaunch());
}

/// Tray/menu-bar icon + context menu. Reflects live status in the tooltip and
/// offers Connect/Disconnect, Show, and Quit.
class AuroraTray with TrayListener, WindowListener {
  AuroraTray(this._bridge, {bool? isLinux})
    : _isLinux = isLinux ?? Platform.isLinux;

  final AuroraBridge _bridge;
  late final TunnelRecovery _recovery = TunnelRecovery(bridge: _bridge);
  late final DesktopConnectionRecovery connections = DesktopConnectionRecovery(
    bridge: _bridge,
    recovery: _recovery,
  );

  void cancelRecovery() => connections.stopRequested();

  /// Platform differences are confined to one place: Linux's tray_manager implements only
  /// the four methods destroy/setIcon/setTitle/setContextMenu (see its
  /// `linux/tray_manager_plugin.cc`); `setToolTip` and `popUpContextMenu` do not exist
  /// there at all. It is injected rather than reading [Platform.isLinux] directly, so
  /// this difference can be pinned by tests on any dev machine.
  final bool _isLinux;
  AuroraStatus _status = AuroraStatus.disconnected;
  DataPlaneHealth _dataPlane = DataPlaneHealth.unknown;
  bool _connecting = false;

  /// Installs the tray icon and menu. Returns whether the icon was actually installed — it returns false
  /// when the desktop environment has no tray protocol (or the plugin does not implement it), and the
  /// caller uses that to decide whether to turn "close window" into "hide to tray".
  Future<bool> init() async {
    trayManager.addListener(this);
    windowManager.addListener(this);
    // macOS uses a monochrome template PNG in the menu bar; Windows uses an .ico.
    final iconReady = await desktopShellStep(
      'tray icon',
      () => trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray/aurora_tray.ico'
            : 'assets/tray/aurora_tray.png',
        isTemplate: Platform.isMacOS,
      ),
    );
    await _rebuildMenu();
    await _applyStatusText();
    _bridge.statusStream().listen(handleStatus, onError: (_) {});
    VpnSessionSupervisor.instance.dataPlaneStream.listen((health) {
      _dataPlane = health;
      unawaited(_applyStatusText());
    }, onError: (_) {});
    // Seed with the live status: if the tunnel is already up when the shell
    // starts (login autostart) the stream may deliver no initial event, and a
    // stale "disconnected" here makes the toggle mis-dispatch.
    unawaited(_bridge.status().then(handleStatus).catchError((_) {}));
    return iconReady;
  }

  @visibleForTesting
  void handleStatus(AuroraStatus s) {
    _status = s;
    // Fired without awaiting, but every branch carries its own fallback: a Future nobody awaits that
    // completes with an exception is an unhandled async error in Flutter.
    unawaited(_rebuildMenu());
    unawaited(_applyStatusText());
  }

  /// Writes the current status onto the tray.
  ///
  /// The two platform families use **different methods**: macOS/Windows use the hover tooltip `setToolTip`;
  /// Linux's tray_manager does not have it (its `linux/tray_manager_plugin.cc`
  /// only handles destroy/setIcon/setTitle/setContextMenu), and calling it always throws
  /// `MissingPluginException` — exactly the black-window incident. Linux uses
  /// `setTitle` instead, which lands in AppIndicator's `app_indicator_set_label`, shown as a line of
  /// text next to the icon.
  Future<void> _applyStatusText() => desktopShellStep(
    'tray status text',
    () => _isLinux
        ? trayManager.setTitle(_panelLabel())
        : trayManager.setToolTip('Aurora — ${_statusLabel()}'),
  );

  /// The permanent text on the Linux panel: the status word only. The full explanation (why it is unavailable,
  /// which route is locked) is left to the tray menu and main window — cramming a whole sentence into the top bar would push other icons out.
  String _panelLabel() {
    final label = _statusLabel();
    final detail = label.indexOf(' (');
    return 'Aurora · ${detail < 0 ? label : label.substring(0, detail)}';
  }

  /// The tray is often the only surface a user sees, so it must not claim a
  /// healthy connection while the watchdog is reporting a dead data path —
  /// and, symmetrically with the main window (`connect_page.dart`'s
  /// `_deadLabelSuffix`/`_lockedFamilyHint`), must not blame "the network" in
  /// general when the user has actually pinned a route family: it names that
  /// family and says self-heal will not cross to another one.
  String _statusLabel() {
    final routeFamily = VpnSessionSupervisor.instance.routeFamily;
    return switch (_status) {
      // A dead physical network is not a route's fault and triggers no route switch or restart; what the tray
      // should say is "waiting for the network", not name some route.
      AuroraStatus.connected when _dataPlane == DataPlaneHealth.offline =>
        'Connected, but local network is down (re-verifies automatically when it returns)',
      AuroraStatus.connected
          when _dataPlane == DataPlaneHealth.dead ||
              _dataPlane == DataPlaneHealth.deadUnrecoverable =>
        routeFamily == null
            ? 'Connected, but no internet'
            : 'Connected, but ${routeFamilyLabel(routeFamily)} is unavailable'
                  ' (route is locked and will not switch automatically; switch to Auto in the window)',
      AuroraStatus.connected => 'Connected',
      AuroraStatus.connecting => 'Connecting',
      AuroraStatus.disconnecting => 'Disconnecting',
      AuroraStatus.error => 'Error',
      AuroraStatus.disconnected => 'Disconnected',
    };
  }

  bool get _isOn =>
      _status == AuroraStatus.connected || _status == AuroraStatus.connecting;

  Future<void> _rebuildMenu() => desktopShellStep(
    'tray menu',
    () => trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'toggle',
            label: _status == AuroraStatus.disconnecting
                ? 'Stay disconnected'
                : _isOn
                ? 'Disconnect'
                : 'Connect',
          ),
          MenuItem.separator(),
          MenuItem(key: 'show', label: 'Show window'),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    ),
  );

  /// On Linux the AppIndicator pops up the menu itself and `popUpContextMenu` is not implemented;
  /// calling it the macOS way throws `MissingPluginException`.
  void _popUpMenu() {
    if (_isLinux) return;
    unawaited(desktopShellStep('pop up tray menu', trayManager.popUpContextMenu));
  }

  @override
  void onTrayIconMouseDown() => _popUpMenu();

  @override
  void onTrayIconRightMouseDown() => _popUpMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'toggle':
        if (_status == AuroraStatus.disconnecting) {
          cancelRecovery();
          return;
        }
        if (_isOn) {
          cancelRecovery();
          await _bridge.stop();
        } else {
          await _connect();
        }
      case 'show':
        await _showWindow();
      case 'quit':
        await _quit();
    }
  }

  Future<void> _showWindow() => desktopShellStep('show window', () async {
    await windowManager.show();
    await windowManager.focus();
  });

  /// Full teardown: hand off to the native terminate path, which stops the VPN
  /// tunnel before the process exits so quitting the app leaves nothing running
  /// to intercept other apps' traffic. Falls back to closing the window if the
  /// host channel is unavailable (older build without the native handler).
  Future<void> _quit() async {
    cancelRecovery();
    try {
      await _bridge.stop();
    } catch (_) {
      // Native terminate still tears the tunnel down; ignore a soft-stop error.
    }
    // Linux's runner has no such native channel (macOS/Windows do), so this always takes the
    // window-close branch below; if closing the window fails too, only a hard exit is left — the tunnel is already
    // stopped by now, and on Linux/Windows the tunnel belongs to the separate aurora-svc process anyway.
    final quitNatively = await desktopShellStep(
      'native quit',
      () => _desktopChannel.invokeMethod<void>('quit'),
    );
    if (quitNatively) return;
    final closed = await desktopShellStep('close window to quit', () async {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    });
    if (!closed) exit(0);
  }

  /// Opening the app connects automatically with the persisted mode — the same
  /// headless pipeline the tray "Connect" runs. No-op when a tunnel is already
  /// alive (e.g. a relaunch adopting the running session).
  Future<void> autoConnectOnLaunch() async =>
      _connect(surfaceFailure: false, adoptRunning: true);

  /// The same exclusive, cancellable stop/wait/start sequence as mobile.
  /// ConnectFlow owns the bounded retry; desktop additionally shows failures.
  Future<bool> restartTunnel() async {
    if (_connecting || ConnectFlow.isBusy) return false;
    final acted = await connections.restartForWatchdog();
    if (acted && ConnectFlow.lastBackgroundError.value != null) {
      await _showWindow();
    }
    return acted;
  }

  /// Headless connect with the persisted mode — the same pipeline the connect
  /// page runs. Only on failure do we surface the window, where the user can
  /// retry and read the error with full UI context.
  Future<bool> _connect({
    bool surfaceFailure = true,
    bool adoptRunning = false,
  }) async {
    if (_connecting || ConnectFlow.isBusy) return true;
    _connecting = true;
    final isCancelled = connections.beginConnection();
    AuroraStatus? adoptedStatus;
    try {
      if (adoptRunning) {
        try {
          final status = await _bridge.status();
          if (isCancelled()) return false;
          if (status == AuroraStatus.connected ||
              status == AuroraStatus.connecting ||
              status == AuroraStatus.disconnecting) {
            // Keep observing an outgoing native session. Its disconnected
            // event schedules recovery; never start over its pending stop.
            adoptedStatus = status;
            return true;
          }
        } catch (_) {
          adoptedStatus = AuroraStatus.error;
          // A temporarily unavailable helper is handled by the same bounded
          // recovery budget as a helper that disappears during a session.
        }
      }
      if (isCancelled()) return false;
      final granted = await _bridge.prepare();
      if (!granted) {
        throw StateError('VPN permission denied');
      }
      await ConnectFlow.compileAndStart(_bridge, isCancelled: isCancelled);
      return true;
    } catch (e) {
      if (isCancelled()) return false;
      debugPrint('tray connect failed: $e');
      // Surface the reason inside the window we are about to show; a bare
      // debugPrint leaves the user staring at "Disconnected" with no explanation.
      ConnectFlow.lastBackgroundError.value = ConnectFlow.describeError(e);
      // Note this line is inside a catch: if it throws itself, the exception replaces the real failure
      // above and bubbles up as an unhandled async error.
      if (surfaceFailure) await _showWindow();
      return false;
    } finally {
      _connecting = false;
      if (!isCancelled()) connections.endConnection(status: adoptedStatus);
    }
  }

  @override
  void onWindowClose() async {
    // Close was prevented => hide to tray instead of terminating.
    if (await windowManager.isPreventClose()) {
      await desktopShellStep('hide to tray', windowManager.hide);
      return;
    }
    cancelRecovery();
    // No interception = this close is a quit (this is the path when the tray icon was not installed, see the
    // `windowReady && trayReady` condition in `initDesktopShell`).
    //
    // Only stop the tunnel, do not call [_quit]: the window is already on its way closed (window_manager lets WM_CLOSE
    // continue after sending this event), so closing again is pointless. This stop is **best effort**:
    // the process may be gone before this await completes. The real guarantee is on the other side: aurora-svc
    // treats this process as the tunnel's owner and tears it down itself once the process disappears (see ownerPid in main.dart).
    // All this does is save the second between "the window closes" and "the network is cleanly restored".
    try {
      await _bridge.stop();
    } catch (_) {
      // It was never connected, or the service already tore it down first.
    }
  }
}

/// Login-item autostart. macOS registers a LaunchAgent; Windows writes the HKCU
/// Run key. Disabled by default: the app runs only when the user opens it, and
/// [ensureDisabled] removes any previously-registered login item on launch.
/// The [enable]/[disable] controls remain for an explicit user opt-in.
class DesktopAutostart {
  static bool _wired = false;

  static Future<void> _setup() async {
    if (_wired) return;
    final info = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: info.appName,
      appPath: Platform.resolvedExecutable,
    );
    _wired = true;
  }

  static Future<void> ensureDisabled() async {
    await _setup();
    if (await launchAtStartup.isEnabled()) {
      await launchAtStartup.disable();
    }
  }

  static Future<void> ensureRegistered() async {
    await _setup();
    if (!await launchAtStartup.isEnabled()) {
      await launchAtStartup.enable();
    }
  }

  static Future<bool> isEnabled() async {
    await _setup();
    return launchAtStartup.isEnabled();
  }

  static Future<void> enable() async {
    await _setup();
    await launchAtStartup.enable();
  }

  static Future<void> disable() async {
    await _setup();
    await launchAtStartup.disable();
  }
}
