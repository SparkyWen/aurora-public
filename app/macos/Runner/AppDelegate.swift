import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var auroraVPN: AuroraVPN?

  static func main() {
    let arguments = CommandLine.arguments
    if AuroraKeychainDefaultACLCheck.requested(arguments) {
      // Explicit qualification permits only temporary public dummy writes;
      // production items remain attribute-only. Never initialize GUI or VPN.
      let result = AuroraKeychainDefaultACLCheck(api: AuroraSystemKeychainAPI(),
        qualify: AuroraSystemDefaultACLFactory.qualify).run(arguments)
      let output = result.exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError
      output.write(Data(result.message.utf8))
      exit(result.exitCode)
    }
    if AuroraKeychainReadOnlyCheck.requested(arguments) {
      // Synchronous, attribute-only diagnostics. This path never constructs
      // AppKit/Flutter, a VPN manager or a migration receipt store.
      let result = AuroraKeychainReadOnlyCheck(api: AuroraSystemKeychainAPI()).run(arguments)
      let output = result.exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError
      output.write(Data(result.message.utf8))
      exit(result.exitCode)
    }
    if AuroraKeychainMaintenance.requested(arguments) {
      // This branch runs before AppKit loads the main nib or a Flutter engine.
      // It cannot activate the extension, connect, stop, or launch the GUI.
      Task {
        do {
          try await AuroraKeychainMaintenance(environment: AuroraSystemKeychainMaintenance()).run(arguments)
          FileHandle.standardOutput.write(Data("KEYCHAIN_ROLLBACK_COMPLETE\n".utf8))
          exit(EXIT_SUCCESS)
        } catch {
          FileHandle.standardError.write(Data("KEYCHAIN_ROLLBACK_REFUSED\n".utf8))
          exit(EXIT_FAILURE)
        }
      }
      RunLoop.main.run()
      return
    }
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = CommandLine.arguments
    if let optionIndex = arguments.firstIndex(of: "--install-runtime-config"),
       arguments.indices.contains(optionIndex + 1) {
      let configPath = arguments[optionIndex + 1]
      let shouldStart = arguments.contains("--start-vpn")
      Task {
        do {
          let config = try String(contentsOfFile: configPath, encoding: .utf8)
          try await AuroraVPN.installRuntimeConfig(config, shouldStart: shouldStart)
          FileHandle.standardOutput.write(
            Data("Aurora runtime config installed\n".utf8)
          )
          exit(EXIT_SUCCESS)
        } catch {
          FileHandle.standardError.write(
            Data("Aurora runtime config install failed: \(error.localizedDescription)\n".utf8)
          )
          exit(EXIT_FAILURE)
        }
      }
      super.applicationDidFinishLaunching(notification)
      return
    }

    // Register the app-level VPN channel on the Flutter engine's messenger,
    // mirroring iOS's AppDelegate wiring (architecture §4.3). The window's
    // FlutterViewController is created in MainFlutterWindow.awakeFromNib.
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      auroraVPN = AuroraVPN(messenger: controller.engine.binaryMessenger)
    }
    // Submit the system-extension activation on every launch so the newer
    // extension in /Applications replaces the running older one (an upgrade
    // within the same team needs no new user approval). Otherwise the code
    // changes but the system keeps running the old extension. The System
    // Settings approval prompt only appears on first install.
    SystemExtensionInstaller.shared.activate { ok in
      SystemExtensionInstaller.diag("auto-activate on launch → \(ok)")
    }
    super.applicationDidFinishLaunching(notification)
  }

  // Keep the app alive in the menu bar when the window closes; the tray (Dart
  // desktop_shell) owns the lifecycle and hides-to-tray on close.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon click / Finder reopen. After hide-to-tray the window is ordered
  // out, and AppKit's default reopen only restores miniaturized windows — so
  // without this the app activates but no window ever appears. Mirrors
  // window_manager's show() (the tray "Show window" path) so the Dart-side
  // WindowListener state stays in sync.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag, let window = mainFlutterWindow {
      if window.isMiniaturized {
        window.deminiaturize(self)
      } else {
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  // Quitting the app (Cmd-Q, app menu, or the tray "Quit") stops the VPN tunnel
  // first, so no full-tunnel session outlives the GUI and keeps capturing other
  // apps' traffic. terminateLater defers the exit until the bounded stop
  // finishes, then replies to let the app quit.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
      await AuroraVPN.stopForTermination()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
