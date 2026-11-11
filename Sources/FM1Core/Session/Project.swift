import Foundation

/// Identifies an installed AUv3 (four-char codes from AudioComponentDescription)
/// without importing AudioToolbox, so the model stays platform independent.
public struct PluginComponentID: Codable, Hashable, Sendable {
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturer: UInt32
    public var name: String
    public var manufacturerName: String

    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32, name: String, manufacturerName: String) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.name = name
        self.manufacturerName = manufacturerName
    }

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    public var role: PluginRole {
        switch PluginComponentID.fourCCString(type) {
        case "aumu": return .instrument
        case "aufx": return .audioEffect
        case "aumf": return .musicEffect
        case "aumi": return .midiProcessor
        case "augn": return .generator
        default: return .other
        }
    }
}

public enum PluginRole: String, Codable, Sendable {
    case instrument, audioEffect, musicEffect, midiProcessor, generator, other
}

/// One slot in a track's device chain.
public struct DeviceSlot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var component: PluginComponentID
    /// The plugin's `fullStateForDocument`, plist-encoded. Restored on load.
    public var state: Data?
    public var isBypassed: Bool
    /// Dry/wet for effects (0...1). Instruments ignore it.
    public var mix: Double

    public init(id: UUID = UUID(), component: PluginComponentID, state: Data? = nil, isBypassed: Bool = false, mix: Double = 1) {
        self.id = id
        self.component = component
        self.state = state
        self.isBypassed = isBypassed
        self.mix = mix
    }
}

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// Records/monitors hardware inputs through effects.
    case audio
    /// MIDI in -> AUv3 instrument -> effects.
    case instrument
    /// MIDI only: sequences hardware, other apps or CV. No audio.
    case midi
    /// Ableton's "External Instrument": MIDI out to a hardware synth, its audio
    /// back in through the interface, processed and mixed like any track.
    case externalInstrument
    /// Sums other tracks (sub-mix / bus).
    case group
}

public enum MonitorMode: String, Codable, Sendable, CaseIterable {
    case auto   // monitor when armed
    case on
    case off
}

/// Pre/post-fader send to a hardware output pair: external effects loops,
/// a headphone cue mix, or a pedal board.
public struct HardwareSend: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var outputChannels: [Int]
    public var levelDB: Double
    public var preFader: Bool

    public init(id: UUID = UUID(), outputChannels: [Int], levelDB: Double = -12, preFader: Bool = false) {
        self.id = id
        self.outputChannels = outputChannels
        self.levelDB = levelDB
        self.preFader = preFader
    }
}

public enum ClipContent: Codable, Hashable, Sendable {
    case midi(MIDIClipData)
    /// Audio file inside the project folder (WAV/CAF/AIFF/M4A).
    case audio(fileName: String, lengthBeats: Double, warp: Bool)
}

public struct Clip: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var content: ClipContent
    public var loop: Bool
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, content: ClipContent, loop: Bool = true, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.content = content
        self.loop = loop
        self.colorIndex = colorIndex
    }

    public var lengthBeats: Double {
        switch content {
        case let .midi(d): return d.lengthBeats
        case let .audio(_, len, _): return len
        }
    }
}

public struct Track: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var colorIndex: Int

    /// Hardware input channels (0-based). 1 = mono, 2 = stereo.
    public var audioInputs: [Int]
    public var monitor: MonitorMode
    /// For midi / externalInstrument tracks: where the notes go.
    public var midiOutput: EndpointID?
    /// 0-based; nil = keep incoming channel.
    public var midiOutputChannel: UInt8?
    /// Round-trip latency of the hardware synth path, compensated on recording.
    public var externalLatencyMs: Double

    public var devices: [DeviceSlot]
    public var volumeDB: Double
    public var pan: Double
    public var isMuted: Bool
    public var isSoloed: Bool
    public var isArmed: Bool
    /// nil = master bus.
    public var outputChannels: [Int]?
    /// Route into a group track instead of master.
    public var groupID: UUID?
    public var sends: [HardwareSend]
    /// Session-view slots, one per scene.
    public var clipSlots: [Clip?]

    public init(id: UUID = UUID(), name: String, kind: TrackKind, colorIndex: Int = 0,
                audioInputs: [Int] = [], monitor: MonitorMode = .auto,
                midiOutput: EndpointID? = nil, midiOutputChannel: UInt8? = nil, externalLatencyMs: Double = 0,
                devices: [DeviceSlot] = [], volumeDB: Double = 0, pan: Double = 0,
                isMuted: Bool = false, isSoloed: Bool = false, isArmed: Bool = false,
                outputChannels: [Int]? = nil, groupID: UUID? = nil, sends: [HardwareSend] = [],
                clipSlots: [Clip?] = Array(repeating: nil, count: 8)) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colorIndex = colorIndex
        self.audioInputs = audioInputs
        self.monitor = monitor
        self.midiOutput = midiOutput
        self.midiOutputChannel = midiOutputChannel
        self.externalLatencyMs = externalLatencyMs
        self.devices = devices
        self.volumeDB = volumeDB
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isArmed = isArmed
        self.outputChannels = outputChannels
        self.groupID = groupID
        self.sends = sends
        self.clipSlots = clipSlots
    }

    /// The router endpoint that feeds this track.
    public var endpoint: EndpointID { .track(id) }

    public var producesAudio: Bool { kind != .midi }
}

