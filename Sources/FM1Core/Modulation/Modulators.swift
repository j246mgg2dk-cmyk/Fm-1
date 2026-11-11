import Foundation

/// Bitwig-style modulators. Any modulator can be dragged onto any parameter
/// of any hosted AUv3 (or the mixer, or a CV output) with its own depth.
/// Outputs are normalised: bipolar sources produce -1...1, unipolar 0...1.
public enum LFOShape: String, Codable, Sendable, CaseIterable {
    case sine, triangle, sawUp, sawDown, square, sampleAndHold
}

public enum ModulatorRate: Codable, Hashable, Sendable {
    case hertz(Double)
    /// Synced to transport; length of one cycle in quarter-note beats.
    case beats(Double)
}

public enum ModulatorKind: Codable, Hashable, Sendable {
    case lfo(shape: LFOShape, rate: ModulatorRate, phaseOffset: Double, bipolar: Bool)
    /// Gate comes from a track's notes (or a CV gate input).
    case adsr(attack: Double, decay: Double, sustain: Double, release: Double)
    /// Step sequencer modulator: values 0...1, one step per `stepBeats`.
    case steps(values: [Double], stepBeats: Double, glide: Double)
    /// Smoothed random walk / "Random" modulator.
    case random(rate: ModulatorRate, smoothing: Double)
    /// A macro knob the user (or a MIDI CC) moves by hand.
    case macro(value: Double)
    /// Follows the amplitude of a track's audio (envelope follower).
    case audioFollower(attack: Double, release: Double, gain: Double)
}

public struct ModulatorDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ModulatorKind
    /// Track whose notes gate an ADSR / whose audio drives a follower.
    public var sourceTrack: UUID?

    public init(id: UUID = UUID(), name: String, kind: ModulatorKind, sourceTrack: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceTrack = sourceTrack
    }
}

/// Per-modulator runtime state. Advanced once per audio block (control rate)
/// on the audio thread: no allocation after init.
public struct ModulatorState: Sendable {
    public var definition: ModulatorDefinition
    public private(set) var output: Double = 0

    private var phase: Double = 0
    private var envLevel: Double = 0
    private var envStage: EnvStage = .idle
    private var lastGate = false
    private var randomCurrent: Double = 0
    private var randomTarget: Double = 0
    private var shHeld: Double = 0
    private var rng: SplitMix64

    private enum EnvStage: Sendable { case idle, attack, decay, sustain, release }

    public init(_ definition: ModulatorDefinition, seed: UInt64 = 0x5EED_F00D) {
        self.definition = definition
        // Stable across launches (hashValue is randomised per process).
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in definition.id.uuidString.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        self.rng = SplitMix64(seed: seed ^ h)
    }

    public struct Inputs: Sendable {
        public var deltaSeconds: Double
        public var beatPosition: Double
        public var tempo: Double
        public var isPlaying: Bool
        public var gate: Bool
        public var audioLevel: Double
        public init(deltaSeconds: Double, beatPosition: Double, tempo: Double, isPlaying: Bool,
                    gate: Bool = false, audioLevel: Double = 0) {
            self.deltaSeconds = deltaSeconds
            self.beatPosition = beatPosition
            self.tempo = tempo
            self.isPlaying = isPlaying
            self.gate = gate
            self.audioLevel = audioLevel
        }
    }

    @discardableResult
    public mutating func advance(_ inp: Inputs) -> Double {
        switch definition.kind {
        case let .lfo(shape, rate, phaseOffset, bipolar):
            let p = advancePhase(rate: rate, inp: inp, offset: phaseOffset)
            let wrapped = p - floor(p)
            var v: Double
            switch shape {
            case .sine: v = sin(2 * .pi * wrapped)
            case .triangle: v = wrapped < 0.5 ? (4 * wrapped - 1) : (3 - 4 * wrapped)
            case .sawUp: v = 2 * wrapped - 1
            case .sawDown: v = 1 - 2 * wrapped
            case .square: v = wrapped < 0.5 ? 1 : -1
            case .sampleAndHold:
                if wrapped < lastWrapped { shHeld = rng.nextUnit() * 2 - 1 }
                v = shHeld
            }
            lastWrapped = wrapped
            if !bipolar { v = (v + 1) / 2 }
            output = v

        case let .adsr(a, d, s, r):
            output = advanceEnvelope(a: a, d: d, s: s, r: r, gate: inp.gate, dt: inp.deltaSeconds)

        case let .steps(values, stepBeats, glide):
            guard !values.isEmpty, stepBeats > 0 else { output = 0; break }
            let idx = Int(floor(inp.beatPosition / stepBeats)) % values.count
            let target = min(max(values[(idx + values.count) % values.count], 0), 1)
            if glide <= 0 {
                output = target
            } else {
                let coeff = 1 - exp(-inp.deltaSeconds / max(glide, 1e-4))
                output += (target - output) * coeff
            }

        case let .random(rate, smoothing):
            let p = advancePhase(rate: rate, inp: inp, offset: 0)
            let wrapped = p - floor(p)
            if wrapped < lastWrapped { randomTarget = rng.nextUnit() * 2 - 1 }
            lastWrapped = wrapped
            if smoothing <= 0 {
                randomCurrent = randomTarget
            } else {
                let coeff = 1 - exp(-inp.deltaSeconds / max(smoothing, 1e-4))
                randomCurrent += (randomTarget - randomCurrent) * coeff
            }
            output = randomCurrent

        case let .macro(value):
            output = min(max(value, 0), 1)

        case let .audioFollower(attack, release, gain):
            let target = min(max(inp.audioLevel * gain, 0), 1)
            let t = target > output ? attack : release
            let coeff = 1 - exp(-inp.deltaSeconds / max(t, 1e-4))
            output += (target - output) * coeff
        }
        return output
    }

    private var lastWrapped: Double = 1

    private mutating func advancePhase(rate: ModulatorRate, inp: Inputs, offset: Double) -> Double {
        switch rate {
        case let .hertz(hz):
            phase += hz * inp.deltaSeconds
            phase = phase - floor(phase)
            return phase + offset
        case let .beats(len):
            guard len > 0 else { return offset }
            if inp.isPlaying {
                // Locked to song position, so it's in phase every time you hit play.
                phase = inp.beatPosition / len
            } else {
                phase += (inp.tempo / 60.0) * inp.deltaSeconds / len
            }
            return phase + offset
        }
    }

    private mutating func advanceEnvelope(a: Double, d: Double, s: Double, r: Double, gate: Bool, dt: Double) -> Double {
        let sustain = min(max(s, 0), 1)
        if gate && !lastGate { envStage = .attack }
        if !gate && lastGate { envStage = .release }
        lastGate = gate
        switch envStage {
        case .idle:
            envLevel = 0
        case .attack:
            envLevel += a <= 0 ? 1 : dt / a
            if envLevel >= 1 { envLevel = 1; envStage = .decay }
        case .decay:
            envLevel -= d <= 0 ? 1 : dt * (1 - sustain) / d
            if envLevel <= sustain { envLevel = sustain; envStage = .sustain }
        case .sustain:
            envLevel = sustain
        case .release:
            envLevel -= r <= 0 ? 1 : dt / r
            if envLevel <= 0 { envLevel = 0; envStage = .idle }
        }
        return envLevel
    }
}

/// Small, fast, deterministic PRNG (no allocation, audio-thread safe).
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
