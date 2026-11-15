import SwiftUI
import UIKit

// MARK: - Look

enum Panel {
    static let face = LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
    static let silk = Color(white: 0.78)                       // silkscreen labels
    static let silkDim = Color(white: 0.52)
    static let key = LinearGradient(colors: [Color(white: 0.27), Color(white: 0.19)], startPoint: .top, endPoint: .bottom)
    static let keyDown = LinearGradient(colors: [Color(white: 0.15), Color(white: 0.20)], startPoint: .top, endPoint: .bottom)
    static let red = Color(red: 1.0, green: 0.16, blue: 0.10)
    static let green = Color(red: 0.25, green: 1.0, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.16)
}

/// A panel LED: off, or glowing.
struct LED: View {
    var on: Bool
    var color: Color = Panel.red
    var size: CGFloat = 7
    var body: some View {
        Circle()
            .fill(on ? color : Color(white: 0.08))
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.9) : .clear, radius: on ? size * 0.8 : 0)
    }
}

/// Small silkscreen label.
struct Silk: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = Panel.silk
    init(_ text: String, size: CGFloat = 10, color: Color = Panel.silk) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold, design: .rounded)).tracking(size * 0.08)
            .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
    }
}

// MARK: - Keys

/// A rubber key: press and release are separate events, so keys can be held and combined
/// (FUNCTION + TRIG, record + trig, ...) with several fingers at once.
struct PanelKey<Content: View>: View {
    let control: Int
    var width: CGFloat
    var height: CGFloat
    var haptic: UIImpactFeedbackGenerator.FeedbackStyle = .light
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var machine: MachineController
    @State private var down = false

    var body: some View {
        RoundedRectangle(cornerRadius: min(width, height) * 0.18, style: .continuous)
            .fill(down ? Panel.keyDown : Panel.key)
            .overlay(RoundedRectangle(cornerRadius: min(width, height) * 0.18, style: .continuous)
                .stroke(Color.white.opacity(down ? 0.04 : 0.10), lineWidth: 1))
            .shadow(color: .black.opacity(down ? 0.2 : 0.55), radius: down ? 1 : 3, y: down ? 0 : 2)
            .overlay(content())
            .frame(width: width, height: height)
            .scaleEffect(down ? 0.97 : 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    UIImpactFeedbackGenerator(style: haptic).impactOccurred()
                    machine.press(control, true)
                }
                .onEnded { _ in
                    down = false
                    machine.press(control, false)
                })
            .animation(.easeOut(duration: 0.06), value: down)
    }
}

/// A labelled function key.
struct FunctionKey: View {
    let control: MDControl
    let label: String
    var w: CGFloat
    var h: CGFloat
    var body: some View {
        PanelKey(control: control.rawValue, width: w, height: h) {
            Silk(label, size: h * 0.24)
        }
    }
}

/// One of the 16 trig keys, with its step LED.
struct TrigKey: View {
    let index: Int
    var w: CGFloat
    var h: CGFloat
    @EnvironmentObject private var panel: PanelState
    var body: some View {
        PanelKey(control: MDControl.trig(index), width: w, height: h, haptic: .medium) {
            VStack(spacing: h * 0.08) {
                LED(on: panel.leds.step(index), size: h * 0.13)
                Text("\(index + 1)").font(.system(size: h * 0.22, weight: .bold, design: .rounded))
                    .foregroundStyle(Panel.silkDim)
            }
        }
    }
}

// MARK: - Encoder

/// An endless encoder. Drag up/right to turn clockwise (one detent per few points), hold
/// still for a moment to push it (data entry encoders), keep holding and drag to turn
/// while pushed.
struct EncoderKnob: View {
    let encoder: Int
    let label: String
    var size: CGFloat
    var pushable = true
    @EnvironmentObject private var machine: MachineController
    @State private var angle: Double = 0
    @State private var last: CGSize = .zero
    @State private var accum: CGFloat = 0
    @State private var pushed = false
    @State private var moved = false
    @State private var holdTask: Task<Void, Never>?

    private let pointsPerDetent: CGFloat = 9