extension EndpointID {
    public static func track(_ id: UUID) -> EndpointID { EndpointID(.track, id.uuidString) }
    public static func plugin(_ device: UUID) -> EndpointID { EndpointID(.plugin, device.uuidString) }
    public static let clock = EndpointID(.internalClock, "FM-1 Clock")
    /// FM-1's own virtual ports, visible to AUM, Koala, Drambo, etc.
    public static let fm1VirtualOut = EndpointID(.virtualPort, "FM-1 Out")
    public static let fm1VirtualIn = EndpointID(.virtualPort, "FM-1 In")
}

public struct LaunchScene: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Optional tempo change when launched.
    public var tempo: Double?
    public init(id: UUID = UUID(), name: String, tempo: Double? = nil) {
        self.id = id
        self.name = name
        self.tempo = tempo
    }
}

public struct ClockSettings: Codable, Hashable, Sendable {
    public var source: ClockSource = .internalClock
    /// When following external MIDI clock: which input.
    public var externalInput: EndpointID?
    /// Send MIDI clock + start/stop/SPP to these (drum machines, sequencers, Eurorack MIDI modules).
    public var sendClockTo: [EndpointID] = []
    /// Shift clock earlier/later to line up gear with audible output.
    public var clockOffsetMs: Double = 0
    public init() {}
}

/// A hardware knob/fader (CC) mapped to a macro modulator, which can in turn
/// drive any number of plugin parameters, mixer controls or CV outputs.
public struct MacroMapping: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// nil = any input.
    public var source: EndpointID?
    /// 0-based; nil = any channel.
    public var channel: UInt8?
    public var controller: UInt8
    public var modulator: UUID

    public init(id: UUID = UUID(), source: EndpointID? = nil, channel: UInt8? = nil, controller: UInt8, modulator: UUID) {
        self.id = id
        self.source = source
        self.channel = channel
        self.controller = controller
        self.modulator = modulator
    }

    public func matches(_ m: MIDIMessage, from src: EndpointID) -> UInt8? {
        guard case let .controlChange(ch, cc, v) = m, cc == controller else { return nil }
        if let source, source != src { return nil }
        if let channel, channel != ch { return nil }
        return v
    }
}

public struct Project: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = Project.currentFormatVersion
    public var name: String
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var launchQuantization: LaunchQuantization
    public var clock: ClockSettings
    public var tracks: [Track]
    public var scenes: [LaunchScene]
    public var midiRoutes: [MIDIRoute]
    public var modulators: [ModulatorDefinition]
    public var modulation: [ModulationConnection]
    public var macroMappings: [MacroMapping]
    public var cvOutputs: [CVOutputConfig]
    public var masterOutputChannels: [Int]
    public var masterVolumeDB: Double
    /// Count-in bars before recording starts.
    public var countInBars: Int
    public var metronomeOn: Bool
    public var metronomeOutputChannels: [Int]?
    /// Also print the master mix to a stereo file whenever recording (jam capture).
    public var recordMasterMix: Bool

    public init(name: String = "Untitled", tempo: Double = 120) {
        self.name = name
        self.tempo = tempo
        self.timeSignature = TimeSignature()
        self.launchQuantization = .bar
        self.clock = ClockSettings()
        self.tracks = []
        self.scenes = (1...8).map { LaunchScene(name: "Scene \($0)") }
        self.midiRoutes = []
        self.modulators = []
        self.modulation = []
        self.macroMappings = []
        self.cvOutputs = []
        self.masterOutputChannels = [0, 1]
        self.masterVolumeDB = 0
        self.countInBars = 0
        self.metronomeOn = false
        self.metronomeOutputChannels = nil
        self.recordMasterMix = true
    }

    public func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }

    public mutating func addScene() {
        scenes.append(LaunchScene(name: "Scene \(scenes.count + 1)"))
        for i in tracks.indices { tracks[i].clipSlots.append(nil) }
    }

    /// Adds a track with one slot per scene.
    @discardableResult
    public mutating func addTrack(_ kind: TrackKind, name: String? = nil) -> Track {
        let n = tracks.count + 1
        let defaultName: String
        switch kind {
        case .audio: defaultName = "Audio \(n)"
        case .instrument: defaultName = "Instrument \(n)"
        case .midi: defaultName = "MIDI \(n)"
        case .externalInstrument: defaultName = "Ext Synth \(n)"
        case .group: defaultName = "Group \(n)"
        }
        let t = Track(name: name ?? defaultName, kind: kind, colorIndex: n % 12,
                      clipSlots: Array(repeating: nil, count: scenes.count))
        tracks.append(t)
        return t
    }

    /// Removes a track and everything that pointed at it (routes, modulation, CV).
    public mutating func removeTrack(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        let ep = EndpointID.track(id)
        midiRoutes.removeAll { $0.destination == ep || $0.source == ep }
        modulation.removeAll {
            switch $0.target {
            case let .pluginParameter(t, _, _), let .trackVolume(t), let .trackPan(t), let .sendLevel(t, _):
                return t == id
            case .cvOutput: return false
            }
        }
        for i in tracks.indices where tracks[i].groupID == id { tracks[i].groupID = nil }
    }

    // MARK: Persistence

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }
}

public enum Decibels {
    public static func toGain(_ db: Double) -> Double { db <= -96 ? 0 : pow(10, db / 20) }
    public static func fromGain(_ g: Double) -> Double { g <= 0 ? -96 : max(-96, 20 * log10(g)) }

    /// Equal-power pan law (-3 dB centre).
    public static func panGains(_ pan: Double) -> (left: Double, right: Double) {
        let p = (min(max(pan, -1), 1) + 1) * .pi / 4
        return (cos(p), sin(p))
    }
}
