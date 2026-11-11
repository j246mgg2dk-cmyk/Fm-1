import AVFoundation
import AudioToolbox
import CoreAudioKit
import FM1Core
import UIKit

/// Host-side info every plugin can query (tempo, beat, playing) so arps,
/// delays, LFOs and Koala's sequencer lock to Mod-Lab's transport.
final class HostClockInfo: @unchecked Sendable {
    // Written by the audio thread at the start of each block, read by plugins during that block.
    var tempo: Double = 120
    var beatPosition: Double = 0
    var beatsPerBar: Double = 4
    var noteValue: Int = 4
    var sampleRate: Double = 48_000
    var isPlaying = false
    var transportChanged = false
    var sampleTime: Double = 0
}

/// One AUv3 instance (any vendor: Moog, Korg, FabFilter, Koala, Drambo, etc.)
/// rendered manually by Mod-Lab's graph — the same approach AUM uses — which is
/// what makes per-channel routing, CV and sends possible.
final class HostedPlugin {
    let deviceID: UUID
    let component: PluginComponentID
    let au: AUAudioUnit
    let role: PluginRole

    let bypassed = AtomicFlag(false)
    let mix = AtomicFloat(1)

    /// MIDI coming out of this plugin (arp/sequencer/MIDI FX). The track drains
    /// it on the audio thread and feeds the next device in the chain.
    let chainMIDI = SPSCQueue<RawMIDI>(capacity: 512, initial: RawMIDI())
    /// MIDI that should leave the track (to hardware/other tracks via the router).
    weak var globalMIDIOut: SPSCQueue<RawMIDI>?
    var globalPort: UInt16 = 0

    private let renderBlock: AURenderBlock
    private let midiBlock: AUScheduleMIDIEventBlock?
    private let paramBlock: AUScheduleParameterBlock
    private let outList: UnsafeMutableAudioBufferListPointer
    private let maxFrames: Int

    // Set right before each render call; read by the pull block.
    private var pullL: UnsafeMutablePointer<Float>?
    private var pullR: UnsafeMutablePointer<Float>?
    private var pullBlock: AURenderPullInputBlock!

    var hasMIDIInput: Bool { midiBlock != nil }

    init(deviceID: UUID, component: PluginComponentID, au: AUAudioUnit,
         sampleRate: Double, maxFrames: Int, clock: HostClockInfo) throws {
        self.deviceID = deviceID
        self.component = component
        self.au = au
        self.role = component.role
        self.maxFrames = maxFrames

        let fmt = AVAudioFormat.modLab(channels: 2, sampleRate: sampleRate)
        if au.outputBusses.count > 0 { try au.outputBusses[0].setFormat(fmt) }
        if au.inputBusses.count > 0 { try? au.inputBusses[0].setFormat(fmt) }
        au.maximumFramesToRender = AUAudioFrameCount(maxFrames)

        // Tempo/transport sync for the plugin.
        au.musicalContextBlock = { tempo, tsNum, tsDen, beat, sampleOffsetToNextBeat, downbeat in
            tempo?.pointee = clock.tempo
            tsNum?.pointee = clock.beatsPerBar
            tsDen?.pointee = clock.noteValue
            beat?.pointee = clock.beatPosition
            if let sampleOffsetToNextBeat {
                let frac = clock.beatPosition - floor(clock.beatPosition)
                sampleOffsetToNextBeat.pointee = Int((1 - frac) * 60 / clock.tempo * clock.sampleRate)
            }
            downbeat?.pointee = floor(clock.beatPosition / clock.beatsPerBar) * clock.beatsPerBar
            return true
        }
        au.transportStateBlock = { flags, samplePos, _, _ in
            var f: AUHostTransportStateFlags = []
            if clock.isPlaying { f.insert(.moving) }
            if clock.transportChanged { f.insert(.changed) }
            flags?.pointee = f
            samplePos?.pointee = clock.sampleTime
            return true
        }

        renderBlock = au.renderBlock
        midiBlock = au.scheduleMIDIEventBlock
        paramBlock = au.scheduleParameterBlock

        outList = AudioBufferList.allocate(maximumBuffers: 2)

        let isMIDIProcessor = component.role == .midiProcessor
        let chain = chainMIDI
        au.midiOutputEventBlock = { [weak self] sampleTime, _, length, bytes in
            guard length > 0, length <= 3 else { return noErr } // sysex from plugins is ignored
            var raw = RawMIDI(b0: bytes[0], b1: length > 1 ? bytes[1] : 0, b2: length > 2 ? bytes[2] : 0, length: UInt8(length))
            raw.frameOffset = 0
            if isMIDIProcessor {
                chain.push(raw)
            } else if let self, let out = self.globalMIDIOut {
                raw.port = self.globalPort
                out.push(raw)
            }
            _ = sampleTime
            return noErr
        }

        pullBlock = { [unowned self] _, _, frameCount, _, inputData in
            let abl = UnsafeMutableAudioBufferListPointer(inputData)
            let frames = Int(frameCount)
            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            for i in 0..<min(abl.count, 2) {
                // Mono-input effects get the left channel.
                guard let src = (i == 0 ? self.pullL : (self.pullR ?? self.pullL)) else { return kAudioUnitErr_NoConnection }
                if abl[i].mData == nil {
                    abl[i].mData = UnsafeMutableRawPointer(src)
                } else {
                    abl[i].mData!.assumingMemoryBound(to: Float.self).update(from: src, count: frames)
                }
                abl[i].mDataByteSize = bytes
            }
            return noErr
        }

        try au.allocateRenderResources()
    }

