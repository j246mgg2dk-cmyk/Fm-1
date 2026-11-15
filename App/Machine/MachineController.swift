import AVFoundation
import CoreMIDI
import Combine
import QuartzCore
import SwiftUI
import UIKit

/// Panel controls in the engine's order (md::PanelControl). Only the ones a Machinedrum has
/// are used by the panel.
enum MDControl: Int {
    case trig1 = 0 // ...trig16 = 15
    case tempo = 22, synEfxRout = 23, function = 24, kit = 25, enter = 26, exit = 27
    case up = 28, down = 29, left = 30, right = 31
    case bankGroup = 32, bankA = 33, bankB = 34, bankC = 35, bankD = 36
    case record = 37, play = 38, stop = 39
    case scale = 42, patternSong = 43, classicExtended = 46

    static func trig(_ i: Int) -> Int { i }   // 0...15
}

/// LED bits, as the engine reports them.
struct MDLeds: Equatable {
    var steps: UInt32 = 0      // bit n = step n+1
    var tracks: UInt32 = 0     // bit n = track n+1
    var status: UInt32 = 0     // page1, page2, page3, pattern, song, routing, effects, synthesis
    var mode: UInt32 = 0       // classic, extended, bank A-D, bank E-H, record, tempo, page4

    func step(_ i: Int) -> Bool { steps & (1 << UInt32(i)) != 0 }
    func track(_ i: Int) -> Bool { tracks & (1 << UInt32(i)) != 0 }
    var page1: Bool { status & 0x01 != 0 }
    var page2: Bool { status & 0x02 != 0 }
    var page3: Bool { status & 0x04 != 0 }
    var page4: Bool { mode & 0x40 != 0 }
    var pattern: Bool { status & 0x08 != 0 }
    var song: Bool { status & 0x10 != 0 }
    var routing: Bool { status & 0x20 != 0 }
    var effects: Bool { status & 0x40 != 0 }
    var synthesis: Bool { status & 0x80 != 0 }
    var classic: Bool { mode & 0x01 != 0 }
    var extended: Bool { mode & 0x02 != 0 }
    var bankAD: Bool { mode & 0x04 != 0 }
    var bankEH: Bool { mode & 0x08 != 0 }
    var record: Bool { mode & 0x10 != 0 }
    var tempo: Bool { mode & 0x20 != 0 }
}

/// What the panel draws: the LCD image and the LEDs. Separate from the controller so only the
/// panel redraws 60 times a second.
@MainActor
final class PanelState: ObservableObject {
    @Published var lcd: CGImage?
    @Published var leds = MDLeds()
    @Published var load: Double = 0          // emulation time / audio time, last quarter second
    @Published var safety: Double = 1        // lowest safety-buffer fill / target, last quarter second
    @Published var stressRemaining: Int?     // seconds left in a running stress test
    @Published var midiIn = false            // blinks on activity
    @Published var midiOut = false
}

enum LCDTheme: String, CaseIterable, Identifiable {
    case amber, ice, classic
    var id: String { rawValue }
    var name: String { switch self { case .amber: "Amber"; case .ice: "Ice"; case .classic: "Classic" } }
    /// Lit pixel, unlit pixel, background (RGB 0...255).
    var colors: (lit: (UInt8, UInt8, UInt8), unlit: (UInt8, UInt8, UInt8), back: (UInt8, UInt8, UInt8)) {
        switch self {
        case .amber: ((255, 168, 48), (34, 20, 8), (14, 9, 4))
        case .ice: ((150, 225, 255), (14, 26, 34), (6, 12, 17))
        case .classic: ((24, 32, 20), (142, 160, 104), (156, 176, 112))
        }
    }
}

@MainActor
final class MachineController: ObservableObject {
    enum Phase: Equatable { case needsFirmware, booting(String), running, failed(String), suspended }

