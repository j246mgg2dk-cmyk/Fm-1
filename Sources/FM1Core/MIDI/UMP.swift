/// Conversion between Universal MIDI Packets (what CoreMIDI's modern
/// `MIDIEventList` APIs speak) and plain MIDI 1.0 messages.
///
/// Mod-Lab opens its CoreMIDI ports with the MIDI 1.0 protocol so CoreMIDI
/// hands us type 1/2/3 packets. Type 4 (MIDI 2.0 channel voice) is down-converted
/// as a fallback so nothing is silently dropped.
public struct UMPDecoder {
    private var sysex: [UInt8] = []
    private var inSysex = false

    public init() {}

    public mutating func decode<C: Collection>(_ words: C) -> [MIDIMessage] where C.Element == UInt32, C.Index == Int {
        var out: [MIDIMessage] = []
        var i = words.startIndex
        while i < words.endIndex {
            let w0 = words[i]
            let type = UInt8(w0 >> 28)
            let size = UMPDecoder.wordCount(forType: type)
            guard i + size <= words.endIndex else { break }
            switch type {
            case 0x1:
                let status = UInt8((w0 >> 16) & 0xFF)
                let d1 = UInt8((w0 >> 8) & 0x7F)
                let d2 = UInt8(w0 & 0x7F)
                if let m = MIDIMessage(status: status, data1: d1, data2: d2) { out.append(m) }
            case 0x2:
                let status = UInt8((w0 >> 16) & 0xFF)
                let d1 = UInt8((w0 >> 8) & 0x7F)
                let d2 = UInt8(w0 & 0x7F)
                if let m = MIDIMessage(status: status, data1: d1, data2: d2) { out.append(m) }
            case 0x3:
                decodeSysex7(w0, words[i + 1], into: &out)
            case 0x4:
                if let m = downconvertMIDI2(w0, words[i + 1]) { out.append(m) }
            default:
                break
            }
            i += size
        }
        return out
    }

    public static func wordCount(forType type: UInt8) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4 // 0x5, 0xD, 0xE, 0xF
        }
    }

    private mutating func decodeSysex7(_ w0: UInt32, _ w1: UInt32, into out: inout [MIDIMessage]) {
        let status = UInt8((w0 >> 20) & 0xF)
        let count = Int((w0 >> 16) & 0xF)
        let payload: [UInt8] = [
            UInt8((w0 >> 8) & 0x7F), UInt8(w0 & 0x7F),
            UInt8((w1 >> 24) & 0x7F), UInt8((w1 >> 16) & 0x7F),
            UInt8((w1 >> 8) & 0x7F), UInt8(w1 & 0x7F),
        ]
        let bytes = payload.prefix(min(count, 6))
        switch status {
        case 0x0: // complete in one packet
            var complete: [UInt8] = [0xF0]
            complete.append(contentsOf: bytes)
            complete.append(0xF7)
            out.append(.sysex(complete))
            inSysex = false
        case 0x1: // start
            sysex = [0xF0]
            sysex.append(contentsOf: bytes)
            inSysex = true
        case 0x2: // continue
            if inSysex { sysex.append(contentsOf: bytes) }
        case 0x3: // end
            if inSysex {
                sysex.append(contentsOf: bytes)
                sysex.append(0xF7)
                out.append(.sysex(sysex))
            }
            sysex.removeAll()
            inSysex = false
        default:
            break
        }
    }

    private func downconvertMIDI2(_ w0: UInt32, _ w1: UInt32) -> MIDIMessage? {
        let status = UInt8((w0 >> 16) & 0xF0)
        let ch = UInt8((w0 >> 16) & 0x0F)
        let idx = UInt8((w0 >> 8) & 0x7F)
        switch status {
        case 0x80: return .noteOff(channel: ch, note: idx, velocity: UInt8(w1 >> 25))
        case 0x90:
            // MIDI 2.0 velocity 0 is legal for note-on; never let it become a note-off.
            let v = UInt8(w1 >> 25)
            return .noteOn(channel: ch, note: idx, velocity: max(v, 1))
        case 0xA0: return .polyPressure(channel: ch, note: idx, pressure: UInt8(w1 >> 25))
        case 0xB0: return .controlChange(channel: ch, controller: idx, value: UInt8(w1 >> 25))
        case 0xC0: return .programChange(channel: ch, program: UInt8((w1 >> 24) & 0x7F))
        case 0xD0: return .channelPressure(channel: ch, pressure: UInt8(w1 >> 25))
        case 0xE0: return .pitchBend(channel: ch, value: UInt16(w1 >> 18))
        default: return nil
        }
    }
}

public enum UMPEncoder {
    /// Encodes a MIDI 1.0 message as UMP words (MIDI 1.0 protocol, types 1/2/3).
    public static func words(for message: MIDIMessage, group: UInt8 = 0) -> [UInt32] {
        let g = UInt32(group & 0xF) << 24
        if case let .sysex(data) = message {
            return sysex7Words(data, group: g)
        }
        let b = message.bytes
        guard let status = b.first else { return [] }
        let type: UInt32 = status >= 0xF0 ? 0x1 : 0x2
        let d1 = b.count > 1 ? UInt32(b[1]) : 0
        let d2 = b.count > 2 ? UInt32(b[2]) : 0
        return [(type << 28) | g | (UInt32(status) << 16) | (d1 << 8) | d2]
    }

    private static func sysex7Words(_ data: [UInt8], group g: UInt32) -> [UInt32] {
        // Strip F0/F7 framing; UMP carries only the payload.
        var payload = data
        if payload.first == 0xF0 { payload.removeFirst() }
        if payload.last == 0xF7 { payload.removeLast() }

        var chunks: [ArraySlice<UInt8>] = []
        var idx = 0
        repeat {
            let end = min(idx + 6, payload.count)
            chunks.append(payload[idx..<end])
            idx = end
        } while idx < payload.count

        var words: [UInt32] = []
        for (n, chunk) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 { status = 0x0 }
            else if n == 0 { status = 0x1 }
            else if n == chunks.count - 1 { status = 0x3 }
            else { status = 0x2 }
            var p = [UInt8](repeating: 0, count: 6)
            for (k, byte) in chunk.enumerated() { p[k] = byte & 0x7F }
            let w0 = (UInt32(0x3) << 28) | g | (status << 20) | (UInt32(chunk.count) << 16)
                | (UInt32(p[0]) << 8) | UInt32(p[1])
            let w1 = (UInt32(p[2]) << 24) | (UInt32(p[3]) << 16) | (UInt32(p[4]) << 8) | UInt32(p[5])
            words.append(w0)
            words.append(w1)
        }
        return words
    }
}
