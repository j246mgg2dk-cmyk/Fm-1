import AVFoundation
import AudioToolbox
import Foundation

/// Owns the hardware: AVAudioSession + a RemoteIO unit running full duplex
/// with *all* channels of whatever is plugged in (USB class-compliant
/// interfaces, docks, the built-in mic/speaker).
///
/// Input is pulled inside the output callback, so input and output are
/// processed in the same cycle: monitoring latency is one IO buffer each way,
/// the same as AUM.
final class AudioIO {
    struct Configuration: Equatable {
        var preferredSampleRate: Double = 48_000
        var preferredBufferFrames: Int = 128
        /// Let AUM, Koala, etc. keep making sound while FM-1 runs.
        var mixWithOthers = true
        /// Allow Bluetooth headphones (adds lots of latency; off for studio use).
        var allowBluetoothOutput = false
    }

    struct Status: Equatable {
        var sampleRate: Double = 48_000
        var bufferFrames: Int = 0
        var inputChannels: Int = 0
        var outputChannels: Int = 2
        var inputLatency: TimeInterval = 0
        var outputLatency: TimeInterval = 0
        var inputName = ""
        var outputName = ""
        var isRunning = false
    }

    /// Called on the audio thread. Input list has `status.inputChannels` buffers
    /// (may be 0), output list has `status.outputChannels`.
    typealias RenderHandler = (
        _ input: UnsafeMutableAudioBufferListPointer,
        _ output: UnsafeMutableAudioBufferListPointer,
        _ frames: Int,
        _ timestamp: UnsafePointer<AudioTimeStamp>
    ) -> Void

    static let maxFrames = 4096

    private(set) var status = Status()
    var configuration = Configuration()
    var renderHandler: RenderHandler?
    /// Fired on the main queue whenever the hardware changes (interface plugged/unplugged).
    var onRouteChange: ((Status) -> Void)?