    @Published var phase: Phase = .needsFirmware
    @Published var log: [String] = []
    @Published var midiSources: [MDMIDIEndpoint] = []
    @Published var midiDestinations: [MDMIDIEndpoint] = []

    // Settings (remembered). Changing an engine setting restarts the machine (state is saved first).
    @AppStorage("ioBufferFrames") var bufferFrames = 256
    @AppStorage("safetyFrames") var safetyFrames = 1024
    @AppStorage("perfLog") var perfLogEnabled = false
    @AppStorage("secondCore") var secondCore = true
    @AppStorage("lowPowerWait") var lowPowerWait = true
    @AppStorage("volume") var volume: Double = 0.85 { didSet { engine.volume = Float(volume) } }
    @AppStorage("lcdTheme") var lcdThemeRaw = LCDTheme.amber.rawValue { didSet { panel.lcd = nil; lastLCD = nil; redrawLCD() } }

    var lcdTheme: LCDTheme { LCDTheme(rawValue: lcdThemeRaw) ?? .amber }

    let panel = PanelState()
    let engine = MDLiveEngine()
    private(set) lazy var midi = MDMIDI(engine: engine)

    private var displayLink: CADisplayLink?
    private var lcdBytes = [UInt8](repeating: 0, count: 128 * 64)
    private var lastLCD: [UInt8]?
    private var ledWords = [UInt32](repeating: 0, count: 4)
    private var lastStats = Date.distantPast
    private var lastMidiIn = 0, lastMidiOut = 0
    private var saveTimer: Timer?
    private var lastSavedHash: Int?

