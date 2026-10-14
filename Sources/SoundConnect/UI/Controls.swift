import SwiftUI

/// Horizontal level slider with an amber fill, step ticks, live dragging and full keyboard/VoiceOver support.
struct LevelSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    var enabled = true
    var accessibilityName: String
    /// Called continuously while dragging.
    var onDrag: (Int) -> Void
    /// Called once when the interaction ends (release, key press, VoiceOver adjust).
    var onCommit: (Int) -> Void

    @State private var dragValue: Int?
    @State private var isDragging = false
    @FocusState private var focused: Bool

    private var shown: Int { dragValue ?? value }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = CGFloat(max(1, range.upperBound - range.lowerBound))
            let fraction = CGFloat(shown - range.lowerBound) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control).frame(height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.75), Theme.accentSoft], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, fraction * width), height: 6)
                    .opacity(enabled ? 1 : 0.35)
                HStack(spacing: 0) {
                    ForEach(range.lowerBound...range.upperBound, id: \.self) { step in
                        Circle()
                            .fill(Color.white.opacity(step <= shown ? 0.0 : 0.10))
                            .frame(width: 3, height: 3)
                        if step != range.upperBound { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 1.5)
                .allowsHitTesting(false)
                Circle()
                    .fill(Theme.text)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .overlay(Circle().strokeBorder(focused ? Theme.accent : .clear, lineWidth: 2))
                    .offset(x: fraction * (width - 20))
                    .opacity(enabled ? 1 : 0.5)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        isDragging = true
                        let raw = gesture.location.x / max(1, width) * span + CGFloat(range.lowerBound)
                        let stepped = min(range.upperBound, max(range.lowerBound, Int(raw.rounded())))
                        if stepped != dragValue {
                            dragValue = stepped
                            onDrag(stepped)
                        }
                    }
                    .onEnded { _ in
                        guard enabled, let final = dragValue else { return }
                        isDragging = false
                        onCommit(final)
                        settleAfterCommit()
                    }
            )
        }
        .frame(height: 22)
        .focusable(enabled)
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.downArrow) { step(-1) }
        .onKeyPress(.upArrow) { step(1) }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(shown)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
        .onChange(of: value) { _, newValue in
            if !isDragging || dragValue == newValue { dragValue = nil }
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard enabled else { return .ignored }
        let next = min(range.upperBound, max(range.lowerBound, shown + delta))
        guard next != shown else { return .handled }
        dragValue = next
        onCommit(next)
        settleAfterCommit()
        return .handled
    }

    private func settleAfterCommit() {
        let committed = dragValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !isDragging, dragValue == committed { dragValue = nil }
        }
    }
}

/// Vertical EQ band slider: value label on top, frequency label below.
struct BandSlider: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    var enabled = true
    var highlight = false
    var onDrag: (Int) -> Void
    var onCommit: (Int) -> Void

    @State private var dragValue: Int?
    @FocusState private var focused: Bool
    private var shown: Int { dragValue ?? value }

    var body: some View {
        VStack(spacing: 8) {
            Text(shown > 0 ? "+\(shown)" : "\(shown)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(shown == 0 ? Theme.secondary : Theme.text)
                .frame(height: 14)
            GeometryReader { proxy in
                let height = proxy.size.height
                let span = CGFloat(range.upperBound - range.lowerBound)
                let fraction = CGFloat(shown - range.lowerBound) / span
                let zero = CGFloat(0 - range.lowerBound) / span
                ZStack {
                    Capsule().fill(Theme.control).frame(width: 4)
                    // Fill from the 0 dB line to the value.
                    let top = height * (1 - max(fraction, zero))
                    let bottom = height * (1 - min(fraction, zero))
                    Capsule()
                        .fill(highlight ? Theme.accentSoft : Theme.accent)
                        .frame(width: 4, height: max(2, bottom - top))
                        .position(x: proxy.size.width / 2, y: (top + bottom) / 2)
                        .opacity(enabled ? 1 : 0.35)
                    Circle()
                        .fill(Theme.text)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                        .overlay(Circle().strokeBorder(focused ? Theme.accent : .clear, lineWidth: 2))
                        .position(x: proxy.size.width / 2, y: 9 + (1 - fraction) * (height - 18))
                        .opacity(enabled ? 1 : 0.5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard enabled else { return }
                            let f = 1 - min(1, max(0, (gesture.location.y - 9) / max(1, height - 18)))
                            let stepped = range.lowerBound + Int((f * span).rounded())
                            if stepped != dragValue {
                                dragValue = stepped
                                onDrag(stepped)
                            }
                        }
                        .onEnded { _ in
                            guard enabled, let final = dragValue else { return }
                            onCommit(final)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dragValue = nil }
                        }
                )
            }
            .frame(width: 34)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(highlight ? Theme.accentSoft : Theme.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .focusable(enabled)
        .focused($focused)
        .onKeyPress(.upArrow) { step(1) }
        .onKeyPress(.downArrow) { step(-1) }
        .accessibilityElement()
        .accessibilityLabel(label == "Clear Bass" ? "Clear Bass" : "\(label) hertz band")
        .accessibilityValue("\(shown)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
        .onChange(of: value) { _, newValue in
            if dragValue == newValue { dragValue = nil }
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard enabled else { return .ignored }
        let next = min(range.upperBound, max(range.lowerBound, shown + delta))
        guard next != shown else { return .handled }
        dragValue = next
        onCommit(next)
        return .handled
    }
}

/// Smooth curve through band values (Catmull-Rom), with an optional soft fill.
struct EqualizerCurve: Shape {
    var values: [Double]
    var range: ClosedRange<Double>
    var closed = false
    /// Place points at the centres of equal-width columns (aligns with a row of band sliders).
    var centered = false

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: values) }
        set { values = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let span = range.upperBound - range.lowerBound
        let points = values.enumerated().map { index, value -> CGPoint in
            let x = centered
                ? rect.minX + rect.width * (CGFloat(index) + 0.5) / CGFloat(values.count)
                : rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.minY + rect.height * CGFloat(1 - (value - range.lowerBound) / span)
            return CGPoint(x: x, y: y)
        }
        var path = Path()
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, +)
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, -)
    }

    private static func combine(_ lhs: AnimatableVector, _ rhs: AnimatableVector, _ op: (Double, Double) -> Double) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        return AnimatableVector(values: (0..<count).map { index in
            op(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }

    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// Compact visualisation of an EQ curve with the 0 dB line.
struct EqualizerPreview: View {
    let bands: [Int]
    let range: ClosedRange<Int>
    var centered = false

    var body: some View {
        let values = bands.map(Double.init)
        let r = Double(range.lowerBound)...Double(range.upperBound)
        ZStack {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            EqualizerCurve(values: values, range: r, closed: true, centered: centered)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            EqualizerCurve(values: values, range: r, centered: centered)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