    deinit {
        au.deallocateRenderResources()
        free(outList.unsafeMutablePointer)
    }

    // MARK: Audio thread

    @inline(__always)
    func sendMIDI(_ raw: RawMIDI, frameOffset: Int) {
        guard let midiBlock else { return }
        var bytes = (raw.b0, raw.b1, raw.b2)
        withUnsafePointer(to: &bytes) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 3) { b in
                midiBlock(AUEventSampleTimeImmediate + AUEventSampleTime(frameOffset), 0, Int(raw.length), b)
            }
        }
    }

    @inline(__always)
    func setParameter(address: AUParameterAddress, value: AUValue) {
        paramBlock(AUEventSampleTimeImmediate, 0, address, value)
    }

    /// Renders in place: `l`/`r` hold the input on entry (for effects) and the output on exit.
    /// `scratchL/R` must be distinct buffers of at least `frames`.
    func render(l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>,
                scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>,
                frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        if bypassed.value { return }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(scratchL))
        outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(scratchR))
        outList.count = 2

        pullL = l
        pullR = r
        var flags = AudioUnitRenderActionFlags()
        let status = renderBlock(&flags, timestamp, AUAudioFrameCount(frames), 0, outList.unsafeMutablePointer, pullBlock)
        pullL = nil
        pullR = nil
        guard status == noErr else { return } // leave dry signal untouched on error

        let wet = mix.value
        let dry = 1 - wet
        let isEffect = role == .audioEffect || role == .musicEffect
        for ch in 0..<2 {
            // A mono plugin hands back one buffer: copy it to both sides.
            let produced = outList[min(ch, outList.count - 1)].mData?.assumingMemoryBound(to: Float.self) ?? (ch == 0 ? scratchL : scratchR)
            let d = ch == 0 ? l : r
            if isEffect && wet < 0.999 {
                for i in 0..<frames { d[i] = d[i] * dry + produced[i] * wet }
            } else if produced != d {
                d.update(from: produced, count: frames)
            }
        }
    }

    // MARK: Main thread

    /// After the interface's sample rate changes. Only call while no graph references this plugin.
    func reconfigure(sampleRate: Double) throws {
        au.deallocateRenderResources()
        let fmt = AVAudioFormat.modLab(channels: 2, sampleRate: sampleRate)
        if au.outputBusses.count > 0 { try au.outputBusses[0].setFormat(fmt) }
        if au.inputBusses.count > 0 { try? au.inputBusses[0].setFormat(fmt) }
        try au.allocateRenderResources()
    }

    func requestViewController() async -> UIViewController? {
        await withCheckedContinuation { cont in
            au.requestViewController { vc in cont.resume(returning: vc) }
        }
    }

    /// Plugin state for saving with the project.
    func saveState() -> Data? {
        guard let state = au.fullStateForDocument else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    func restoreState(_ data: Data) {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return }
        au.fullStateForDocument = dict
    }

    struct ParameterInfo: Identifiable, Hashable {
        var id: AUParameterAddress { address }
        let address: AUParameterAddress
        let name: String
        let min: AUValue
        let max: AUValue
        let value: AUValue
    }

    func parameters() -> [ParameterInfo] {
        (au.parameterTree?.allParameters ?? [])
            .filter { $0.flags.contains(.flag_IsWritable) }
            .map { ParameterInfo(address: $0.address, name: $0.displayName, min: $0.minValue, max: $0.maxValue, value: $0.value) }
    }
}
