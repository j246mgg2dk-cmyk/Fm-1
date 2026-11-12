import FM1Core
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.project.tracks) { t in
                    ChannelStrip(track: t, selected: model.selectedTrackID == t.id)
                        .onTapGesture { model.selectTrack(t.id) }
                }
                Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 8)
                masterStrip
            }
            .padding(14)
            .frame(maxHeight: .infinity)
        }
        .background(Theme.bg)
    }

    private var masterStrip: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4, height: 14)
                Text("Master").font(Theme.title(13))
            }
            Caps("Out \(pairName(model.project.masterOutputChannels))")
            HStack(alignment: .bottom, spacing: 6) {
                Fader(db: Binding(get: { model.project.masterVolumeDB }, set: { model.setMasterVolume($0) }))
                StereoMeter(left: live.masterPeak.0, right: live.masterPeak.1, segments: 24).frame(width: 12)
            }
            .frame(maxHeight: .infinity)
            Text(dbText(model.project.masterVolumeDB)).font(Theme.mono(11))
            OutputMenu(channels: Binding(get: { model.project.masterOutputChannels },
                                         set: { model.project.masterOutputChannels = $0 ?? [0, 1]; model.rebuild() }),
                       allowMaster: false)
        }
        .padding(10)
        .frame(width: 112)
        .frame(maxHeight: .infinity)
        .panel(Theme.surface, radius: 12)
    }
}

struct ChannelStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let track: Track
    let selected: Bool

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(trackColor(track.colorIndex)).frame(width: 4, height: 14)
                    Text(track.name).font(Theme.title(12.5)).lineLimit(1)
                }
                Caps(track.kind.label, size: 8)
            }
            if track.kind != .midi {
                Knob(value: Binding(get: { track.pan }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.pan = v } }),
                     range: -1...1, defaultValue: 0, label: "Pan", size: 34, bipolar: true, format: panText)
                ForEach(track.sends) { s in
                    Knob(value: Binding(get: { s.levelDB }, set: { v in
                        model.updateTrack(track.id, rebuildGraph: false) { t in
                            if let i = t.sends.firstIndex(where: { $0.id == s.id }) { t.sends[i].levelDB = v.rounded(toPlaces: 1) }
                        }
                    }), range: -60...6, defaultValue: -12, label: "→\(pairName(s.outputChannels))", size: 28,
                         color: Theme.solo, format: { dbText($0) })
                }
                HStack(alignment: .bottom, spacing: 6) {
                    Fader(db: Binding(get: { track.volumeDB },
                                      set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.volumeDB = v } }),
                          color: trackColor(track.colorIndex))
                    StereoMeter(left: live.trackPeaks[track.id]?.0 ?? 0, right: live.trackPeaks[track.id]?.1 ?? 0, segments: 24)
                        .frame(width: 12)
                }
                .frame(maxHeight: .infinity)
                Text(dbText(track.volumeDB)).font(Theme.mono(11))
            } else {
                Spacer()
                Caps("MIDI only")
                Spacer()
            }
            HStack(spacing: 3) {
                KeyCap("●", isOn: track.isArmed, onColor: Theme.record, width: 26, height: 24) { model.setArmed(track.id, !track.isArmed) }
                KeyCap("S", isOn: track.isSoloed, onColor: Theme.solo, width: 26, height: 24) {
                    model.updateTrack(track.id, rebuildGraph: false) { $0.isSoloed.toggle() }
                }
                KeyCap("M", isOn: track.isMuted, onColor: Theme.mute, width: 26, height: 24) {
                    model.updateTrack(track.id, rebuildGraph: false) { $0.isMuted.toggle() }
                }
            }
            if track.kind != .midi {
                OutputMenu(channels: Binding(get: { track.outputChannels },
                                             set: { v in model.updateTrack(track.id) { $0.outputChannels = v } }),
                           allowMaster: true)
                Menu {
                    ForEach(stereoPairs(model.audioStatus.outputChannels), id: \.self) { pair in
                        Button("Send to Out \(pairName(pair))") {
                            model.updateTrack(track.id) { $0.sends.append(HardwareSend(outputChannels: pair)) }
                        }
                    }
                    if !track.sends.isEmpty {
                        Button("Remove last send", role: .destructive) { model.updateTrack(track.id) { _ = $0.sends.popLast() } }
                    }
                } label: {
                    Caps("+ Send", size: 8.5).frame(maxWidth: .infinity).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                }
            }
        }
        .padding(10)
        .frame(width: 104)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.raised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? trackColor(track.colorIndex).opacity(0.7) : Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

/// Picks a hardware output (stereo pair or mono) on the current interface.
struct OutputMenu: View {
    @EnvironmentObject var model: AppModel
    @Binding var channels: [Int]?
    let allowMaster: Bool

    var body: some View {
        Menu {
            if allowMaster { Button("Master") { channels = nil } }
            SwiftUI.Section("Stereo") {
                ForEach(stereoPairs(model.audioStatus.outputChannels), id: \.self) { p in
                    Button("Out \(pairName(p))") { channels = p }
                }
            }
            SwiftUI.Section("Mono") {
                ForEach(0..<model.audioStatus.outputChannels, id: \.self) { c in
                    Button("Out \(channelName(c))") { channels = [c] }
                }
            }
        } label: {
            VStack(spacing: 1) {
                Caps("Out", size: 7.5)
                Text(pairName(channels)).font(Theme.mono(10.5)).foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
        }
    }
}
