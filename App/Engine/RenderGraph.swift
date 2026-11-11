import AVFoundation
import FM1Core

/// Commands from the UI to the audio thread. Trivial (POD) so they can go
/// through `SPSCQueue` without touching ARC.
enum EngineCommand {
    case play
    case stop
    case locate(beat: Double)
    case setTempo(Double)
    case launchClip(track: Int, slot: Int)
    case stopTrack(track: Int)
    case launchScene(Int)
    case stopAllClips
    case panic
}

/// Commands from the MIDI thread (external clock follow).
enum SyncCommand {
    case start
    case `continue`
    case stop
    case songPosition(beat: Double)
}

/// A decoded audio file held in RAM (session clips / loops).
final class AudioClipBuffer {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let frames: Int

    init(url: URL, sampleRate: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat.fm1(channels: 2, sampleRate: sampleRate)
        let srcFrames = AVAudioFrameCount(file.length)
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: src)

        // Convert to engine rate / stereo once, up front, so playback is a memcpy.
        let ratio = sampleRate / file.processingFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(srcFrames) * ratio + 1024)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: fmt),
              let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: dstCapacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var fed = false
        var err: NSError?
        converter.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        if let err { throw err }

        frames = Int(dst.frameLength)
        left = .allocate(capacity: max(frames, 1))
        right = .allocate(capacity: max(frames, 1))
        if let ch = dst.floatChannelData {
            left.update(from: ch[0], count: frames)
            right.update(from: dst.format.channelCount > 1 ? ch[1] : ch[0], count: frames)
        }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

enum ClipRender {
    case midi(MIDIClipData, loop: Bool)
    case audio(AudioClipBuffer, loop: Bool)
}

/// Per-track state that survives graph rebuilds (meters, clip playback,
/// note state). Only the audio thread mutates the non-atomic members.
final class TrackNode {
    let id: UUID

    // UI-controlled, read by the audio thread every block.
    let volume = AtomicFloat(1)      // linear
    let pan = AtomicFloat(0)         // -1...1
    let muted = AtomicFlag(false)
    let soloed = AtomicFlag(false)
    let armed = AtomicFlag(false)
    var sendGains: [AtomicFloat] = []

    // Meters (audio thread writes max, UI exchanges with 0).
    let peakL = AtomicFloat(0)
    let peakR = AtomicFloat(0)
    let playingSlot = AtomicInt(-1)
    let queuedSlot = AtomicInt(-1)

    // Audio-thread state.
    let bufL: UnsafeMutablePointer<Float>
    let bufR: UnsafeMutablePointer<Float>
    let scratchL: UnsafeMutablePointer<Float>
    let scratchR: UnsafeMutablePointer<Float>
    let groupL: UnsafeMutablePointer<Float>
    let groupR: UnsafeMutablePointer<Float>

    var lastGainL: Float = 0
    var lastGainR: Float = 0
    var clipPlayer: MIDIClipPlayer?
    var audioClip: AudioClipBuffer?
    var audioClipLoop = true
    var audioClipPos = 0
    var audioClipStartBeat = 0.0
    var pendingSlot = -1          // -2 = pending stop
    var pendingBeat = 0.0
    var mono = MonoNoteTracker()
    var level: Double = 0         // block RMS for audio followers
    /// CV timeline for this block: (frame, note, gate, trigger counter).
    var cvPoints: [(Int, UInt8, Bool, UInt64, UInt8)]
    var cvPointCount = 0
    var lastHeldNote: UInt8 = 36  // CV pitch holds the last note through the release
    var clipEvents: [ScheduledMIDI] = []

    init(id: UUID, maxFrames: Int) {
        self.id = id
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        bufL = buf(); bufR = buf(); scratchL = buf(); scratchR = buf(); groupL = buf(); groupR = buf()
        cvPoints = Array(repeating: (0, 0, false, 0, 0), count: 128)
        clipEvents.reserveCapacity(256)
    }

    deinit {
        [bufL, bufR, scratchL, scratchR, groupL, groupR].forEach { $0.deallocate() }
    }

    func recordCV(frame: Int) {
        guard cvPointCount < cvPoints.count else { return }
        cvPoints[cvPointCount] = (frame, mono.currentNote ?? 0, mono.gate, mono.triggerCount, mono.velocity)
        cvPointCount += 1
    }
}

struct SendRender {
    var left: Int
    var right: Int
    var preFader: Bool
    var gain: AtomicFloat
}

/// Immutable per-track configuration inside one graph snapshot.
struct TrackRender {
    let node: TrackNode
    let kind: TrackKind
    let inputs: [Int]
    let monitorAlways: Bool
    let monitorWhenArmed: Bool
    let outLeft: Int             // -1 = master
    let outRight: Int
    let groupIndex: Int          // index in graph.tracks, -1 = none
    let plugins: [HostedPlugin]
    let instrumentIndex: Int     // first plugin that takes MIDI, -1 = none
    let midiOutPort: Int         // index into graph.midiDestinations, -1 = none
    let midiOutChannel: Int      // -1 = keep
    let sends: [SendRender]
    let clips: [ClipRender?]
    let inbox: SPSCQueue<RawMIDI>
    let recordStream: RecordingStream?
}

