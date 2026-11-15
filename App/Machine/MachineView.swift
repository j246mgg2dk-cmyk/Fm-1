import CoreAudioKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app: the Machinedrum's front panel, with a slim top bar.
struct MachineView: View {
    @EnvironmentObject private var machine: MachineController
    @EnvironmentObject private var panel: PanelState
    @State private var showSettings = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        ZStack {
            Panel.face.ignoresSafeArea()
            switch machine.phase {
            case .running:
                VStack(spacing: 0) {
                    topBar
                    FrontPanelView()
                }
            case .needsFirmware:
                firmwarePrompt
            case .booting(let line):
                VStack(spacing: 14) {
                    ProgressView().tint(Panel.orange)
                    Silk("BOOTING", size: 13)
                    Text(line).font(.footnote).foregroundStyle(Panel.silkDim)
                }
            case .failed(let why):
                VStack(spacing: 14) {
                    Text("The Machinedrum didn't start").font(.headline).foregroundStyle(Panel.silk)
                    Text(why).font(.footnote).foregroundStyle(Panel.silkDim).multilineTextAlignment(.center).frame(maxWidth: 480)
                    Button("Try again") { machine.boot() }.buttonStyle(.borderedProminent).tint(Panel.orange)
                    Button("Settings") { showSettings = true }
                }
            case .suspended:
                VStack(spacing: 14) {
                    Silk("MACHINEDRUM", size: 15)
                    Button("Start") { machine.boot() }.buttonStyle(.borderedProminent).tint(Panel.orange)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(machine) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let report = performImport(url, intended: .firmware)
                DispatchQueue.main.async {
                    report.lines.forEach { machine.say($0) }
                    if let e = report.error { importError = e } else { machine.boot() }
                }
            }
        }
        .alert("Firmware", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .onAppear { if machine.phase == .suspended { machine.boot() } }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Silk("MACHINEDRUM", size: 12)
            Silk("SPS-1 UW", size: 10, color: Panel.silkDim)
            Spacer()
            // Audio load: green under 75%, orange under 95%, red above.
            HStack(spacing: 6) {
                Silk("CPU", size: 9, color: Panel.silkDim)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.08))
                        Capsule().fill(panel.load < 0.75 ? Panel.green : panel.load < 0.95 ? Panel.orange : Panel.red)
                            .frame(width: g.size.width * min(1, panel.load))
                    }
                }
                .frame(width: 70, height: 5)
                Text("\(Int(panel.load * 100))%").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Panel.silkDim)
                    .frame(width: 34, alignment: .leading)
            }
            HStack(spacing: 6) {
                Silk("MIDI", size: 9, color: Panel.silkDim)
                LED(on: panel.midiIn, color: Panel.green, size: 6)
                LED(on: panel.midiOut, color: Panel.orange, size: 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Panel.silkDim)
                Slider(value: $machine.volume, in: 0...1).frame(width: 120).tint(Panel.orange)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16)).foregroundStyle(Panel.silk)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    private var firmwarePrompt: some View {
        VStack(spacing: 16) {
            Silk("MACHINEDRUM", size: 16)
            Text("Import your Machinedrum UW OS 1.63 firmware (elektron_sps1-1uw_os1.63.bin) to start. It stays on this iPad and is never shared.")
                .font(.callout).foregroundStyle(Panel.silkDim).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Import firmware…") { importing = true }.buttonStyle(.borderedProminent).tint(Panel.orange)
        }
    }
}

/// Settings: audio, display, MIDI, your data, diagnostics.
struct SettingsView: View {
    @EnvironmentObject private var machine: MachineController
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestart = false
    @State private var exportURL: URL?
    @State private var restoring = false
    @State private var showBluetooth = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Audio buffer", selection: restartOnChange($machine.bufferFrames)) {
                        Text("256 frames (5.8 ms)").tag(256)
                        Text("512 frames (11.6 ms)").tag(512)
                        Text("1024 frames (23.2 ms)").tag(1024)
                    }
                    Toggle("Use a second core", isOn: restartOnChange($machine.secondCore))
                    Toggle("Low-power waiting", isOn: restartOnChange($machine.lowPowerWait))
                        .disabled(!machine.secondCore)
                    if pendingRestart {
                        Button("Apply (restarts the Machinedrum, your work is saved first)") {
                            pendingRestart = false
                            machine.restart()
                        }
                    }
                } header: { Text("Audio") } footer: {
                    Text("On an M1 iPad, 1024 frames gives the most headroom. Smaller buffers mean less latency but more risk of clicks. Watch the CPU meter at the top.")
                }

                Section("Display") {
                    Picker("LCD", selection: $machine.lcdThemeRaw) {
                        ForEach(LCDTheme.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if machine.midiSources.isEmpty && machine.midiDestinations.isEmpty {
                        Text("No MIDI devices yet. Connect a USB interface, pair Bluetooth MIDI below, or route to “Machinedrum” in another app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(machine.midiSources, id: \.uniqueID) { e in
                        Toggle(isOn: Binding(get: { e.enabled }, set: { machine.midi.setEndpoint(e.uniqueID, enabled: $0) })) {
                            Label(e.name, systemImage: "arrow.down.circle")
                        }
                    }
                    ForEach(machine.midiDestinations, id: \.uniqueID) { e in
                        Toggle(isOn: Binding(get: { e.enabled }, set: { machine.midi.setEndpoint(e.uniqueID, enabled: $0) })) {
                            Label(e.name, systemImage: "arrow.up.circle")
                        }
                    }
                    Toggle("Network MIDI (Wi-Fi)", isOn: Binding(get: { machine.midi.networkEnabled }, set: { machine.midi.networkEnabled = $0 }))
                    Button("Pair Bluetooth MIDI…") { showBluetooth = true }
                } header: { Text("MIDI") } footer: {
                    Text("Inputs (↓) play and control the Machinedrum; outputs (↑) receive its notes, CCs, clock and SysEx. Other apps see it as “Machinedrum”. Set the MIDI channel, clock and sync options in the Machinedrum's own GLOBAL menu.")
                }

                Section {
                    Button("Back up kits, patterns and songs…") { exportURL = machine.exportBackup() }
                    Button("Restore a backup…") { restoring = true }
                    Button("Reset to factory…", role: .destructive) { confirmReset = true }
                } header: { Text("Your data") } footer: {
                    Text("Saved automatically every 30 seconds and whenever you leave the app. A factory reset keeps your current state as a backup file first, so it can be restored.")
                }

                Section {
                    NavigationLink("Diagnostics and engine tests") {
                        DiagnosticsView()
                            .onAppear { machine.suspend() }
                    }
                } footer: {
                    Text("Opening Diagnostics stops the Machinedrum (your work is saved). Press Start when you come back.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset the Machinedrum to its factory kits, patterns and settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to factory", role: .destructive) { machine.factoryReset(); dismiss() }
            } message: {
                Text("Your current state is saved as a backup file first, so you can restore it later.")
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { item in
            ShareSheet(url: item.url)
        }
        .sheet(isPresented: $showBluetooth) { BluetoothMIDIView() }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { machine.restoreBackup(from: url); dismiss() }
        }
    }

    private func restartOnChange<T: Equatable>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { v in
            if v != binding.wrappedValue { binding.wrappedValue = v; pendingRestart = true }
        })
    }
}

private struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Apple's Bluetooth MIDI pairing screen.
private struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CABTMIDICentralViewController()
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        return nav
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
