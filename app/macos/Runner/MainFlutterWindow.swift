import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  private let secureStoreQueue = DispatchQueue(label: "aurora.secure-store-migration")
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // launch_at_startup is a pure-Dart package; on macOS the host implements the
    // native side (see the package README). Register the login item with the
    // system SMAppService (macOS 13+) rather than pulling in a third-party SPM
    // dependency; on macOS 12 this degrades to a no-op (tunnel autostart is
    // handled by the CLI LaunchAgent).
    FlutterMethodChannel(
      name: "launch_at_startup",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    .setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if #available(macOS 13.0, *) {
        switch call.method {
        case "launchAtStartupIsEnabled":
          result(SMAppService.mainApp.status == .enabled)
        case "launchAtStartupSetEnabled":
          do {
            if let args = call.arguments as? [String: Any],
               args["setEnabledValue"] as? Bool == true {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            result(nil)
          } catch {
            result(FlutterError(code: "launch_at_startup",
                                message: error.localizedDescription, details: nil))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      } else {
        switch call.method {
        case "launchAtStartupIsEnabled": result(false)
        case "launchAtStartupSetEnabled": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }

    // App-lifecycle actions from the Dart tray. "quit" routes through the
    // native terminate path (AppDelegate.applicationShouldTerminate), which
    // stops the VPN tunnel before the process exits — so the tray "Quit" fully
    // tears down instead of just closing the Flutter window.
    FlutterMethodChannel(
      name: "aurora/desktop",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    .setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "quit":
        result(nil)
        NSApplication.shared.terminate(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterMethodChannel(
      name: "aurora/secure-store",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    .setMethodCallHandler { [secureStoreQueue] call, result in
      guard call.method == "prepareBackgroundAccess" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard call.arguments == nil else {
        result(FlutterError(code: "keychain_migration_arguments", message: nil, details: nil))
        return
      }
      secureStoreQueue.async {
        do {
          let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
          let receipts = AuroraKeychainFileReceiptStore(
            directory: support.appendingPathComponent("Aurora-KeychainMigration", isDirectory: true))
          try AuroraKeychainMigration(api: AuroraSystemKeychainAPI(), receipts: receipts,
            defaults: AuroraSystemDefaultACLFactory.provider).prepare()
          DispatchQueue.main.async { result(true) }
        } catch {
          // No key names, paths, attributes, or secret values enter Flutter errors.
          let status: Int32?
          if case AuroraKeychainMigrationError.security(let value) = error { status = value }
          else { status = nil }
          DispatchQueue.main.async {
            result(FlutterError(code: "keychain_migration", message: nil, details: status))
          }
        }
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
