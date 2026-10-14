import AppKit
import SwiftUI

/// Interactive product model or illustration, with device name, battery and audio badges.
struct HeroView: View {
    @Environment(HeadphoneController.self) private var controller
    var compact = false

    var body: some View {
        let state = controller.state
        VStack(spacing: compact ? 10 : 18) {
            if !compact, (state.modelName ?? controller.selectedName).uppercased().contains("WH-1000XM4") {
                HeadphoneModelView()
                    .frame(width: 400)
            } else {
                ProductImage(modelName: state.modelName ?? controller.selectedName, colorCode: state.colorCode)
                    .frame(width: compact ? 150 : 260, height: compact ? 120 : 212)
                    .padding(.top, compact ? 0 : 8)
            }

            VStack(spacing: 10) {
                Text(state.modelName ?? controller.selectedName)
                    .font(compact ? .system(size: 22, weight: .bold) : .heroTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)

                BatteryLabel(battery: state.battery)

                HStack(spacing: 8) {
                    if let codec = state.codec, codec != .unsettled {
                        Badge(text: codec.title, tint: Theme.text.opacity(0.9))
                            .accessibilityLabel("Codec \(codec.title)")
                    }
                    if let name = state.capabilities.upscalingName, state.upscaling?.enabled == true {
                        Badge(text: name.uppercased(), symbol: state.upscaling?.active == true ? "waveform" : nil,
                              tint: state.upscaling?.active == true ? Theme.accent : Theme.text.opacity(0.9),
                              filled: state.upscaling?.active == true)
                            .help(state.upscaling?.active == true ? "Upscaling now" : "On")
                            .accessibilityLabel("\(name) \(state.upscaling?.active == true ? "active" : "on")")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct BatteryLabel: View {
    let battery: BatteryState

    var body: some View {
        if let level = battery.headlineLevel {
            HStack(spacing: 6) {
                Image(systemName: symbol(level))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(level <= 15 ? Theme.danger : Theme.text.opacity(0.92))
                    .symbolRenderingMode(.hierarchical)
                Text("\(level)%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                if let l = battery.left, let r = battery.right {
                    Text("L \(l.level)%  R \(r.level)%").font(.caption11).foregroundStyle(Theme.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery \(level) percent\(battery.isCharging ? ", charging" : "")")
        }
    }

    private func symbol(_ level: Int) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// Rendered XM4 thumbnail, with a generic illustration for other models.
struct ProductImage: View {
    let modelName: String
    let colorCode: UInt8?
    var glow = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            productArt(size: size)
                .frame(width: size.width, height: size.height)
                // Decorations live in a background so they can extend past the frame without affecting layout
                // (as ZStack siblings they would enlarge the stack and the render would be fitted to that).
                .background {
                    if glow { decorations(size: size) }
                }
        }
        .accessibilityElement()
        .accessibilityLabel("\(modelName) product image")
    }


    private static let renderedXM4: NSImage? = {
        guard let url = Bundle.main.url(forResource: "WH-1000XM4", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    @ViewBuilder
    private func productArt(size: CGSize) -> some View {
        if modelName.uppercased().contains("WH-1000XM4"), let image = Self.renderedXM4 {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            DrawnHeadphones(tint: Self.tint(for: colorCode))
                .padding(size.width * 0.1)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
        }
    }

    private func decorations(size: CGSize) -> some View {
        // A cool halo lifts the black product off the charcoal canvas (Sony uses a lit backdrop). The square
        // frame is 2 × endRadius so the gradient fades out completely before any edge.
        let radius = max(size.width, size.height) * 0.58
        return ZStack {
            RadialGradient(colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.07), Theme.accent.opacity(0)],
                           center: .center, startRadius: 0, endRadius: radius)
                .frame(width: radius * 2, height: radius * 2)
            Ellipse()
                .fill(Color.black.opacity(0.6))
                .frame(width: size.width * 0.55, height: max(8, size.height * 0.07))
                .blur(radius: max(4, size.height * 0.05))
                .offset(y: size.height * 0.47)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func tint(for code: UInt8?) -> Color {
        switch (code ?? 0x01) & 0x0F {
        case 0x02, 0x0B: Color(red: 0.86, green: 0.85, blue: 0.82)  // white / cream
        case 0x03: Color(red: 0.74, green: 0.74, blue: 0.76)        // silver / platinum
        case 0x05: Color(red: 0.24, green: 0.30, blue: 0.42)        // midnight blue
        case 0x06: Color(red: 0.86, green: 0.72, blue: 0.72)
        default: Color(red: 0.17, green: 0.17, blue: 0.19)          // black
        }
    }
}

/// Vector over-ear headphones.
struct DrawnHeadphones: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Path { path in
                    path.addArc(center: CGPoint(x: w / 2, y: h * 0.52), radius: w * 0.38,
                                startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
                }
                .stroke(LinearGradient(colors: [tint.opacity(1.0), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: w * 0.075, lineCap: .round))
                Path { path in
                    path.addArc(center: CGPoint(x: w / 2, y: h * 0.52), radius: w * 0.34,
                                startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
                }
                .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: w * 0.03, lineCap: .round))
                ForEach([-1.0, 1.0], id: \.self) { side in
                    RoundedRectangle(cornerRadius: w * 0.11, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: w * 0.11, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .frame(width: w * 0.24, height: h * 0.36)
                        .position(x: w / 2 + side * w * 0.36, y: h * 0.66)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
