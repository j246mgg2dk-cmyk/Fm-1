import CoreAudioKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app: the Machinedrum's front panel, with a slim top bar.
struct MachineView: View {
    @EnvironmentObject private var machine: MachineController
    @State private var showSettings = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        ZStack {
            Panel.face.ignoresSafeArea()
            switch machine.phase {
            case .running:
                VStack(spacing: 0) {
                    TopBar(showSettings: $showSettings)
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

    private var firmwarePrompt: some View {
        VStack(spacing: 16) {
            Silk("MACHINEDRUM", size: 16)
            Text("Import your Machinedrum UW OS 1.63 firmware (elektron_sps1-1uw_os1.63.bin) to start. It stays on this iPad and is never shared.")
                .font(.callout).foregroundStyle(Panel.silkDim).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Import firmware…") { importing = true }.buttonStyle(.borderedProminent).tint(Panel.orange)
        }
    }
}

/// Status, meters and settings above the panel. Observes the meters on its own so the panel
/// doesn't redraw with them.
struct TopBar: View {
    @Binding var showSettings: Bool
    @EnvironmentObject private var machine: MachineController
    @EnvironmentObject private var panel: PanelState
    @State private var showProjects = false

    var body: some View {
        HStack(spacing: 16) {
            Silk("MACHINEDRUM", size: 12)
            Silk("UW 1.63", size: 10, color: Panel.silkDim)
            if let left = panel.stressRemaining {
                Text(String(format: "STRESS TEST %d:%02d", left / 60, left % 60))
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Panel.orange)
                Button("Stop") { machine.stopStressTest(restore: true) }.font(.system(size: 11, weight: .semibold))
            }
            Button { showProjects = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: machine.isSaving ? "arrow.down.doc.fill" : "folder.fill").font(.system(size: 12))
                    Text(machine.currentProject.isEmpty ? "Unsaved session" : machine.currentProject)
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(Panel.silk)
            }
            .sheet(isPresented: $showProjects) { ProjectsView().environmentObject(machine) }
            Spacer()
            // Emulation load: how much of real time the emulator needs (average over the last
            // quarter second). Green under 75%, orange under 95%, red above.
            meter("DSP", value: panel.load, label: "\(Int(panel.load * 100))%",
                  color: panel.load < 0.75 ? Panel.green : panel.load < 0.95 ? Panel.orange : Panel.red)
            // Safety buffer: how full it stayed. Near empty means a click is close.
            meter("SAFETY", value: panel.safety, label: "\(Int(panel.safety * 100))%",
                  color: panel.safety > 0.4 ? Panel.green : panel.safety > 0.15 ? Panel.orange : Panel.red)
            HStack(spacing: 6) {
                Silk("MIDI", size: 9, color: Panel.silkDim)
                LED(on: panel.midiIn, color: Panel.green, size: 6)
                LED(on: panel.midiOut, color: Panel.orange, size: 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Panel.silkDim)
                Slider(value: $machine.volume, in: 0...1).frame(width: 110).tint(Panel.orange)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16)).foregroundStyle(Panel.silk)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    private func meter(_ title: String, value: Double, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Silk(title, size: 9, color: Panel.silkDim)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.08))
                    Capsule().fill(color).frame(width: g.size.width * min(1, max(0, value)))
                }
            }
            .frame(width: 60, height: 5)
            Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Panel.silkDim)
                .frame(width: 34, alignment: .leading)
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
                    Picker("Output buffer", selection: restartOnChange($machine.bufferFrames)) {
                        Text("128 frames (2.9 ms)").tag(128)
                        Text("256 frames (5.8 ms)").tag(256)
                        Text("512 frames (11.6 ms)").tag(512)
                    }
                    Picker("Safety buffer", selection: restartOnChange($machine.safetyFrames)) {
                        Text("512 frames (11.6 ms)").tag(512)
                        Text("768 frames (17.4 ms)").tag(768)
                        Text("1024 frames (23.2 ms)").tag(1024)
                        Text("1536 frames (34.8 ms)").tag(1536)
                        Text("2048 frames (46.4 ms)").tag(2048)
                    }
                    LabeledContent("Total latency", value: String(format: "about %.0f ms", Double(machine.bufferFrames + machine.safetyFrames) / 44.1))
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
                    Text("The emulator runs on its own thread ahead of the output by the safety buffer, so heavy moments (fast knob sweeps, kit changes) are absorbed instead of heard. The DSP meter shows how much of real time the emulation needs; SAFETY shows how full the buffer stayed. If SAFETY keeps dipping to red, choose a bigger safety buffer.")
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
                    Picker("Autosave", selection: $machine.autosaveMinutes) {
                        Text("Off").tag(0)
                        Text("Every 2 minutes").tag(2)
                        Text("Every 5 minutes").tag(5)
                        Text("Every 15 minutes").tag(15)
                    }
                    .onChange(of: machine.autosaveMinutes) { _, _ in machine.startAutosave() }
                    Toggle("Keep the session when leaving the app", isOn: $machine.saveOnLeave)
                    Button("Back up kits, patterns and songs…") { exportURL = machine.exportBackup() }
                    Button("Restore a backup…") { restoring = true }
                    Button("Reset to factory…", role: .destructive) { confirmReset = true }
                } header: { Text("Your data") } footer: {
                    Text("Nothing is written while you play unless you save (the folder button at the top) or turn on autosave. “Keep the session” saves once when the app goes to the background or quits, never while it's in front, so iOS closing the app doesn't lose your work. A factory reset keeps your current state as a backup file first.")
                }

                Section {
                    Toggle("Performance log", isOn: $machine.perfLogEnabled)
                    Button(machine.isStressRunning ? "Stop the stress test" : "Run the stress test (5 minutes)") {
                        if machine.isStressRunning { machine.stopStressTest(restore: true) } else { machine.startStressTest(minutes: 5); dismiss() }
                    }
                    if !machine.isStressRunning {
                        Button("Run the stress test (30 minutes)") { machine.startStressTest(minutes: 30); dismiss() }
                    }
                    Button("Share the performance log…") {
                        if FileManager.default.fileExists(atPath: Storage.perfLog.path) { exportURL = Storage.perfLog }
                    }
                } header: { Text("Performance") } footer: {
                    Text("The log adds a line every 10 seconds: emulation load, worst render block, underruns, lowest safety-buffer fill, automatic audio restarts, memory, thermal state and per-thread CPU. The stress test hammers all knobs, triggers all 16 tracks, sends parameter CCs and changes patterns on top of what you're playing; your state is saved first and put back afterwards.")
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


/// Projects: Save, Save As and Load of the complete machine (all kits, patterns, songs, globals).
struct ProjectsView: View {
    @EnvironmentObject private var machine: MachineController
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askName = false
    @State private var confirmLoad: String?
    @State private var confirmOverwrite: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !machine.currentProject.isEmpty {
                        Button {
                            machine.saveProject(); dismiss()
                        } label: { Label("Save “\(machine.currentProject)”", systemImage: "square.and.arrow.down") }
                    }
                    Button { newName = suggestedName(); askName = true } label: {
                        Label(machine.currentProject.isEmpty ? "Save as a project…" : "Save as a new project…", systemImage: "plus.square.on.square")
                    }
                } footer: {
                    Text("A project is the whole machine: all 64 kits, 128 patterns, songs and global settings, exactly as the Machinedrum holds them. Saving runs in the background and doesn't interrupt the audio. Within a project, save and reload kits in the Machinedrum's own KIT menu, as on the hardware.")
                }
                Section("Load") {
                    if machine.projects.isEmpty {
                        Text("No saved projects yet.").foregroundStyle(.secondary)
                    }
                    ForEach(machine.projects) { p in
                        Button { confirmLoad = p.name } label: {
                            HStack {
                                Text(p.name).foregroundStyle(.primary)
                                if p.name == machine.currentProject { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                Spacer()
                                Text(p.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                Text(p.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { machine.projects[$0].name }.forEach(machine.deleteProject) }
                }
            }
            .navigationTitle("Projects")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { machine.refreshProjects() }
            .alert("Save as a project", isPresented: $askName) {
                TextField("Name", text: $newName)
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    if machine.projects.contains(where: { $0.name == name }) { confirmOverwrite = name }
                    else { machine.saveProject(as: name); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Replace the saved project “\(confirmOverwrite ?? "")”?", isPresented: Binding(get: { confirmOverwrite != nil }, set: { if !$0 { confirmOverwrite = nil } }), titleVisibility: .visible) {
                Button("Replace", role: .destructive) { if let n = confirmOverwrite { machine.saveProject(as: n); dismiss() } }
            }
            .confirmationDialog("Load “\(confirmLoad ?? "")”?", isPresented: Binding(get: { confirmLoad != nil }, set: { if !$0 { confirmLoad = nil } }), titleVisibility: .visible) {
                Button("Load") { if let n = confirmLoad { machine.loadProject(n); dismiss() } }
            } message: {
                Text("Unsaved changes in the current session are replaced. The machine restarts with the project (a few seconds).")
            }
        }
    }

    private func suggestedName() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        return "Jam \(f.string(from: Date()))"
    }
}
