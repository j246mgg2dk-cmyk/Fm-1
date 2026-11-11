import FM1Core
import SwiftUI

/// Ableton-style clip launcher: tracks across, scenes down.
struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var selectedTrack: UUID?

    private let cellW: CGFloat = 132
    private let cellH: CGFloat = 44

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 2) {
                ForEach(Array(model.project.tracks.enumerated()), id: \.element.id) { ti, track in
                    VStack(spacing: 2) {
                        header(track)
                        ForEach(0..<model.project.scenes.count, id: \.self) { si in
                            cell(trackIndex: ti, track: track, slot: si)
                        }
                        Button { model.stopTrack(ti) } label: {
                            Image(systemName: "stop.fill").frame(width: cellW, height: 28)
                        }
                        .buttonStyle(.bordered)
                        trackFooter(track)
                    }
                }
                sceneColumn
                addTrackMenu
            }
            .padding()
        }
    }

    private func header(_ track: Track) -> some View {
        Button { selectedTrack = track.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.headline).lineLimit(1)
                Text(track.kind.label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: cellW, height: 44, alignment: .leading)
            .padding(.horizontal, 6)
            .background(trackColor(track.colorIndex).opacity(selectedTrack == track.id ? 0.6 : 0.3),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { renameTarget = track.id }
            Menu("Group into") {
                Button("None") { model.updateTrack(track.id) { $0.groupID = nil } }
                ForEach(model.project.tracks.filter { $0.kind == .group && $0.id != track.id }) { g in
                    Button(g.name) { model.updateTrack(track.id) { $0.groupID = g.id } }
                }
            }
            Button("Delete Track", role: .destructive) { model.removeTrack(track.id) }
        }
        .alert("Rename Track", isPresented: Binding(get: { renameTarget == track.id }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") {
                model.updateTrack(track.id, rebuildGraph: false) { $0.name = renameText }
                renameTarget = nil
            }
        }
    }

    @State private var renameTarget: UUID?
    @State private var renameText = ""

    private func cell(trackIndex ti: Int, track: Track, slot si: Int) -> some View {
        let clip = si < track.clipSlots.count ? track.clipSlots[si] : nil
        let playing = live.playingSlots[track.id] == si
        let queued = live.queuedSlots[track.id] == si
        return Button {
            if clip != nil { model.launch(track: ti, slot: si) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: playing ? "play.fill" : (queued ? "clock" : (clip == nil ? "square" : "play")))
                    .font(.caption)
                Text(clip?.name ?? "").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(width: cellW, height: cellH)
            .background(clip == nil ? Color.gray.opacity(0.12) : trackColor(clip!.colorIndex).opacity(playing ? 0.85 : 0.45),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(queued ? Color.white : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let clip {
                Button(clip.loop ? "Loop Off" : "Loop On") {
                    model.updateTrack(track.id) { $0.clipSlots[si]?.loop.toggle() }
                }
                if case let .midi(data) = clip.content {
                    Button("Quantize 1/16") {
                        model.updateTrack(track.id) { $0.clipSlots[si]?.content = .midi(data.quantized(grid: 0.25)) }
                    }
                    Button("Double Length") {
                        var d = data
                        d.notes += data.notes.map { n in var c = n; c.start += data.lengthBeats; return c }
                        d.lengthBeats *= 2
                        model.updateTrack(track.id) { $0.clipSlots[si]?.content = .midi(d) }
                    }
                }
                Button("Delete Clip", role: .destructive) {
                    model.updateTrack(track.id) { $0.clipSlots[si] = nil }
                }
            } else if track.kind != .audio && track.kind != .group {
                Button("New 1-Bar MIDI Clip") { newClip(track, si, bars: 1) }
                Button("New 4-Bar MIDI Clip") { newClip(track, si, bars: 4) }
            }
        }
    }

    private func newClip(_ track: Track, _ si: Int, bars: Double) {
        let len = model.project.timeSignature.quarterNotesPerBar * bars
        model.updateTrack(track.id) {
            $0.clipSlots[si] = Clip(name: "Clip \(si + 1)", content: .midi(MIDIClipData(lengthBeats: len)), colorIndex: track.colorIndex)
        }
    }

    private func trackFooter(_ track: Track) -> some View {
        HStack(spacing: 4) {
            toggle("A", on: track.isArmed, color: .red) { model.setArmed(track.id, !track.isArmed) }
            toggle("S", on: track.isSoloed, color: .blue) { model.updateTrack(track.id, rebuildGraph: false) { $0.isSoloed.toggle() } }
            toggle("M", on: !track.isMuted, color: .yellow) { model.updateTrack(track.id, rebuildGraph: false) { $0.isMuted.toggle() } }
            MeterBar(left: live.trackPeaks[track.id]?.0 ?? 0, right: live.trackPeaks[track.id]?.1 ?? 0)
                .frame(height: 12)
        }
        .frame(width: cellW)
    }

    private func toggle(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.bold()).frame(width: 26, height: 22)
                .background(on ? color.opacity(0.8) : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    private var sceneColumn: some View {
        VStack(spacing: 2) {
            Text("Scenes").font(.headline).frame(width: 110, height: 44)
            ForEach(Array(model.project.scenes.enumerated()), id: \.element.id) { si, scene in
                Button { model.launchScene(si) } label: {
                    HStack {
                        Image(systemName: "play.fill").font(.caption)
                        Text(scene.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        if let t = scene.tempo { Text("\(Int(t))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 6)
                    .frame(width: 110, height: cellH)
                    .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Set Scene Tempo to Current") { model.project.scenes[si].tempo = model.project.tempo }
                    Button("Clear Scene Tempo") { model.project.scenes[si].tempo = nil }
                }
            }
            Button { model.engine.send(.stopAllClips) } label: {
                Text("Stop All").font(.caption.bold()).frame(width: 110, height: 28)
            }
            .buttonStyle(.bordered)
            Button { model.project.addScene(); model.rebuild() } label: {
                Label("Scene", systemImage: "plus").font(.caption).frame(width: 110, height: 28)
            }
        }
    }

    private var addTrackMenu: some View {
        Menu {
            ForEach(TrackKind.allCases, id: \.self) { k in
                Button(k.label) { model.addTrack(k) }
            }
        } label: {
            Label("Track", systemImage: "plus").frame(width: 90, height: 44)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
