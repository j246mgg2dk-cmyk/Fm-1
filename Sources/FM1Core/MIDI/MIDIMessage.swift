/// A MIDI 1.0 message. Channels are 0-based (0...15) internally; the UI shows 1...16.
public enum MIDIMessage: Hashable, Sendable {
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case polyPressure(channel: UInt8, note: UInt8, pressure: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case channelPressure(channel: UInt8, pressure: UInt8)
    /// 14-bit value, 8192 = centre.
    case pitchBend(channel: UInt8, value: UInt16)

    case sysex([UInt8])          // full message including F0 ... F7
    case timeCodeQuarterFrame(UInt8)
    case songPosition(UInt16)    // in MIDI beats (16th notes)
    case songSelect(UInt8)
    case tuneRequest

    case clock
    case start
    case `continue`
    case stop
    case activeSensing
    case systemReset

    public var channel: UInt8? {
        switch self {
        case let .noteOff(c, _, _), let .noteOn(c, _, _), let .polyPressure(c, _, _),
             let .controlChange(c, _, _), let .programChange(c, _), let .channelPressure(c, _),
             let .pitchBend(c, _):
            return c
        default:
            return nil
        }
    }

    /// Returns the same message on another channel. Non-channel messages are returned unchanged.
    public func withChannel(_ ch: UInt8) -> MIDIMessage {
        let c = ch & 0x0F
        switch self {
        case let .noteOff(_, n, v): return .noteOff(channel: c, note: n, velocity: v)
        case let .noteOn(_, n, v): return .noteOn(channel: c, note: n, velocity: v)
        case let .polyPressure(_, n, p): return .polyPressure(channel: c, note: n, pressure: p)
        case let .controlChange(_, cc, v): return .controlChange(channel: c, controller: cc, value: v)
        case let .programChange(_, p): return .programChange(channel: c, program: p)
        case let .channelPressure(_, p): return .channelPressure(channel: c, pressure: p)
        case let .pitchBend(_, v): return .pitchBend(channel: c, value: v)
        default: return self
        }
    }

    public var isRealtime: Bool {
        switch self {
        case .clock, .start, .continue, .stop, .activeSensing, .systemReset: return true
        default: return false
        }
    }

    public var isTransport: Bool {
        switch self {
        case .start, .continue, .stop, .songPosition: return true
        default: return false
        }
    }

    /// A note-on with velocity 0 is a note-off by the MIDI spec.
    public var isNoteOff: Bool {
        switch self {
        case .noteOff: return true
        case let .noteOn(_, _, v): return v == 0
        default: return false
        }
    }

    public var isNoteOn: Bool {
        if case let .noteOn(_, _, v) = self { return v > 0 }
        return false
    }

    /// Wire bytes.
    public var bytes: [UInt8] {
        switch self {
        case let .noteOff(c, n, v): return [0x80 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case let .noteOn(c, n, v): return [0x90 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case let .polyPressure(c, n, p): return [0xA0 | (c & 0x0F), n & 0x7F, p & 0x7F]
        case let .controlChange(c, cc, v): return [0xB0 | (c & 0x0F), cc & 0x7F, v & 0x7F]
        case let .programChange(c, p): return [0xC0 | (c & 0x0F), p & 0x7F]
        case let .channelPressure(c, p): return [0xD0 | (c & 0x0F), p & 0x7F]
        case let .pitchBend(c, v):
            let v14 = min(v, 0x3FFF)
            return [0xE0 | (c & 0x0F), UInt8(v14 & 0x7F), UInt8((v14 >> 7) & 0x7F)]
        case let .sysex(data): return data
        case let .timeCodeQuarterFrame(v): return [0xF1, v & 0x7F]
        case let .songPosition(p):
            let p14 = min(p, 0x3FFF)
            return [0xF2, UInt8(p14 & 0x7F), UInt8((p14 >> 7) & 0x7F)]
        case let .songSelect(s): return [0xF3, s & 0x7F]
        case .tuneRequest: return [0xF6]
        case .clock: return [0xF8]
        case .start: return [0xFA]
        case .continue: return [0xFB]
        case .stop: return [0xFC]
        case .activeSensing: return [0xFE]
        case .systemReset: return [0xFF]
        }
    }

    /// Number of data bytes that follow a channel-voice / system-common status byte.
    static func dataLength(forStatus status: UInt8) -> Int? {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        case 0xC0, 0xD0: return 1
        default: break
        }
        switch status {
        case 0xF1, 0xF3: return 1
        case 0xF2: return 2
        case 0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF: return 0
        default: return nil // F0 (sysex), undefined
        }
    }

    /// Builds a message from a complete status + data sequence (no running status).
    public init?(status: UInt8, data1: UInt8 = 0, data2: UInt8 = 0) {
        let c = status & 0x0F
        switch status & 0xF0 {
        case 0x80: self = .noteOff(channel: c, note: data1, velocity: data2)
        case 0x90: self = .noteOn(channel: c, note: data1, velocity: data2)
        case 0xA0: self = .polyPressure(channel: c, note: data1, pressure: data2)
        case 0xB0: self = .controlChange(channel: c, controller: data1, value: data2)
        case 0xC0: self = .programChange(channel: c, program: data1)
        case 0xD0: self = .channelPressure(channel: c, pressure: data1)
        case 0xE0: self = .pitchBend(channel: c, value: UInt16(data1) | (UInt16(data2) << 7))
        default:
            switch status {
            case 0xF1: self = .timeCodeQuarterFrame(data1)
            case 0xF2: self = .songPosition(UInt16(data1) | (UInt16(data2) << 7))
            case 0xF3: self = .songSelect(data1)
            case 0xF6: self = .tuneRequest
            case 0xF8: self = .clock
            case 0xFA: self = .start
            case 0xFB: self = .continue
            case 0xFC: self = .stop
            case 0xFE: self = .activeSensing
            case 0xFF: self = .systemReset
            default: return nil
            }
        }
    }
}

/// Streaming MIDI 1.0 byte parser. Handles running status, realtime bytes
/// interleaved anywhere (including inside sysex) and sysex split across packets.
/// Not thread-safe: use one parser per input stream.
public struct MIDIParser {
    private var runningStatus: UInt8 = 0
    private var pending: [UInt8] = []
    private var expected: Int = 0
    private var sysex: [UInt8]? = nil
    /// Hard cap so a stuck sysex stream can't grow memory forever.
    public var maxSysexLength = 64 * 1024

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [MIDIMessage] where S.Element == UInt8 {
        var out: [MIDIMessage] = []
        for b in bytes { feed(byte: b, into: &out) }
        return out
    }

    public mutating func feed(byte b: UInt8, into out: inout [MIDIMessage]) {
        // System realtime: single byte, may appear anywhere, never affects running status.
        if b >= 0xF8 {
            if let m = MIDIMessage(status: b) { out.append(m) }
            return
        }

        if b == 0xF0 {
            sysex = [0xF0]
            runningStatus = 0
            pending.removeAll(keepingCapacity: true)
            return
        }

        if b == 0xF7 {
            if var s = sysex {
                s.append(0xF7)
                out.append(.sysex(s))
            }
            sysex = nil
            return
        }

        if var s = sysex {
            if b & 0x80 == 0 {
                if s.count < maxSysexLength { s.append(b) }
                sysex = s
                return
            }
            // A status byte inside sysex terminates it (malformed); drop the sysex.
            sysex = nil
        }

        if b & 0x80 != 0 {
            guard let len = MIDIMessage.dataLength(forStatus: b) else {
                runningStatus = 0
                return
            }
            // System common clears running status; channel voice sets it.
            runningStatus = b < 0xF0 ? b : 0
            pending = [b]
            expected = len
            if len == 0 {
                if let m = MIDIMessage(status: b) { out.append(m) }
                pending.removeAll(keepingCapacity: true)
            }
            return
        }

        // Data byte.
        if pending.isEmpty {
            guard runningStatus != 0, let len = MIDIMessage.dataLength(forStatus: runningStatus) else { return }
            pending = [runningStatus]
            expected = len
        }
        pending.append(b)
        if pending.count == expected + 1 {
            let m = MIDIMessage(
                status: pending[0],
                data1: pending.count > 1 ? pending[1] : 0,
                data2: pending.count > 2 ? pending[2] : 0
            )
            if let m { out.append(m) }
            pending.removeAll(keepingCapacity: true)
        }
    }
}
