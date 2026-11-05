import 'dart:async' show unawaited;
import 'dart:io' show Directory, Platform, pid;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getLibraryDirectory;

import 'app/desktop_shell.dart';
import 'app/path_event_log.dart';
import 'app/tunnel_recovery.dart';
import 'app/vpn_session_supervisor.dart';
import 'core/aurora_bridge_factory.dart';
import 'core/aurora_bridge_svc.dart';
import 'features/connect/connect_page.dart';
import 'features/servers/add_server_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!isDesktop) {
    final recovery = TunnelRecovery(
      bridge: createAuroraBridge(),
      canRecover: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    VpnSessionSupervisor.instance.tunnelRestartHandler = recovery.restart;
    VpnSessionSupervisor.instance.cancelTunnelRestartHandler = recovery.cancel;
  }
  if (isDesktop || Platform.isIOS) {
    // Desktop and iPhone opt into the local path-event timeline (unit tests
    // keep the shared instance disabled so they never touch the disk). iPhone
    // had none at first, and a report of "speed is often bad" left nothing to read;
    // there it lives under the app container's Library, pullable via devicectl.
    PathEventLog.instance.enabled = true;
    if (Platform.isIOS) {
      // iOS cannot read HOME (Dart's Platform.environment is always empty there), so the container
      // path has to be asked of the system. Without it there is no timeline — diagnostics must never block startup.
      try {
        final library = await getLibraryDirectory();
        PathEventLog.instance.directory = Directory(
          PathEventLog.iosDirectoryPath(library.path),
        );
      } catch (error) {
        debugPrint('path-event log unavailable on iOS: $error');
      }
    }
    unawaited(PathEventLog.instance.record('app_launch'));
  }
  if (isDesktop) {
    // Bind the tunnel's lifetime to this process. Only the GUI sets it; the command line deliberately does not (it exits once connected).
    //
    // This is the proper fix for "Aurora still affects normal networking after quitting the app": previously only choosing Quit
    // in the tray menu called stop(); Task Manager ending the task, a crash, logging off, the installer's taskkill during an upgrade,
    // and closing the window directly when the tray icon was not installed each left behind a sing-box
    // running as SYSTEM with all the routes taken over, while the UI was gone. Now however the process
    // disappears, aurora-svc tears the tunnel down with it.
    if (Platform.isWindows || Platform.isLinux) {
      AuroraBridgeSvc.forPlatform().ownerPid = pid;
    }
    // Fallback of fallbacks: every step inside `initDesktopShell` already has its own fallback, and this layer guarantees
    // that even if someone later adds an unguarded call inside it, `runApp` still gets executed.
    // Losing tray/window/autostart is at worst inconvenient; `runApp` not running leaves a completely black window.
    try {
      await initDesktopShell(createAuroraBridge());
    } catch (error, stack) {
      debugPrint(
        'desktop shell init failed, starting UI anyway: $error\n$stack',
      );
    }
  }
  runApp(const AuroraApp());
}

class AuroraApp extends StatelessWidget {
  const AuroraApp({super.key});

  static Route<void> _homeRoute() => MaterialPageRoute<void>(
    settings: const RouteSettings(name: Navigator.defaultRouteName),
    builder: (_) => const ConnectPage(),
  );

  static Route<bool> _linkRoute(String name) => MaterialPageRoute<bool>(
    settings: RouteSettings(name: name),
    builder: (_) => AddServerPage(deepLinkRoute: name),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aurora',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      // At a cold start the link is the initial route, and with no home underneath it the
      // page's pop after adding the server would leave nothing on screen.
      onGenerateInitialRoutes: (initialRoute) => [
        _homeRoute(),
        if (initialRoute != Navigator.defaultRouteName) _linkRoute(initialRoute),
      ],
      // To a running app, the Flutter engine delivers `aurora://v1/<data>#<name>` (a scanned
      // QR code) as a pushed route named `/<data>#<name>`, so deep links need no native code.
      // `/` is the home page; anything else can only be such a link, and a malformed one
      // lands on a page that says so rather than crashing the app.
      onGenerateRoute: (settings) {
        final name = settings.name;
        if (name == null) return null;
        return name == Navigator.defaultRouteName ? _homeRoute() : _linkRoute(name);
      },
    );
  }
}
