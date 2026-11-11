import AVFoundation
import AudioToolbox
import Darwin
import FM1Core

struct RecordedMIDI {
    var track: Int32
    var raw: RawMIDI
    var beat: Double
}

/// The realtime core. One render callback per hardware buffer does, in order:
/// commands -> sync (internal / MIDI clock / Link) -> transport -> MIDI clock out
/// -> modulators -> every track (MIDI, clips, input, AUv3 chain, fader, sends)
/// -> groups -> master -> metronome -> CV outputs -> meters.
///
/// Rules on the audio thread: no locks, no allocation in steady state, no
/// Objective-C messaging except into the plugins' own render blocks.
final class AudioEngine {
    let io = AudioIO()
    let clockInfo = HostClockInfo()
    let link = LinkSync(tempo: 120)

    // Main -> audio
    let commands = SPSCQueue<EngineCommand>(capacity: 256, initial: .stop)
    // MIDI thread -> audio
    let syncCommands = SPSCQueue<SyncCommand>(capacity: 64, initial: .stop)
    // Audio -> MIDI sender (port = index into graph.midiDestinations)
    let midiOut = SPSCQueue<RawMIDI>(capacity: 8192, initial: RawMIDI())
    // Plugins -> router (port = plugin source index assigned by the app model)
    let pluginMIDIOut = SPSCQueue<RawMIDI>(capacity: 2048, initial: RawMIDI())
    // Audio -> main (MIDI recording into clips)
    let recordedMIDI = SPSCQueue<RecordedMIDI>(capacity: 4096, initial: RecordedMIDI(track: -1, raw: RawMIDI(), beat: 0))

    // UI mirrors
    let beatMirror = AtomicDouble(0)
    let tempoMirror = AtomicDouble(120)
    let playingMirror = AtomicFlag(false)
    let cpuLoad = AtomicFloat(0)
    let isRecording = AtomicFlag(false)

    // Settings shared with the audio thread
    let clockSource = AtomicInt(0)          // 0 internal, 1 MIDI, 2 Link
    let externalTempo = AtomicDouble(0)
    let externalBeat = AtomicDouble(-1)
    let clockOffsetSeconds = AtomicDouble(0)
    let sendClockWhenStopped = AtomicFlag(true)
    let timeSigBeats = AtomicInt(4)
    let timeSigNote = AtomicInt(4)
    private let sampleRate = AtomicDouble(48_000)
    private let outputLatency = AtomicDouble(0)

    private let graphRef = AtomicReference<RenderGraph>()
    private var graveyard: [(RenderGraph, Date)] = []

