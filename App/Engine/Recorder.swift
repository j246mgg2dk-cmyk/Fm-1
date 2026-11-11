import AVFoundation
import FM1Core

/// One file being recorded. The audio thread writes into lock-free rings; a
/// background writer moves the audio to disk, so a slow SD card / iCloud
/// sync never causes dropouts.
final class RecordingStream {
    let trackID: UUID?           // nil = master/resample
    let url: URL
    let channels: Int
    let ringL: FloatRingBuffer
    let ringR: FloatRingBuffer
    /// Frames to discard at the start: round-trip latency so overdubs land on the grid.
    private let dropTotal: Int
    private var dropped = 0      // audio thread only
    let overruns = AtomicInt(0)

    fileprivate let file: AVAudioFile
    fileprivate let scratch: AVAudioPCMBuffer

    init(trackID: UUID?, url: URL, channels: Int, sampleRate: Double, latencyFrames: Int) throws {
        self.trackID = trackID
        self.url = url
        self.channels = max(1, min(channels, 2))
        let seconds = 30.0 // ring holds 30 s of audio: far more than any disk hiccup
        ringL = FloatRingBuffer(capacity: Int(sampleRate * seconds))
        ringR = FloatRingBuffer(capacity: Int(sampleRate * seconds))
        dropTotal = max(0, latencyFrames)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: self.channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw CocoaError(.fileWriteUnknown)
        }
        scratch = buf
    }

    /// Audio thread.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var l = left, r = right, n = frames
        if dropped < dropTotal {
            let skip = min(dropTotal - dropped, n)
            dropped += skip
            l += skip; r += skip; n -= skip
            if n == 0 { return }
        }
        let a = ringL.write(l, count: n)
        if channels > 1 { ringR.write(r, count: n) }
        if a < n { overruns.value += 1 }
    }

    /// Writer thread. Returns frames written.
    fileprivate func flush() -> Int {
        var total = 0
        while true {
            let avail = min(ringL.availableToRead, Int(scratch.frameCapacity))
            guard avail > 0, let ch = scratch.floatChannelData else { break }
            let n = ringL.read(into: ch[0], count: avail)
            if channels > 1 { _ = ringR.read(into: ch[1], count: n) }
            scratch.frameLength = AVAudioFrameCount(n)
            do { try file.write(from: scratch) } catch { NSLog("Mod-Lab record write failed: \(error)") ; break }
            total += n
        }
        return total
    }
}

/// Drains all active streams to disk on a utility thread.
final class RecordingWriter {
    private let queue = DispatchQueue(label: "modlab.recording.writer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var streams: [RecordingStream] = []

    func start(_ newStreams: [RecordingStream]) {
        queue.sync { streams = newStreams }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.streams.forEach { _ = $0.flush() }
        }
        t.resume()
        timer = t
    }

    /// Call after the graph no longer references the streams. Returns the finished files.
    func stop() -> [RecordingStream] {
        timer?.cancel()
        timer = nil
        return queue.sync {
            streams.forEach { _ = $0.flush() }
            let done = streams
            streams = []
            return done // AVAudioFile finalises the header when the stream is released
        }
    }
}
