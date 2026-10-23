import SwiftUI

/// SwiftUI keeps the main window and the menu bar panel alive after they close, and goes on laying out their views
/// with every change the headphones report. Closed, they hold an empty frame of the same size instead, and the
/// content is built again when they open.
struct ReleasedWhenClosed<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isOpen = true
    @State private var size: CGSize?

    var body: some View {
        ZStack {
            if isOpen {
                content
                    .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            } else {
                Color.clear.frame(width: size?.width, height: size?.height)
            }
        }
        .onAppear { isOpen = true }
        .onDisappear { isOpen = false }
    }
}
