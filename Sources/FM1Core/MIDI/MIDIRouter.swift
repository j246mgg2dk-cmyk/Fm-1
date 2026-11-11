import Foundation

/// Stable identity for anything that can send or receive MIDI.
/// CoreMIDI object refs change on reconnect (especially Bluetooth), so routes
/// are stored by kind + display name and re-bound when devices come back.
public struct EndpointID: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hardware      // USB / DIN interfaces, class-compliant synths
        case bluetooth     // BLE-MIDI
        case network       // RTP-MIDI session
        case virtualPort   // other apps: AUM, Koala, Drambo ... and FM-1's own virtual ports
        case track         // an FM-1 track input
        case plugin        // MIDI output of a hosted AUv3
        case internalClock // FM-1's transport/clock generator
    }

    public var kind: Kind
    public var name: String

    public init(_ kind: Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    public var description: String { "\(kind.rawValue):\(name)" }
}

public enum VelocityCurve: Codable, Hashable, Sendable {
    case linear
    case soft          // easier to play loud
    case hard          // need to hit harder
    case fixed(UInt8)
    case scaled(min: UInt8, max: UInt8)

    public func apply(_ v: UInt8) -> UInt8 {
        guard v > 0 else { return 0 }
        let x = Double(v) / 127.0
        let y: Double
        switch self {
        case .linear: return v
        case .soft: y = x.squareRoot()
        case .hard: y = x * x
        case let .fixed(f): return max(1, min(127, f))
        case let .scaled(lo, hi):
            let l = Double(min(lo, hi)), h = Double(max(lo, hi))
            y = (l + (h - l) * x) / 127.0
        }
        return UInt8(max(1, min(127, (y * 127.0).rounded())))
    }
}

/// Which messages a route lets through. Defaults pass everything.
public struct MIDIFilter: Codable, Hashable, Sendable {
    /// Source channels (0-based). Empty = all channels.
    public var channels: Set<UInt8> = []
    /// Key-range for splits/layers.
    public var lowestNote: UInt8 = 0
    public var highestNote: UInt8 = 127
    public var notes = true
    public var controlChanges = true
    public var pitchBend = true
    public var aftertouch = true
    public var programChanges = true
    public var clock = true
    public var transport = true
    public var sysex = true

    public init() {}

    public func passes(_ m: MIDIMessage) -> Bool {
        if let ch = m.channel, !channels.isEmpty, !channels.contains(ch) { return false }
        switch m {
        case let .noteOn(_, n, _), let .noteOff(_, n, _):
            return notes && n >= lowestNote && n <= highestNote
        case let .polyPressure(_, n, _):
            return aftertouch && n >= lowestNote && n <= highestNote
        case .channelPressure: return aftertouch
        case .controlChange: return controlChanges
        case .pitchBend: return pitchBend
        case .programChange: return programChanges
        case .clock: return clock
        case .start, .stop, .continue, .songPosition: return transport
        case .sysex: return sysex
        default: return true
        }
    }
}

/// What a route does to messages that pass its filter.
public struct MIDITransform: Codable, Hashable, Sendable {
    /// Force everything onto this channel (0-based). nil = keep.
    public var outputChannel: UInt8? = nil
    /// Semitones. Notes pushed outside 0...127 are dropped.
    public var transpose: Int = 0
    public var velocity: VelocityCurve = .linear
    /// Remap CC numbers, e.g. mod wheel (1) -> filter cutoff (74) on a hardware synth.
    public var ccRemap: [UInt8: UInt8] = [:]

    public init() {}

    public var isIdentity: Bool {
        outputChannel == nil && transpose == 0 && velocity == .linear && ccRemap.isEmpty
    }

    public func apply(_ m: MIDIMessage) -> MIDIMessage? {
        var msg = m
        if let ch = outputChannel { msg = msg.withChannel(ch) }
        switch msg {
        case let .noteOn(c, n, v):
            guard let tn = transposed(n) else { return nil }
            return .noteOn(channel: c, note: tn, velocity: v == 0 ? 0 : velocity.apply(v))
        case let .noteOff(c, n, v):
            guard let tn = transposed(n) else { return nil }
            return .noteOff(channel: c, note: tn, velocity: v)
        case let .polyPressure(c, n, p):
            guard let tn = transposed(n) else { return nil }
            return .polyPressure(channel: c, note: tn, pressure: p)
        case let .controlChange(c, cc, v):
            return .controlChange(channel: c, controller: ccRemap[cc] ?? cc, value: v)
        default:
            return msg
        }
    }

    private func transposed(_ n: UInt8) -> UInt8? {
        let t = Int(n) + transpose
        return (0...127).contains(t) ? UInt8(t) : nil
    }
}

public struct MIDIRoute: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: EndpointID
    public var destination: EndpointID
    public var isEnabled: Bool
    public var filter: MIDIFilter
    public var transform: MIDITransform

    public init(id: UUID = UUID(), source: EndpointID, destination: EndpointID,
                isEnabled: Bool = true, filter: MIDIFilter = MIDIFilter(), transform: MIDITransform = MIDITransform()) {
        self.id = id
        self.source = source
        self.destination = destination
        self.isEnabled = isEnabled
        self.filter = filter
        self.transform = transform
    }
}

