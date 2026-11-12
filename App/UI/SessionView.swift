import FM1Core
import SwiftUI

/// Clip launcher: tracks across, scenes down. Tap a header to select a track
/// (its devices appear below); tap a clip to launch it; tap an empty slot on an
/// instrument/MIDI track to draw a new clip.
struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: UIRouter

    private let colW: CGFloat = 148
    private let padH: CGFloat = 46

    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(model.project.tracks.enumerated()), id: \.element.id) { ti, track in
                    column(ti, track)
                }
                AddTrackTile(height: padH)
                Spacer(minLength: 16)
                sceneColumn
            }
            .padding(16)
        }
        .background(Theme.bg)
        .alert("Rename track", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") {
                if let id = renameTarget { model.updateTrack(id, rebuildGraph: false) { $0.name = renameText } }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: Track column

    private func column(_ ti: Int, _ track: Track) -> some View {
        let selected = model.selectedTrackID == track.id
        return VStack(spacing: 5) {
            header(track, selected: selected)
            ForEach(0..<model.project.scenes.count, id: \.self) { si in
                clipPad(ti, track, si)
            }
            Button {
                Haptics.tick()
                model.stopTrack(ti)
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            footer(track)
        }
        .frame(width: colW)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.surface : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? trackColor(track.colorIndex).opacity(0.6) : Color.clear, lineWidth: 1))
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private func header(_ track: Track, selected: Bool) -> some View {
        Button {
            Haptics.tick()
            model.selectTrack(track.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(trackColor(track.colorIndex)).frame(width: 4, height: 14)
                    Text(track.name).font(Theme.title(13)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: track.kind.glyph).font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                Text(deviceSummary(track)).font(Theme.mono(9.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.raisedHi : Theme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .contextMenu {
            Button("Rename…") { renameText = track.name; renameTarget = track.id }
            Menu("Color") {
                ForEach(0..<trackPalette.count, id: \.self) { c in
                    Button("Color \(c + 1)") { model.updateTrack(track.id, rebuildGraph: false) { $0.colorIndex = c } }
                }
            }
            Menu("Group into") {
                Button("None") { model.updateTrack(track.id) { $0.groupID = nil } }
                ForEach(model.project.tracks.filter { $0.kind == .group && $0.id != track.id }) { g in
                    Button(g.name) { model.updateTrack(track.id) { $0.groupID = g.id } }
                }
            }
            Button("Delete Track", role: .destructive) { model.removeTrack(track.id) }
        }
    }

    private func deviceSummary(_ track: Track) -> String {
        if let inst = track.devices.first(where: { $0.component.role == .instrument || $0.component.role == .generator }) {
            let fx = track.devices.filter { $0.component.role.isEffect }.count
            return fx > 0 ? "\(inst.component.name) +\(fx)" : inst.component.name
        }
        switch track.kind {
        case .instrument: return "No instrument"
        case .audio: return track.audioInputs.isEmpty ? "No input" : "In \(pairName(track.audioInputs))"
        case .midi: return track.midiOutput?.name ?? "No MIDI out"
        case .externalInstrument: return track.midiOutput?.name ?? "No MIDI out"
        case .group: return "Group"
        }
    }

    // MARK: Clip pads

    private func clipPad(_ ti: Int, _ track: Track, _ si: Int) -> some View {
        let clip = si < track.clipSlots.count ? track.clipSlots[si] : nil
        let playing = live.playingSlots[track.id] == si
        let queued = live.queuedSlots[track.id] == si
        let color = trackColor(clip?.colorIndex ?? track.colorIndex)
        let canDraw = track.kind == .instrument || track.kind == .midi || track.kind == .externalInstrument

        return Button {
            Haptics.tick()
            if clip != nil {
                model.launch(track: ti, slot: si)
            } else if canDraw {
                model.createMIDIClip(trackID: track.id, slot: si, bars: 1)
                model.selectTrack(track.id)
                router.clipEditor = .init(trackID: track.id, slot: si)
            }
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(clip == nil ? Theme.surface : color.opacity(playing ? 0.95 : 0.32))
                if let clip {
                    HStack(spacing: 6) {
                        Image(systemName: playing ? "play.fill" : (queued ? "clock" : "play"))
                            .font(.system(size: 9, weight: .bold))
                        Text(clip.name).font(Theme.mono(10.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(playing ? Color.black.opacity(0.85) : Theme.text)
                    .padding(.horizontal, 9)
                } else {
                    Circle().fill(Theme.faint.opacity(0.6)).frame(width: 4, height: 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: padH)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(queued ? Theme.accent : Theme.line, lineWidth: queued ? 2 : 1)
                    .opacity(queued ? 1 : (clip == nil ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .animation(.easeOut(duration: 0.15), value: playing)
        .contextMenu { clipMenu(track, si, clip) }
        .overlay(alignment: .topTrailing) {
                if let clip, case .midi = clip.content {
                    Button {
                        Haptics.tick()
                        model.selectTrack(track.id)
                        router.clipEditor = .init(trackID: track.id, slot: si)
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(playing ? Color.black.opacity(0.7) : Theme.dim)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }
    }

    @ViewBuilder
    private func clipMenu(_ track: Track, _ si: Int, _ clip: Clip?) -> some View {
        if let clip {
            if case let .midi(data) = clip.content {
                Button("Edit Notes") { router.clipEditor = .init(trackID: track.id, slot: si) }
                Button("Quantize 1/16") { model.setClipData(trackID: track.id, slot: si, data.quantized(grid: 0.25)) }
                Button("Double Length") {
                    var d = data
                    d.notes += data.notes.map { n in var c = n; c.start += data.lengthBeats; return c }
                    d.lengthBeats *= 2
                    model.setClipData(trackID: track.id, slot: si, d)
                }
            }
            Button(clip.loop ? "Loop Off" : "Loop On") {
                model.updateTrack(track.id) { $0.clipSlots[si]?.loop.toggle() }
            }
            Button("Delete Clip", role: .destructive) {
                model.updateTrack(track.id) { $0.clipSlots[si] = nil }
            }
        } else if track.kind != .audio && track.kind != .group {
            Button("New 1-Bar Clip") { model.createMIDIClip(trackID: track.id, slot: si, bars: 1) }
            Button("New 2-Bar Clip") { model.createMIDIClip(trackID: track.id, slot: si, bars: 2) }
            Button("New 4-Bar Clip") { model.createMIDIClip(trackID: track.id, slot: si, bars: 4) }
        }
    }

    // MARK: Footer

    private func footer(_ track: Track) -> some View {
        HStack(spacing: 4) {
            KeyCap("●", isOn: track.isArmed, onColor: Theme.record, width: 28, height: 24) {
                model.setArmed(track.id, !track.isArmed)
            }
            KeyCap("S", isOn: track.isSoloed, onColor: Theme.solo, width: 28, height: 24) {
                model.updateTrack(track.id, rebuildGraph: false) { $0.isSoloed.toggle() }
            }
            KeyCap("M", isOn: track.isMuted, onColor: Theme.mute, width: 28, height: 24) {
                model.updateTrack(track.id, rebuildGraph: false) { $0.isMuted.toggle() }
            }
            Spacer(minLength: 2)
            StereoMeter(left: live.trackPeaks[track.id]?.0 ?? 0, right: live.trackPeaks[track.id]?.1 ?? 0,
                        vertical: true, segments: 10)
                .frame(width: 9, height: 24)
        }
    }

    // MARK: Scenes

    private var sceneColumn: some View {
        VStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Caps("Scenes")
                Text("\(model.project.scenes.count)").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            .frame(width: 110, height: 50, alignment: .leading)
            ForEach(Array(model.project.scenes.enumerated()), id: \.element.id) { si, scene in
                Button {
                    Haptics.click()
                    model.launchScene(si)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                        Text(scene.name).font(Theme.mono(10.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let t = scene.tempo { Text("\(Int(t))").font(Theme.mono(9)).foregroundStyle(Theme.dim) }
                    }
                    .padding(.horizontal, 9)
                    .frame(width: 110, height: padH)
                    .panel(Theme.raised, radius: 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .contextMenu {
                    Button("Set Scene Tempo to Current") { model.project.scenes[si].tempo = model.project.tempo }
                    Button("Clear Scene Tempo") { model.project.scenes[si].tempo = nil }
                }
            }
            SlabButton(title: "Stop all", systemImage: "stop.fill") { model.engine.send(.stopAllClips) }
                .frame(width: 110)
            SlabButton(title: "Scene", systemImage: "plus") { model.project.addScene(); model.rebuild() }
                .frame(width: 110)
        }
        .padding(.top, 6)
    }
}

/// The "+" column: choose what kind of track to add. A new instrument track
/// opens the plugin browser straight away.
struct AddTrackTile: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: UIRouter
    let height: CGFloat
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tick()
            open = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                Caps("Track")
            }
            .foregroundStyle(Theme.dim)
            .frame(width: 96, height: 120)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .padding(.top, 6)
        .popover(isPresented: $open, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Caps("New track").padding(.bottom, 4)
                ForEach([TrackKind.instrument, .audio, .midi, .externalInstrument, .group], id: \.self) { k in
                    Button {
                        open = false
                        let id = model.addTrack(k)
                        if k == .instrument {
                            router.browser = .init(trackID: id, role: .instrument)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: k.glyph).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.label).font(Theme.title(14)).foregroundStyle(Theme.text)
                                Text(k.blurb).font(.system(size: 11)).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .frame(width: 300)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                }
            }
            .padding(14)
            .background(Theme.surface)
            .presentationCompactAdaptation(.popover)
        }
    }
}
