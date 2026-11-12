import AVFoundation
import Combine
import CoreMIDI
import FM1Core
import SwiftUI

/// Live values the UI polls ~30x per second (meters, playhead, CPU).
@MainActor
final class LiveState: ObservableObject {
    @Published var position = "1.1.1"
    @Published var beat: Double = 0
    @Published var tempo: Double = 120
    @Published var isPlaying = false
    @Published var cpu: Float = 0
    @Published var trackPeaks: [UUID: (Float, Float)] = [:]
    @Published var masterPeak: (Float, Float) = (0, 0)
    @Published var inputPeaks: [Float] = []
    @Published var playingSlots: [UUID: Int] = [:]
    @Published var queuedSlots: [UUID: Int] = [:]
    @Published var externalTempo: Double?
    @Published var lastMIDI: String = ""
}

/// The app's brain on the main thread: owns the project, the engine, MIDI,
/// plugin instances, and turns project edits into render graphs.
@MainActor
final class AppModel: ObservableObject {
    @Published var project = Project(name: "Jam")
    @Published private(set) var audioStatus = AudioIO.Status()
    @Published private(set) var midiSources: [MIDIManager.Endpoint] = []
    @Published private(set) var midiDestinations: [MIDIManager.Endpoint] = []
    @Published private(set) var loadingDevices: Set<UUID> = []
    @Published private(set) var failedDevices: [UUID: String] = [:]
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var ioConfig = AudioIO.Configuration()
    @Published var learningMacro: UUID?

    /// The track the device strip, keyboard and clip editor work on.
    @Published private(set) var selectedTrackID: UUID?
    /// Manual "Audio input" switch on the I/O page. Never persisted: the app always opens with input off.
    @Published private(set) var inputSwitch = false
    @Published private(set) var availableInputs: [AudioIO.InputPort] = []
    @Published private(set) var preferredInputUID: String? = UserDefaults.standard.string(forKey: "preferredInputUID")
    private var inputRequestPending = false

    let live = LiveState()
    let catalog = PluginCatalog()
    let engine = AudioEngine()
    let midi = MIDIManager()

    private(set) var plugins: [UUID: HostedPlugin] = [:]          // by DeviceSlot.id
    private var nodes: [UUID: TrackNode] = [:]
    private var inboxes: [UUID: SPSCQueue<RawMIDI>] = [:]
    private var sendGains: [UUID: AtomicFloat] = [:]
    private var macroValues: [UUID: AtomicDouble] = [:]
    private var audioClipCache: [String: AudioClipBuffer] = [:]
    private var pluginSourceIDs: [EndpointID] = []
    private let masterGain = AtomicFloat(1)

    private let writer = RecordingWriter()
    private var activeStreams: [RecordingStream] = []
    private var midiRecorders: [Int: MIDIClipRecorder] = [:]
    private var recordStartBeat = 0.0

    private var uiTimer: Timer?
    private let clockFollow = ClockFollowState()