    var body: some View {
        VStack(spacing: size * 0.08) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.34), Color(white: 0.13)], center: .init(x: 0.4, y: 0.3),
                                             startRadius: 1, endRadius: size * 0.7))
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).padding(size * 0.12)
                Capsule().fill(pushed ? Panel.orange : Color(white: 0.85))
                    .frame(width: max(2, size * 0.06), height: size * 0.22)
                    .offset(y: -size * 0.3)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
            .scaleEffect(pushed ? 0.95 : 1)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if holdTask == nil && !moved && !pushed && last == .zero {
                        startHold()
                    }
                    let d = CGSize(width: v.translation.width - last.width, height: v.translation.height - last.height)
                    last = v.translation
                    let delta = d.width - d.height                     // right or up = clockwise
                    if abs(v.translation.width) + abs(v.translation.height) > 4 { moved = true }
                    accum += delta
                    let steps = Int(accum / pointsPerDetent)
                    if steps != 0 {
                        accum -= CGFloat(steps) * pointsPerDetent
                        angle += Double(steps) * 12
                        machine.turn(encoder, steps)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel(); holdTask = nil
                    if pushed { machine.pushEncoder(encoder, false); pushed = false }
                    last = .zero; accum = 0; moved = false
                })
            Silk(label, size: max(9, size * 0.2))
        }
    }

    private func startHold() {
        guard pushable else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, !moved else { return }
            pushed = true
            machine.pushEncoder(encoder, true)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }
}

// MARK: - LCD

struct LCDDisplay: View {
    @EnvironmentObject private var panel: PanelState
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
            if let img = panel.lcd {
                Image(decorative: img, scale: 1).interpolation(.none).resizable()
                    .aspectRatio(2, contentMode: .fit)
                    .padding(10)
            } else {
                Silk("MACHINEDRUM", size: 14, color: Panel.silkDim)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(white: 0.3), lineWidth: 2))
        .shadow(color: .black.opacity(0.7), radius: 6, y: 3)
    }
}

// MARK: - The front panel

struct FrontPanelView: View {
    @EnvironmentObject private var machine: MachineController
    @EnvironmentObject private var panel: PanelState

