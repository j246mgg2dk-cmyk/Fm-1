import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct MDTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

/// Where imported files live: Documents/Machinedrum (visible in the Files app).
/// Firmware is never bundled with the app; you import your own.
enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Machinedrum")
    }
    static var firmware: URL { root.appendingPathComponent("roms/elektron_sps1-1uw_os1.63.bin") }
    static var cache: URL { root.appendingPathComponent("nvram/md-uw-1.63-factory-v2.cache") }
    static var recording: URL { root.appendingPathComponent("test-recording.wav") }
    static var logFile: URL { root.appendingPathComponent("test-log.txt") }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func move(_ src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.moveItem(at: src, to: dst)
    }
}

enum ImportTarget: String { case firmware, cache }

/// Outcome of one import, with a step-by-step log.
struct ImportReport: Sendable {
    var lines: [String] = []
    var error: String?
    mutating func say(_ s: String) { lines.append(s) }
}

/// Copies a picked file into the app, logging every step. Runs off the main thread:
/// reading an iCloud file that is not on the iPad yet waits for its download.
func performImport(_ url: URL, intended: ImportTarget) -> ImportReport {
    var r = ImportReport()
    let fm = FileManager.default
    r.say("Import (\(intended.rawValue) button): picked \(url.lastPathComponent)")

    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    r.say("  security-scoped access: \(scoped ? "granted" : "not needed or refused")")

    if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) {
        let status = v.ubiquitousItemDownloadingStatus.map { $0.rawValue.replacingOccurrences(of: "NSURLUbiquitousItemDownloadingStatus", with: "") }
        r.say("  source: \(v.fileSize.map { "\($0) bytes" } ?? "size unknown")"
              + ((v.isUbiquitousItem ?? false) ? ", iCloud item, download status \(status ?? "unknown")" : ", local file"))
    } else {
        r.say("  source: could not read file attributes")
    }

    // Coordinated read: for an iCloud file this downloads it before handing it over.
    let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var coordError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readable in
        do { try fm.copyItem(at: readable, to: temp) } catch { copyError = error }
    }
    if let e = coordError ?? (copyError as NSError?) {
        r.say("  copy FAILED: \(e.localizedDescription) [\(e.domain) \(e.code)]")
        r.error = "Couldn't read \(url.lastPathComponent): \(e.localizedDescription)"
        return r
    }
    r.say("  copied into the app: \(Storage.size(temp).map { "\($0) bytes" } ?? "size unknown")")
    defer { try? fm.removeItem(at: temp) }

    let isFirmware = MDEngineTest.isSupportedFirmware(temp.path)
    // Only describe the firmware check when it matters: a firmware import, or a file that is the firmware.
    if intended == .firmware || isFirmware {
        r.say("  firmware check: \(MDEngineTest.describeFirmware(temp.path))")
    }

    do {
        if isFirmware {
            if intended == .cache { r.say("  this is the firmware, not the cache: installing it as the firmware") }
            try Storage.move(temp, to: Storage.firmware)
            r.say("  installed as firmware ✓")
        } else if intended == .firmware {
            let size = Storage.size(temp) ?? 0
            let why: String
            if size == 0 {
                why = "The file is empty. It may be an iCloud placeholder that didn't download: open it once in the Files app (or tick “Keep Downloaded”) and try again."
            } else if size != 8_388_608 {
                why = "It is \(size) bytes; the MD UW OS 1.63 image is exactly 8,388,608 bytes. It may be a different file or an incomplete copy."
            } else {
                why = "The size is right but the contents don't match MD UW OS 1.63 (a different OS version, or a modified or corrupted copy)."
            }
            r.say("  NOT installed: \(why)")
            r.error = "\(url.lastPathComponent) wasn't accepted as the firmware.\n\n\(why)\n\nThe log at the bottom of the screen has the details."
        } else {
            try Storage.move(temp, to: Storage.cache)
            r.say("  installed as factory cache ✓ (it is checked against the firmware when the test boots)")
        }
    } catch {
        r.say("  install FAILED: \(error.localizedDescription)")
        r.error = "Couldn't save the file: \(error.localizedDescription)"
    }
    return r
}

/// Measured with the factory pattern playing: the work a real-time Machinedrum needs
/// from the two DSPs, in millions of instructions per second.
let requiredDspMips = 149.8

