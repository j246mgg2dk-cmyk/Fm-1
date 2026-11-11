import Foundation

public struct NoteEvent: Codable, Hashable, Sendable {
    public var start: Double     // beats from clip start
    public var length: Double    // beats
    public var note: UInt8
    public var velocity: UInt8
    /// Probability 0...1 that the note plays each loop (Bitwig-style note expression).
    public var chance: Double

    public init(start: Double, length: Double, note: UInt8, velocity: UInt8 = 100, chance: Double = 1) {
        self.start = max(0, start)
        self.length = max(1.0 / 960.0, length)
        self.note = min(note, 127)
        self.velocity = max(1, min(velocity, 127))
        self.chance = min(max(chance, 0), 1)
    }

    public var end: Double { start + length }
}

public struct MIDIClipData: Codable, Hashable, Sendable {
    public var notes: [NoteEvent]
    public var lengthBeats: Double

    public init(notes: [NoteEvent] = [], lengthBeats: Double = 4) {
        self.notes = notes.sorted { $0.start < $1.start }
        self.lengthBeats = max(0.25, lengthBeats)
    }

    /// Snap note starts to a grid (beats). `strength` 0...1 like Ableton's quantize amount.
    public func quantized(grid: Double, strength: Double = 1) -> MIDIClipData {
        guard grid > 0 else { return self }
        let s = min(max(strength, 0), 1)
        let notes = self.notes.map { n -> NoteEvent in
            var q = n
            let target = (n.start / grid).rounded() * grid
            q.start = max(0, n.start + (target - n.start) * s)
            return q
        }
        return MIDIClipData(notes: notes, lengthBeats: lengthBeats)
    }
}

/// A scheduled MIDI event inside one audio block.
public struct ScheduledMIDI: Equatable, Sendable {
    /// Beats from the start of the block.
    public var beatOffset: Double
    public var message: MIDIMessage
}

/// Plays a looping MIDI clip against the transport. Audio-thread friendly:
/// no allocation once `reserveCapacity` has been done by init.
public struct MIDIClipPlayer: Sendable {
    public private(set) var clip: MIDIClipData
    public private(set) var launchBeat: Double
    public var channel: UInt8
    public var loop: Bool
    private var active: [UInt8] = []
    private var rng = SplitMix64(seed: 0xC11F)
    private var skipped: [Bool]

    public init(clip: MIDIClipData, launchBeat: Double, channel: UInt8 = 0, loop: Bool = true) {
        self.clip = clip
        self.launchBeat = launchBeat
        self.channel = channel
        self.loop = loop
        active.reserveCapacity(128)
        skipped = Array(repeating: false, count: clip.notes.count)
    }

    public var activeNotes: [UInt8] { active }

    /// Emits note events for the song-time block [range.lowerBound, range.upperBound).
    public mutating func render(_ range: Range<Double>, into out: inout [ScheduledMIDI]) {
        guard range.upperBound > range.lowerBound, range.upperBound > launchBeat else { return }
        let len = clip.lengthBeats
        let blockStart = max(range.lowerBound, launchBeat)
        var localStart = blockStart - launchBeat
        let localEnd = range.upperBound - launchBeat

        if !loop {
            guard localStart < len else { return }
            let first = out.count
            emit(lo: localStart, hi: min(localEnd, len), loopIndex: 0, songOffset: launchBeat - range.lowerBound, into: &out)
            Self.sortBlock(&out, from: first)
            return
        }

        // Walk the block one loop segment at a time (handles blocks longer than the clip too).
        let first = out.count
        var loopIndex = floor(localStart / len)
        while true {
            let segBase = loopIndex * len
            let lo = max(0, localStart - segBase)
            if lo < len {
                let hi = min(localEnd - segBase, len)
                if hi > lo {
                    emit(lo: lo, hi: hi, loopIndex: Int(loopIndex),
                         songOffset: launchBeat + segBase - range.lowerBound, into: &out)
                }
            }
            if localEnd - segBase <= len { break }
            loopIndex += 1
            localStart = loopIndex * len
        }
        Self.sortBlock(&out, from: first)
    }

