import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var auroraVPN: AuroraVPN?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register the app-level VPN channel on the implicit engine's own messenger.
    // (Wiring this via window.rootViewController in didFinishLaunching is unreliable
    // under the implicit-engine architecture — the engine/messenger isn't ready there,
    // so the channel handler never attaches and invokeMethod('start') silently no-ops.)
    auroraVPN = AuroraVPN(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