    init() {}

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            body()
        }
    }

    // MARK: Startup

    func start() async {
        // No microphone permission request here: input is off until an input feature is switched on.
        engine.io.inputEnabled = false
        engine.io.preferredInputUID = preferredInputUID
        engine.io.configuration = ioConfig
        engine.io.onRouteChange = { [weak self] status in
            Task { @MainActor in self?.hardwareChanged(status) }
        }
        do {
            try engine.start()
            audioStatus = engine.currentStatus
        } catch {
            errorMessage = "Audio failed to start: \(error.localizedDescription)"
        }
        do {
            midi.onSetupChanged = { [weak self] in
                Task { @MainActor in self?.midiSetupChanged() }
            }
            installMIDIMonitor()
            try midi.start()
            midi.startSender(engine: engine)
        } catch {
            errorMessage = "MIDI failed to start: \(error)"
        }
        loadLastProjectOrDefault()
        startUITimer()
    }

    private func hardwareChanged(_ status: AudioIO.Status) {
        let rateChanged = status.sampleRate != audioStatus.sampleRate
        audioStatus = status
        availableInputs = engine.io.availableInputs()
        engine.syncFromIO()
        if rateChanged {
            // Plugins must be re-prepared at the new rate, off the audio thread.
            engine.publishEmpty()
            audioClipCache.removeAll()
            after(0.15) { [weak self] in
                guard let self else { return }
                for p in self.plugins.values { try? p.reconfigure(sampleRate: status.sampleRate) }
                self.rebuild()
            }
        } else {
            rebuild()
        }
    }

    func applyIOConfig() {
        engine.io.configuration = ioConfig
        engine.io.restart()
    }

    private func midiSetupChanged() {
        midiSources = midi.sources
        midiDestinations = midi.destinations
        ensureDefaultMIDIRoutes()   // a keyboard plugged in later still plays the armed track
        rebuild() // output port table may have changed
    }

    /// Every MIDI input can reach every instrument/MIDI track; only the armed
    /// track's routes are enabled (Ableton-style). Adds routes for sources that
    /// appeared after the track was made.
    private func ensureDefaultMIDIRoutes() {
        for t in project.tracks where t.kind != .audio && t.kind != .group {
            for src in midiSources where !project.midiRoutes.contains(where: { $0.source == src.id && $0.destination == t.endpoint }) {
                var f = MIDIFilter()
                f.clock = false
                f.transport = false
                project.midiRoutes.append(MIDIRoute(source: src.id, destination: t.endpoint, isEnabled: t.isArmed, filter: f))
            }
        }
    }

    // MARK: Audio input (microphone / interface inputs)

    /// Input runs only for an explicit input feature: the I/O page's input switch,
    /// an audio/external-synth track armed for recording, or input monitoring set to On.
    /// Playing instruments, effects, clips and MIDI never needs it.
    var inputNeeded: Bool {
        inputSwitch || project.tracks.contains { t in
            (t.kind == .audio || t.kind == .externalInstrument) && (t.isArmed || t.monitor == .on)
        }
    }

    func setInputSwitch(_ on: Bool) {
        inputSwitch = on
        updateInputState()
    }

    func selectInput(_ uid: String?) {
        preferredInputUID = uid
        UserDefaults.standard.set(uid, forKey: "preferredInputUID")
        engine.io.preferredInputUID = uid
        if engine.io.inputEnabled { engine.io.restart() }
    }

    /// Starts or releases the hardware input to match `inputNeeded`.
    /// Microphone permission is requested here, the first time input is actually needed.
    private func updateInputState() {
        let need = inputNeeded
        guard need != engine.io.inputEnabled, !inputRequestPending else { return }
        guard need else {
            setHardwareInput(false)
            return
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            setHardwareInput(true)
        case .undetermined:
            inputRequestPending = true
            Task { @MainActor in
                let ok = await AudioIO.requestMicrophoneAccess()
                self.inputRequestPending = false
                if ok { self.updateInputState() } else { self.inputDenied() }
            }
        default:
            inputDenied()
        }
    }

    private func setHardwareInput(_ on: Bool) {
        engine.io.inputEnabled = on
        engine.io.preferredInputUID = preferredInputUID
        engine.io.restart()   // -> onRouteChange -> hardwareChanged -> rebuild
    }

    private func inputDenied() {
        inputSwitch = false
        for i in project.tracks.indices where project.tracks[i].kind == .audio || project.tracks[i].kind == .externalInstrument {
            project.tracks[i].isArmed = false
            if project.tracks[i].monitor == .on { project.tracks[i].monitor = .auto }
        }
        errorMessage = "Mod-Lab isn't allowed to use audio input. To record or monitor, allow it in Settings › Privacy & Security › Microphone."
        rebuild()
    }

    func setMonitor(_ trackID: UUID, _ mode: MonitorMode) {
        updateTrack(trackID) { $0.monitor = mode }
    }

    // MARK: Selection & playing

    /// Selecting an instrument/MIDI track arms it (exclusive), so every MIDI
    /// keyboard and the on-screen keys play it, like Ableton's auto-arm.
    func selectTrack(_ id: UUID?) {
        selectedTrackID = id
        guard let id, let t = project.track(id), t.kind == .instrument || t.kind == .midi else { return }
        if !t.isArmed { setArmed(id, true) }
    }

    var selectedTrack: Track? { selectedTrackID.flatMap { project.track($0) } }

    /// Note from the on-screen keyboard to the selected track.
    func playNote(_ note: Int, on: Bool, velocity: Int = 100) {
        guard let id = selectedTrackID, let ti = project.tracks.firstIndex(where: { $0.id == id }),
              (0...127).contains(note) else { return }
        let raw = on
            ? RawMIDI(b0: 0x90, b1: UInt8(note), b2: UInt8(max(1, min(velocity, 127))), length: 3)
            : RawMIDI(b0: 0x80, b1: UInt8(note), b2: 0, length: 3)
        engine.send(.liveMIDI(track: ti, raw: raw))
    }

    // MARK: Clip editing

    func createMIDIClip(trackID: UUID, slot: Int, bars: Double = 1) {
        guard let t = project.track(trackID), slot < t.clipSlots.count else { return }
        let len = project.timeSignature.quarterNotesPerBar * bars
        updateTrack(trackID) {
            $0.clipSlots[slot] = Clip(name: "Clip \(slot + 1)", content: .midi(MIDIClipData(lengthBeats: len)), colorIndex: t.colorIndex)
        }
    }

    /// Replaces a clip's notes. A playing clip is relaunched so the edit is heard
    /// (it restarts on the next launch-quantize boundary).
    func setClipData(trackID: UUID, slot: Int, _ data: MIDIClipData) {
        updateTrack(trackID) { t in
            guard slot < t.clipSlots.count, t.clipSlots[slot] != nil else { return }
            t.clipSlots[slot]?.content = .midi(data)
        }
        if live.playingSlots[trackID] == slot, let ti = project.tracks.firstIndex(where: { $0.id == trackID }) {
            launch(track: ti, slot: slot)
        }
    }

    // MARK: MIDI monitor, clock follow, macro learn

    private func installMIDIMonitor() {
        let follow = clockFollow
        let engine = self.engine
        midi.onMessage = { @Sendable [weak self] m, src, ts in
            // CoreMIDI thread: never touch main-actor state directly here.
            if follow.isFollowing(src) {
                switch m {
                case .clock:
                    let state = follow.handle(m, at: Self.seconds(ts))
                    if let t = state.tempo { engine.externalTempo.value = t }
                    engine.externalBeat.value = state.beat
                case .start: _ = follow.handle(m, at: 0); engine.syncCommands.push(.start)
                case .continue: _ = follow.handle(m, at: 0); engine.syncCommands.push(.continue)
                case .stop: _ = follow.handle(m, at: 0); engine.syncCommands.push(.stop)
                case let .songPosition(p):
                    _ = follow.handle(m, at: 0)
                    engine.syncCommands.push(.songPosition(beat: Double(p) / 4))
                default: break
                }
            }
            if case .controlChange = m {
                for (mapping, atom) in follow.macroSnapshot() {
                    if let v = mapping.matches(m, from: src) { atom.value = Double(v) / 127 }
                }
            }
            if m.isRealtime { return }
            let text = "\(src.name): \(m)"
            Task { @MainActor in
                guard let self else { return }
                self.live.lastMIDI = text
                if let target = self.learningMacro, case let .controlChange(ch, cc, _) = m {
                    self.project.macroMappings.removeAll { $0.modulator == target }
                    self.project.macroMappings.append(MacroMapping(source: src, channel: ch, controller: cc, modulator: target))
                    self.learningMacro = nil
                    self.rebuild()
                }
            }
        }
    }

    nonisolated static func seconds(_ hostTime: MIDITimeStamp) -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let t = hostTime == 0 ? mach_absolute_time() : hostTime
        return Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    // MARK: Graph building

    /// Turns the project into a render graph and swaps it in. Cheap enough to
    /// call after any structural edit (add track, route, plugin, CV...).
    func rebuild() {
        let p = project
        let sr = audioStatus.sampleRate
        let maxFrames = engine.maxFrames

        // MIDI destinations the audio thread can address by index.
        var destTable: [EndpointID] = []
        func port(_ id: EndpointID?) -> Int {
            guard let id else { return -1 }
            if let i = destTable.firstIndex(of: id) { return i }
            destTable.append(id)
            return destTable.count - 1
        }

        // Plugin MIDI sources (for routing a plugin's MIDI out anywhere).
        pluginSourceIDs = []

        var trackRenders: [TrackRender] = []
        var liveIDs = Set<UUID>()
        for track in p.tracks {
            liveIDs.insert(track.id)
            let node = nodes[track.id] ?? TrackNode(id: track.id, maxFrames: maxFrames)
            nodes[track.id] = node
            node.volume.value = Float(Decibels.toGain(track.volumeDB))
            node.pan.value = Float(track.pan)
            node.muted.value = track.isMuted
            node.soloed.value = track.isSoloed
            node.armed.value = track.isArmed

            let inbox = inboxes[track.id] ?? SPSCQueue<RawMIDI>(capacity: 1024, initial: RawMIDI())
            inboxes[track.id] = inbox

            var chain: [HostedPlugin] = []
            for slot in track.devices {
                guard let h = plugins[slot.id] else { continue }
                h.bypassed.value = slot.isBypassed
                h.mix.value = Float(slot.mix)
                h.globalMIDIOut = engine.pluginMIDIOut
                h.globalPort = UInt16(pluginSourceIDs.count)
                pluginSourceIDs.append(.plugin(slot.id))
                chain.append(h)
            }
            let instrumentIndex = chain.firstIndex { $0.hasMIDIInput } ?? -1

            let sends = track.sends.map { s -> SendRender in
                let g = sendGains[s.id] ?? AtomicFloat(1)
                g.value = Float(Decibels.toGain(s.levelDB))
                sendGains[s.id] = g
                return SendRender(left: s.outputChannels.first ?? -1,
                                  right: s.outputChannels.count > 1 ? s.outputChannels[1] : (s.outputChannels.first ?? -1),
                                  preFader: s.preFader, gain: g)
            }

            let clips: [ClipRender?] = track.clipSlots.map { clip in
                guard let clip else { return nil }
                switch clip.content {
                case let .midi(data): return .midi(data, loop: clip.loop)
                case let .audio(fileName, _, _):
                    guard let buf = audioClip(named: fileName, sampleRate: sr) else { return nil }
                    return .audio(buf, loop: clip.loop)
                }
            }

            let outs = track.outputChannels
            trackRenders.append(TrackRender(
                node: node,
                kind: track.kind,
                inputs: track.audioInputs,
                monitorAlways: track.monitor == .on,
                monitorWhenArmed: track.monitor == .auto,
                outLeft: outs?.first ?? -1,
                outRight: outs.map { $0.count > 1 ? $0[1] : ($0.first ?? -1) } ?? -1,
                groupIndex: track.groupID.flatMap { gid in p.tracks.firstIndex { $0.id == gid } } ?? -1,
                plugins: chain,
                instrumentIndex: instrumentIndex,
                midiOutPort: port(track.midiOutput),
                midiOutChannel: track.midiOutputChannel.map(Int.init) ?? -1,
                sends: sends,
                clips: clips,
                inbox: inbox,
                recordStream: activeStreams.first { $0.trackID == track.id }))
        }
        nodes = nodes.filter { liveIDs.contains($0.key) }
        inboxes = inboxes.filter { liveIDs.contains($0.key) }

        let clockPorts = p.clock.sendClockTo.map { port($0) }

        // Modulators
        for m in p.modulators {
            if case let .macro(v) = m.kind, macroValues[m.id] == nil { macroValues[m.id] = AtomicDouble(v) }
        }
        let macroAtoms: [AtomicDouble?] = p.modulators.map { m in
            if case .macro = m.kind { return macroValues[m.id] }
            return nil
        }
        let compiled = CompiledModulationMatrix(modulators: p.modulators, connections: p.modulation)
        let modTargets: [ModTargetRender] = compiled.targets.enumerated().map { i, target in
            let base = compiled.bases[i]
            switch target {
            case let .pluginParameter(_, device, address):
                guard let h = plugins[device], let param = h.au.parameterTree?.parameter(withAddress: address) else {
                    return ModTargetRender(kind: .none, base: 0)
                }
                let range = max(param.maxValue - param.minValue, 1e-9)
                let current = Double((param.value - param.minValue) / range)
                return ModTargetRender(kind: .plugin(h, address, min: param.minValue, max: param.maxValue), base: base ?? current)
            case let .trackVolume(tid):
                guard let ti = p.tracks.firstIndex(where: { $0.id == tid }) else { return ModTargetRender(kind: .none, base: 0) }
                return ModTargetRender(kind: .volume(ti), base: base ?? 1)
            case let .trackPan(tid):
                guard let ti = p.tracks.firstIndex(where: { $0.id == tid }) else { return ModTargetRender(kind: .none, base: 0) }
                return ModTargetRender(kind: .pan(ti), base: base ?? (p.tracks[ti].pan + 1) / 2)
            case let .sendLevel(tid, si):
                guard let ti = p.tracks.firstIndex(where: { $0.id == tid }) else { return ModTargetRender(kind: .none, base: 0) }
                return ModTargetRender(kind: .send(ti, si), base: base ?? 1)
            case .cvOutput:
                return ModTargetRender(kind: .none, base: 0) // CV outputs read modulators directly
            }
        }

        // CV
        let cv: [CVRender] = p.cvOutputs.map { c in
            var trackIndex = -1
            var modIndex = -1
            var bipolar = false
            switch c.source {
            case let .pitch(t, _), let .gate(t), let .trigger(t), let .velocity(t):
                trackIndex = p.tracks.firstIndex { $0.id == t } ?? -1
            case let .modulator(id):
                modIndex = p.modulators.firstIndex { $0.id == id } ?? -1
                if modIndex >= 0 {
                    switch p.modulators[modIndex].kind {
                    case let .lfo(_, _, _, bi): bipolar = bi
                    case .random: bipolar = true
                    default: bipolar = false
                    }
                }
            default: break
            }
            return CVRender(config: c, trackIndex: trackIndex, modulatorIndex: modIndex, bipolar: bipolar)
        }

        masterGain.value = Float(Decibels.toGain(p.masterVolumeDB))
        engine.timeSigBeats.value = p.timeSignature.beatsPerBar
        engine.timeSigNote.value = p.timeSignature.noteValue
        engine.clockSource.value = p.clock.source == .internalClock ? 0 : (p.clock.source == .externalMIDI ? 1 : 2)
        engine.clockOffsetSeconds.value = p.clock.clockOffsetMs / 1000
        engine.link.isEnabled = p.clock.source == .abletonLink
        clockFollow.configure(input: p.clock.source == .externalMIDI ? p.clock.externalInput : nil,
                              macros: p.macroMappings.compactMap { m in macroValues[m.modulator].map { (m, $0) } })

        let graph = RenderGraph(
            tracks: trackRenders,
            masterChannels: p.masterOutputChannels,
            masterGain: masterGain,
            inputChannels: audioStatus.inputChannels,
            midiDestinations: destTable,
            clockPorts: clockPorts,
            cvOutputs: cv,
            modulators: p.modulators,
            macroValues: macroAtoms,
            connections: p.modulation,
            modTargets: modTargets,
            launchQuantization: p.launchQuantization,
            metronome: p.metronomeOn,
            metronomeChannels: p.metronomeOutputChannels,
            recordMaster: activeStreams.first { $0.trackID == nil },
            maxFrames: maxFrames)

        midi.setOutputPortTable(destTable)
        midi.setPluginSourceTable(pluginSourceIDs)
        midi.setTrackInboxes(Dictionary(uniqueKeysWithValues: p.tracks.compactMap { t in inboxes[t.id].map { (t.endpoint, $0) } }))
        for r in midi.router.setRoutes(p.midiRoutes) { midi.deliver(r) }
        engine.publish(graph)
        updateInputState()
    }

    private func audioClip(named name: String, sampleRate: Double) -> AudioClipBuffer? {
        if let c = audioClipCache[name] { return c }
        let url = projectFolder.appendingPathComponent("Audio").appendingPathComponent(name)
        guard let buf = try? AudioClipBuffer(url: url, sampleRate: sampleRate) else { return nil }
        audioClipCache[name] = buf
        return buf
    }

    // MARK: Tracks

    /// Adds a track and selects it. Audio/external-synth tracks are created
    /// unarmed so adding one never switches the input on by itself.
    @discardableResult
    func addTrack(_ kind: TrackKind) -> UUID {
        var t = project.addTrack(kind)
        let idx = project.tracks.count - 1
        switch kind {
        case .audio:
            t.audioInputs = [0, 1]          // first stereo pair; change per track
        case .externalInstrument:
            t.audioInputs = [0, 1]
            t.midiOutput = midiDestinations.first?.id
        case .instrument, .midi, .group:
            break
        }
        project.tracks[idx] = t
        ensureDefaultMIDIRoutes()
        rebuild()
        selectTrack(t.id)
        return t.id
    }

    func removeTrack(_ id: UUID) {
        if let t = project.track(id) { for d in t.devices { plugins[d.id] = nil } }
        project.removeTrack(id)
        if selectedTrackID == id { selectedTrackID = project.tracks.first?.id }
        project.cvOutputs.removeAll { cv in
            switch cv.source {
            case let .pitch(t, _), let .gate(t), let .trigger(t), let .velocity(t): return t == id
            default: return false
            }
        }
        rebuild()
    }

    func updateTrack(_ id: UUID, rebuildGraph: Bool = true, _ change: (inout Track) -> Void) {
        guard let i = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&project.tracks[i])
        let t = project.tracks[i]
        // Fast path: fader moves go straight to the audio thread.
        if let n = nodes[id] {
            n.volume.value = Float(Decibels.toGain(t.volumeDB))
            n.pan.value = Float(t.pan)
            n.muted.value = t.isMuted
            n.soloed.value = t.isSoloed
            n.armed.value = t.isArmed
        }
        for s in t.sends { sendGains[s.id]?.value = Float(Decibels.toGain(s.levelDB)) }
        if rebuildGraph { rebuild() }
    }

    /// Arming a track enables its "all inputs -> track" routes (Live-style).
    func setArmed(_ id: UUID, _ armed: Bool, exclusive: Bool = true) {
        for i in project.tracks.indices {
            let t = project.tracks[i]
            if t.id == id {
                project.tracks[i].isArmed = armed
            } else if exclusive && armed && t.kind != .audio && project.tracks[i].isArmed && t.kind != .group {
                project.tracks[i].isArmed = false
            }
        }
        for r in project.midiRoutes.indices {
            if let t = project.tracks.first(where: { $0.endpoint == project.midiRoutes[r].destination }), t.kind != .audio {
                if project.midiRoutes[r].source.kind != .plugin && project.midiRoutes[r].source.kind != .internalClock {
                    project.midiRoutes[r].isEnabled = t.isArmed
                }
            }
        }
        rebuild()
    }

    // MARK: Plugins

    func addPlugin(_ entry: PluginCatalog.Entry, to trackID: UUID) {
        guard let i = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let slot = DeviceSlot(component: entry.component)
        // Instruments / MIDI FX go first, effects after.
        let role = entry.component.role
        if role == .midiProcessor {
            project.tracks[i].devices.insert(slot, at: 0)
        } else if role == .instrument || role == .generator {
            let insertAt = project.tracks[i].devices.lastIndex { $0.component.role == .midiProcessor }.map { $0 + 1 } ?? 0
            project.tracks[i].devices.insert(slot, at: insertAt)
        } else {
            project.tracks[i].devices.append(slot)
        }
        Task { await load(slot) }
    }

    func removePlugin(_ deviceID: UUID, from trackID: UUID) {
        updateTrack(trackID, rebuildGraph: false) { $0.devices.removeAll { $0.id == deviceID } }
        project.modulation.removeAll {
            if case let .pluginParameter(_, d, _) = $0.target { return d == deviceID }
            return false
        }
        rebuild()
        // Release after the old graph is retired.
        after(1.5) { [weak self] in
            self?.plugins[deviceID] = nil
        }
    }

    func moveDevice(in trackID: UUID, from: IndexSet, to: Int) {
        updateTrack(trackID) { $0.devices.move(fromOffsets: from, toOffset: to) }
    }

    func load(_ slot: DeviceSlot) async {
        loadingDevices.insert(slot.id)
        defer { loadingDevices.remove(slot.id) }
        do {
            let au = try await AUAudioUnit.instantiate(with: PluginCatalog.description(for: slot.component), options: [])
            let hosted = try HostedPlugin(deviceID: slot.id, component: slot.component, au: au,
                                          sampleRate: audioStatus.sampleRate, maxFrames: engine.maxFrames,
                                          clock: engine.clockInfo)
            if let state = slot.state { hosted.restoreState(state) }
            plugins[slot.id] = hosted
            failedDevices[slot.id] = nil
            rebuild()
        } catch {
            failedDevices[slot.id] = "\(slot.component.name) couldn't load: \(error.localizedDescription). Is the app still installed?"
        }
    }

    func plugin(_ deviceID: UUID) -> HostedPlugin? { plugins[deviceID] }

    // MARK: Transport & clips

    func togglePlay() { engine.send(live.isPlaying ? .stop : .play) }
    func stop() { engine.send(.stop) }
    func setTempo(_ t: Double) {
        project.tempo = min(max(t, 20), 999)
        engine.send(.setTempo(project.tempo))
    }
    func launch(track: Int, slot: Int) { engine.send(.launchClip(track: track, slot: slot)) }
    func stopTrack(_ track: Int) { engine.send(.stopTrack(track: track)) }
    func launchScene(_ scene: Int) {
        if scene < project.scenes.count, let t = project.scenes[scene].tempo { setTempo(t) }
        engine.send(.launchScene(scene))
    }
    func panic() {
        engine.send(.panic)
        midi.panic()
    }

    func setMasterVolume(_ db: Double) {
        project.masterVolumeDB = db
        masterGain.value = Float(Decibels.toGain(db))
    }

    func setMacro(_ id: UUID, _ value: Double) {
        macroValues[id]?.value = value
        if let i = project.modulators.firstIndex(where: { $0.id == id }) {
            project.modulators[i].kind = .macro(value: value)
        }
    }

    // MARK: Recording

    func toggleRecord() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        let folder = projectFolder.appendingPathComponent("Audio")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.fileStamp()
        let sr = audioStatus.sampleRate
        let latency = engine.roundTripLatencyFrames
        var streams: [RecordingStream] = []
        for t in project.tracks where t.isArmed && (t.kind == .audio || t.kind == .externalInstrument) && !t.audioInputs.isEmpty {
            let url = folder.appendingPathComponent("\(Self.safe(t.name)) \(stamp).wav")
            if let s = try? RecordingStream(trackID: t.id, url: url, channels: t.audioInputs.count, sampleRate: sr, latencyFrames: latency) {
                streams.append(s)
            }
        }
        if project.recordMasterMix {
            let url = folder.appendingPathComponent("Master \(stamp).wav")
            if let s = try? RecordingStream(trackID: nil, url: url, channels: 2, sampleRate: sr, latencyFrames: 0) {
                streams.append(s)
            }
        }
        activeStreams = streams
        writer.start(streams)
        recordStartBeat = live.beat
        midiRecorders = [:]
        for (i, t) in project.tracks.enumerated() where t.isArmed && (t.kind == .instrument || t.kind == .midi || t.kind == .externalInstrument) {
            midiRecorders[i] = MIDIClipRecorder(startBeat: recordStartBeat)
        }
        rebuild()
        engine.isRecording.value = true
        isRecording = true
        if !live.isPlaying { engine.send(.play) }
    }

    func stopRecording() {
        engine.isRecording.value = false
        isRecording = false
        let endBeat = live.beat
        let streams = activeStreams
        activeStreams = []
        rebuild()
        drainRecordedMIDI()
        after(0.3) { [weak self] in
            guard let self else { return }
            let finished = self.writer.stop()
            _ = streams // keep alive until the writer has flushed them
            for s in finished { self.addRecordedAudioClip(s) }
        }
        let barLen = project.timeSignature.quarterNotesPerBar
        for (i, var rec) in midiRecorders where i < project.tracks.count {
            let data = rec.finish(atBeat: endBeat, barLength: barLen)
            guard !data.notes.isEmpty else { continue }
            placeClip(Clip(name: "Take \(Self.fileStamp())", content: .midi(data), colorIndex: project.tracks[i].colorIndex), track: i)
        }
        midiRecorders = [:]
        rebuild()
    }

    private func addRecordedAudioClip(_ s: RecordingStream) {
        guard let tid = s.trackID, let ti = project.tracks.firstIndex(where: { $0.id == tid }),
              let file = try? AVAudioFile(forReading: s.url) else { return }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let beats = seconds * project.tempo / 60
        placeClip(Clip(name: s.url.deletingPathExtension().lastPathComponent,
                       content: .audio(fileName: s.url.lastPathComponent, lengthBeats: beats, warp: false),
                       loop: false, colorIndex: project.tracks[ti].colorIndex), track: ti)
        rebuild()
    }

    private func placeClip(_ clip: Clip, track: Int) {
        if let empty = project.tracks[track].clipSlots.firstIndex(where: { $0 == nil }) {
            project.tracks[track].clipSlots[empty] = clip
        } else {
            project.addScene()
            project.tracks[track].clipSlots[project.tracks[track].clipSlots.count - 1] = clip
        }
    }

    private func drainRecordedMIDI() {
        engine.recordedMIDI.drain { ev in
            guard let m = ev.raw.message else { return }
            self.midiRecorders[Int(ev.track)]?.handle(m, atBeat: ev.beat)
        }
    }

    // MARK: UI polling

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        drainRecordedMIDI()
        var t = Transport(tempo: engine.tempoMirror.value, timeSignature: project.timeSignature)
        t.locate(engine.beatMirror.value)
        live.beat = t.beatPosition
        live.position = t.positionString
        live.tempo = t.tempo
        live.isPlaying = engine.playingMirror.value
        live.cpu = engine.cpuLoad.exchange(0)
        if project.clock.source != .internalClock { project.tempo = (live.tempo * 100).rounded() / 100 }

        var peaks: [UUID: (Float, Float)] = [:]
        var playing: [UUID: Int] = [:]
        var queued: [UUID: Int] = [:]
        for (id, n) in nodes {
            peaks[id] = (n.peakL.exchange(0), n.peakR.exchange(0))
            if n.playingSlot.value >= 0 { playing[id] = n.playingSlot.value }
            if n.queuedSlot.value >= 0 { queued[id] = n.queuedSlot.value }
        }
        live.trackPeaks = peaks
        live.playingSlots = playing
        live.queuedSlots = queued
        engine.withCurrentGraph { g in
            guard let g else { return }
            live.masterPeak = (g.masterPeakL.exchange(0), g.masterPeakR.exchange(0))
            live.inputPeaks = g.inputPeaks.map { $0.exchange(0) }
        }
        live.externalTempo = project.clock.source == .externalMIDI && engine.externalTempo.value > 0 ? engine.externalTempo.value : nil
    }

    // MARK: Persistence (Files app: On My iPad > Mod-Lab)

    static var projectsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var projectFolder: URL {
        Self.projectsRoot.appendingPathComponent(Self.safe(project.name))
    }

    func save() {
        // Capture plugin states.
        for ti in project.tracks.indices {
            for di in project.tracks[ti].devices.indices {
                let id = project.tracks[ti].devices[di].id
                if let s = plugins[id]?.saveState() { project.tracks[ti].devices[di].state = s }
            }
        }
        do {
            try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
            let url = projectFolder.appendingPathComponent("\(Self.safe(project.name)).modlab")
            try project.encoded().write(to: url, options: .atomic)
            UserDefaults.standard.set(url.path, forKey: "lastProject")
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func open(_ url: URL) {
        do {
            let p = try Project.decode(Data(contentsOf: url))
            replaceProject(p)
            UserDefaults.standard.set(url.path, forKey: "lastProject")
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func newProject(named name: String) {
        var p = Project(name: name, tempo: project.tempo)
        p.clock = project.clock
        p.cvOutputs = project.cvOutputs.filter {
            if case .clock = $0.source { return true }
            if case .reset = $0.source { return true }
            return false
        }
        replaceProject(p)
    }

    private func replaceProject(_ p: Project) {
        engine.send(.stop)
        engine.publishEmpty()
        plugins.removeAll()
        audioClipCache.removeAll()
        macroValues.removeAll()
        var p = p
        // Opening a project never starts the input: recording arm and input
        // monitoring on audio tracks are not restored.
        for i in p.tracks.indices where p.tracks[i].kind == .audio || p.tracks[i].kind == .externalInstrument {
            p.tracks[i].isArmed = false
            if p.tracks[i].monitor == .on { p.tracks[i].monitor = .auto }
        }
        project = p
        inputSwitch = false
        ensureDefaultMIDIRoutes()
        engine.send(.setTempo(p.tempo))
        rebuild()
        for t in p.tracks { for d in t.devices { Task { await load(d) } } }
        selectTrack(p.tracks.first { $0.kind == .instrument }?.id ?? p.tracks.first?.id)
    }

    private func loadLastProjectOrDefault() {
        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else {
            var p = Project(name: "First Jam")
            p.addTrack(.instrument)
            replaceProject(p)
        }
    }

    func listProjects() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.projectsRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs.flatMap { d in
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "modlab" }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-")
    }

    static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}

/// State touched from the CoreMIDI thread (clock follow + macro CCs), behind a lock.
final class ClockFollowState: @unchecked Sendable {
    private let lock = NSLock()
    private var input: EndpointID?
    private var follower = MIDIClockFollower()
    private var macros: [(MacroMapping, AtomicDouble)] = []

    func configure(input: EndpointID?, macros: [(MacroMapping, AtomicDouble)]) {
        lock.lock(); defer { lock.unlock() }
        if input != self.input { follower = MIDIClockFollower() }
        self.input = input
        self.macros = macros
    }

    func isFollowing(_ src: EndpointID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return input == src
    }

    func handle(_ m: MIDIMessage, at time: Double) -> (tempo: Double?, beat: Double) {
        lock.lock(); defer { lock.unlock() }
        follower.handle(m, at: time)
        return (follower.tempo, follower.beatPosition)
    }

    func macroSnapshot() -> [(MacroMapping, AtomicDouble)] {
        lock.lock(); defer { lock.unlock() }
        return macros
    }
}
