// Compile boundary only: the real AppDelegate/MainFlutterWindow are linked
// against this module. Any attempt to create Flutter during CLI tests traps.
import Cocoa
public typealias FlutterResult = (Any?) -> Void
public let FlutterMethodNotImplemented = NSObject()
public struct FlutterError {
    public init(code: String, message: String?, details: Any?) {}
}
public struct FlutterMethodCall {
    public let method: String
    public let arguments: Any?
}
public final class FlutterMethodChannel {
    public init(name: String, binaryMessenger: Any) { fatalError("Flutter must not start in maintenance") }
    public func setMethodCallHandler(_ handler: @escaping (FlutterMethodCall, @escaping FlutterResult) -> Void) {}
}
public final class FlutterEngine {
    public let binaryMessenger: Any = NSObject()
}
open class FlutterViewController: NSViewController {
    public let engine = FlutterEngine()
    public convenience init() { self.init(nibName: nil, bundle: nil); fatalError("Flutter must not start in maintenance") }
}
open class FlutterAppDelegate: NSObject, NSApplicationDelegate {
    public var mainFlutterWindow: NSWindow?
    open func applicationDidFinishLaunching(_ notification: Notification) {}
    open func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    open func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    open func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    open func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
}
