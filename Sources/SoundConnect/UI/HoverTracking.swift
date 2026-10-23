import AppKit
import SwiftUI

extension View {
    /// Like `onHover`, from an AppKit tracking area. With any `onHover` in it, SwiftUI hit-tests the whole window on
    /// every mouse move (about 9% CPU while the pointer crosses My Device, 4% without); a tracking area only reports
    /// entering and leaving.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(HoverTracker(onChange: action))
    }
}

private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // AppKit keeps an `inVisibleRect` area in step with the view, also while it scrolls.
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }

        // Only watches; clicks belong to the view it decorates.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
