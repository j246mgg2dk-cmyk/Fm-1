import FM1Core
import SwiftUI

/// Step-grid note editor for one MIDI clip: tap a cell to add or remove a
/// 1/16 note, tap a row label to hear the pitch. Changes apply on Done.
struct ClipEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID
    let slot: Int

    @State private var data = MIDIClipData()
    @State private var loaded = false
    @State private var lowNote = 48            // bottom row (C3)
    @State private var noteLength = 1          // in steps
    private let rows = 25                      // two octaves + 1
    private let cellW: CGFloat = 30
    private let cellH: CGFloat = 24
    private let step = 0.25                    // beats per step (1/16)

    private var track: Track? { model.project.track(trackID) }
    private var stepCount: Int { Int((data.lengthBeats / step).rounded()) }
    private var stepsPerBeat: Int { Int((1 / step).rounded()) }
    private var stepsPerBar: Int { stepsPerBeat * Int(model.project.timeSignature.quarterNotesPerBar.rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    pitchColumn
                    grid
                }
                .padding(12)
            }
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.flatMap { $0.clipSlots.indices.contains(slot) ? $0.clipSlots[slot]?.name : nil } ?? "Clip")
                    .font(Theme.title(16))
                Caps("\(track?.name ?? "") · \(data.notes.count) notes")
            }
            Spacer()
            Caps("Length", size: 8.5)
            Segmented(selection: Binding(get: { bars }, set: { setBars($0) }),
                      options: [(1, "1 bar"), (2, "2"), (4, "4")])
                .frame(width: 170)
            Caps("Note", size: 8.5)
            Segmented(selection: $noteLength, options: [(1, "1/16"), (2, "1/8"), (4, "1/4")])
                .frame(width: 170)
            HStack(spacing: 4) {
                KeyCap("−", isOn: false) { lowNote = max(0, lowNote - 12) }
                Text(noteName(lowNote)).font(Theme.mono(11)).frame(width: 34)
                KeyCap("+", isOn: false) { lowNote = min(127 - rows, lowNote + 12) }
            }
            SlabButton(title: "Clear", systemImage: "trash") { data.notes.removeAll() }
            SlabButton(title: "Done", prominent: true) {
                model.setClipData(trackID: trackID, slot: slot, data)
                dismiss()
            }
        }
        .padding(12)
        .background(Theme.surface)
    }

    private var bars: Int {
        max(1, Int((data.lengthBeats / model.project.timeSignature.quarterNotesPerBar).rounded()))
    }

    private func setBars(_ b: Int) {
        data.lengthBeats = model.project.timeSignature.quarterNotesPerBar * Double(b)
        data.notes.removeAll { $0.start >= data.lengthBeats }
    }

    private var pitchColumn: some View {
        VStack(spacing: 0) {
            ForEach((0..<rows).reversed(), id: \.self) { r in
                let n = lowNote + r
                let black = [1, 3, 6, 8, 10].contains(n % 12)
                Button { audition(n) } label: {
                    Text(n % 12 == 0 ? noteName(n) : noteNames[n % 12])
                        .font(Theme.mono(9.5))
                        .foregroundStyle(n % 12 == 0 ? Theme.text : Theme.dim)
                        .frame(width: 52, height: cellH, alignment: .leading)
                        .padding(.leading, 6)
                        .background(black ? Theme.bg : Theme.surface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 1))
            }
        }
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach((0..<rows).reversed(), id: \.self) { r in
                let n = lowNote + r
                let black = [1, 3, 6, 8, 10].contains(n % 12)
                HStack(spacing: 0) {
                    ForEach(0..<stepCount, id: \.self) { s in
                        cell(note: n, step: s, black: black)
                    }
                }
            }
        }
    }

    private func cell(note: Int, step s: Int, black: Bool) -> some View {
        let covering = data.notes.first { Int($0.note) == note && $0.start <= Double(s) * step + 1e-6 && $0.end > Double(s) * step + 1e-6 }
        let isStart = covering.map { abs($0.start - Double(s) * step) < 1e-6 } ?? false
        let barLine = s % stepsPerBar == 0
        let beatLine = s % stepsPerBeat == 0
        return Rectangle()
            .fill(black ? Color.white.opacity(0.015) : Color.white.opacity(0.035))
            .overlay(alignment: .leading) {
                Rectangle().fill(barLine ? Theme.dim.opacity(0.5) : (beatLine ? Theme.line : Theme.line.opacity(0.4)))
                    .frame(width: barLine ? 1.5 : 1)
            }
            .overlay(Rectangle().fill(Theme.line.opacity(0.35)).frame(height: 1), alignment: .bottom)
            .overlay {
                if covering != nil {
                    RoundedRectangle(cornerRadius: isStart ? 4 : 1)
                        .fill(trackColor(track?.colorIndex ?? 0))
                        .padding(.vertical, 3)
                        .padding(.leading, isStart ? 2 : 0)
                }
            }
            .frame(width: cellW, height: cellH)
            .contentShape(Rectangle())
            .onTapGesture { toggle(note: note, step: s) }
    }

    private func toggle(note: Int, step s: Int) {
        let t = Double(s) * step
        if let i = data.notes.firstIndex(where: { Int($0.note) == note && $0.start <= t + 1e-6 && $0.end > t + 1e-6 }) {
            data.notes.remove(at: i)
            Haptics.tick()
        } else {
            let len = min(Double(noteLength) * step, data.lengthBeats - t)
            data.notes.append(NoteEvent(start: t, length: len, note: UInt8(note), velocity: 100))
            data.notes.sort { $0.start < $1.start }
            audition(note)
        }
    }

    /// Plays the pitch on the clip's track (works when that track is selected).
    private func audition(_ note: Int) {
        guard model.selectedTrackID == trackID else { return }
        Haptics.tick()
        model.playNote(note, on: true, velocity: 90)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { model.playNote(note, on: false) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let clip = track?.clipSlots[safe: slot] ?? nil, case let .midi(d) = clip.content {
            data = d
            if let lowest = d.notes.map({ Int($0.note) }).min() {
                lowNote = max(0, min(127 - rows, (lowest / 12) * 12))
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