    init() {
        engine.volume = Float(volume)
        midi.onChange = { [weak self] in
            guard let self else { return }
            self.midiSources = self.midi.sources
            self.midiDestinations = self.midi.destinations
        }
        phase = FileManager.default.fileExists(atPath: Storage.firmware.path) ? .suspended : .needsFirmware
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveState() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveStateNow() }
        }
    }

    func say(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Lifecycle

    /// Boots the Machinedrum with your saved kits, patterns and songs.
    func boot() {
        guard FileManager.default.fileExists(atPath: Storage.firmware.path) else { phase = .needsFirmware; return }
        if case .booting = phase { return }
        if phase == .running { return }
        phase = .booting("Starting audio…")
        let fw = Storage.firmware.path, home = Storage.root.path
        let state = try? Data(contentsOf: Storage.state)
        let buffer = bufferFrames, two = secondCore
        engine.lowPowerWait = lowPowerWait
        engine.safetyFrames = safetyFrames
        let engine = self.engine
        runOnPerformanceCore {
            let ok = engine.start(withFirmware: fw, homePath: home, secondCore: two, bufferFrames: buffer,
                                  restoreState: state, autoPlay: false) { line in
                Task { @MainActor in
                    self.say(line)
                    if case .booting = self.phase { self.phase = .booting(line) }
                }
            }
            Task { @MainActor in
                if ok {
                    self.phase = .running
                    self.perfLastUnderruns = 0
                    self.lastSavedHash = state?.hashValue
                    self.midi.start()
                    self.startDisplay()
                    self.startAutosave()
                    UIApplication.shared.isIdleTimerDisabled = true
                } else {
                    self.phase = .failed(self.log.last ?? "The Machinedrum could not start.")
                }
            }
        }
    }

    /// Saves and stops (for Diagnostics, or before applying engine settings).
    func suspend(save: Bool = true) {
        guard phase == .running else { return }
        var save = save
        if stressTimer != nil {
            // Stopped mid-test: put your state back instead of saving the stressed one.
            stressTimer?.invalidate(); stressTimer = nil
            panel.stressRemaining = nil
            if let snap = stressSnapshot {
                try? snap.write(to: Storage.state, options: .atomic)
                lastSavedHash = snap.hashValue
                stressSnapshot = nil
                save = false
            }
        }
        if save { saveStateNow() }
        stopDisplay()
        saveTimer?.invalidate(); saveTimer = nil
        engine.stop()
        phase = .suspended
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func restart() {
        suspend()
        boot()
    }

    // MARK: Panel

    func press(_ control: Int, _ down: Bool) { engine.setControl(control, pressed: down) }
    func turn(_ encoder: Int, _ steps: Int) { engine.turnEncoder(encoder, steps: steps) }
    func pushEncoder(_ encoder: Int, _ down: Bool) { engine.setEncoder(encoder, pressed: down) }

    private func startDisplay() {
        stopDisplay()
        let link = CADisplayLink(target: DisplayTarget { [weak self] in self?.tick() }, selector: #selector(DisplayTarget.fire))
        // 30 frames a second is plenty for an LCD and LEDs, and leaves the cores to the emulator.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplay() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let changed = lcdBytes.withUnsafeMutableBufferPointer { lcd in
            ledWords.withUnsafeMutableBufferPointer { leds in
                engine.copyPanelLCD(lcd.baseAddress!, leds: leds.baseAddress!)
            }
        }
        if changed {
            if lastLCD != lcdBytes { lastLCD = lcdBytes; redrawLCD() }
            let l = MDLeds(steps: ledWords[0], tracks: ledWords[1], status: ledWords[2], mode: ledWords[3])
            if l != panel.leds { panel.leds = l }
        }
        let now = Date()
        if now.timeIntervalSince(lastStats) > 0.25 {
            lastStats = now
            let s = engine.stats()
            panel.load = s.recentLoad
            panel.safety = s.safetyFrames > 0 ? min(1, Double(s.safetyMinFill) / Double(s.safetyFrames)) : 1
            recordPerformance(s)
            let inNow = s.midiInCount, outNow = s.midiOutCount
            panel.midiIn = inNow != lastMidiIn
            panel.midiOut = outNow != lastMidiOut
            lastMidiIn = inNow; lastMidiOut = outNow
        }
    }

    /// Renders the 128x64 LCD at 3x with a one-pixel gap, like the real dot matrix.
    private func redrawLCD() {
        guard let src = lastLCD else { return }
        let (lit, unlit, back) = lcdTheme.colors
        let scale = 3, w = 128 * scale, h = 64 * scale
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = back.0; px[i + 1] = back.1; px[i + 2] = back.2; px[i + 3] = 255 }
        for y in 0..<64 {
            for x in 0..<128 {
                let c = src[y * 128 + x] != 0 ? lit : unlit
                for dy in 0..<(scale - 1) {
                    var o = ((y * scale + dy) * w + x * scale) * 4
                    for _ in 0..<(scale - 1) { px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2; o += 4 }
                }
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return }
        panel.lcd = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Performance log and stress test

    private var perfStart = Date()
    private var perfLast = Date()
    private var perfLoadSum = 0.0, perfLoadCount = 0, perfPeak = 0.0
    private var perfMinSafety = Int.max, perfUnderrunsAtStart = 0, perfLastUnderruns = 0
    private var perfWaitSum = 0.0, perfBusySum = 0.0, perfMipsSum = 0.0, perfSplitCount = 0
    private var stressTimer: Timer?
    private var stressSnapshot: Data?
    private var stressEnd = Date()
    private var stressTick = 0
    private var rng = SystemRandomNumberGenerator()

    /// Every 10 s, while the log is on: one CSV line in Documents/Machinedrum/performance-log.csv.
    private func recordPerformance(_ s: MDLiveStats) {
        guard perfLogEnabled || stressTimer != nil else { return }
        perfLoadSum += s.recentLoad; perfLoadCount += 1
        perfPeak = max(perfPeak, s.recentPeakLoad)
        perfMinSafety = min(perfMinSafety, s.safetyMinFill)
        if s.workerBusy > 0 { perfWaitSum += s.schedulerWait; perfBusySum += s.workerBusy; perfMipsSum += s.dsp1Mips; perfSplitCount += 1 }
        let now = Date()
        guard now.timeIntervalSince(perfLast) >= 10 else { return }
        perfLast = now
        let fm = FileManager.default
        // A log from an older version has different columns: start a new one.
        if let h = try? FileHandle(forReadingFrom: Storage.perfLog) {
            let head = String(decoding: h.readData(ofLength: 400), as: UTF8.self)
            try? h.close()
            if !head.contains("dsp1_mips") { try? fm.removeItem(at: Storage.perfLog) }
        }
        if !fm.fileExists(atPath: Storage.perfLog.path) {
            try? fm.createDirectory(at: Storage.perfLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "time,elapsed_s,stress,load_avg_pct,block_peak_pct,underruns,min_safety_frames,safety_frames,output_frames,audio_restarts,memory_mb,thermal,midi_in,midi_out,render_waits_for_dsp1_pct,dsp1_busy_pct,dsp1_mips,threads\n"
            try? header.write(to: Storage.perfLog, atomically: true, encoding: .utf8)
        }
        let thermal = ["nominal", "fair", "serious", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]
        let f = ISO8601DateFormatter()
        let split = perfSplitCount > 0
            ? String(format: "%.0f,%.0f,%.1f", perfWaitSum / Double(perfSplitCount) * 100, perfBusySum / Double(perfSplitCount) * 100, perfMipsSum / Double(perfSplitCount))
            : ",,"
        let underruns = max(0, s.overruns - perfLastUnderruns)
        let line = String(format: "%@,%.0f,%@,%.1f,%.1f,%ld,%ld,%ld,%ld,%ld,%.0f,%@,%ld,%ld,%@,\"%@\"\n",
                          f.string(from: now), now.timeIntervalSince(perfStart), stressTimer != nil ? "yes" : "no",
                          perfLoadCount > 0 ? perfLoadSum / Double(perfLoadCount) * 100 : 0, perfPeak * 100,
                          underruns, perfMinSafety == Int.max ? -1 : perfMinSafety, s.safetyFrames,
                          s.bufferFrames, s.audioRestarts, s.footprintMB, thermal, s.midiInCount, s.midiOutCount,
                          split, MDLiveEngine.threadCPUReport())
        perfLastUnderruns = s.overruns
        if let h = try? FileHandle(forWritingTo: Storage.perfLog) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        }
        perfLoadSum = 0; perfLoadCount = 0; perfPeak = 0; perfMinSafety = Int.max
        perfWaitSum = 0; perfBusySum = 0; perfMipsSum = 0; perfSplitCount = 0
    }

    func resetPerformanceLog() {
        try? FileManager.default.removeItem(at: Storage.perfLog)
        perfStart = Date(); perfLast = Date()
        perfLastUnderruns = engine.stats().overruns
    }

    /// Hammers the running machine: encoder sweeps on all eight data knobs and LEVEL, triggers
    /// on all 16 tracks, CC parameter changes on the four track channels and pattern changes,
    /// on top of whatever you're playing. Your state is saved first and put back afterwards.
    func startStressTest(minutes: Int) {
        guard phase == .running, stressTimer == nil else { return }
        stressSnapshot = engine.copyState()
        saveTimer?.invalidate(); saveTimer = nil              // don't autosave the mangled state
        resetPerformanceLog()
        stressEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        stressTick = 0
        say("Stress test started for \(minutes) minutes. Your state is saved and will be put back.")
        stressTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stressStep() }
        }
    }

    private func stressStep() {
        let left = stressEnd.timeIntervalSinceNow
        if left <= 0 { stopStressTest(restore: true); return }
        panel.stressRemaining = Int(left)
        stressTick += 1
        // Every 25 ms: turn a random knob by up to 6 detents.
        let enc = Int.random(in: 0...8, using: &rng)
        turn(enc, Int.random(in: -6...6, using: &rng))
        // Every 50 ms: trigger a random track (notes 36-51 on the base channel).
        if stressTick % 2 == 0 {
            var note: [UInt8] = [0x90, UInt8(36 + Int.random(in: 0..<16, using: &rng)), UInt8(Int.random(in: 40...127, using: &rng))]
            engine.receiveMIDI(&note, length: 3, hostTime: 0)
        }
        // Every 75 ms: a random track parameter CC on the four track channels.
        if stressTick % 3 == 0 {
            var cc: [UInt8] = [UInt8(0xB0 | Int.random(in: 0..<4, using: &rng)), UInt8(Int.random(in: 16...119, using: &rng)), UInt8(Int.random(in: 0...127, using: &rng))]
            engine.receiveMIDI(&cc, length: 3, hostTime: 0)
        }
        // Every 8 s: change pattern (program change on the base channel).
        if stressTick % 320 == 0 {
            var pc: [UInt8] = [0xC0, UInt8(Int.random(in: 0..<16, using: &rng))]
            engine.receiveMIDI(&pc, length: 2, hostTime: 0)
        }
    }

    func stopStressTest(restore: Bool) {
        stressTimer?.invalidate(); stressTimer = nil
        panel.stressRemaining = nil
        say("Stress test finished. The log is in Files › On My iPad › MD Engine Test › Machinedrum › performance-log.csv.")
        guard restore, let snap = stressSnapshot else { startAutosave(); return }
        stressSnapshot = nil
        suspend(save: false)
        try? snap.write(to: Storage.state, options: .atomic)
        lastSavedHash = snap.hashValue
        boot()
    }

    var isStressRunning: Bool { stressTimer != nil }

    // MARK: Saved state

    private func startAutosave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveState() }
        }
    }

    /// Saves in the background (the engine copies its memory under its own locks).
    func saveState() {
        guard phase == .running else { return }
        let engine = self.engine
        DispatchQueue.global(qos: .utility).async {
            guard let data = engine.copyState() else { return }
            Task { @MainActor in self.write(data) }
        }
    }

    func saveStateNow() {
        guard phase == .running, let data = engine.copyState() else { return }
        write(data)
    }

    private func write(_ data: Data) {
        let h = data.hashValue
        if h == lastSavedHash { return }
        do {
            try FileManager.default.createDirectory(at: Storage.state.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Storage.state, options: .atomic)
            lastSavedHash = h
        } catch {
            say("Could not save your state: \(error.localizedDescription)")
        }
    }

    /// A dated copy of your state for the share sheet.
    func exportBackup() -> URL? {
        saveStateNow()
        guard let data = try? Data(contentsOf: Storage.state) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Machinedrum \(f.string(from: Date())).mdstate")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Back to the factory kits, patterns and settings. Your current state is kept as a backup
    /// file first (Files › On My iPad › MD Engine Test › Machinedrum › state).
    func factoryReset() {
        suspend()
        let fm = FileManager.default
        if fm.fileExists(atPath: Storage.state.path) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
            let keep = Storage.state.deletingLastPathComponent().appendingPathComponent("before-reset \(f.string(from: Date())).mdstate")
            try? fm.moveItem(at: Storage.state, to: keep)
            say("Your previous state is kept as \(keep.lastPathComponent).")
        }
        lastSavedHash = nil
        say("Factory reset; restarting.")
        boot()
    }

    /// Replaces your state with a backup and restarts the machine with it.
    func restoreBackup(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { say("That backup could not be read."); return }
        suspend()
        do {
            try FileManager.default.createDirectory(at: Storage.state.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: Storage.state.path) {
                try? FileManager.default.removeItem(at: Storage.statePrevious)
                try? FileManager.default.copyItem(at: Storage.state, to: Storage.statePrevious)
            }
            try data.write(to: Storage.state, options: .atomic)
            say("Backup restored; restarting.")
        } catch {
            say("Could not restore: \(error.localizedDescription)")
        }
        boot()
    }
}

/// CADisplayLink needs an NSObject target.
private final class DisplayTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
