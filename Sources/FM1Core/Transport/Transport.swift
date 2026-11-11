import Foundation

public struct TimeSignature: Codable, Hashable, Sendable {
    public var beatsPerBar: Int
    public var noteValue: Int
    public init(_ beatsPerBar: Int = 4, _ noteValue: Int = 4) {
        self.beatsPerBar = max(1, beatsPerBar)
        self.noteValue = max(1, noteValue)
    }
    /// Length of a bar in quarter-note beats (FM-1's beat unit everywhere).
    public var quarterNotesPerBar: Double { Double(beatsPerBar) * 4.0 / Double(noteValue) }
}

/// Where the tempo comes from.
public enum ClockSource: String, Codable, Sendable, CaseIterable {
    case internalClock      // FM-1 is the master
    case externalMIDI       // follow MIDI clock from a chosen input
    case abletonLink        // share tempo/phase with Link peers (AUM, Koala, Ableton, Bitwig...)
}

/// Sample-accurate musical timeline. Owned by the audio thread; the UI reads
/// snapshots. All positions are in quarter-note beats.
public struct Transport: Sendable {
    public var tempo: Double { didSet { tempo = min(max(tempo, 20), 999) } }
    public var timeSignature: TimeSignature
    public private(set) var isPlaying = false
    public private(set) var beatPosition: Double = 0
    public private(set) var sampleTime: Int64 = 0

    public init(tempo: Double = 120, timeSignature: TimeSignature = TimeSignature()) {
        self.tempo = min(max(tempo, 20), 999)
        self.timeSignature = timeSignature
    }

    public func beats(forFrames frames: Int, sampleRate: Double) -> Double {
        Double(frames) * tempo / (60.0 * sampleRate)
    }

    public func frames(forBeats beats: Double, sampleRate: Double) -> Double {
        beats * 60.0 * sampleRate / tempo
    }

    public mutating func play(from beat: Double? = nil) {
        if let beat { beatPosition = max(0, beat) }
        isPlaying = true
    }

    public mutating func stop() { isPlaying = false }

    public mutating func locate(_ beat: Double) { beatPosition = max(0, beat) }

    /// Advances one audio block; returns the beat range it covered (half-open).
    @discardableResult
    public mutating func advance(frames: Int, sampleRate: Double) -> Range<Double> {
        let start = beatPosition
        sampleTime += Int64(frames)
        guard isPlaying else { return start..<start }
        beatPosition += beats(forFrames: frames, sampleRate: sampleRate)
        return start..<beatPosition
    }

    public var bar: Int { Int(beatPosition / timeSignature.quarterNotesPerBar) }

    public var beatInBar: Double {
        beatPosition.truncatingRemainder(dividingBy: timeSignature.quarterNotesPerBar)
    }

    /// "bar.beat.sixteenth", 1-based, for the transport display.
    public var positionString: String {
        let qpb = timeSignature.quarterNotesPerBar
        let barNum = Int(beatPosition / qpb) + 1
        let inBar = beatPosition - Double(barNum - 1) * qpb
        let beatNum = Int(inBar) + 1
        let six = Int((inBar - floor(inBar)) * 4) + 1
        return "\(barNum).\(beatNum).\(six)"
    }
}

/// Generates 24 PPQN MIDI clock ticks sample-accurately for a block.
/// Phase is derived from the transport beat, so tempo changes never drift.
public struct MIDIClockGenerator: Sendable {
    public static let ppqn = 24.0
    public init() {}

    /// Frame offsets within the block at which a clock tick falls.
    public func tickOffsets(beatRange: Range<Double>, frames: Int) -> [Int] {
        guard frames > 0, beatRange.upperBound > beatRange.lowerBound else { return [] }
        let span = beatRange.upperBound - beatRange.lowerBound
        var out: [Int] = []
        var tick = (beatRange.lowerBound * Self.ppqn).rounded(.up)
        while tick / Self.ppqn < beatRange.upperBound {
            let beat = tick / Self.ppqn
            let offset = Int((((beat - beatRange.lowerBound) / span) * Double(frames)).rounded())
            out.append(min(max(offset, 0), frames - 1))
            tick += 1
        }
        return out
    }

    /// Song Position Pointer (in 16ths) for a beat, sent before Continue when locating.
    public static func songPosition(forBeat beat: Double) -> UInt16 {
        UInt16(min(max((beat * 4).rounded(.down), 0), 16383))
    }
}

/// Follows incoming MIDI clock and estimates tempo. Robust to jitter
/// (BLE-MIDI is notoriously jittery) via a sliding window over 24 ticks plus
/// outlier rejection.
public struct MIDIClockFollower: Sendable {
    private var times: [Double] = []
    private let window: Int
    public private(set) var tempo: Double?
    public private(set) var tickCount: Int = 0
    public private(set) var isRunning = false

    public init(window: Int = 48) {
        self.window = max(4, window)
        times.reserveCapacity(window + 1)
    }

    /// - Parameter time: arrival timestamp in seconds (use CoreMIDI timestamps, not wall clock).
    public mutating func handle(_ message: MIDIMessage, at time: Double) {
        switch message {
        case .clock:
            tickCount += 1
            if let last = times.last, time - last > 0.5 {
                times.removeAll(keepingCapacity: true) // clock stalled; restart estimate
            }
            times.append(time)
            if times.count > window { times.removeFirst(times.count - window) }
            estimate()
        case .start:
            isRunning = true
            tickCount = 0
        case .continue:
            isRunning = true
        case .stop:
            isRunning = false
        case let .songPosition(sixteenths):
            tickCount = Int(sixteenths) * 6
        default:
            break
        }
    }

    /// Beat position implied by ticks received since Start / SPP.
    public var beatPosition: Double { Double(tickCount) / MIDIClockGenerator.ppqn }

    private mutating func estimate() {
        guard times.count >= 4 else { return }
        var intervals: [Double] = []
        intervals.reserveCapacity(times.count - 1)
        for i in 1..<times.count { intervals.append(times[i] - times[i - 1]) }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return }
        // Reject outliers (dropped/bunched packets), then average.
        let kept = intervals.filter { abs($0 - median) < median * 0.5 }
        guard !kept.isEmpty else { return }
        let mean = kept.reduce(0, +) / Double(kept.count)
        let bpm = 60.0 / (mean * MIDIClockGenerator.ppqn)
        guard bpm.isFinite, (20...999).contains(bpm) else { return }
        // Round to 0.01 BPM to stop the display flickering.
        tempo = (bpm * 100).rounded() / 100
    }
}
