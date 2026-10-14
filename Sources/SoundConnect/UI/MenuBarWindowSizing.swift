import AppKit
import SwiftUI

/// Keep the native menu panel in step with its content, including when controls disappear.
/// This belongs only in MenuBarExtra, so it never resizes the main window or snapshot hosts.
struct MenuBarWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ nsView: SizingView, context: Context) { nsView.scheduleResize() }

    final class SizingView: NSView {
        private var resizeScheduled = false
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            if let window {
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleResize() }
                }
            }
            scheduleResize()
        }

        override func layout() {
            super.layout()
            scheduleResize()
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            // Wait until SwiftUI has laid out the fixed-size menu content.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                self.resizeToContent()
            }
        }

        private func resizeToContent() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let contentSize = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            let previous = window.frame
            guard abs(previous.width - size.width) > 0.5 || abs(previous.height - size.height) > 0.5 else { return }
            // Anchor the top edge beneath the status item while the panel grows or shrinks.
            window.setFrame(NSRect(x: previous.minX, y: previous.maxY - size.height,
                                   width: size.width, height: size.height), display: true)
        }
    }
}
