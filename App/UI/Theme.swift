import FM1Core
import SwiftUI

// MARK: - Design tokens
//
// Graphite surfaces, one signal colour (orange) for "active", and a restrained
// track palette. Labels are small uppercase captions with wide tracking; every
// number is set in a monospaced face so readouts don't jitter.

enum Theme {
    static let bg       = Color(hex: 0x0D0D0F)
    static let surface  = Color(hex: 0x161619)
    static let raised   = Color(hex: 0x1F1F23)
    static let raisedHi = Color(hex: 0x2A2A2F)
    static let line     = Color(hex: 0x2C2C32)
    static let text     = Color(hex: 0xECECEE)
    static let dim      = Color(hex: 0x8C8C94)
    static let faint    = Color(hex: 0x56565D)

    static let accent   = Color(hex: 0xFF5B1A)   // signal orange: playing, selected, on
    static let record   = Color(hex: 0xF0453A)
    static let solo     = Color(hex: 0x5AA9FF)
    static let mute     = Color(hex: 0xE8B04A)
    static let ok       = Color(hex: 0x7CC46A)

    static let radius: CGFloat = 8
    static let gap: CGFloat = 6

    static func caps(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Restrained track colours (muted, print-like) instead of system rainbow.
let trackPalette: [Color] = [
    Color(hex: 0xFF7A3D), Color(hex: 0xE8B04A), Color(hex: 0x9BC45A), Color(hex: 0x4FB8A8),
    Color(hex: 0x5A9BE0), Color(hex: 0x8F7BE0), Color(hex: 0xE06A8F), Color(hex: 0xC9B79C),
    Color(hex: 0xD9D9DC), Color(hex: 0x6FC2E0), Color(hex: 0xB8E05A), Color(hex: 0xE0895A),
]
func trackColor(_ i: Int) -> Color { trackPalette[((i % trackPalette.count) + trackPalette.count) % trackPalette.count] }

// MARK: - Text styles

/// Small uppercase caption: the label language used everywhere.
struct Caps: View {
    let text: String
    var color: Color = Theme.dim
    var size: CGFloat = 10

    init(_ text: String, color: Color = Theme.dim, size: CGFloat = 10) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caps(size))
            .tracking(size * 0.12)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - Surfaces

struct PanelModifier: ViewModifier {
    var fill: Color = Theme.surface
    var radius: CGFloat = Theme.radius
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func panel(_ fill: Color = Theme.surface, radius: CGFloat = Theme.radius) -> some View {
        modifier(PanelModifier(fill: fill, radius: radius))
    }

    /// Settings-style pages (routing, CV, sync...) in the graphite theme.
    func modLabFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .tint(Theme.accent)
    }
}

/// Section header for the settings pages.
struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle { Caps(subtitle) }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Shared labels

extension ClockSource {
    var label: String {
        switch self {
        case .internalClock: return "Internal"
        case .externalMIDI: return "Ext MIDI"
        case .abletonLink: return "Link"
        }
    }
}

extension LaunchQuantization {
    var label: String {
        switch self {
        case .none: return "None"
        case .sixteenth: return "1/16"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        case .bar: return "1 Bar"
        case .twoBars: return "2 Bars"
        case .fourBars: return "4 Bars"
        case .eightBars: return "8 Bars"
        }
    }
}

extension TrackKind {
    var label: String {
        switch self {
        case .audio: return "Audio"
        case .instrument: return "Instrument"
        case .midi: return "MIDI"
        case .externalInstrument: return "External Synth"
        case .group: return "Group"
        }
    }

    var glyph: String {
        switch self {
        case .audio: return "waveform"
        case .instrument: return "pianokeys"
        case .midi: return "cable.connector.horizontal"
        case .externalInstrument: return "dial.medium"
        case .group: return "square.stack"
        }
    }

    var blurb: String {
        switch self {
        case .instrument: return "AUv3 synth or sampler, played by MIDI"
        case .audio: return "Record or process interface inputs"
        case .midi: return "Sequence hardware or other apps"
        case .externalInstrument: return "Hardware synth: MIDI out, audio back in"
        case .group: return "Sub-mix other tracks"
        }
    }
}

extension PluginRole {
    var label: String {
        switch self {
        case .instrument: return "Instrument"
        case .audioEffect: return "Effect"
        case .musicEffect: return "Music FX"
        case .midiProcessor: return "MIDI FX"
        case .generator: return "Generator"
        case .other: return "Other"
        }
    }

    var glyph: String {
        switch self {
        case .instrument, .generator: return "pianokeys"
        case .midiProcessor: return "arrow.triangle.branch"
        case .audioEffect, .musicEffect: return "dial.medium"
        case .other: return "puzzlepiece"
        }
    }

    var isEffect: Bool { self == .audioEffect || self == .musicEffect }
}

func channelName(_ c: Int) -> String { "\(c + 1)" }
func pairName(_ chs: [Int]?) -> String {
    guard let chs, let f = chs.first else { return "Master" }
    return chs.count > 1 ? "\(f + 1)/\(chs[1] + 1)" : "\(f + 1)"
}
func stereoPairs(_ count: Int) -> [[Int]] {
    stride(from: 0, to: max(count - 1, 0), by: 2).map { [$0, $0 + 1] }
}

func dbText(_ db: Double) -> String {
    db <= -59.9 ? "-∞" : String(format: "%+.1f", db)
}

func panText(_ pan: Double) -> String {
    abs(pan) < 0.01 ? "C" : (pan < 0 ? "L\(Int((-pan * 50).rounded()))" : "R\(Int((pan * 50).rounded()))")
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}

let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
func noteName(_ n: Int) -> String { "\(noteNames[((n % 12) + 12) % 12])\(n / 12 - 1)" }
