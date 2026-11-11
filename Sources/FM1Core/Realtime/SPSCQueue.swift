import Atomics

/// Lock-free single-producer / single-consumer ring buffer.
///
/// This is how data crosses into and out of the audio thread without locks:
/// CoreMIDI thread -> audio thread (incoming notes), audio thread -> MIDI
/// sender (clock ticks, plugin MIDI out), audio thread -> disk writer (recording).
///
/// Use only with trivial (POD) element types so push/pop never touch ARC or the allocator.
public final class SPSCQueue<Element>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Element>
    private let mask: Int
    private let head = ManagedAtomic<Int>(0) // next write (producer owns)
    private let tail = ManagedAtomic<Int>(0) // next read  (consumer owns)

    public let capacity: Int

    /// Capacity is rounded up to a power of two.
    public init(capacity: Int, initial: Element) {
        var c = 2
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        buffer = .allocate(capacity: c)
        buffer.initialize(repeating: initial, count: c)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Producer side. Returns false (drops the element) when full.
    @discardableResult
    public func push(_ value: Element) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t < capacity else { return false }
        buffer[h & mask] = value
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Consumer side.
    public func pop() -> Element? {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t != h else { return nil }
        let v = buffer[t & mask]
        tail.store(t + 1, ordering: .releasing)
        return v
    }

    /// Consumer side: drain everything currently available.
    @inline(__always)
    public func drain(_ body: (Element) -> Void) {
        while let v = pop() { body(v) }
    }

    public var approximateCount: Int {
        head.load(ordering: .relaxed) - tail.load(ordering: .relaxed)
    }
}

/// A short MIDI message as plain bytes: safe to move through `SPSCQueue`.
public struct RawMIDI: Sendable, Equatable {
    public var b0: UInt8
    public var b1: UInt8
    public var b2: UInt8
    public var length: UInt8
    /// Opaque endpoint/track index assigned by whoever builds the queue.
    public var port: UInt16
    /// Sample offset inside the block (audio-thread side), or 0.
    public var frameOffset: UInt32
    /// Host-time timestamp (mach ticks) for scheduled sends, 0 = now.
    public var hostTime: UInt64

    public init(b0: UInt8 = 0, b1: UInt8 = 0, b2: UInt8 = 0, length: UInt8 = 0,
                port: UInt16 = 0, frameOffset: UInt32 = 0, hostTime: UInt64 = 0) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.length = length
        self.port = port
        self.frameOffset = frameOffset
        self.hostTime = hostTime
    }

    /// nil for sysex (too long; sysex never goes through the audio thread).
    public init?(_ m: MIDIMessage, port: UInt16 = 0, frameOffset: UInt32 = 0, hostTime: UInt64 = 0) {
        if case .sysex = m { return nil }
        let b = m.bytes
        self.init(b0: b[0], b1: b.count > 1 ? b[1] : 0, b2: b.count > 2 ? b[2] : 0,
                  length: UInt8(b.count), port: port, frameOffset: frameOffset, hostTime: hostTime)
    }

    public var message: MIDIMessage? {
        MIDIMessage(status: b0, data1: b1, data2: b2)
    }
}