    // Audio-thread-only state
    private var transport = Transport()
    private let clockGen = MIDIClockGenerator()
    private var lastPlaying = false
    private var idleClockBeat = 0.0
    private var pendingLinkTempo: Double?
    private var pendingLinkPlay: Bool?
    private var clickFramesLeft = 0
    private var clickPhase = 0.0
    private var clickFreq = 1000.0
    private var startedThisBlock = false
    private let hostTicksPerSecond: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        hostTicksPerSecond = 1e9 * Double(tb.denom) / Double(tb.numer)
        io.renderHandler = { [unowned self] input, output, frames, ts in
            self.render(input: input, output: output, frames: frames, timestamp: ts)
        }
    }

    var currentStatus: AudioIO.Status { io.status }
    var maxFrames: Int { AudioIO.maxFrames }

    func start() throws {
        try io.start()
        syncFromIO()
    }

    func syncFromIO() {
        let s = io.status
        sampleRate.value = s.sampleRate
        clockInfo.sampleRate = s.sampleRate
        outputLatency.value = s.outputLatency + Double(s.bufferFrames) / s.sampleRate
    }

    /// Round-trip latency for recording compensation.
    var roundTripLatencyFrames: Int {
        let s = io.status
        return Int(((s.inputLatency + s.outputLatency) * s.sampleRate).rounded()) + s.bufferFrames
    }

    func send(_ c: EngineCommand) { commands.push(c) }

    /// Publishes a new graph. The old one is kept alive for a second so the
    /// audio thread is guaranteed to be done with it before it's freed.
    func publish(_ graph: RenderGraph) {
        if let old = graphRef.exchange(graph) { graveyard.append((old, Date())) }
        let cutoff = Date().addingTimeInterval(-1)
        graveyard.removeAll { $0.1 < cutoff }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            let cutoff = Date().addingTimeInterval(-1)
            self?.graveyard.removeAll { $0.1 < cutoff }
        }
    }

    /// Detach everything from the audio thread (before reconfiguring plugins).
    func publishEmpty() {
        if let old = graphRef.exchange(nil) { graveyard.append((old, Date())) }
    }

    func withCurrentGraph<R>(_ body: (RenderGraph?) -> R) -> R { graphRef.withBorrowed(body) }

    // MARK: - Render

    private func render(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer,
                        frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        let t0 = mach_absolute_time()
        for b in output {
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
        graphRef.withBorrowed { g in
            guard let g else {
                commands.drain { _ in }
                return
            }
            renderGraph(g, input: input, output: output, frames: frames, ts: timestamp)
        }
        let elapsed = Double(mach_absolute_time() - t0) / hostTicksPerSecond
        let budget = Double(frames) / sampleRate.value
        cpuLoad.max(Float(elapsed / budget))
    }

    private func hostTime(_ ts: UnsafePointer<AudioTimeStamp>, plusSeconds s: Double) -> UInt64 {
        let base = Double(ts.pointee.mHostTime)
        return UInt64(max(0, base + s * hostTicksPerSecond))
    }

    private func renderGraph(_ g: RenderGraph, input: UnsafeMutableAudioBufferListPointer,
                             output: UnsafeMutableAudioBufferListPointer, frames: Int, ts: UnsafePointer<AudioTimeStamp>) {
        let sr = sampleRate.value
        let latency = outputLatency.value
        transport.timeSignature = TimeSignature(timeSigBeats.value, timeSigNote.value)
        startedThisBlock = false

        // 1. Commands
        commands.drain { handle($0, g, ts: ts) }
        syncCommands.drain { handleSync($0, g, ts: ts) }

        // 2. Sync source
        switch clockSource.value {
        case 2:
            let heardAt = hostTime(ts, plusSeconds: latency)
            if let st = link.beginBlock(hostTime: heardAt, requestedTempo: pendingLinkTempo, requestedPlaying: pendingLinkPlay) {
                transport.tempo = st.tempo
                if st.isPlaying && !transport.isPlaying {
                    transport.play(from: max(0, st.beat))
                    startedThisBlock = true
                } else if !st.isPlaying && transport.isPlaying {
                    stopAllPlayback(g, ts: ts)
                    transport.stop()
                } else if st.isPlaying {
                    transport.locate(max(0, st.beat))
                }
            }
            pendingLinkTempo = nil
            pendingLinkPlay = nil
        case 1:
            let et = externalTempo.value
            if et > 0 { transport.tempo = et }
            let eb = externalBeat.value
            if transport.isPlaying, eb >= 0 {
                // Gentle phase-lock to the incoming clock, no audible jumps.
                let err = eb - transport.beatPosition
                if abs(err) > 1 { transport.locate(eb) } else { transport.locate(transport.beatPosition + err * 0.05) }
            }
        default:
            break
        }

        // 3. Transport
        let playing = transport.isPlaying
        let range = transport.advance(frames: frames, sampleRate: sr)
        let beatsPerFrame = transport.tempo / (60 * sr)
        clockInfo.tempo = transport.tempo
        clockInfo.beatPosition = range.lowerBound
        clockInfo.beatsPerBar = transport.timeSignature.quarterNotesPerBar
        clockInfo.noteValue = transport.timeSignature.noteValue
        clockInfo.isPlaying = playing
        clockInfo.transportChanged = playing != lastPlaying
        clockInfo.sampleTime = Double(transport.sampleTime)
        beatMirror.value = transport.beatPosition
        tempoMirror.value = transport.tempo
        playingMirror.value = playing

        // 4. MIDI clock + transport messages to hardware
        let clockShift = latency + clockOffsetSeconds.value
        if !g.clockPorts.isEmpty {
            if playing && !lastPlaying {
                for port in g.clockPorts {
                    if range.lowerBound < 0.001 {
                        midiOut.push(RawMIDI(b0: 0xFA, length: 1, port: UInt16(port), hostTime: hostTime(ts, plusSeconds: clockShift)))
                    } else {
                        let spp = MIDIClockGenerator.songPosition(forBeat: range.lowerBound)
                        midiOut.push(RawMIDI(b0: 0xF2, b1: UInt8(spp & 0x7F), b2: UInt8((spp >> 7) & 0x7F), length: 3,
                                             port: UInt16(port), hostTime: hostTime(ts, plusSeconds: clockShift)))
                        midiOut.push(RawMIDI(b0: 0xFB, length: 1, port: UInt16(port), hostTime: hostTime(ts, plusSeconds: clockShift)))
                    }
                }
            } else if !playing && lastPlaying {
                for port in g.clockPorts {
                    midiOut.push(RawMIDI(b0: 0xFC, length: 1, port: UInt16(port), hostTime: hostTime(ts, plusSeconds: clockShift)))
                }
            }
            var clockRange = range
            if !playing {
                // Keep clocking while stopped so gear shows the right tempo and is ready to go.
                let span = transport.beats(forFrames: frames, sampleRate: sr)
                clockRange = idleClockBeat..<(idleClockBeat + span)
                idleClockBeat += span
            } else {
                idleClockBeat = 0
            }
            if playing || sendClockWhenStopped.value {
                for offset in clockGen.tickOffsets(beatRange: clockRange, frames: frames) {
                    let when = hostTime(ts, plusSeconds: clockShift + Double(offset) / sr)
                    for port in g.clockPorts {
                        midiOut.push(RawMIDI(b0: 0xF8, length: 1, port: UInt16(port), hostTime: when))
                    }
                }
            }
        }

        // 5. Modulators (control rate: once per block)
        let dt = Double(frames) / sr
        for i in 0..<g.modulators.count {
            let src = g.modSourceTrack[i]
            let node = src >= 0 ? g.tracks[src].node : nil
            if i < g.macroValues.count, let macro = g.macroValues[i] {
                g.modOut[i] = min(max(macro.value, 0), 1)
                continue
            }
            g.modOut[i] = g.modulators[i].advance(.init(
                deltaSeconds: dt, beatPosition: range.lowerBound, tempo: transport.tempo, isPlaying: playing,
                gate: node?.mono.gate ?? false, audioLevel: node?.level ?? 0))
        }
        if !g.modTargets.isEmpty {
            g.modulation.apply(modulatorOutputs: g.modOut, bases: g.modBases, into: &g.modValues)
            for i in 0..<g.modTargets.count {
                let v = g.modValues[i]
                switch g.modTargets[i].kind {
                case let .plugin(p, address, lo, hi):
                    p.setParameter(address: address, value: lo + (hi - lo) * Float(v))
                case let .volume(ti):
                    g.modVolume[ti] = Float(v)
                case let .pan(ti):
                    g.modPan[ti] = Float(v * 2 - 1)
                case let .send(ti, si):
                    if si < g.modSend[ti].count { g.modSend[ti][si] = Float(v) }
                case .none:
                    break
                }
            }
        }

        // 6. Tracks
        g.masterL.update(repeating: 0, count: frames)
        g.masterR.update(repeating: 0, count: frames)
        var anySolo = false
        for t in g.tracks where t.node.soloed.value { anySolo = true; break }
        for t in g.tracks where t.kind == .group {
            t.node.groupL.update(repeating: 0, count: frames)
            t.node.groupR.update(repeating: 0, count: frames)
        }
        for idx in g.renderOrder {
            renderTrack(idx, g, input: input, output: output, frames: frames, range: range,
                        beatsPerFrame: beatsPerFrame, playing: playing, anySolo: anySolo, ts: ts, latency: latency)
        }

        // 7. Master
        let mg = g.masterGain.value
        var pl: Float = 0, pr: Float = 0
        for i in 0..<frames {
            g.masterL[i] *= mg
            g.masterR[i] *= mg
            pl = max(pl, abs(g.masterL[i]))
            pr = max(pr, abs(g.masterR[i]))
        }
        g.masterPeakL.max(pl)
        g.masterPeakR.max(pr)
        g.recordMaster?.write(left: g.masterL, right: g.masterR, frames: frames)

        // 8. Metronome
        if g.metronome && playing {
            renderClick(range: range, frames: frames, beatsPerFrame: beatsPerFrame, sr: sr)
        }

        addToOutput(output, channel: g.masterLeft, g.masterL, frames: frames)
        addToOutput(output, channel: g.masterRight, g.masterR, frames: frames)
        if clickBufferFilled {
            addToOutput(output, channel: g.metronomeLeft, clickBuffer, frames: frames)
            if g.metronomeRight != g.metronomeLeft { addToOutput(output, channel: g.metronomeRight, clickBuffer, frames: frames) }
            clickBufferFilled = false
        }

        // 9. CV (overwrites its channels: DC-coupled outs are dedicated)
        for c in 0..<g.cvOutputs.count {
            renderCV(c, g, output: output, frames: frames, range: range, beatsPerFrame: beatsPerFrame, playing: playing, sr: sr)
        }

        // 10. Input meters
        for ch in 0..<min(input.count, g.inputPeaks.count) {
            guard let p = input[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var m: Float = 0
            for i in 0..<frames { m = max(m, abs(p[i])) }
            g.inputPeaks[ch].max(m)
        }

        lastPlaying = playing
    }

    // MARK: Commands

    private func handle(_ c: EngineCommand, _ g: RenderGraph, ts: UnsafePointer<AudioTimeStamp>) {
        switch c {
        case .play:
            if !transport.isPlaying {
                transport.play()
                startedThisBlock = true
                pendingLinkPlay = true
            }
        case .stop:
            if transport.isPlaying {
                stopAllPlayback(g, ts: ts)
                transport.stop()
                pendingLinkPlay = false
            } else {
                transport.locate(0) // second press: back to the start, like Live
            }
        case let .locate(b):
            transport.locate(b)
        case let .setTempo(t):
            transport.tempo = t
            pendingLinkTempo = t
        case let .launchClip(track, slot):
            guard track >= 0, track < g.tracks.count else { return }
            queueLaunch(g.tracks[track].node, slot: slot, g)
        case let .stopTrack(track):
            guard track >= 0, track < g.tracks.count else { return }
            queueLaunch(g.tracks[track].node, slot: -2, g)
        case let .launchScene(scene):
            for t in g.tracks where t.kind != .group {
                let has = scene < t.clips.count && t.clips[scene] != nil
                queueLaunch(t.node, slot: has ? scene : -2, g)
            }
        case .stopAllClips:
            for t in g.tracks { queueLaunch(t.node, slot: -2, g) }
        case .panic:
            for t in g.tracks {
                sendAllNotesOff(t, ts: ts)
                t.node.mono = MonoNoteTracker(priority: t.node.mono.priority)
            }
            for port in 0..<g.midiDestinations.count {
                for ch in UInt8(0)..<16 {
                    midiOut.push(RawMIDI(b0: 0xB0 | ch, b1: 123, b2: 0, length: 3, port: UInt16(port)))
                    midiOut.push(RawMIDI(b0: 0xB0 | ch, b1: 64, b2: 0, length: 3, port: UInt16(port)))
                }
            }
        }
    }

    private func handleSync(_ c: SyncCommand, _ g: RenderGraph, ts: UnsafePointer<AudioTimeStamp>) {
        guard clockSource.value == 1 else { return }
        switch c {
        case .start:
            transport.play(from: 0)
            startedThisBlock = true
        case .continue:
            transport.play()
        case .stop:
            stopAllPlayback(g, ts: ts)
            transport.stop()
        case let .songPosition(b):
            transport.locate(b)
        }
    }

    private func queueLaunch(_ n: TrackNode, slot: Int, _ g: RenderGraph) {
        if transport.isPlaying {
            n.pendingBeat = g.launchQuantization.nextLaunchBeat(after: transport.beatPosition, timeSignature: transport.timeSignature)
        } else {
            n.pendingBeat = transport.beatPosition
            if slot >= 0 {
                transport.play()
                startedThisBlock = true
                pendingLinkPlay = true
            }
        }
        n.pendingSlot = slot
        n.queuedSlot.value = slot >= 0 ? slot : -1
    }

    private func stopAllPlayback(_ g: RenderGraph, ts: UnsafePointer<AudioTimeStamp>) {
        for t in g.tracks {
            let n = t.node
            n.clipEvents.removeAll(keepingCapacity: true)
            n.clipPlayer?.stop(into: &n.clipEvents)
            for e in n.clipEvents { if let raw = RawMIDI(rawFrom: e.message) { dispatch(raw, t, frame: 0, ts: ts) } }
            n.clipEvents.removeAll(keepingCapacity: true)
            n.clipPlayer = nil
            n.audioClip = nil
            n.pendingSlot = -1
            n.playingSlot.value = -1
            n.queuedSlot.value = -1
        }
    }

    private func sendAllNotesOff(_ t: TrackRender, ts: UnsafePointer<AudioTimeStamp>) {
        for ch in UInt8(0)..<16 {
            dispatch(RawMIDI(b0: 0xB0 | ch, b1: 123, b2: 0, length: 3), t, frame: 0, ts: ts)
        }
    }

    // MARK: Tracks

    private func renderTrack(_ idx: Int, _ g: RenderGraph, input: UnsafeMutableAudioBufferListPointer,
                             output: UnsafeMutableAudioBufferListPointer, frames: Int, range: Range<Double>,
                             beatsPerFrame: Double, playing: Bool, anySolo: Bool,
                             ts: UnsafePointer<AudioTimeStamp>, latency: Double) {
        let t = g.tracks[idx]
        let n = t.node

        if t.kind == .group {
            n.bufL.update(from: n.groupL, count: frames)
            n.bufR.update(from: n.groupR, count: frames)
        } else {
            n.bufL.update(repeating: 0, count: frames)
            n.bufR.update(repeating: 0, count: frames)
        }
        n.cvPointCount = 0
        n.recordCV(frame: 0)

        // Quantized clip launch / stop
        if n.pendingSlot != -1, !playing || n.pendingBeat < range.upperBound {
            let offsetBeats = max(0, n.pendingBeat - range.lowerBound)
            let frame = min(frames - 1, Int(offsetBeats / max(beatsPerFrame, 1e-12)))
            n.clipEvents.removeAll(keepingCapacity: true)
            n.clipPlayer?.stop(into: &n.clipEvents, atBeatOffset: offsetBeats)
            n.clipPlayer = nil
            n.audioClip = nil
            let slot = n.pendingSlot
            if slot >= 0, slot < t.clips.count, let clip = t.clips[slot] {
                switch clip {
                case let .midi(data, loop):
                    let ch = UInt8(max(0, t.midiOutChannel))
                    n.clipPlayer = MIDIClipPlayer(clip: data, launchBeat: n.pendingBeat, channel: ch, loop: loop)
                case let .audio(buffer, loop):
                    n.audioClip = buffer
                    n.audioClipLoop = loop
                    n.audioClipPos = -frame
                }
                n.playingSlot.value = slot
            } else {
                n.playingSlot.value = -1
            }
            n.queuedSlot.value = -1
            n.pendingSlot = -1
            for e in n.clipEvents {
                if let raw = RawMIDI(rawFrom: e.message) { dispatch(raw, t, frame: frame, ts: ts) }
            }
        }

        // Live MIDI from the router
        let recording = isRecording.value && n.armed.value && playing
        t.inbox.drain { raw in
            dispatch(raw, t, frame: 0, ts: ts)
            if recording {
                recordedMIDI.push(RecordedMIDI(track: Int32(idx), raw: raw, beat: range.lowerBound))
            }
        }

        // Clip MIDI
        if playing, n.clipPlayer != nil {
            n.clipEvents.removeAll(keepingCapacity: true)
            n.clipPlayer?.render(range, into: &n.clipEvents)
            for e in n.clipEvents {
                guard let raw = RawMIDI(rawFrom: e.message) else { continue }
                let frame = min(frames - 1, max(0, Int(e.beatOffset / beatsPerFrame)))
                dispatch(raw, t, frame: frame, ts: ts)
            }
        }

        // Hardware input
        if (t.kind == .audio || t.kind == .externalInstrument), let first = t.inputs.first, first < input.count,
           let srcL = input[first].mData?.assumingMemoryBound(to: Float.self) {
            let second = t.inputs.count > 1 ? t.inputs[1] : first
            let srcR = second < input.count ? (input[second].mData?.assumingMemoryBound(to: Float.self) ?? srcL) : srcL
            if let rec = t.recordStream, isRecording.value { rec.write(left: srcL, right: srcR, frames: frames) }
            if t.monitorAlways || (t.monitorWhenArmed && n.armed.value) {
                n.bufL.update(from: srcL, count: frames)
                n.bufR.update(from: srcR, count: frames)
            }
        }

        // Audio clip playback
        if let clip = n.audioClip, playing {
            for i in 0..<frames {
                var pos = n.audioClipPos + i
                if pos < 0 { continue }
                if pos >= clip.frames {
                    guard n.audioClipLoop, clip.frames > 0 else { break }
                    pos %= clip.frames
                }
                n.bufL[i] += clip.left[pos]
                n.bufR[i] += clip.right[pos]
            }
            n.audioClipPos += frames
            if !n.audioClipLoop && n.audioClipPos >= clip.frames {
                n.audioClip = nil
                n.playingSlot.value = -1
            } else if n.audioClipLoop && clip.frames > 0 && n.audioClipPos >= clip.frames {
                n.audioClipPos %= clip.frames
            }
        }

        // Device chain
        if t.kind != .midi {
            for pi in 0..<t.plugins.count {
                let p = t.plugins[pi]
                p.render(l: n.bufL, r: n.bufR, scratchL: n.scratchL, scratchR: n.scratchR, frames: frames, timestamp: ts)
                if p.role == .midiProcessor {
                    var next = -1
                    var k = pi + 1
                    while k < t.plugins.count { if t.plugins[k].hasMIDIInput { next = k; break }; k += 1 }
                    p.chainMIDI.drain { raw in
                        if next >= 0 {
                            t.plugins[next].sendMIDI(raw, frameOffset: 0)
                        } else if t.midiOutPort >= 0 {
                            var r = raw
                            r.port = UInt16(t.midiOutPort)
                            r.hostTime = hostTime(ts, plusSeconds: latency)
                            midiOut.push(r)
                        }
                    }
                }
            }
        } else {
            // MIDI tracks still run MIDI processors (arps, chord generators) for hardware.
            for pi in 0..<t.plugins.count where t.plugins[pi].role == .midiProcessor {
                let p = t.plugins[pi]
                p.render(l: n.bufL, r: n.bufR, scratchL: n.scratchL, scratchR: n.scratchR, frames: frames, timestamp: ts)
                p.chainMIDI.drain { raw in
                    guard t.midiOutPort >= 0 else { return }
                    var r = raw
                    r.port = UInt16(t.midiOutPort)
                    r.hostTime = hostTime(ts, plusSeconds: latency)
                    midiOut.push(r)
                }
            }
            n.level = 0
            n.peakL.max(0)
            return
        }

        // Fader, pan, mute/solo with per-block ramp (no zipper noise)
        let silent = n.muted.value || (anySolo && !n.soloed.value && t.kind != .group)
        let modPan = g.modPan[idx]
        let pan = modPan.isNaN ? n.pan.value : modPan
        let pg = Decibels.panGains(Double(pan))
        let vol = silent ? 0 : n.volume.value * g.modVolume[idx]
        let targetL = vol * Float(pg.left) * Float(2.0.squareRoot())
        let targetR = vol * Float(pg.right) * Float(2.0.squareRoot())

        // Pre-fader sends
        for (si, s) in t.sends.enumerated() where s.preFader {
            let sg = s.gain.value * (si < g.modSend[idx].count ? g.modSend[idx][si] : 1)
            addToOutput(output, channel: s.left, n.bufL, frames: frames, gain: sg)
            addToOutput(output, channel: s.right, n.bufR, frames: frames, gain: sg)
        }

        let stepL = (targetL - n.lastGainL) / Float(frames)
        let stepR = (targetR - n.lastGainR) / Float(frames)
        var gl = n.lastGainL, gr = n.lastGainR
        var pkL: Float = 0, pkR: Float = 0, sum: Float = 0
        for i in 0..<frames {
            gl += stepL
            gr += stepR
            let l = n.bufL[i] * gl
            let r = n.bufR[i] * gr
            n.bufL[i] = l
            n.bufR[i] = r
            pkL = max(pkL, abs(l))
            pkR = max(pkR, abs(r))
            sum += l * l + r * r
        }
        n.lastGainL = targetL
        n.lastGainR = targetR
        n.peakL.max(pkL)
        n.peakR.max(pkR)
        n.level = Double((sum / Float(2 * frames)).squareRoot())

        // Post-fader sends
        for (si, s) in t.sends.enumerated() where !s.preFader {
            let sg = s.gain.value * (si < g.modSend[idx].count ? g.modSend[idx][si] : 1)
            addToOutput(output, channel: s.left, n.bufL, frames: frames, gain: sg)
            addToOutput(output, channel: s.right, n.bufR, frames: frames, gain: sg)
        }

        // Destination
        if t.groupIndex >= 0 {
            let gn = g.tracks[t.groupIndex].node
            for i in 0..<frames { gn.groupL[i] += n.bufL[i]; gn.groupR[i] += n.bufR[i] }
        } else if t.outLeft >= 0 {
            addToOutput(output, channel: t.outLeft, n.bufL, frames: frames)
            addToOutput(output, channel: t.outRight, n.bufR, frames: frames)
        } else {
            for i in 0..<frames { g.masterL[i] += n.bufL[i]; g.masterR[i] += n.bufR[i] }
        }
    }

    /// Delivers one MIDI event to a track: its instrument/MIDI-FX chain, its
    /// hardware/app MIDI output, and its CV note tracker.
    private func dispatch(_ raw: RawMIDI, _ t: TrackRender, frame: Int, ts: UnsafePointer<AudioTimeStamp>) {
        var r = raw
        if t.midiOutChannel >= 0, r.b0 < 0xF0 {
            r.b0 = (r.b0 & 0xF0) | UInt8(t.midiOutChannel & 0x0F)
        }
        if let m = r.message {
            t.node.mono.handle(m)
            if let n = t.node.mono.currentNote { t.node.lastHeldNote = n }
            t.node.recordCV(frame: frame)
        }
        if t.instrumentIndex >= 0 {
            t.plugins[t.instrumentIndex].sendMIDI(r, frameOffset: frame)
        }
        if t.midiOutPort >= 0 {
            r.port = UInt16(t.midiOutPort)
            r.hostTime = hostTime(ts, plusSeconds: outputLatency.value + Double(frame) / sampleRate.value)
            midiOut.push(r)
        }
    }

    private func addToOutput(_ output: UnsafeMutableAudioBufferListPointer, channel: Int,
                             _ src: UnsafePointer<Float>, frames: Int, gain: Float = 1) {
        guard channel >= 0, channel < output.count,
              let dst = output[channel].mData?.assumingMemoryBound(to: Float.self) else { return }
        if gain == 1 {
            for i in 0..<frames { dst[i] += src[i] }
        } else if gain != 0 {
            for i in 0..<frames { dst[i] += src[i] * gain }
        }
    }

    // MARK: Metronome

    private let clickBuffer: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioIO.maxFrames)
        p.initialize(repeating: 0, count: AudioIO.maxFrames)
        return p
    }()
    private var clickBufferFilled = false

    private func renderClick(range: Range<Double>, frames: Int, beatsPerFrame: Double, sr: Double) {
        clickBuffer.update(repeating: 0, count: frames)
        let nextBeat = range.lowerBound.rounded(.up)
        var startFrame = Int.max
        if nextBeat < range.upperBound {
            startFrame = Int((nextBeat - range.lowerBound) / beatsPerFrame)
            let bar = transport.timeSignature.quarterNotesPerBar
            clickFreq = nextBeat.truncatingRemainder(dividingBy: bar) < 0.001 ? 1600 : 1000 // accent the downbeat
        }
        let length = Int(0.03 * sr)
        for i in 0..<frames {
            if i == startFrame { clickFramesLeft = length; clickPhase = 0 }
            if clickFramesLeft > 0 {
                let env = Float(clickFramesLeft) / Float(length)
                clickBuffer[i] = Float(sin(clickPhase)) * env * env * 0.5
                clickPhase += 2 * .pi * clickFreq / sr
                clickFramesLeft -= 1
            }
        }
        clickBufferFilled = true
    }

    // MARK: CV

    private func renderCV(_ c: Int, _ g: RenderGraph, output: UnsafeMutableAudioBufferListPointer, frames: Int,
                          range: Range<Double>, beatsPerFrame: Double, playing: Bool, sr: Double) {
        let cv = g.cvOutputs[c]
        let cfg = cv.config
        guard cfg.isEnabled, cfg.channel >= 0, cfg.channel < output.count,
              let dst = output[cfg.channel].mData?.assumingMemoryBound(to: Float.self) else { return }
        let cal = cfg.calibration
        let pulseFrames = max(1, Int(cfg.pulseWidthMs / 1000 * sr))
        let high = cal.sample(forVolts: cfg.maxVolts)
        let low = cal.sample(forVolts: cfg.minVolts)

        func fillSegments(_ value: (Int) -> Float) {
            guard cv.trackIndex >= 0 else { return }
            let n = g.tracks[cv.trackIndex].node
            for p in 0..<n.cvPointCount {
                let start = n.cvPoints[p].0
                let end = p + 1 < n.cvPointCount ? n.cvPoints[p + 1].0 : frames
                guard end > start else { continue }
                let v = value(p)
                for i in start..<min(end, frames) { dst[i] = v }
            }
        }

        switch cfg.source {
        case let .pitch(_, bendRange):
            guard cv.trackIndex >= 0 else { return }
            let n = g.tracks[cv.trackIndex].node
            let bend = n.mono.pitchBend * bendRange
            fillSegments { p in
                let pt = n.cvPoints[p]
                let note = pt.2 ? pt.1 : n.lastHeldNote
                return cal.sample(forVolts: cfg.volts(forNote: Double(note) + bend))
            }
        case .gate:
            guard cv.trackIndex >= 0 else { return }
            let n = g.tracks[cv.trackIndex].node
            fillSegments { p in n.cvPoints[p].2 ? high : low }
        case .velocity:
            guard cv.trackIndex >= 0 else { return }
            let n = g.tracks[cv.trackIndex].node
            fillSegments { p in cal.sample(forVolts: cfg.volts(forNormalised: Double(n.cvPoints[p].4) / 127, bipolar: false)) }
        case .trigger:
            guard cv.trackIndex >= 0 else { return }
            let n = g.tracks[cv.trackIndex].node
            var p = 0
            for i in 0..<frames {
                while p < n.cvPointCount && n.cvPoints[p].0 <= i {
                    if n.cvPoints[p].3 != g.cvRuntime[c].lastTrigger {
                        g.cvRuntime[c].lastTrigger = n.cvPoints[p].3
                        if n.cvPoints[p].2 { g.cvRuntime[c].pulseLeft = pulseFrames }
                    }
                    p += 1
                }
                dst[i] = g.cvRuntime[c].pulseLeft > 0 ? high : low
                if g.cvRuntime[c].pulseLeft > 0 { g.cvRuntime[c].pulseLeft -= 1 }
            }
        case let .clock(ppq):
            let q = Double(max(1, ppq))
            var nextPulse = playing ? (range.lowerBound * q).rounded(.up) : Double.infinity
            for i in 0..<frames {
                let beat = range.lowerBound + Double(i) * beatsPerFrame
                if beat * q >= nextPulse { g.cvRuntime[c].pulseLeft = pulseFrames; nextPulse += 1 }
                dst[i] = g.cvRuntime[c].pulseLeft > 0 ? high : low
                if g.cvRuntime[c].pulseLeft > 0 { g.cvRuntime[c].pulseLeft -= 1 }
            }
        case let .reset(everyBars):
            let barLen = transport.timeSignature.quarterNotesPerBar * Double(max(1, everyBars))
            if playing {
                if startedThisBlock || (!lastPlaying) { g.cvRuntime[c].pulseLeft = pulseFrames }
                let next = (range.lowerBound / barLen).rounded(.up) * barLen
                let startFrame = next < range.upperBound && next > 0 ? Int((next - range.lowerBound) / beatsPerFrame) : Int.max
                for i in 0..<frames {
                    if i == startFrame { g.cvRuntime[c].pulseLeft = pulseFrames }
                    dst[i] = g.cvRuntime[c].pulseLeft > 0 ? high : low
                    if g.cvRuntime[c].pulseLeft > 0 { g.cvRuntime[c].pulseLeft -= 1 }
                }
            } else {
                for i in 0..<frames { dst[i] = low }
            }
        case .modulator:
            guard cv.modulatorIndex >= 0, cv.modulatorIndex < g.modOut.count else { return }
            let v = cal.sample(forVolts: cfg.volts(forNormalised: g.modOut[cv.modulatorIndex], bipolar: cv.bipolar))
            for i in 0..<frames { dst[i] = v }
        case let .constant(volts):
            let v = cal.sample(forVolts: volts)
            for i in 0..<frames { dst[i] = v }
        }
    }
}