/// Runs work on a dedicated thread at the highest QoS so iPadOS schedules it on a
/// performance core, as it would the real audio thread.
func runOnPerformanceCore(_ work: @escaping @Sendable () -> Void) {
    let t = Thread(block: work)
    t.qualityOfService = .userInteractive
    t.stackSize = 8 << 20
    t.start()
}

@MainActor
final class TestModel: ObservableObject {
    @Published var firmwareOK = false
    @Published var hasCache = false
    @Published var running = false
    @Published var log: [String] = []
    @Published var rawMips: Double?
    @Published var result: MDTestResult?
    @Published var error: String?
    @Published var importing = false
    private var player: AVAudioPlayer?

    init() {
        repairMisplacedFirmware()
        refresh()
    }

    func refresh() {
        let fwExists = FileManager.default.fileExists(atPath: Storage.firmware.path)
        firmwareOK = fwExists && MDEngineTest.isSupportedFirmware(Storage.firmware.path)
        hasCache = FileManager.default.fileExists(atPath: Storage.cache.path)
        if fwExists && !firmwareOK {
            say("Installed firmware file is not valid: \(MDEngineTest.describeFirmware(Storage.firmware.path))")
        }
    }

    /// Earlier builds saved every import into the cache slot (the file picker clears its
    /// "showing" state before reporting the picked file). Move a firmware found there.
    private func repairMisplacedFirmware() {
        guard FileManager.default.fileExists(atPath: Storage.cache.path),
              MDEngineTest.isSupportedFirmware(Storage.cache.path) else { return }
        do {
            try Storage.move(Storage.cache, to: Storage.firmware)
            say("Found the firmware saved in the cache slot by the earlier import bug: moved it to the firmware slot. Please import the factory cache again.")
        } catch {
            say("Found the firmware in the cache slot but couldn't move it: \(error.localizedDescription)")
        }
    }