struct CVRender {
    let config: CVOutputConfig
    let trackIndex: Int          // for note-driven sources, else -1
    let modulatorIndex: Int      // for .modulator, else -1
    let bipolar: Bool            // modulator output range is -1...1
}

struct CVRuntime {
    var lastTrigger: UInt64 = 0
    var pulseLeft = 0
}

struct ModTargetRender {
    enum Kind { case plugin(HostedPlugin, AUParameterAddress, min: Float, max: Float), volume(Int), pan(Int), send(Int, Int), none }
    let kind: Kind
    let base: Double
}

/// Everything the audio thread needs, built on the main thread and swapped in
/// atomically. Never mutated after publishing (except the node/modulator state it points at).
final class RenderGraph {
    let tracks: [TrackRender]
    let renderOrder: [Int]               // non-group tracks first, then groups
    let masterLeft: Int
    let masterRight: Int
    let masterGain: AtomicFloat
    let masterPeakL = AtomicFloat(0)
    let masterPeakR = AtomicFloat(0)
    let inputPeaks: [AtomicFloat]
    let midiDestinations: [EndpointID]
    let clockPorts: [Int]
    let cvOutputs: [CVRender]
    let modulation: CompiledModulationMatrix
    var modulators: [ModulatorState]
    let modTargets: [ModTargetRender]
    var modOut: [Double]
    var modBases: [Double]
    var modValues: [Double]
    let modSourceTrack: [Int]
    /// Live macro knob values (UI / MIDI CC write, audio reads). nil for non-macros.
    let macroValues: [AtomicDouble?]
    /// Per-track modulation results for this block (1 / NaN / 1 = unmodulated).
    var modVolume: [Float]
    var modPan: [Float]
    var modSend: [[Float]]
    var cvRuntime: [CVRuntime]
    let launchQuantization: LaunchQuantization
    let metronome: Bool
    let metronomeLeft: Int
    let metronomeRight: Int
    let recordMaster: RecordingStream?
    let masterL: UnsafeMutablePointer<Float>
    let masterR: UnsafeMutablePointer<Float>

    init(tracks: [TrackRender], masterChannels: [Int], masterGain: AtomicFloat, inputChannels: Int,
         midiDestinations: [EndpointID], clockPorts: [Int], cvOutputs: [CVRender],
         modulators: [ModulatorDefinition], macroValues: [AtomicDouble?], connections: [ModulationConnection], modTargets: [ModTargetRender],
         launchQuantization: LaunchQuantization, metronome: Bool, metronomeChannels: [Int]?,
         recordMaster: RecordingStream?, maxFrames: Int) {
        self.tracks = tracks
        let groups = tracks.indices.filter { tracks[$0].kind == .group }
        self.renderOrder = tracks.indices.filter { tracks[$0].kind != .group } + groups
        self.masterLeft = masterChannels.first ?? 0
        self.masterRight = masterChannels.count > 1 ? masterChannels[1] : (masterChannels.first ?? 0)
        self.masterGain = masterGain
        self.inputPeaks = (0..<inputChannels).map { _ in AtomicFloat(0) }
        self.midiDestinations = midiDestinations
        self.clockPorts = clockPorts
        self.cvOutputs = cvOutputs
        self.modulation = CompiledModulationMatrix(modulators: modulators, connections: connections)
        self.modulators = modulators.map { ModulatorState($0) }
        self.modTargets = modTargets
        self.modOut = Array(repeating: 0, count: modulators.count)
        self.modBases = modTargets.map(\.base)
        self.modValues = Array(repeating: 0, count: modTargets.count)
        self.modSourceTrack = modulators.map { def in
            guard let id = def.sourceTrack else { return -1 }
            return tracks.firstIndex { $0.node.id == id } ?? -1
        }
        self.macroValues = macroValues
        self.modVolume = Array(repeating: 1, count: tracks.count)
        self.modPan = Array(repeating: .nan, count: tracks.count)
        self.modSend = tracks.map { Array(repeating: 1, count: $0.sends.count) }
        self.cvRuntime = Array(repeating: CVRuntime(), count: cvOutputs.count)
        self.launchQuantization = launchQuantization
        self.metronome = metronome
        self.metronomeLeft = metronomeChannels?.first ?? masterChannels.first ?? 0
        self.metronomeRight = metronomeChannels.map { $0.count > 1 ? $0[1] : ($0.first ?? 0) } ?? (masterChannels.count > 1 ? masterChannels[1] : 0)
        self.recordMaster = recordMaster
        masterL = .allocate(capacity: maxFrames)
        masterR = .allocate(capacity: maxFrames)
        masterL.initialize(repeating: 0, count: maxFrames)
        masterR.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        masterL.deallocate()
        masterR.deallocate()
    }
}