    /// Time order; at equal times note-offs go first so retriggers are clean.
    static func sortBlock(_ out: inout [ScheduledMIDI], from first: Int) {
        guard out.count - first > 1 else { return }
        out[first...].sort { a, b in
            if a.beatOffset != b.beatOffset { return a.beatOffset < b.beatOffset }
            return a.message.isNoteOff && !b.message.isNoteOff
        }
    }

    private mutating func emit(lo: Double, hi: Double, loopIndex: Int, songOffset: Double, into out: inout [ScheduledMIDI]) {
        let len = clip.lengthBeats
        // 1. Ends of notes that started in an earlier segment/block.
        for (i, n) in clip.notes.enumerated() where n.start < lo {
            let end = min(n.end, len)
            if end > lo && end <= hi, !skipped[i], let idx = active.firstIndex(of: n.note) {
                active.remove(at: idx)
                out.append(ScheduledMIDI(beatOffset: songOffset + end, message: .noteOff(channel: channel, note: n.note, velocity: 0)))
            }
        }
        // 2. Starts in this segment, and their ends if they also fall inside it.
        for (i, n) in clip.notes.enumerated() where n.start >= lo && n.start < hi {
            if n.chance < 1, rng.nextUnit() >= n.chance {
                skipped[i] = true
                continue
            }
            skipped[i] = false
            if active.contains(n.note) {
                out.append(ScheduledMIDI(beatOffset: songOffset + n.start, message: .noteOff(channel: channel, note: n.note, velocity: 0)))
            } else if active.count < 128 {
                active.append(n.note)
            }
            out.append(ScheduledMIDI(beatOffset: songOffset + n.start, message: .noteOn(channel: channel, note: n.note, velocity: n.velocity)))
            let end = min(n.end, len)
            if end <= hi, let idx = active.firstIndex(of: n.note) {
                active.remove(at: idx)
                out.append(ScheduledMIDI(beatOffset: songOffset + end, message: .noteOff(channel: channel, note: n.note, velocity: 0)))
            }
        }
    }

    /// Note-offs for everything still sounding (clip stopped or replaced).
    public mutating func stop(into out: inout [ScheduledMIDI], atBeatOffset offset: Double = 0) {
        for n in active {
            out.append(ScheduledMIDI(beatOffset: offset, message: .noteOff(channel: channel, note: n, velocity: 0)))
        }
        active.removeAll(keepingCapacity: true)
    }
}

/// Captures live MIDI into a clip while recording (overdub-friendly).
public struct MIDIClipRecorder: Sendable {
    private var open: [UInt8: (start: Double, velocity: UInt8)] = [:]
    public private(set) var notes: [NoteEvent] = []
    public let startBeat: Double

    public init(startBeat: Double) { self.startBeat = startBeat }

    public mutating func handle(_ m: MIDIMessage, atBeat beat: Double) {
        let t = beat - startBeat
        switch m {
        case let .noteOn(_, n, v) where v > 0:
            if let o = open[n] { notes.append(NoteEvent(start: o.start, length: t - o.start, note: n, velocity: o.velocity)) }
            open[n] = (t, v)
        case let .noteOn(_, n, _), let .noteOff(_, n, _):
            if let o = open.removeValue(forKey: n) {
                notes.append(NoteEvent(start: o.start, length: t - o.start, note: n, velocity: o.velocity))
            }
        default:
            break
        }
    }

    /// Closes held notes and returns a clip whose length is rounded up to whole bars.
    public mutating func finish(atBeat beat: Double, barLength: Double) -> MIDIClipData {
        let t = beat - startBeat
        for (n, o) in open { notes.append(NoteEvent(start: o.start, length: t - o.start, note: n, velocity: o.velocity)) }
        open.removeAll()
        let bars = max(1, (t / barLength).rounded(.up))
        return MIDIClipData(notes: notes, lengthBeats: bars * barLength)
    }
}
