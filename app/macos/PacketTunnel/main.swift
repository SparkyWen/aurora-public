import Foundation
import NetworkExtension

// System extension entry point: hand the process to NetworkExtension, which
// instantiates PacketTunnelProvider from the Info.plist NEProviderClasses entry.
// (On iOS the system injects the entry point of an appex; a macOS system
// extension is a standalone executable and must provide its own main.)
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