    var body: some View {
        GeometryReader { geo in
            // Designed at 1180 x 760 points (11-inch iPad Pro, landscape); everything scales.
            let u = min(geo.size.width / 1180, geo.size.height / 760)
            let key = 62 * u, keyH = 44 * u
            VStack(spacing: 16 * u) {
                // Row 1: LEVEL, LCD, data entry encoders, navigation.
                HStack(alignment: .top, spacing: 22 * u) {
                    VStack(spacing: 14 * u) {
                        EncoderKnob(encoder: 8, label: "LEVEL", size: 74 * u, pushable: false)
                    }
                    .padding(.top, 20 * u)
                    LCDDisplay().frame(width: 400 * u, height: 210 * u)
                    VStack(spacing: 14 * u) {
                        HStack(spacing: 18 * u) { ForEach(0..<4) { i in EncoderKnob(encoder: i, label: ["A", "B", "C", "D"][i], size: 64 * u) } }
                        HStack(spacing: 18 * u) { ForEach(4..<8) { i in EncoderKnob(encoder: i, label: ["E", "F", "G", "H"][i - 4], size: 64 * u) } }
                    }
                    navigation(u: u, key: key, keyH: keyH)
                }
                // Row 2: modes, banks, pages.
                HStack(alignment: .bottom, spacing: 14 * u) {
                    ledKey(.classicExtended, "CLASSIC/EXT", leds: [("CLASSIC", panel.leds.classic, Panel.green), ("EXTENDED", panel.leds.extended, Panel.green)], u: u)
                    ledKey(.patternSong, "PATTERN/SONG", leds: [("PATTERN", panel.leds.pattern, Panel.green), ("SONG", panel.leds.song, Panel.green)], u: u)
                    ledKey(.bankGroup, "BANK GROUP", leds: [("A-D", panel.leds.bankAD, Panel.green), ("E-H", panel.leds.bankEH, Panel.green)], u: u)
                    HStack(spacing: 8 * u) {
                        FunctionKey(control: .bankA, label: "A", w: keyH, h: keyH)
                        FunctionKey(control: .bankB, label: "B", w: keyH, h: keyH)
                        FunctionKey(control: .bankC, label: "C", w: keyH, h: keyH)
                        FunctionKey(control: .bankD, label: "D", w: keyH, h: keyH)
                    }
                    Spacer(minLength: 8 * u)
                    ledKey(.synEfxRout, "SYN/EFX/ROUT", leds: [("SYNTH", panel.leds.synthesis, Panel.red), ("EFFECTS", panel.leds.effects, Panel.red), ("ROUTING", panel.leds.routing, Panel.red)], u: u)
                    FunctionKey(control: .kit, label: "KIT", w: key, h: keyH)
                    VStack(spacing: 5 * u) {
                        LED(on: panel.leds.tempo, color: Panel.red, size: 7 * u)
                        FunctionKey(control: .tempo, label: "TEMPO", w: key, h: keyH)
                    }
                    ledKey(.scale, "SCALE", leds: [("1", panel.leds.page1, Panel.red), ("2", panel.leds.page2, Panel.red), ("3", panel.leds.page3, Panel.red), ("4", panel.leds.page4, Panel.red)], u: u)
                }
                // Row 3: track LEDs above the trigs.
                HStack(spacing: 0) {
                    Color.clear.frame(width: transportWidth(u: u, key: key))
                    HStack(spacing: 6 * u) {
                        ForEach(0..<16) { i in
                            Capsule().fill(panel.leds.track(i) ? Panel.red : Color(white: 0.09))
                                .frame(height: 4 * u)
                                .shadow(color: panel.leds.track(i) ? Panel.red : .clear, radius: 4 * u)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                // Row 4: transport and the 16 trig keys.
                HStack(spacing: 10 * u) {
                    transport(u: u, key: key)
                    HStack(spacing: 6 * u) {
                        ForEach(0..<16) { i in
                            TrigKey(index: i, w: (geo.size.width - transportWidth(u: u, key: key) - 48 * u - 15 * 6 * u) / 16, h: 108 * u)
                        }
                    }
                }
            }
            .padding(.horizontal, 24 * u)
            .padding(.vertical, 18 * u)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func transportWidth(u: CGFloat, key: CGFloat) -> CGFloat { 3 * 58 * u + 2 * 8 * u + 10 * u }

    private func transport(u: CGFloat, key: CGFloat) -> some View {
        HStack(spacing: 8 * u) {
            PanelKey(control: MDControl.record.rawValue, width: 58 * u, height: 108 * u, haptic: .medium) {
                VStack(spacing: 6 * u) {
                    LED(on: panel.leds.record, size: 8 * u)
                    Circle().fill(Panel.red.opacity(0.85)).frame(width: 16 * u, height: 16 * u)
                    Silk("REC", size: 9 * u, color: Panel.silkDim)
                }
            }
            PanelKey(control: MDControl.play.rawValue, width: 58 * u, height: 108 * u, haptic: .medium) {
                VStack(spacing: 6 * u) {
                    Image(systemName: "play.fill").font(.system(size: 18 * u)).foregroundStyle(Panel.green.opacity(0.85))
                    Silk("PLAY", size: 9 * u, color: Panel.silkDim)
                }
            }
            PanelKey(control: MDControl.stop.rawValue, width: 58 * u, height: 108 * u, haptic: .medium) {
                VStack(spacing: 6 * u) {
                    RoundedRectangle(cornerRadius: 2).fill(Panel.silk).frame(width: 15 * u, height: 15 * u)
                    Silk("STOP", size: 9 * u, color: Panel.silkDim)
                }
            }
        }
    }

    private func navigation(u: CGFloat, key: CGFloat, keyH: CGFloat) -> some View {
        VStack(spacing: 8 * u) {
            HStack(spacing: 8 * u) {
                FunctionKey(control: .function, label: "FUNC", w: key, h: keyH)
                FunctionKey(control: .up, label: "▲", w: keyH, h: keyH)
                Color.clear.frame(width: key, height: keyH)
            }
            HStack(spacing: 8 * u) {
                FunctionKey(control: .left, label: "◀", w: keyH, h: keyH)
                FunctionKey(control: .down, label: "▼", w: keyH, h: keyH)
                FunctionKey(control: .right, label: "▶", w: keyH, h: keyH)
            }
            HStack(spacing: 8 * u) {
                FunctionKey(control: .exit, label: "NO/EXIT", w: key * 1.15, h: keyH)
                FunctionKey(control: .enter, label: "YES/ENTER", w: key * 1.15, h: keyH)
            }
        }
    }

    /// A key with a row of labelled LEDs above it.
    private func ledKey(_ control: MDControl, _ label: String, leds: [(String, Bool, Color)], u: CGFloat) -> some View {
        VStack(spacing: 6 * u) {
            HStack(spacing: 8 * u) {
                ForEach(Array(leds.enumerated()), id: \.offset) { _, l in
                    VStack(spacing: 3 * u) {
                        LED(on: l.1, color: l.2, size: 7 * u)
                        Silk(l.0, size: 7.5 * u, color: Panel.silkDim)
                    }
                }
            }
            FunctionKey(control: control, label: label, w: max(88 * u, CGFloat(leds.count) * 34 * u), h: 44 * u)
        }
    }
}
