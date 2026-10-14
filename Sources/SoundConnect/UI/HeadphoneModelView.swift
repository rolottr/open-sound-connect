import AppKit
import SceneKit
import SwiftUI

/// A local, interactive product model. Dragging changes only its presentation, never headset settings.
struct HeadphoneModelView: View {
    @State private var resetID = 0

    var body: some View {
        HeadphoneModelCanvas(resetID: resetID)
            .frame(height: 268)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    resetID += 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .padding(8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("Reset headphone model view")
                .help("Reset view")
            }
    }
}

private struct HeadphoneModelCanvas: NSViewRepresentable {
    let resetID: Int

    func makeNSView(context: Context) -> HeadphoneSceneView {
        HeadphoneSceneView(frame: .zero)
    }

    func updateNSView(_ view: HeadphoneSceneView, context: Context) {
        if view.resetID != resetID {
            view.resetID = resetID
            view.resetOrientation()
        }
    }
}

final class HeadphoneSceneView: SCNView {
    var resetID = 0
    private let pivot = SCNNode()
    private var yaw: CGFloat = -0.58
    private var pitch: CGFloat = -0.13
    private var lastDragPoint: NSPoint?

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        rendersContinuously = false
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        setupScene()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Interactive WH-1000XM4 model")
        setAccessibilityHelp("Hold the left mouse button and drag to rotate. Arrow keys rotate; Space resets the view.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Rotate left") { [weak self] in self?.rotate(horizontal: -0.2, vertical: 0); return true },
            NSAccessibilityCustomAction(name: "Rotate right") { [weak self] in self?.rotate(horizontal: 0.2, vertical: 0); return true },
            NSAccessibilityCustomAction(name: "Reset view") { [weak self] in self?.resetOrientation(); return true }
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupScene() {
        let scene = SCNScene()
        self.scene = scene
        scene.rootNode.addChildNode(pivot)
        if let url = Bundle.main.url(forResource: "WH-1000XM4", withExtension: "usdz"),
           let product = try? SCNScene(url: url) {
            let content = product.rootNode.clone()
            let bounds = content.boundingBox
            content.position = SCNVector3(-(bounds.min.x + bounds.max.x) / 2,
                                          -(bounds.min.y + bounds.max.y) / 2,
                                          -(bounds.min.z + bounds.max.z) / 2)
            pivot.addChildNode(content)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 0.135
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 10
        camera.camera?.wantsHDR = true
        // Automatic exposure brightens a small dark product against transparency to white.
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = 0
        camera.position = SCNVector3(0, 0, 0.7)
        scene.rootNode.addChildNode(camera)
        pointOfView = camera
        addLight(to: scene, type: .ambient, position: SCNVector3Zero, color: NSColor(white: 0.9, alpha: 1), intensity: 100)
        addLight(to: scene, type: .directional, position: SCNVector3(-0.3, 0.4, 0.5), color: NSColor(red: 0.91, green: 0.95, blue: 1, alpha: 1), intensity: 600)
        addLight(to: scene, type: .directional, position: SCNVector3(0.3, 0.1, 0.25), color: NSColor(red: 1, green: 0.91, blue: 0.82, alpha: 1), intensity: 280)
        addLight(to: scene, type: .directional, position: SCNVector3(0.1, 0.3, -0.3), color: NSColor(red: 0.79, green: 0.86, blue: 1, alpha: 1), intensity: 650)
        resetOrientation()
    }

    private func addLight(to scene: SCNScene, type: SCNLight.LightType, position: SCNVector3, color: NSColor, intensity: CGFloat) {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = type
        node.light?.color = color
        node.light?.intensity = intensity
        node.position = position
        if type == .directional { node.look(at: SCNVector3Zero) }
        scene.rootNode.addChildNode(node)
    }

    func resetOrientation() {
        yaw = -0.58
        pitch = -0.13
        applyOrientation()
    }

    private func rotate(horizontal: CGFloat, vertical: CGFloat) {
        yaw = (yaw + horizontal).truncatingRemainder(dividingBy: .pi * 2)
        pitch = min(.pi / 2.2, max(-.pi / 2.2, pitch + vertical))
        applyOrientation()
    }

    private func applyOrientation() {
        pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
        setAccessibilityValue("Horizontal rotation \(Int(yaw * 180 / .pi)) degrees, vertical rotation \(Int(pitch * 180 / .pi)) degrees")
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let last = lastDragPoint else { return }
        rotate(horizontal: (point.x - last.x) * 0.012, vertical: -(point.y - last.y) * 0.012)
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        if lastDragPoint != nil { NSCursor.pop() }
        lastDragPoint = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: rotate(horizontal: -0.15, vertical: 0)
        case 124: rotate(horizontal: 0.15, vertical: 0)
        case 125: rotate(horizontal: 0, vertical: 0.15)
        case 126: rotate(horizontal: 0, vertical: -0.15)
        case 49: resetOrientation()
        default: super.keyDown(with: event)
        }
    }
}
