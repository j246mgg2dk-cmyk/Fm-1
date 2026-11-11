/// Turns polyphonic MIDI into a single pitch + gate for CV / monosynths.
/// Last-note priority with a held-note stack, so releasing a key falls back to
/// the previous still-held key (legato behaviour expected on modular).
public struct MonoNoteTracker: Sendable {
    public enum Priority: String, Codable, Sendable { case last, lowest, highest }

    public var priority: Priority
    public private(set) var stack: [UInt8] = []
    public private(set) var velocity: UInt8 = 0
    /// Increments on every new note-on; CV outputs use it to emit a retrigger pulse.
    public private(set) var triggerCount: UInt64 = 0
    public private(set) var pitchBend: Double = 0 // -1...1

    public init(priority: Priority = .last) {
        self.priority = priority
        stack.reserveCapacity(16)
    }

    public var gate: Bool { !stack.isEmpty }

    public var currentNote: UInt8? {
        switch priority {
        case .last: return stack.last
        case .lowest: return stack.min()
        case .highest: return stack.max()
        }
    }

    public mutating func handle(_ m: MIDIMessage) {
        switch m {
        case let .noteOn(_, n, v) where v > 0:
            stack.removeAll { $0 == n }
            if stack.count >= 16 { stack.removeFirst() }
            stack.append(n)
            velocity = v
            triggerCount &+= 1
        case let .noteOn(_, n, _), let .noteOff(_, n, _):
            stack.removeAll { $0 == n }
        case let .pitchBend(_, v):
            pitchBend = (Double(v) - 8192.0) / 8192.0
        case .controlChange(_, 123, _), .controlChange(_, 120, _), .systemReset:
            stack.removeAll()
        default:
            break
        }
    }
}