    func say(_ line: String) {
        log.append(line)
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let text = "[\(stamp)] \(line)\n"
        try? FileManager.default.createDirectory(at: Storage.root, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Storage.logFile) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: Storage.logFile)
        }
    }

    func importPicked(_ result: Result<URL, Error>, as target: ImportTarget) {
        switch result {
        case .failure(let e):
            say("Import (\(target.rawValue) button): the file picker reported an error: \(e.localizedDescription)")
            error = e.localizedDescription
        case .success(let url):
            importing = true
            Task.detached(priority: .userInitiated) {
                let report = performImport(url, intended: target)
                await MainActor.run {
                    report.lines.forEach { self.say($0) }
                    self.refresh()
                    self.importing = false
                    if let e = report.error { self.error = e }
                }
            }
        }
    }

    func runRaw() {
        running = true
        say("Measuring raw DSP interpreter speed…")
        runOnPerformanceCore {
            let mips = MDEngineTest.measureRawDspMips()
            Task { @MainActor in
                self.rawMips = mips
                self.say(String(format: "Raw DSP interpreter: %.1f M instructions/s", mips))
                self.running = false
            }
        }
    }

    func runFull() {
        guard firmwareOK else { return }
        running = true
        result = nil
        say("Starting full Machinedrum test…")
        let fw = Storage.firmware.path, home = Storage.root.path, wav = Storage.recording.path
        let boot = hasCache ? 12.0 : 30.0
        UIApplication.shared.isIdleTimerDisabled = true
        runOnPerformanceCore {
            let r = MDEngineTest.run(withFirmware: fw, homePath: home, bootSeconds: boot, seconds: 10, wavPath: wav) { line in
                Task { @MainActor in self.say(line) }
            }
            Task { @MainActor in
                self.result = r
                self.running = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    func play() {
        player = try? AVAudioPlayer(contentsOf: Storage.recording)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player?.play()
    }
}

struct ContentView: View {
    @StateObject private var m = TestModel()
    // Which button opened the picker. Kept separately from `showImporter`: SwiftUI sets the
    // picker's isPresented to false *before* calling its completion handler.
    @State private var importTarget: ImportTarget = .firmware
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filesPanel
                    testsPanel
                    if let r = m.result { resultPanel(r) }
                    logPanel
                }
                .padding(20)
            }
            .background(Color(white: 0.06))
            .navigationTitle("Machinedrum engine test")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { res in
            m.importPicked(res, as: importTarget)
        }
        .alert("MD Engine Test", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
    }

    private var filesPanel: some View {
        panel("1 · Your files") {
            row(ok: m.firmwareOK, title: "Firmware", detail: m.firmwareOK ? "MD UW OS 1.63 ready" : "Import elektron_sps1-1uw_os1.63.bin from Files") {
                importTarget = .firmware; showImporter = true
            }
            row(ok: m.hasCache, title: "Factory cache (optional)",
                detail: m.hasCache ? "Factory kits & patterns ready" : "md-uw-1.63-factory-v2.cache from your Mac's Gearmulator nvram folder; skips the slow factory setup") {
                importTarget = .cache; showImporter = true
            }
            if m.importing {
                HStack(spacing: 8) { ProgressView(); Text("Importing… (an iCloud file downloads first)").font(.footnote) }
            }
            Text("Nothing is included with the app: these are your own files, stored only on this iPad (Files › On My iPad › MD Engine Test).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(m.importing || m.running)
    }

    private var testsPanel: some View {
        panel("2 · Tests") {
            HStack(spacing: 12) {
                Button("Raw DSP speed") { m.runRaw() }.buttonStyle(.bordered)
                Button("Full Machinedrum test") { m.runFull() }.buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!m.firmwareOK)
                if m.running { ProgressView() }
            }
            .disabled(m.running)
            if let mips = m.rawMips {
                Text(String(format: "Raw interpreter: %.0f M instr/s (cloud test machine: 216)", mips)).font(.callout.monospaced())
            }
            Text("The full test boots your firmware with the no-JIT engine, presses PLAY and times 10 s of audio. Keep the app open and the iPad plugged in; it takes one to two minutes.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func resultPanel(_ r: MDTestResult) -> some View {
        panel("3 · Result on this iPad") {
            LCDView(data: r.lcd).frame(height: 160)
            Grid(alignment: .leading, verticalSpacing: 6) {
                stat("Engine", r.engineMode)
                stat("Boot time", String(format: "%.1f s", r.bootSeconds))
                stat("Real-time factor", String(format: "%.2f×  (1.00 = keeps up)", r.realtimeFactor))
                stat("DSP throughput", String(format: "%.1f M instr/s", r.dspInstructionsPerWallSecond))
                stat("Needed for real time", String(format: "%.1f M instr/s", requiredDspMips))
                stat("Audio", r.peak > 0.0001 ? String(format: "sound (peak %.2f)", r.peak) : "silent")
            }
            .font(.callout.monospaced())
            if r.peak > 0.0001 { Button("Play the recording") { m.play() } }
            Text(r.realtimeFactor >= 1.0
                 ? "This iPad runs the full Machinedrum (both DSPs and the ColdFire) faster than real time on one core, without JIT."
                 : String(format: "On one core, without JIT, this iPad runs the Machinedrum at %.0f%% of real-time speed. Please send me this screen: it decides which speed-up comes next.", r.realtimeFactor * 100))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var logPanel: some View {
        panel("Log") {
            ForEach(Array(m.log.suffix(60).enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Copy log") { UIPasteboard.general.string = m.log.joined(separator: "\n") }
                    .buttonStyle(.bordered).disabled(m.log.isEmpty)
                Text("Also saved as Files › On My iPad › MD Engine Test › Machinedrum › test-log.txt")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }

    private func row(ok: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Import…", action: action).buttonStyle(.bordered)
        }
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.orange)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11)))
    }
}

/// The emulated Machinedrum's 128×64 LCD.
struct LCDView: View {
    let data: Data
    var body: some View {
        Canvas { ctx, size in
            let px = min(size.width / 128, size.height / 64)
            let ox = (size.width - px * 128) / 2
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.05, green: 0.09, blue: 0.12)))
            data.withUnsafeBytes { raw in
                guard let b = raw.bindMemory(to: UInt8.self).baseAddress, raw.count >= 128 * 64 else { return }
                for y in 0..<64 { for x in 0..<128 where b[y * 128 + x] != 0 {
                    ctx.fill(Path(CGRect(x: ox + CGFloat(x) * px, y: CGFloat(y) * px, width: px * 0.9, height: px * 0.9)),
                             with: .color(Color(red: 0.6, green: 0.9, blue: 1.0)))
                } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
