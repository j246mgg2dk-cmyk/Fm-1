import CoreMIDI
import Foundation
import FM1Core

/// Everything CoreMIDI: USB class-compliant gear, DIN interfaces, Bluetooth
/// LE MIDI, RTP network sessions and other apps (AUM, Koala, Drambo, ...).
///
/// Mod-Lab publishes two virtual ports, "Mod-Lab Out" and "Mod-Lab In", so any other
/// app can send to or receive from Mod-Lab like a hardware device.
///
/// Every incoming message goes through `MIDIRouter` on the CoreMIDI thread,
/// then out to hardware immediately or into a track's lock-free inbox.
final class MIDIManager {
    struct Endpoint: Identifiable, Hashable {
        var id: EndpointID
        var ref: MIDIEndpointRef
        var isOnline: Bool
        var manufacturer: String
    }

    private(set) var sources: [Endpoint] = []
    private(set) var destinations: [Endpoint] = []

    /// Called on the main queue when devices appear/disappear.
    var onSetupChanged: (() -> Void)?
    /// Called on the CoreMIDI thread for every parsed message (for MIDI learn, monitor, clock follow).
    var onMessage: ((MIDIMessage, EndpointID, MIDITimeStamp) -> Void)?

    let router = MIDIRouter()

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var virtualDestination = MIDIEndpointRef()

    private let lock = NSLock()
    private var decoders: [MIDIEndpointRef: UMPDecoder] = [:]
    private var sourceIDs: [MIDIEndpointRef: EndpointID] = [:]
    private var destinationRefs: [EndpointID: MIDIEndpointRef] = [:]
    private var trackInboxes: [EndpointID: (SPSCQueue<RawMIDI>, NSLock)] = [:]
    /// Index -> endpoint table that the audio thread's `port` numbers refer to.
    private var outPortTable: [EndpointID] = []
    private var pluginSourceTable: [EndpointID] = []

    private var senderTimer: DispatchSourceTimer?
    private let senderQueue = DispatchQueue(label: "modlab.midi.sender", qos: .userInteractive)

    init() {
        MIDINetworkSession.default().isEnabled = true
        MIDINetworkSession.default().connectionPolicy = .anyone
    }

    func start() throws {
        var status = MIDIClientCreateWithBlock("Mod-Lab" as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved {
                DispatchQueue.main.async { self?.refreshEndpoints() }
            }
        }
        guard status == noErr else { throw MIDIError(status) }

        status = MIDIInputPortCreateWithProtocol(client, "Mod-Lab Input" as CFString, ._1_0, &inputPort) { [weak self] list, srcRef in
            guard let self, let srcRef else { return }
            let ref = MIDIEndpointRef(UInt(bitPattern: srcRef))
            self.receive(list, from: ref)
        }
        guard status == noErr else { throw MIDIError(status) }

        status = MIDIOutputPortCreate(client, "Mod-Lab Output" as CFString, &outputPort)
        guard status == noErr else { throw MIDIError(status) }

        // Virtual ports other apps see as a device called "Mod-Lab".
        status = MIDISourceCreateWithProtocol(client, "Mod-Lab Out" as CFString, ._1_0, &virtualSource)
        guard status == noErr else { throw MIDIError(status) }
        status = MIDIDestinationCreateWithProtocol(client, "Mod-Lab In" as CFString, ._1_0, &virtualDestination) { [weak self] list, _ in
            guard let self else { return }
            self.receive(list, from: self.virtualDestination, id: .modLabVirtualIn)
        }
        guard status == noErr else { throw MIDIError(status) }
        // Stable unique IDs so AUM/Koala remember the connection between launches.
        MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, 0x464D_3101)
        MIDIObjectSetIntegerProperty(virtualDestination, kMIDIPropertyUniqueID, 0x464D_3102)

