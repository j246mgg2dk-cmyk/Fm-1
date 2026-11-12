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

    static func install(_ src: URL, to dst: URL) throws {
        let ok = src.startAccessingSecurityScopedResource()
        defer { if ok { src.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }
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
    private var player: AVAudioPlayer?

    init() { refresh() }

    func refresh() {
        firmwareOK = FileManager.default.fileExists(atPath: Storage.firmware.path)
            && MDEngineTest.isSupportedFirmware(Storage.firmware.path)
        hasCache = FileManager.default.fileExists(atPath: Storage.cache.path)
    }

    func importFirmware(_ url: URL) {
        do {
            try Storage.install(url, to: Storage.firmware)
            refresh()
            if !firmwareOK { error = "That file isn't the Machinedrum UW OS 1.63 image (elektron_sps1-1uw_os1.63.bin, 8 MB)." }
        } catch { self.error = error.localizedDescription }
    }

    func importCache(_ url: URL) {
        do { try Storage.install(url, to: Storage.cache); refresh() } catch { self.error = error.localizedDescription }
    }

    func runRaw() {
        running = true
        log.append("Measuring raw DSP interpreter speed…")
        runOnPerformanceCore {
            let mips = MDEngineTest.measureRawDspMips()
            Task { @MainActor in
                self.rawMips = mips
                self.log.append(String(format: "Raw DSP interpreter: %.1f M instructions/s", mips))
                self.running = false
            }
        }
    }

    func runFull() {
        guard firmwareOK else { return }
        running = true
        result = nil
        log.append("Starting full Machinedrum test…")
        let fw = Storage.firmware.path, home = Storage.root.path, wav = Storage.recording.path
        let boot = hasCache ? 12.0 : 30.0
        UIApplication.shared.isIdleTimerDisabled = true
        runOnPerformanceCore {
            let r = MDEngineTest.run(withFirmware: fw, homePath: home, bootSeconds: boot, seconds: 10, wavPath: wav) { line in
                Task { @MainActor in self.log.append(line) }
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
    @State private var importing: Importing?

    enum Importing: Identifiable { case firmware, cache; var id: Self { self } }

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
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.data, .item]) { res in
            guard case let .success(url) = res else { return }
            if importing == .firmware { m.importFirmware(url) } else { m.importCache(url) }
            importing = nil
        }
        .alert("MD Engine Test", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
    }

    private var filesPanel: some View {
        panel("1 · Your files") {
            row(ok: m.firmwareOK, title: "Firmware", detail: m.firmwareOK ? "MD UW OS 1.63 ready" : "Import elektron_sps1-1uw_os1.63.bin from Files") {
                importing = .firmware
            }
            row(ok: m.hasCache, title: "Factory cache (optional)",
                detail: m.hasCache ? "Factory kits & patterns ready" : "md-uw-1.63-factory-v2.cache from your Mac's Gearmulator nvram folder; skips the slow factory setup") {
                importing = .cache
            }
            Text("Nothing is included with the app: these are your own files, stored only on this iPad (Files › On My iPad › MD Engine Test).")
                .font(.footnote).foregroundStyle(.secondary)
        }
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
            ForEach(Array(m.log.suffix(40).enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).foregroundStyle(.secondary)
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
