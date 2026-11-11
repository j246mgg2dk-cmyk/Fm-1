import Foundation

/// CV output over a DC-coupled audio interface (Expert Sleepers ES-8/ES-9,
/// MOTU UltraLite mk5, etc.). Mod-Lab writes DC sample values; the interface turns
/// full-scale (±1.0) into ±`fullScaleVolts`.
public struct CVCalibration: Codable, Hashable, Sendable {
    /// Volts produced by a sample value of 1.0. ES-8: 10 V. MOTU mk5: ~10 V (check with a meter).
    public var fullScaleVolts: Double = 10
    /// Trim, in volts, added before conversion (tune each output against a tuner).
    public var offsetVolts: Double = 0
    /// Scale trim; 1.0 = perfect 1 V/oct. Adjust if octaves come out sharp/flat.
    public var scaleTrim: Double = 1

    public init(fullScaleVolts: Double = 10, offsetVolts: Double = 0, scaleTrim: Double = 1) {
        self.fullScaleVolts = fullScaleVolts
        self.offsetVolts = offsetVolts
        self.scaleTrim = scaleTrim
    }

    public func sample(forVolts v: Double) -> Float {
        let s = (v * scaleTrim + offsetVolts) / fullScaleVolts
        return Float(min(max(s, -1), 1))
    }
}

public enum CVSource: Codable, Hashable, Sendable {
    /// 1 V/oct pitch from a track's mono note tracker (+ pitch bend range in semitones).
    case pitch(track: UUID, bendRange: Double)
    /// Gate high while a key is held on the track.
    case gate(track: UUID)
    /// Short pulse on every new note (for envelopes that need retrigger).
    case trigger(track: UUID)
    /// Velocity as 0...maxVolts.
    case velocity(track: UUID)
    /// Clock pulses at `pulsesPerQuarter` (1 = quarter notes, 4 = 16ths, 24 = DIN-sync style).
    case clock(pulsesPerQuarter: Int)
    /// Pulse on transport start / every N bars (reset for sequencers).
    case reset(everyBars: Int)
    /// Any modulator, scaled into minVolts...maxVolts.
    case modulator(UUID)
    /// Fixed voltage (handy for calibration).
    case constant(volts: Double)
}

public struct CVOutputConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Hardware output channel, 0-based.
    public var channel: Int
    public var source: CVSource
    public var minVolts: Double
    public var maxVolts: Double
    /// MIDI note that produces 0 V on pitch outputs (36 = C2 is common).
    public var zeroVoltNote: Int
    public var quantizer: ScaleQuantizer?
    public var calibration: CVCalibration
    public var pulseWidthMs: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, channel: Int, source: CVSource,
                minVolts: Double = 0, maxVolts: Double = 5, zeroVoltNote: Int = 36,
                quantizer: ScaleQuantizer? = nil, calibration: CVCalibration = CVCalibration(),
                pulseWidthMs: Double = 5, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.channel = channel
        self.source = source
        self.minVolts = minVolts
        self.maxVolts = maxVolts
        self.zeroVoltNote = zeroVoltNote
        self.quantizer = quantizer
        self.calibration = calibration
        self.pulseWidthMs = pulseWidthMs
        self.isEnabled = isEnabled
    }

    /// 1 V/oct.
    public func volts(forNote note: Double) -> Double {
        var n = note
        if let q = quantizer { n = Double(q.quantize(Int(n.rounded()))) + (note - note.rounded()) }
        return (n - Double(zeroVoltNote)) / 12.0
    }

    /// For unipolar 0...1 or bipolar -1...1 sources.
    public func volts(forNormalised x: Double, bipolar: Bool) -> Double {
        let u = bipolar ? (x + 1) / 2 : x
        return minVolts + (maxVolts - minVolts) * min(max(u, 0), 1)
    }
}

/// Snaps notes to a scale; useful for random/modulator-driven pitch into modular.
public struct ScaleQuantizer: Codable, Hashable, Sendable {
    public enum Scale: String, Codable, Sendable, CaseIterable {
        case chromatic, major, minor, dorian, phrygian, lydian, mixolydian,
             majorPentatonic, minorPentatonic, blues, wholeTone, harmonicMinor

        public var intervals: [Int] {
            switch self {
            case .chromatic: return Array(0..<12)
            case .major: return [0, 2, 4, 5, 7, 9, 11]
            case .minor: return [0, 2, 3, 5, 7, 8, 10]
            case .dorian: return [0, 2, 3, 5, 7, 9, 10]
            case .phrygian: return [0, 1, 3, 5, 7, 8, 10]
            case .lydian: return [0, 2, 4, 6, 7, 9, 11]
            case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
            case .majorPentatonic: return [0, 2, 4, 7, 9]
            case .minorPentatonic: return [0, 3, 5, 7, 10]
            case .blues: return [0, 3, 5, 6, 7, 10]
            case .wholeTone: return [0, 2, 4, 6, 8, 10]
            case .harmonicMinor: return [0, 2, 3, 5, 7, 8, 11]
            }
        }
    }

    public var root: Int   // 0 = C
    public var scale: Scale

    public init(root: Int = 0, scale: Scale = .chromatic) {
        self.root = ((root % 12) + 12) % 12
        self.scale = scale
    }

    /// Nearest in-scale note; ties resolve downward.
    public func quantize(_ note: Int) -> Int {
        let rel = note - root
        let octave = Int(floor(Double(rel) / 12.0))
        let pc = rel - octave * 12
        var best = scale.intervals[0]
        var bestDist = Int.max
        // Include the next octave's root so e.g. B can snap up to C.
        for iv in scale.intervals + [12] {
            let d = abs(iv - pc)
            if d < bestDist { best = iv; bestDist = d }
        }
        return root + octave * 12 + best
    }
}
