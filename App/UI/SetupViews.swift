import FM1Core
import SwiftUI

// MARK: - CV / Modular

struct CVView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(model.project.cvOutputs) { cv in CVRow(cv: cv) }
                    .onDelete { model.project.cvOutputs.remove(atOffsets: $0); model.rebuild() }
                Menu {
                    let t = model.project.tracks.first { $0.kind != .audio }?.id ?? UUID()
                    Button("Pitch (1V/oct)") { add("Pitch", .pitch(track: t, bendRange: 2), lo: -5, hi: 5) }
                    Button("Gate") { add("Gate", .gate(track: t)) }
                    Button("Trigger") { add("Trig", .trigger(track: t)) }
                    Button("Velocity") { add("Vel", .velocity(track: t)) }
                    Button("Clock (16ths)") { add("Clock", .clock(pulsesPerQuarter: 4)) }
                    Button("Reset (every bar)") { add("Reset", .reset(everyBars: 1)) }
                    if let m = model.project.modulators.first {
                        Button("Modulator → CV") { add("Mod", .modulator(m.id), lo: -5, hi: 5) }
                    }
                    Button("Constant (calibration)") { add("Const", .constant(volts: 1)) }
                } label: { Label("Add CV Output", systemImage: "plus") }
            } header: {
                Text("CV Outputs")
            } footer: {
                Text("Needs a DC-coupled interface (Expert Sleepers ES-8/ES-9, MOTU UltraLite mk5, etc.). Never send CV to speakers. Use a Constant output and a multimeter/tuner to calibrate.")
            }
        }
    }

    private func add(_ name: String, _ source: CVSource, lo: Double = 0, hi: Double = 5) {
        let used = Set(model.project.cvOutputs.map(\.channel))
        let ch = (0..<max(model.audioStatus.outputChannels, 1)).reversed().first { !used.contains($0) && !model.project.masterOutputChannels.contains($0) } ?? 0
        model.project.cvOutputs.append(CVOutputConfig(name: "\(name) \(model.project.cvOutputs.count + 1)", channel: ch, source: source, minVolts: lo, maxVolts: hi))
        model.rebuild()
    }
}

struct CVRow: View {
    @EnvironmentObject var model: AppModel
    let cv: CVOutputConfig

    private func update(_ f: (inout CVOutputConfig) -> Void) {
        guard let i = model.project.cvOutputs.firstIndex(where: { $0.id == cv.id }) else { return }
        f(&model.project.cvOutputs[i])
        model.rebuild()
    }

