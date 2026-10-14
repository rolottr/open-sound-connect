import SwiftUI

/// Sound Connect's visual language, after Sony's own app in dark mode: deep neutral charcoal, off-white type,
/// soft lavender for whatever is active.
enum Theme {
    // Surfaces (neutral charcoal, a hair of blue so lavender sits naturally on it)
    static let canvasTop = Color(red: 0.090, green: 0.090, blue: 0.106)
    static let canvasBottom = Color(red: 0.055, green: 0.055, blue: 0.067)
    static let sidebar = Color(red: 0.067, green: 0.067, blue: 0.078)
    static let card = Color(red: 0.133, green: 0.133, blue: 0.153)
    static let cardRaised = Color(red: 0.165, green: 0.165, blue: 0.188)
    static let control = Color(red: 0.200, green: 0.200, blue: 0.227)
    static let hairline = Color.white.opacity(0.07)

    // Type
    static let text = Color(red: 0.957, green: 0.957, blue: 0.969)
    static let secondary = Color(red: 0.635, green: 0.635, blue: 0.675)
    static let tertiary = Color(red: 0.420, green: 0.420, blue: 0.455)

    // Accent: Sony's soft lavender
    static let accent = Color(red: 0.655, green: 0.655, blue: 0.965)
    static let accentSoft = Color(red: 0.776, green: 0.776, blue: 0.988)
    static let onAccent = Color(red: 0.078, green: 0.078, blue: 0.180)

    // Status
    static let good = Color(red: 0.545, green: 0.796, blue: 0.608)
    static let warning = Color(red: 0.906, green: 0.769, blue: 0.416)
    static let danger = Color(red: 0.925, green: 0.541, blue: 0.502)

    static let cardRadius: CGFloat = 20
    static let pagePadding: CGFloat = 28
    static let cardSpacing: CGFloat = 16

    static var canvas: LinearGradient {
        LinearGradient(colors: [canvasTop, canvasBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension Font {
    static let heroTitle = Font.system(size: 30, weight: .semibold, design: .default)
    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body15 = Font.system(size: 13.5, weight: .regular)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption11 = Font.system(size: 11, weight: .regular)
    static let mono11 = Font.system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, symbol: String? = nil, trailing: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title).font(.cardTitle).foregroundStyle(Theme.text)
                        }
                        if let subtitle {
                            Text(subtitle).font(.caption11).foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.025)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

/// A row inside a card: icon, title/detail, trailing control.
struct SettingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption11).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
                // Toggles/pickers here are drawn without visible labels; give VoiceOver the row's title.
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(detail ?? ""))
        }
        .padding(.vertical, 2)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 44)
    }
}

// MARK: - Badges & chips

struct Badge: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.secondary
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .bold)).tracking(0.4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(filled ? Theme.onAccent : tint)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(filled ? tint : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(filled ? Color.clear : tint.opacity(0.7), lineWidth: 1)
        )
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var pending = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if pending {
                    ProgressView().controlSize(.mini).tint(selected ? Theme.onAccent : Theme.accent)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .foregroundStyle(selected ? Theme.onAccent : Theme.text)
            .background(Capsule().fill(selected ? Theme.accent : Theme.control))
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Large circular mode button, after Sound Connect's noise-control and listening-mode rows.
struct ModeButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    var pending = false
    var enabled = true
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Theme.accentSoft, Theme.accent],
                                                                        startPoint: .top, endPoint: .bottom))
                                       : AnyShapeStyle(Theme.control))
                        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.25 : (hovering ? 0.14 : 0.06)), lineWidth: 1))
                        .shadow(color: selected ? Theme.accent.opacity(0.35) : .clear, radius: 12, y: 3)
                    if pending {
                        ProgressView().controlSize(.small).tint(selected ? Theme.onAccent : Theme.accent)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(selected ? Theme.onAccent : Theme.text.opacity(enabled ? 0.92 : 0.4))
                    }
                }
                .frame(width: 58, height: 58)
                .scaleEffect(hovering && !reduceMotion && enabled ? 1.04 : 1)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(pending ? "Applying" : "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The connector line behind a row of ModeButtons (Sony draws the modes as stations on a rail).
struct ModeRail: View {
    let count: Int
    var body: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(max(count, 1))
            Path { path in
                path.move(to: CGPoint(x: step / 2, y: 29))
                path.addLine(to: CGPoint(x: proxy.size.width - step / 2, y: 29))
            }
            .stroke(Theme.control, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

struct AccentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Theme.accent)
    }
}

extension View {
    func pageBackground() -> some View {
        background(Theme.canvas.ignoresSafeArea())
    }
}

/// Small status dot used for connection and "processing" indicators.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(pulsing && phase && !reduceMotion ? 2.2 : 1)
                    .opacity(pulsing && !reduceMotion ? (phase ? 0 : 0.8) : 0)
            )
            .onAppear {
                guard pulsing, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = true }
            }
            .accessibilityHidden(true)
    }
}
