import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let delegate = ProbeAppDelegate()
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(delegate) { app.run() }
            }
        } else {
            SoundConnectApp.main()
        }
    }
}