    var body: some View {
        DisclosureGroup {
            Picker("Output channel", selection: Binding(get: { cv.channel }, set: { v in update { $0.channel = v } })) {
                ForEach(0..<max(model.audioStatus.outputChannels, 1), id: \.self) { Text("Out \($0 + 1)").tag($0) }
            }
            if let t = cv.trackSource {
                Picker("Track", selection: Binding(get: { t }, set: { v in update { $0.source = $0.source.withTrack(v) } })) {
                    ForEach(model.project.tracks) { Text($0.name).tag($0.id) }
                }
            }
            if case .pitch = cv.source {
                Stepper("0 V = \(noteName(UInt8(clamping: cv.zeroVoltNote)))", value: Binding(get: { cv.zeroVoltNote }, set: { v in update { $0.zeroVoltNote = v } }), in: 0...127)
                Picker("Quantize", selection: Binding(get: { cv.quantizer?.scale }, set: { v in update { $0.quantizer = v.map { ScaleQuantizer(root: 0, scale: $0) } } })) {
                    Text("Off").tag(ScaleQuantizer.Scale?.none)
                    ForEach(ScaleQuantizer.Scale.allCases, id: \.self) { Text($0.rawValue).tag(ScaleQuantizer.Scale?.some($0)) }
                }
            }
            if case let .clock(ppq) = cv.source {
                Picker("Rate", selection: Binding(get: { ppq }, set: { v in update { $0.source = .clock(pulsesPerQuarter: v) } })) {
                    Text("1/4").tag(1); Text("1/8").tag(2); Text("1/16").tag(4); Text("24 ppq").tag(24)
                }
            }
            if case let .constant(volts) = cv.source {
                Stepper(String(format: "%.2f V", volts), value: Binding(get: { volts }, set: { v in update { $0.source = .constant(volts: v) } }), in: -10...10, step: 0.25)
            }
            Stepper(String(format: "Range low %.1f V", cv.minVolts), value: Binding(get: { cv.minVolts }, set: { v in update { $0.minVolts = v } }), in: -10...10, step: 0.5)
            Stepper(String(format: "Range high %.1f V", cv.maxVolts), value: Binding(get: { cv.maxVolts }, set: { v in update { $0.maxVolts = v } }), in: -10...10, step: 0.5)
            Stepper(String(format: "Pulse %.0f ms", cv.pulseWidthMs), value: Binding(get: { cv.pulseWidthMs }, set: { v in update { $0.pulseWidthMs = v } }), in: 1...100)
            SwiftUI.Section("Calibration") {
                Stepper(String(format: "Interface full scale %.1f V", cv.calibration.fullScaleVolts),
                        value: Binding(get: { cv.calibration.fullScaleVolts }, set: { v in update { $0.calibration.fullScaleVolts = v } }), in: 1...20, step: 0.1)
                Stepper(String(format: "Offset %+.3f V", cv.calibration.offsetVolts),
                        value: Binding(get: { cv.calibration.offsetVolts }, set: { v in update { $0.calibration.offsetVolts = v } }), in: -1...1, step: 0.001)
                Stepper(String(format: "Scale trim %.4f", cv.calibration.scaleTrim),
                        value: Binding(get: { cv.calibration.scaleTrim }, set: { v in update { $0.calibration.scaleTrim = v } }), in: 0.9...1.1, step: 0.0005)
            }
        } label: {
            Toggle(isOn: Binding(get: { cv.isEnabled }, set: { v in update { $0.isEnabled = v } })) {
                VStack(alignment: .leading) {
                    Text(cv.name)
                    Text("Out \(cv.channel + 1)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension CVOutputConfig {
    var trackSource: UUID? {
        switch source {
        case let .pitch(t, _), let .gate(t), let .trigger(t), let .velocity(t): return t
        default: return nil
        }
    }
}

extension CVSource {
    func withTrack(_ t: UUID) -> CVSource {
        switch self {
        case let .pitch(_, b): return .pitch(track: t, bendRange: b)
        case .gate: return .gate(track: t)
        case .trigger: return .trigger(track: t)
        case .velocity: return .velocity(track: t)
        default: return self
        }
    }
}

// MARK: - Sync

struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @State private var showLinkSettings = false

    var body: some View {
        Form {
            SwiftUI.Section("Tempo source") {
                Picker("Clock", selection: Binding(get: { model.project.clock.source }, set: { model.project.clock.source = $0; model.rebuild() })) {
                    ForEach(ClockSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.project.clock.source == .externalMIDI {
                    Picker("Follow input", selection: Binding(get: { model.project.clock.externalInput }, set: { model.project.clock.externalInput = $0; model.rebuild() })) {
                        Text("None").tag(EndpointID?.none)
                        Text("FM-1 In").tag(EndpointID?.some(.fm1VirtualIn))
                        ForEach(model.midiSources) { Text($0.id.name).tag(EndpointID?.some($0.id)) }
                    }
                    Text(live.externalTempo.map { String(format: "Receiving %.2f BPM", $0) } ?? "No clock received yet")
                        .foregroundStyle(.secondary)
                }
                if model.project.clock.source == .abletonLink {
                    if model.engine.link.isAvailable {
                        Button("Link Settings") { showLinkSettings = true }
                    } else {
                        Text("Add LinkKit.xcframework to the project to enable Ableton Link (see README).").foregroundStyle(.orange)
                    }
                }
            }
            SwiftUI.Section {
                ForEach(model.midiDestinations + [MIDIManager.Endpoint(id: .fm1VirtualOut, ref: 0, isOnline: true, manufacturer: "")]) { d in
                    Toggle(d.id.name, isOn: Binding(get: { model.project.clock.sendClockTo.contains(d.id) }, set: { on in
                        if on { model.project.clock.sendClockTo.append(d.id) } else { model.project.clock.sendClockTo.removeAll { $0 == d.id } }
                        model.rebuild()
                    }))
                }
                Toggle("Keep clock running while stopped", isOn: Binding(get: { model.engine.sendClockWhenStopped.value },
                                                                         set: { model.engine.sendClockWhenStopped.value = $0 }))
                Stepper(String(format: "Clock offset %+.1f ms", model.project.clock.clockOffsetMs),
                        value: Binding(get: { model.project.clock.clockOffsetMs }, set: { model.project.clock.clockOffsetMs = $0; model.rebuild() }),
                        in: -50...50, step: 0.5)
            } header: {
                Text("Send MIDI clock + start/stop to")
            } footer: {
                Text("Clock is timestamped against audio output latency so drum machines and sequencers land with what you hear. Nudge the offset if a specific box runs early or late.")
            }
            SwiftUI.Section("Time signature") {
                Stepper("\(model.project.timeSignature.beatsPerBar) / \(model.project.timeSignature.noteValue)",
                        value: Binding(get: { model.project.timeSignature.beatsPerBar }, set: { model.project.timeSignature.beatsPerBar = $0; model.rebuild() }),
                        in: 1...32)
                Picker("Note value", selection: Binding(get: { model.project.timeSignature.noteValue }, set: { model.project.timeSignature.noteValue = $0; model.rebuild() })) {
                    Text("4").tag(4); Text("8").tag(8); Text("16").tag(16)
                }
            }
        }
        .sheet(isPresented: $showLinkSettings) {
            if let vc = model.engine.link.settingsViewControllerIfAvailable() {
                NavigationStack { PluginView(viewController: vc).toolbar { Button("Done") { showLinkSettings = false } } }
            }
        }
    }
}

extension LinkSync {
    func settingsViewControllerIfAvailable() -> UIViewController? {
        #if canImport(LinkKit)
        return settingsViewController()
        #else
        return nil
        #endif
    }
}

// MARK: - Audio I/O

struct AudioIOView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    var body: some View {
        Form {
            SwiftUI.Section("Interface") {
                LabeledContent("Input", value: model.audioStatus.inputName)
                LabeledContent("Output", value: model.audioStatus.outputName)
                LabeledContent("Channels", value: "\(model.audioStatus.inputChannels) in / \(model.audioStatus.outputChannels) out")
                LabeledContent("Sample rate", value: String(format: "%.0f Hz", model.audioStatus.sampleRate))
                LabeledContent("Buffer", value: "\(model.audioStatus.bufferFrames) frames")
                LabeledContent("Round-trip latency",
                               value: String(format: "%.1f ms", Double(model.engine.roundTripLatencyFrames) / model.audioStatus.sampleRate * 1000))
            }
            SwiftUI.Section("Settings") {
                Picker("Buffer size", selection: $model.ioConfig.preferredBufferFrames) {
                    ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Sample rate", selection: $model.ioConfig.preferredSampleRate) {
                    Text("44.1 kHz").tag(44_100.0); Text("48 kHz").tag(48_000.0); Text("96 kHz").tag(96_000.0)
                }
                Toggle("Run alongside other audio apps (AUM, Koala…)", isOn: $model.ioConfig.mixWithOthers)
                Toggle("Allow Bluetooth headphones (high latency)", isOn: $model.ioConfig.allowBluetoothOutput)
                Button("Apply") { model.applyIOConfig() }
            }
            SwiftUI.Section("Input levels") {
                ForEach(Array(live.inputPeaks.enumerated()), id: \.offset) { i, v in
                    HStack {
                        Text("In \(i + 1)").frame(width: 50, alignment: .leading)
                        MeterBar(left: v, right: v).frame(height: 10)
                    }
                }
                if live.inputPeaks.isEmpty { Text("No inputs (check microphone permission in Settings)").foregroundStyle(.secondary) }
            }
            SwiftUI.Section("Recording") {
                Toggle("Also record the master mix (jam capture)", isOn: $model.project.recordMasterMix)
                Text("Recordings land in Files › On My iPad › FM-1 › <project> › Audio, ready for Koala, AUM, AudioShare or your desktop DAW.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Bluetooth & network

struct ConnectView: View {
    @State private var showCentral = false
    @State private var showPeripheral = false

    var body: some View {
        Form {
            SwiftUI.Section {
                Button("Connect Bluetooth MIDI devices…") { showCentral = true }
                Button("Advertise this iPad as a Bluetooth MIDI device…") { showPeripheral = true }
            } header: {
                Text("Bluetooth LE MIDI")
            } footer: {
                Text("Connected devices appear in MIDI Routing like any USB device and stay routed when they reconnect.")
            }
            SwiftUI.Section {
                Text("Network MIDI (RTP) is enabled and accepts connections from any Mac or iPad on the same network. On a Mac, open Audio MIDI Setup › MIDI Network Setup and connect to this iPad.")
            } header: {
                Text("Network MIDI")
            }
            SwiftUI.Section {
                Text("FM-1 In / FM-1 Out are virtual MIDI ports. In AUM, Koala, Drambo etc., pick \"FM-1 Out\" as an input to receive FM-1's clock and notes, or send to \"FM-1 In\".")
                Text("Any AUv3 that works in AUM loads inside FM-1, including Koala Sampler's AUv3 and AUM-style MIDI FX.")
            } header: {
                Text("Other apps")
            }
        }
        .sheet(isPresented: $showCentral) { BluetoothMIDICentralView() }
        .sheet(isPresented: $showPeripheral) { BluetoothMIDIPeripheralView() }
    }
}

// MARK: - Projects

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var projects: [URL] = []

    var body: some View {
        List {
            SwiftUI.Section("Current") {
                TextField("Project name", text: $model.project.name)
                Button("Save") { model.save(); projects = model.listProjects() }
                HStack {
                    TextField("New project name", text: $newName)
                    Button("Create") {
                        model.save()
                        model.newProject(named: newName.isEmpty ? "Untitled" : newName)
                        newName = ""
                    }
                }
            }
            SwiftUI.Section("Saved projects") {
                ForEach(projects, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        model.save()
                        model.open(url)
                    }
                }
            }
        }
        .onAppear { projects = model.listProjects() }
    }
}