    private var unit: AUAudioUnit?
    private var ioRender: AURenderBlock?
    private var inputList: UnsafeMutableAudioBufferListPointer?
    private var inputStorage: [UnsafeMutablePointer<Float>] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Category changes we cause ourselves would loop.
            if reason == .categoryChange { return }
            self.scheduleRestartIfHardwareChanged()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self.restart() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.unit = nil
            self?.restart()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        stop()
        freeInputBuffers()
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        try configureSession()
        try buildUnit()
    }

    func stop() {
        unit?.stopHardware()
        unit?.deallocateRenderResources()
        unit = nil
        ioRender = nil
        status.isRunning = false
    }

    func restart() {
        stop()
        do {
            try start()
        } catch {
            NSLog("FM-1 audio restart failed: \(error)")
        }
        onRouteChange?(status)
    }

    private var pendingRestart: DispatchWorkItem?

    /// Route notifications arrive in bursts when an interface is plugged in;
    /// debounce, and only rebuild when something we depend on actually changed.
    private func scheduleRestartIfHardwareChanged() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let s = AVAudioSession.sharedInstance()
            let changed = s.sampleRate != self.status.sampleRate
                || s.maximumOutputNumberOfChannels != self.status.outputChannels
                || (s.isInputAvailable ? s.maximumInputNumberOfChannels : 0) != self.status.inputChannels
                || (s.currentRoute.inputs.first?.portName ?? "None") != self.status.inputName
                || (s.currentRoute.outputs.first?.portName ?? "None") != self.status.outputName
                || !self.status.isRunning
            if changed { self.restart() }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Session

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if configuration.mixWithOthers { options.insert(.mixWithOthers) }
        if configuration.allowBluetoothOutput { options.insert(.allowBluetoothA2DP) }
        try s.setCategory(.playAndRecord, mode: .default, options: options)
        try? s.setPreferredSampleRate(configuration.preferredSampleRate)
        try? s.setPreferredIOBufferDuration(Double(configuration.preferredBufferFrames) / configuration.preferredSampleRate)
        try s.setActive(true)

        // Ask for every channel the interface has (an 18-in/20-out USB box shows up as 18/20 here).
        if s.isInputAvailable {
            try? s.setPreferredInputNumberOfChannels(s.maximumInputNumberOfChannels)
        }
        try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels)

        status.sampleRate = s.sampleRate
        status.bufferFrames = Int((s.ioBufferDuration * s.sampleRate).rounded())
        status.inputChannels = s.isInputAvailable ? s.inputNumberOfChannels : 0
        status.outputChannels = max(1, s.outputNumberOfChannels)
        status.inputLatency = s.inputLatency
        status.outputLatency = s.outputLatency
        status.inputName = s.currentRoute.inputs.first?.portName ?? "None"
        status.outputName = s.currentRoute.outputs.first?.portName ?? "None"
    }

    // MARK: RemoteIO

    private func buildUnit() throws {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        let au = try AUAudioUnit(componentDescription: desc)

        let outFormat = AVAudioFormat.fm1(channels: status.outputChannels, sampleRate: status.sampleRate)
        // On an IO unit, input bus 0 is "what the app sends to the hardware output".
        try au.inputBusses[0].setFormat(outFormat)
        au.isOutputEnabled = true

        let wantsInput = status.inputChannels > 0 && AVAudioApplication.shared.recordPermission == .granted
        if wantsInput {
            // Output bus 1 is "what the hardware input gives the app".
            let inFormat = AVAudioFormat.fm1(channels: status.inputChannels, sampleRate: status.sampleRate)
            try au.outputBusses[1].setFormat(inFormat)
            au.isInputEnabled = true
        } else {
            status.inputChannels = 0
        }
        au.maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
        allocateInputBuffers(channels: status.inputChannels)

        au.outputProvider = { [unowned self] _, timestamp, frameCount, _, outputData in
            let frames = Int(frameCount)
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            let bytes = UInt32(frames * MemoryLayout<Float>.size)

            // Pull hardware input synchronously for this same cycle.
            if let input = self.inputList {
                for i in 0..<input.count {
                    input[i].mData = UnsafeMutableRawPointer(self.inputStorage[i])
                    input[i].mDataByteSize = bytes
                }
                var flags = AudioUnitRenderActionFlags()
                let err = self.ioRender?(&flags, timestamp, frameCount, 1, input.unsafeMutablePointer, nil) ?? -1
                if err != noErr {
                    for i in 0..<input.count { self.inputStorage[i].update(repeating: 0, count: frames) }
                }
            }

            if let handler = self.renderHandler, let input = self.inputList ?? Self.emptyList {
                handler(input, out, frames, timestamp)
            } else {
                for b in out { memset(b.mData, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }

        try au.allocateRenderResources()
        ioRender = au.renderBlock
        try au.startHardware()
        unit = au
        status.isRunning = true
    }

    private static let emptyList: UnsafeMutableAudioBufferListPointer? = AudioBufferList.allocate(maximumBuffers: 1).withZeroCount()

    private func allocateInputBuffers(channels: Int) {
        freeInputBuffers()
        guard channels > 0 else { return }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            p.initialize(repeating: 0, count: Self.maxFrames)
            inputStorage.append(p)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: UnsafeMutableRawPointer(p))
        }
        inputList = list
    }

    private func freeInputBuffers() {
        inputStorage.forEach { $0.deallocate() }
        inputStorage.removeAll()
        if let l = inputList { free(l.unsafeMutablePointer) }
        inputList = nil
    }
}

private extension UnsafeMutableAudioBufferListPointer {
    func withZeroCount() -> UnsafeMutableAudioBufferListPointer {
        var copy = self
        copy.count = 0
        return copy
    }
}

extension AVAudioFormat {
    /// Deinterleaved Float32 with N discrete channels: the only format FM-1 uses internally.
    static func fm1(channels: Int, sampleRate: Double) -> AVAudioFormat {
        if channels <= 2, let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(channels, 1))) {
            return f
        }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }
}
