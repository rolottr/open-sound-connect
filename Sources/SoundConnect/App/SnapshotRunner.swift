import AppKit
import SceneKit
import SwiftUI

/// Developer aid: `open "Sound Connect.app" --args --snapshot-dir /tmp/shots [--snapshot-quit]`.
/// Waits for the headphones (up to 30 s), then renders the app's *own* main window for every page into PNGs via
/// `cacheDisplay` (no screen-recording permission, no input injection). Read-only: it never changes settings.
@MainActor
enum SnapshotRunner {
    static func runIfRequested(navigation: Navigation, controller: HeadphoneController,
                               scenes: SceneStore? = nil, curves: CurveLibrary? = nil) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let quit = arguments.contains("--snapshot-quit")
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let deadline = Date().addingTimeInterval(30)
            while !controller.isConnected && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? await Task.sleep(for: .seconds(1.5))
            if let sizeIndex = arguments.firstIndex(of: "--snapshot-size"), sizeIndex + 1 < arguments.count {
                let parts = arguments[sizeIndex + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, let window = NSApp.windows.first(where: { $0.title == "Sound Connect" && $0.isVisible }) {
                    var frame = window.frame
                    frame.size = NSSize(width: parts[0], height: parts[1])
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            for page in AppPage.allCases {
                navigation.page = page
                try? await Task.sleep(for: .seconds(1.2))
                capture(to: directory.appendingPathComponent("page-\(page.rawValue).png"))
            }
            navigation.page = .myDevice
            if let scenes, let curves {
                renderOffscreen(MenuBarView()
                    .environment(controller).environment(scenes).environment(navigation).environment(UpdateChecker()),
                    width: 320, to: directory.appendingPathComponent("menubar.png"))
                if let scene = scenes.scenes.first {
                    renderOffscreen(SceneEditor(scene: scene, isNew: false) { _ in }
                        .environment(controller).environment(curves),
                        width: 560, to: directory.appendingPathComponent("scene-editor.png"))
                }
            }
            if quit {
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            }
        }
    }

    /// Renders a view in a borderless window parked off-screen (never shown), then captures it.
    static func renderOffscreen<V: View>(_ view: V, width: CGFloat, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: width))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: max(size.height, 100)),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: max(size.height, 100)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        window.contentView = nil
    }

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Sound Connect" && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        captureMetalViews(in: view, into: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    /// AppKit's bitmap cache omits Metal layers. Ask SceneKit for the actual current frame
    /// and composite it at the view's location, preserving the model's camera and rotation.
    private static func captureMetalViews(in root: NSView, into bitmap: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return }
        context.scaleBy(x: CGFloat(bitmap.pixelsWide) / root.bounds.width,
                        y: CGFloat(bitmap.pixelsHigh) / root.bounds.height)
        func bitmapRect(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX - root.bounds.minX,
                   y: root.isFlipped ? root.bounds.maxY - rect.maxY : rect.minY - root.bounds.minY,
                   width: rect.width, height: rect.height)
        }
        func capture(_ view: NSView) {
            guard !view.isHidden else { return }
            if let model = view as? SCNView, !model.visibleRect.isEmpty,
               let image = model.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.saveGState()
                context.clip(to: bitmapRect(root.convert(model.visibleRect, from: model)))
                context.draw(image, in: bitmapRect(root.convert(model.bounds, from: model)))
                context.restoreGState()
            }
            for child in view.subviews { capture(child) }
        }
        capture(root)
    }

}
