import FM1Core
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var selectedTrack: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.project.tracks) { t in
                    ChannelStrip(track: t, selected: selectedTrack == t.id)
                        .onTapGesture { selectedTrack = t.id }
                }
                Divider()
                masterStrip
            }
            .padding()
        }
    }

    private var masterStrip: some View {
        VStack(spacing: 8) {
            Text("Master").font(.headline)
            MeterBar(left: live.masterPeak.0, right: live.masterPeak.1).frame(width: 60, height: 14)
            VerticalFader(value: Binding(get: { model.project.masterVolumeDB },
                                         set: { model.setMasterVolume($0) }))
                .frame(height: 260)
            Text(String(format: "%.1f dB", model.project.masterVolumeDB)).font(.caption.monospacedDigit())
            OutputPicker(channels: Binding(get: { model.project.masterOutputChannels },
                                           set: { model.project.masterOutputChannels = $0 ?? [0, 1]; model.rebuild() }),
                         allowMaster: false)
        }
        .frame(width: 110)
        .padding(8)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChannelStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let track: Track
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(track.name).font(.headline).lineLimit(1)
            Text(track.kind.label).font(.caption2).foregroundStyle(.secondary)

            if track.kind != .midi {
                MeterBar(left: live.trackPeaks[track.id]?.0 ?? 0, right: live.trackPeaks[track.id]?.1 ?? 0)
                    .frame(width: 60, height: 14)
                Slider(value: Binding(get: { track.pan }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.pan = v } }),
                       in: -1...1)
                    .frame(width: 90)
                Text(track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(-track.pan * 50))" : "R\(Int(track.pan * 50))"))
                    .font(.caption2)
                VerticalFader(value: Binding(get: { track.volumeDB },
                                             set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.volumeDB = v } }))
                    .frame(height: 220)
                Text(String(format: "%.1f dB", track.volumeDB)).font(.caption.monospacedDigit())
            }

            HStack(spacing: 4) {
                Toggle("M", isOn: Binding(get: { track.isMuted }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.isMuted = v } }))
                Toggle("S", isOn: Binding(get: { track.isSoloed }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.isSoloed = v } }))
                Toggle("A", isOn: Binding(get: { track.isArmed }, set: { v in model.setArmed(track.id, v) }))
            }
            .toggleStyle(.button)
            .font(.caption)

            if track.kind != .midi {
                Text("Out").font(.caption2).foregroundStyle(.secondary)
                OutputPicker(channels: Binding(get: { track.outputChannels },
                                               set: { v in model.updateTrack(track.id) { $0.outputChannels = v } }),
                             allowMaster: true)
                ForEach(track.sends) { s in
                    HStack {
                        Text("→\(pairName(s.outputChannels))").font(.caption2)
                        Slider(value: Binding(get: { s.levelDB }, set: { v in
                            model.updateTrack(track.id, rebuildGraph: false) { t in
                                if let i = t.sends.firstIndex(where: { $0.id == s.id }) { t.sends[i].levelDB = v }
                            }
                        }), in: -60...6)
                    }
                }
                Menu("Add Send") {
                    ForEach(stereoPairs(model.audioStatus.outputChannels), id: \.self) { pair in
                        Button("Out \(pairName(pair))") {
                            model.updateTrack(track.id) { $0.sends.append(HardwareSend(outputChannels: pair)) }
                        }
                    }
                }
                .font(.caption)
            }
        }
        .frame(width: 110)
        .padding(8)
        .background(trackColor(track.colorIndex).opacity(selected ? 0.25 : 0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct VerticalFader: View {
    @Binding var value: Double   // dB, -60...+6

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let norm = (min(max(value, -60), 6) + 60) / 66
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.gray.opacity(0.25)).frame(width: 8)
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: 8, height: h * norm)
                RoundedRectangle(cornerRadius: 3).fill(.white).shadow(radius: 1)
                    .frame(width: 36, height: 14)
                    .offset(y: -h * norm + 7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let n = 1 - min(max(g.location.y / h, 0), 1)
                value = (n * 66 - 60).rounded(toPlaces: 1)
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(width: 44)
    }
}

/// Picks a hardware output (mono or stereo pair) on the current interface.
struct OutputPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var channels: [Int]?
    let allowMaster: Bool

    var body: some View {
        Menu(pairName(channels)) {
            if allowMaster { Button("Master") { channels = nil } }
            Section("Stereo") {
                ForEach(stereoPairs(model.audioStatus.outputChannels), id: \.self) { p in
                    Button(pairName(p)) { channels = p }
                }
            }
            Section("Mono") {
                ForEach(0..<model.audioStatus.outputChannels, id: \.self) { c in
                    Button(channelName(c)) { channels = [c] }
                }
            }
        }
        .font(.caption)
    }
}

func stereoPairs(_ count: Int) -> [[Int]] {
    stride(from: 0, to: max(count - 1, 0), by: 2).map { [$0, $0 + 1] }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
