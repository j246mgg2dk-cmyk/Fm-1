import SwiftUI
import UIKit

// MARK: - Press feel

/// Physical press: a slight sink and darkening, with a light haptic tick.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

enum Haptics {
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func click() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
}

// MARK: - Key cap (M / S / arm / bypass ...)

struct KeyCap<Label: View>: View {
    let isOn: Bool
    var onColor: Color = Theme.accent
    var width: CGFloat = 30
    var height: CGFloat = 26
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            label()
                .font(Theme.caps(11))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Theme.dim)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? onColor : Theme.raised)
                        .shadow(color: isOn ? onColor.opacity(0.45) : .clear, radius: 6)
                )
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isOn ? Color.clear : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

extension KeyCap where Label == Text {
    init(_ text: String, isOn: Bool, onColor: Color = Theme.accent, width: CGFloat = 30, height: CGFloat = 26,
         action: @escaping () -> Void) {
        self.isOn = isOn
        self.onColor = onColor
        self.width = width
        self.height = height
        self.action = action
        self.label = { Text(text) }
    }
}

/// Larger rectangular button with an icon and caption ("ADD", "EDIT"...).
struct SlabButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title.uppercased()).font(Theme.caps(11)).tracking(1.1)
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Theme.accent : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(prominent ? .clear : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Knob

/// Rotary encoder: drag up/down (or sideways) to turn, double-tap to reset.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var defaultValue: Double?
    var label: String?
    var size: CGFloat = 44
    var color: Color = Theme.accent
    /// Draw the arc from the centre (pan) instead of from the minimum.
    var bipolar = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var dragStart: Double?

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Theme.raised)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .padding(5)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                arc
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Capsule()
                    .fill(Theme.text)
                    .frame(width: 2.5, height: size * 0.22)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStart == nil { dragStart = norm }
                        let delta = (-g.translation.height + g.translation.width * 0.5) / 180
                        let n = min(max((dragStart ?? 0) + delta, 0), 1)
                        value = range.lowerBound + n * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) {
                if let defaultValue { value = defaultValue; Haptics.tick() }
            }
            if let label {
                VStack(spacing: 1) {
                    Text(format(value)).font(Theme.mono(10)).foregroundStyle(Theme.text)
                    Caps(label, size: 8.5)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Knob")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 50
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }

    private var arc: some Shape {
        if bipolar {
            let a = 0.375, b = 0.375 + (norm - 0.5) * 0.75
            return Circle().trim(from: min(a, b), to: max(a, b))
        }
        return Circle().trim(from: 0, to: 0.75 * norm)
    }
}

// MARK: - Fader

/// Long-throw channel fader, -60...+6 dB. Drag anywhere on the track; double-tap = 0 dB.
struct Fader: View {
    @Binding var db: Double
    var color: Color = Theme.accent

    private static let ticks: [Double] = [6, 0, -6, -12, -24, -48]
    @State private var dragStartNorm: Double?

    static func norm(_ db: Double) -> Double {
        // Gentle curve: more resolution around unity gain.
        let c = min(max(db, -60), 6)
        return c >= -12 ? 0.55 + (c + 12) / 18 * 0.45 : 0.55 * pow((c + 60) / 48, 1.4)
    }

    static func dbFrom(_ n: Double) -> Double {
        let n = min(max(n, 0), 1)
        return n >= 0.55 ? -12 + (n - 0.55) / 0.45 * 18 : pow(n / 0.55, 1 / 1.4) * 48 - 60
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - 22
            let y = (1 - Self.norm(db)) * h + 11
            ZStack(alignment: .top) {
                // ticks
                ForEach(Self.ticks, id: \.self) { t in
                    Rectangle().fill(t == 0 ? Theme.dim : Theme.faint)
                        .frame(width: t == 0 ? 14 : 8, height: 1)
                        .offset(x: geo.size.width / 2 - 20, y: (1 - Self.norm(t)) * h + 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // groove
                Capsule().fill(Color.black.opacity(0.6))
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .frame(width: 5, height: h)
                    .offset(y: 11)
                Capsule().fill(color.opacity(0.85))
                    .frame(width: 3, height: max(0, h - (y - 11)))
                    .offset(y: y)
                // cap
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x3A3A40), Color(hex: 0x26262B)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Theme.text).frame(height: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(width: 34, height: 22)
                    .offset(y: y - 11)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartNorm == nil { dragStartNorm = Self.norm(db) }
                        let n = (dragStartNorm ?? 0) - g.translation.height / max(h, 1)
                        db = Self.dbFrom(n).rounded(toPlaces: 1)
                    }
                    .onEnded { _ in dragStartNorm = nil }
            )
            .onTapGesture(count: 2) { db = 0; Haptics.tick() }
        }
        .frame(width: 44)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(dbText(db)) dB")
        .accessibilityAdjustableAction { dir in db = min(max(db + (dir == .increment ? 1 : -1), -60), 6) }
    }
}

// MARK: - Meters

/// Segmented LED meter. `level` is linear peak (0...1+).
struct LEDMeter: View {
    var level: Float
    var segments = 18
    var vertical = true

    private func lit(_ i: Int) -> Bool {
        let db = 20 * log10(max(Double(level), 1e-5))
        let n = max(0, min(1, (db + 54) / 54))
        return Double(i) < n * Double(segments)
    }

    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(segments)
        return f > 0.9 ? Theme.record : (f > 0.72 ? Theme.mute : Theme.ok)
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 1.5)) : AnyLayout(HStackLayout(spacing: 1.5))
        layout {
            ForEach(0..<segments, id: \.self) { k in
                let i = vertical ? segments - 1 - k : k
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit(i) ? color(i) : Color.white.opacity(0.06))
            }
        }
    }
}

/// Stereo pair of LED meters.
struct StereoMeter: View {
    var left: Float
    var right: Float
    var vertical = true
    var segments = 18

    var body: some View {
        let layout = vertical ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        layout {
            LEDMeter(level: left, segments: segments, vertical: vertical)
            LEDMeter(level: right, segments: segments, vertical: vertical)
        }
    }
}

/// Compact horizontal meter (kept for settings pages).
struct MeterBar: View {
    var left: Float
    var right: Float
    var body: some View { StereoMeter(left: left, right: right, vertical: false, segments: 24) }
}

// MARK: - Segmented control

struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { opt in
                let on = opt.0 == selection
                Button {
                    Haptics.tick()
                    withAnimation(.snappy(duration: 0.18)) { selection = opt.0 }
                } label: {
                    Text(opt.1.uppercased())
                        .font(Theme.caps(10)).tracking(1)
                        .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 4)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.97))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// A caps-labelled menu that looks like the rest of the hardware.
struct ChipMenu<Content: View>: View {
    let title: String
    var value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Caps(title, size: 8.5)
                Text(value).font(Theme.mono(11)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}