public struct RoutedMIDI: Equatable, Sendable {
    public var destination: EndpointID
    public var message: MIDIMessage
    public init(_ destination: EndpointID, _ message: MIDIMessage) {
        self.destination = destination
        self.message = message
    }
}

/// The patchbay. Every MIDI message in FM-1 passes through here, whether it
/// comes from a USB keyboard, a BLE controller, AUM, a plugin's MIDI out or the
/// internal clock.
///
/// Guarantees no stuck notes: the router remembers where every note-on went,
/// so the matching note-off always reaches the same destination with the same
/// channel/transpose even if the route was edited (or deleted) while the key
/// was held.
///
/// Thread-safe. Intended to run on the CoreMIDI receive thread, never on the audio thread.
public final class MIDIRouter: @unchecked Sendable {
    private struct HeldKey: Hashable {
        var route: UUID
        var source: EndpointID
        var channel: UInt8
        var note: UInt8
    }

    private struct HeldTarget: Hashable {
        var destination: EndpointID
        var channel: UInt8
        var note: UInt8
    }

    private let lock = NSLock()
    private var routes: [MIDIRoute] = []
    private var routesBySource: [EndpointID: [MIDIRoute]] = [:]
    private var held: [HeldKey: HeldTarget] = [:]

    public init(routes: [MIDIRoute] = []) {
        _ = setRoutes(routes)
    }

    public var currentRoutes: [MIDIRoute] {
        lock.lock(); defer { lock.unlock() }
        return routes
    }

    /// Replaces the routing table. Returns note-offs for notes that were held
    /// through routes that no longer exist or were disabled; send them.
    @discardableResult
    public func setRoutes(_ newRoutes: [MIDIRoute]) -> [RoutedMIDI] {
        lock.lock(); defer { lock.unlock() }
        routes = newRoutes
        routesBySource = Dictionary(grouping: newRoutes.filter(\.isEnabled), by: \.source)
        let live = Set(newRoutes.filter(\.isEnabled).map(\.id))
        var flush: [RoutedMIDI] = []
        for (key, target) in held where !live.contains(key.route) {
            flush.append(RoutedMIDI(target.destination, .noteOff(channel: target.channel, note: target.note, velocity: 0)))
            held[key] = nil
        }
        return flush
    }

    /// Routes one message. Returns everything that should be delivered, in order.
    public func process(_ message: MIDIMessage, from source: EndpointID) -> [RoutedMIDI] {
        lock.lock(); defer { lock.unlock() }
        guard let candidates = routesBySource[source] else {
            return message.isNoteOff ? releaseOrphans(message, from: source) : []
        }
        var out: [RoutedMIDI] = []
        for route in candidates {
            if message.isNoteOff, let ch = message.channel, let note = noteNumber(message) {
                let key = HeldKey(route: route.id, source: source, channel: ch, note: note)
                if let target = held.removeValue(forKey: key) {
                    let vel: UInt8
                    if case let .noteOff(_, _, v) = message { vel = v } else { vel = 0 }
                    out.append(RoutedMIDI(target.destination, .noteOff(channel: target.channel, note: target.note, velocity: vel)))
                }
                // Never route an unmatched note-off; its note-on went elsewhere (or nowhere).
                continue
            }

            guard route.filter.passes(message), let transformed = route.transform.apply(message) else { continue }

            if message.isNoteOn, let ch = message.channel, let note = noteNumber(message),
               let outCh = transformed.channel, let outNote = noteNumber(transformed) {
                let key = HeldKey(route: route.id, source: source, channel: ch, note: note)
                if let previous = held[key] {
                    // Retrigger of a held key: close the old voice first.
                    out.append(RoutedMIDI(previous.destination, .noteOff(channel: previous.channel, note: previous.note, velocity: 0)))
                }
                held[key] = HeldTarget(destination: route.destination, channel: outCh, note: outNote)
            }
            out.append(RoutedMIDI(route.destination, transformed))
        }
        return out
    }

    /// Note-offs for held notes from a source whose routes were all removed.
    private func releaseOrphans(_ message: MIDIMessage, from source: EndpointID) -> [RoutedMIDI] {
        guard let ch = message.channel, let note = noteNumber(message) else { return [] }
        var out: [RoutedMIDI] = []
        for (key, target) in held where key.source == source && key.channel == ch && key.note == note {
            out.append(RoutedMIDI(target.destination, .noteOff(channel: target.channel, note: target.note, velocity: 0)))
            held[key] = nil
        }
        return out
    }

    /// All held notes released + CC 123 (all notes off) on every channel of every routed destination.
    public func panic() -> [RoutedMIDI] {
        lock.lock(); defer { lock.unlock() }
        var out = held.values.map { RoutedMIDI($0.destination, .noteOff(channel: $0.channel, note: $0.note, velocity: 0)) }
        held.removeAll()
        let destinations = Set(routes.map(\.destination))
        for d in destinations.sorted(by: { $0.description < $1.description }) {
            for ch in UInt8(0)..<16 {
                out.append(RoutedMIDI(d, .controlChange(channel: ch, controller: 64, value: 0)))
                out.append(RoutedMIDI(d, .controlChange(channel: ch, controller: 123, value: 0)))
            }
        }
        return out
    }

    public var heldNoteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    private func noteNumber(_ m: MIDIMessage) -> UInt8? {
        switch m {
        case let .noteOn(_, n, _), let .noteOff(_, n, _): return n
        default: return nil
        }
    }
}