extension RawMIDI {
    /// Non-allocating conversion for channel/realtime messages (no sysex).
    init?(rawFrom m: MIDIMessage) {
        switch m {
        case let .noteOff(c, n, v): self.init(b0: 0x80 | c, b1: n, b2: v, length: 3)
        case let .noteOn(c, n, v): self.init(b0: 0x90 | c, b1: n, b2: v, length: 3)
        case let .polyPressure(c, n, p): self.init(b0: 0xA0 | c, b1: n, b2: p, length: 3)
        case let .controlChange(c, cc, v): self.init(b0: 0xB0 | c, b1: cc, b2: v, length: 3)
        case let .programChange(c, p): self.init(b0: 0xC0 | c, b1: p, length: 2)
        case let .channelPressure(c, p): self.init(b0: 0xD0 | c, b1: p, length: 2)
        case let .pitchBend(c, v): self.init(b0: 0xE0 | c, b1: UInt8(v & 0x7F), b2: UInt8((v >> 7) & 0x7F), length: 3)
        case .clock: self.init(b0: 0xF8, length: 1)
        case .start: self.init(b0: 0xFA, length: 1)
        case .continue: self.init(b0: 0xFB, length: 1)
        case .stop: self.init(b0: 0xFC, length: 1)
        default: return nil
        }
    }
}
