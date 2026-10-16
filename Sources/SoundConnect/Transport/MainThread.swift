import Foundation

/// Runs `body` on the main actor: inline when already on the main thread, otherwise queued on the main queue.
/// On macOS 26 IOBluetooth runs on top of CoreBluetooth and can deliver Objective-C callbacks on its own
/// coordinator queue, where `MainActor.assumeIsolated` traps.
nonisolated func onMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
