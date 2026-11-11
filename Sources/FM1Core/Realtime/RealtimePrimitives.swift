import Atomics

/// A Float that the UI thread writes and the audio thread reads (or vice versa)
/// without locks or data races.
public final class AtomicFloat: @unchecked Sendable {
    private let bits: ManagedAtomic<UInt32>
    public init(_ v: Float = 0) { bits = ManagedAtomic(v.bitPattern) }
    public var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    /// Audio thread: keep the running maximum for peak meters.
    @inline(__always) public func max(_ v: Float) {
        if v > value { value = v }
    }
    /// UI thread: read and reset the peak.
    public func exchange(_ v: Float) -> Float {
        Float(bitPattern: bits.exchange(v.bitPattern, ordering: .relaxed))
    }
}

public final class AtomicDouble: @unchecked Sendable {
    private let bits: ManagedAtomic<UInt64>
    public init(_ v: Double = 0) { bits = ManagedAtomic(v.bitPattern) }
    public var value: Double {
        get { Double(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

public final class AtomicInt: @unchecked Sendable {
    private let raw: ManagedAtomic<Int>
    public init(_ v: Int = 0) { raw = ManagedAtomic(v) }
    public var value: Int {
        get { raw.load(ordering: .relaxed) }
        set { raw.store(newValue, ordering: .relaxed) }
    }
}

public final class AtomicFlag: @unchecked Sendable {
    private let raw: ManagedAtomic<Bool>
    public init(_ v: Bool = false) { raw = ManagedAtomic(v) }
    public var value: Bool {
        get { raw.load(ordering: .relaxed) }
        set { raw.store(newValue, ordering: .relaxed) }
    }
}

/// Lock-free SPSC ring for audio samples (bulk read/write), used to hand
/// recorded audio from the audio thread to the disk-writer thread.
public final class FloatRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let mask: Int
    private let head = ManagedAtomic<Int>(0)
    private let tail = ManagedAtomic<Int>(0)
    public let capacity: Int

    public init(capacity: Int) {
        var c = 1024
        while c < capacity { c <<= 1 }
        self.capacity = c
        mask = c - 1
        buffer = .allocate(capacity: c)
        buffer.initialize(repeating: 0, count: c)
    }

    deinit { buffer.deallocate() }

    public var availableToRead: Int { head.load(ordering: .acquiring) - tail.load(ordering: .relaxed) }

    /// Producer. Returns number of samples written (fewer than `count` = overrun).
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = Swift.min(count, capacity - (h - t))
        guard n > 0 else { return 0 }
        let start = h & mask
        let first = Swift.min(n, capacity - start)
        (buffer + start).update(from: src, count: first)
        if n > first { buffer.update(from: src + first, count: n - first) }
        head.store(h + n, ordering: .releasing)
        return n
    }

    /// Consumer.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = Swift.min(count, h - t)
        guard n > 0 else { return 0 }
        let start = t & mask
        let first = Swift.min(n, capacity - start)
        dst.update(from: buffer + start, count: first)
        if n > first { (dst + first).update(from: buffer, count: n - first) }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}

/// Publish an object from the main thread; the audio thread borrows it without
/// retaining. The previous object is handed back to the caller, who must keep
/// it alive until the audio thread can no longer be using it (FM-1 parks old
/// graphs for a second before letting them go).
public final class AtomicReference<T: AnyObject>: @unchecked Sendable {
    private let raw = ManagedAtomic<Unmanaged<T>?>(nil)

    public init() {}

    deinit { _ = exchange(nil) }

    @discardableResult
    public func exchange(_ new: T?) -> T? {
        let newU = new.map { Unmanaged.passRetained($0) }
        let old = raw.exchange(newU, ordering: .acquiringAndReleasing)
        return old?.takeRetainedValue()
    }

    /// Audio thread: use the current object for the duration of `body`.
    @inline(__always)
    public func withBorrowed<R>(_ body: (T?) -> R) -> R {
        guard let u = raw.load(ordering: .acquiring) else { return body(nil) }
        return u._withUnsafeGuaranteedRef { body($0) }
    }
}
