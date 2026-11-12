import FM1Core
import SwiftUI

/// Two-octave multi-touch keyboard that plays the selected track — the
/// same path as a hardware controller, so it also records into clips.
struct KeyboardStrip: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("keyboardOctave") private var octave = 4      // C4 = 60 at the left edge
    @AppStorage("keyboardVelocity") private var velocity = 100.0
    @State private var held: Set<Int> = []

    private var base: Int { (octave + 1) * 12 }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Caps("Plays")
                Text(model.selectedTrack?.name ?? "No track").font(Theme.title(13)).lineLimit(1)
                Text(targetHint).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    KeyCap("−", isOn: false, width: 30, height: 26) { shift(-1) }
                    Text("C\(octave)").font(Theme.mono(12)).frame(width: 34)
                    KeyCap("+", isOn: false, width: 30, height: 26) { shift(1) }
                }
            }
            .frame(width: 140, alignment: .leading)
            Knob(value: $velocity, range: 1...127, defaultValue: 100, label: "Vel", size: 38, format: { "\(Int($0))" })
            PianoKeys(base: base, octaves: 2, held: held,
                      onDown: { n in
                          held.insert(n)
                          model.playNote(n, on: true, velocity: Int(velocity))
                      },
                      onUp: { n in
                          held.remove(n)
                          model.playNote(n, on: false)
                      })
        }
        .padding(10)
        .frame(height: 132)
        .background(Theme.surface)
        .onChange(of: model.selectedTrackID) { _, _ in releaseAll() }
        .onDisappear { releaseAll() }
    }

    private var targetHint: String {
        guard let t = model.selectedTrack else { return "Select a track" }
        let hasInstrument = t.devices.contains { $0.component.role == .instrument || $0.component.role == .generator }
        switch t.kind {
        case .instrument: return hasInstrument ? "Instrument ready" : "Load an instrument to hear it"
        case .midi, .externalInstrument: return t.midiOutput == nil ? "Set a MIDI out" : "→ \(t.midiOutput!.name)"
        case .audio, .group: return "This track has no MIDI"
        }
    }

    private func shift(_ d: Int) {
        releaseAll()
        octave = min(max(octave + d, 0), 8)
    }

    private func releaseAll() {
        for n in held { model.playNote(n, on: false) }
        held.removeAll()
    }
}

/// Flat, hardware-style keys. Each key tracks its own touch, so chords work.
struct PianoKeys: View {
    let base: Int
    let octaves: Int
    let held: Set<Int>
    let onDown: (Int) -> Void
    let onUp: (Int) -> Void

    private static let whiteSteps = [0, 2, 4, 5, 7, 9, 11]
    private static let blackSteps: [(step: Int, afterWhite: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]

    var body: some View {
        GeometryReader { geo in
            let whites = octaves * 7 + 1
            let w = geo.size.width / CGFloat(whites)
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach(0..<whites, id: \.self) { i in
                    let note = base + (i / 7) * 12 + Self.whiteSteps[i % 7]
                    Key(note: note, isBlack: false, isDown: held.contains(note), label: note % 12 == 0 ? noteName(note) : nil,
                        onDown: onDown, onUp: onUp)
                        .frame(width: w - 3, height: h)
                        .offset(x: CGFloat(i) * w)
                }
                ForEach(0..<octaves, id: \.self) { o in
                    ForEach(Self.blackSteps, id: \.step) { b in
                        let note = base + o * 12 + b.step
                        Key(note: note, isBlack: true, isDown: held.contains(note), label: nil, onDown: onDown, onUp: onUp)
                            .frame(width: w * 0.62, height: h * 0.58)
                            .offset(x: CGFloat(o * 7 + b.afterWhite + 1) * w - w * 0.31 - 1.5)
                    }
                }
            }
        }
    }

    struct Key: View {
        let note: Int
        let isBlack: Bool
        let isDown: Bool
        let label: String?
        let onDown: (Int) -> Void
        let onUp: (Int) -> Void
        @State private var touching = false

        var body: some View {
            RoundedRectangle(cornerRadius: isBlack ? 5 : 7, style: .continuous)
                .fill(isDown ? Theme.accent : (isBlack ? Color(hex: 0x111114) : Color(hex: 0x2B2B30)))
                .overlay(RoundedRectangle(cornerRadius: isBlack ? 5 : 7, style: .continuous)
                    .stroke(isBlack ? Color.black : Theme.line, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if let label { Text(label).font(Theme.mono(9)).foregroundStyle(isDown ? .black : Theme.faint).padding(.bottom, 6) }
                }
                .shadow(color: isBlack ? .black.opacity(0.6) : .clear, radius: 2, y: 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !touching { touching = true; onDown(note) }
                        }
                        .onEnded { _ in
                            touching = false
                            onUp(note)
                        }
                )
                .animation(.easeOut(duration: 0.06), value: isDown)
        }
    }
}