        refreshEndpoints()
    }

    // MARK: Endpoints

    func refreshEndpoints() {
        var newSources: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let ref = MIDIGetSource(i)
            guard ref != 0, ref != virtualSource else { continue }
            newSources.append(endpoint(for: ref))
        }
        var newDests: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let ref = MIDIGetDestination(i)
            guard ref != 0, ref != virtualDestination else { continue }
            newDests.append(endpoint(for: ref))
        }
        lock.lock()
        // Connect to every source; the router decides what actually goes anywhere.
        for s in newSources where sourceIDs[s.ref] == nil {
            MIDIPortConnectSource(inputPort, s.ref, UnsafeMutableRawPointer(bitPattern: UInt(s.ref)))
        }
        sourceIDs = Dictionary(newSources.map { ($0.ref, $0.id) }, uniquingKeysWith: { a, _ in a })
        destinationRefs = Dictionary(newDests.map { ($0.id, $0.ref) }, uniquingKeysWith: { a, _ in a })
        destinationRefs[.modLabVirtualOut] = virtualSource
        lock.unlock()
        sources = newSources
        destinations = newDests
        onSetupChanged?()
    }

    private func endpoint(for ref: MIDIEndpointRef) -> Endpoint {
        let name = Self.displayName(ref)
        let kind = Self.kind(of: ref)
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline)
        return Endpoint(id: EndpointID(kind, name), ref: ref, isOnline: offline == 0,
                        manufacturer: Self.stringProperty(ref, kMIDIPropertyManufacturer) ?? "")
    }

    static func displayName(_ ref: MIDIEndpointRef) -> String {
        stringProperty(ref, kMIDIPropertyDisplayName) ?? stringProperty(ref, kMIDIPropertyName) ?? "Unknown"
    }

    private static func stringProperty(_ obj: MIDIObjectRef, _ key: CFString) -> String? {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    private static func kind(of ref: MIDIEndpointRef) -> EndpointID.Kind {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        if MIDIEndpointGetEntity(ref, &entity) != noErr || entity == 0 { return .virtualPort }
        if MIDIEntityGetDevice(entity, &device) != noErr || device == 0 { return .virtualPort }
        let driver = (stringProperty(device, kMIDIPropertyDriverOwner) ?? "").lowercased()
        if driver.contains("bluetooth") || driver.contains("btle") { return .bluetooth }
        if driver.contains("network") || driver.contains("rtp") { return .network }
        return .hardware
    }

    // MARK: Engine wiring

    /// Tells the manager which queue feeds each track (built with each graph).
    func setTrackInboxes(_ inboxes: [EndpointID: SPSCQueue<RawMIDI>]) {
        lock.lock(); defer { lock.unlock() }
        var next: [EndpointID: (SPSCQueue<RawMIDI>, NSLock)] = [:]
        for (id, q) in inboxes {
            next[id] = (q, trackInboxes[id].flatMap { $0.0 === q ? $0.1 : nil } ?? NSLock())
        }
        trackInboxes = next
    }

    func setOutputPortTable(_ table: [EndpointID]) {
        lock.lock(); outPortTable = table; lock.unlock()
    }

    func setPluginSourceTable(_ table: [EndpointID]) {
        lock.lock(); pluginSourceTable = table; lock.unlock()
    }

    /// Drains the audio thread's outbound queues every millisecond. Messages
    /// carry future host timestamps so CoreMIDI schedules them precisely; the
    /// timer only has to stay ahead of the audio output latency.
    func startSender(engine: AudioEngine) {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: senderQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
        t.setEventHandler { [weak self, unowned engine] in
            guard let self else { return }
            engine.midiOut.drain { raw in
                self.lock.lock()
                let id = Int(raw.port) < self.outPortTable.count ? self.outPortTable[Int(raw.port)] : nil
                self.lock.unlock()
                if let id, let m = raw.message { self.send(m, to: id, timestamp: raw.hostTime) }
            }
            engine.pluginMIDIOut.drain { raw in
                self.lock.lock()
                let id = Int(raw.port) < self.pluginSourceTable.count ? self.pluginSourceTable[Int(raw.port)] : nil
                self.lock.unlock()
                if let id, let m = raw.message { self.route(m, from: id) }
            }
        }
        t.resume()
        senderTimer = t
    }

    // MARK: Receive

    private func receive(_ list: UnsafePointer<MIDIEventList>, from ref: MIDIEndpointRef, id explicitID: EndpointID? = nil) {
        lock.lock()
        let id = explicitID ?? sourceIDs[ref]
        var decoder = decoders[ref] ?? UMPDecoder()
        var batches: [(MIDITimeStamp, [MIDIMessage])] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words: [UInt32] = withUnsafeBytes(of: packet.pointee.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(count))
            }
            batches.append((packet.pointee.timeStamp, decoder.decode(words)))
        }
        decoders[ref] = decoder
        lock.unlock()

        guard let id else { return }
        for (ts, msgs) in batches {
            for m in msgs {
                onMessage?(m, id, ts)
                route(m, from: id)
            }
        }
    }

    /// Routes one message and delivers the results.
    func route(_ m: MIDIMessage, from id: EndpointID) {
        for out in router.process(m, from: id) { deliver(out) }
    }

    func deliver(_ r: RoutedMIDI) {
        switch r.destination.kind {
        case .track:
            lock.lock()
            let inbox = trackInboxes[r.destination]
            lock.unlock()
            guard let inbox, let raw = RawMIDI(r.message) else { return }
            let (queue, producerLock) = inbox
            // Several threads produce (CoreMIDI, plugin MIDI sender): serialise producers only.
            producerLock.lock()
            queue.push(raw)
            producerLock.unlock()
        case .internalClock, .plugin:
            break
        default:
            send(r.message, to: r.destination)
        }
    }

    func panic() {
        for r in router.panic() { deliver(r) }
    }

    // MARK: Send

    func send(_ m: MIDIMessage, to id: EndpointID, timestamp: MIDITimeStamp = 0) {
        lock.lock()
        let ref = destinationRefs[id]
        lock.unlock()
        guard let ref else { return }
        let words = UMPEncoder.words(for: m)
        guard !words.isEmpty else { return }

        // MIDIEventList holds one packet inline; give it room for long sysex.
        let byteSize = 1024 + words.count * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        words.withUnsafeBufferPointer { w in
            // Sysex7 packets are 2 words each; everything else is 1 word.
            var i = 0
            while i < w.count {
                let size = UMPDecoder.wordCount(forType: UInt8(w[i] >> 28))
                packet = MIDIEventListAdd(list, byteSize, packet, timestamp, size, w.baseAddress! + i)
                i += size
            }
        }
        if ref == virtualSource {
            MIDIReceivedEventList(virtualSource, list)
        } else {
            MIDISendEventList(outputPort, ref, list)
        }
    }
}

struct MIDIError: Error, CustomStringConvertible {
    let status: OSStatus
    init(_ s: OSStatus) { status = s }
    var description: String { "CoreMIDI error \(status)" }
}
