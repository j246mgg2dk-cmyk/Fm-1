import AudioToolbox
import FM1Core
import SwiftUI

/// Track I/O + device chain (MIDI FX → instrument → effects), with each
/// plugin's own UI one tap away.
struct TrackDetailView: View {
    @EnvironmentObject var model: AppModel
    let trackID: UUID?
    @State private var showBrowser = false
    @State private var openPlugin: OpenPlugin?

    struct OpenPlugin: Identifiable {
        let id: UUID
        let name: String
        let vc: UIViewController?
    }

    var body: some View {
        if let id = trackID, let track = model.project.track(id) {
            Form {
                SwiftUI.Section("Track") {
                    TextField("Name", text: Binding(get: { track.name }, set: { v in model.updateTrack(id, rebuildGraph: false) { $0.name = v } }))
                    Picker("Type", selection: Binding(get: { track.kind }, set: { v in model.updateTrack(id) { $0.kind = v } })) {
                        ForEach(TrackKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if track.kind == .audio || track.kind == .externalInstrument {
                        inputPicker(track)
                        Picker("Monitor", selection: Binding(get: { track.monitor }, set: { v in model.updateTrack(id) { $0.monitor = v } })) {
                            ForEach(MonitorMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                    }
                    if track.kind == .midi || track.kind == .externalInstrument || track.kind == .instrument {
                        midiOutPicker(track)
                    }
                    if track.kind == .externalInstrument {
                        Stepper("Round-trip latency: \(Int(track.externalLatencyMs)) ms",
                                value: Binding(get: { track.externalLatencyMs }, set: { v in model.updateTrack(id, rebuildGraph: false) { $0.externalLatencyMs = v } }),
                                in: 0...100)
                    }
                }

                SwiftUI.Section {
                    if track.devices.isEmpty {
                        Text(track.kind == .instrument ? "Add an instrument (any AUv3: Moog, Korg, Koala, Drambo…)" : "No devices yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(track.devices) { slot in deviceRow(track, slot) }
                        .onMove { model.moveDevice(in: id, from: $0, to: $1) }
                    Button { showBrowser = true } label: { Label("Add Plugin", systemImage: "plus") }
                } header: {
                    Text("Device Chain")
                } footer: {
                    Text("MIDI processors feed the instrument; effects process its audio in order. Drag to reorder.")
                }
            }
            .sheet(isPresented: $showBrowser) {
                PluginBrowser { entry in
                    model.addPlugin(entry, to: id)
                    showBrowser = false
                }
            }
            .sheet(item: $openPlugin) { p in
                NavigationStack {
                    Group {
                        if let vc = p.vc { PluginView(viewController: vc) } else { genericEditor(p.id) }
                    }
                    .navigationTitle(p.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { openPlugin = nil } }
                }
            }
        } else {
            ContentUnavailableView("No track selected", systemImage: "pianokeys", description: Text("Tap a track header in Session or Mixer."))
        }
    }

    private func deviceRow(_ track: Track, _ slot: DeviceSlot) -> some View {
        HStack {
            Image(systemName: icon(slot.component.role))
            VStack(alignment: .leading) {
                Text(slot.component.name)
                Text(slot.component.manufacturerName).font(.caption).foregroundStyle(.secondary)
                if let err = model.failedDevices[slot.id] { Text(err).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if model.loadingDevices.contains(slot.id) { ProgressView() }
            if slot.component.role == .audioEffect || slot.component.role == .musicEffect {
                Slider(value: Binding(get: { slot.mix }, set: { v in
                    model.updateTrack(track.id) { t in if let i = t.devices.firstIndex(where: { $0.id == slot.id }) { t.devices[i].mix = v } }
                }), in: 0...1).frame(width: 90)
            }
            Toggle("", isOn: Binding(get: { !slot.isBypassed }, set: { v in
                model.updateTrack(track.id) { t in if let i = t.devices.firstIndex(where: { $0.id == slot.id }) { t.devices[i].isBypassed = !v } }
            }))
            .labelsHidden()
            Button("Open") {
                Task {
                    let vc = await model.plugin(slot.id)?.requestViewController()
                    openPlugin = OpenPlugin(id: slot.id, name: slot.component.name, vc: vc)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.plugin(slot.id) == nil)
        }
        .swipeActions {
            Button("Remove", role: .destructive) { model.removePlugin(slot.id, from: track.id) }
        }
    }

    /// For plugins without a custom view: every parameter as a slider.
    private func genericEditor(_ deviceID: UUID) -> some View {
        List(model.plugin(deviceID)?.parameters() ?? []) { p in
            VStack(alignment: .leading) {
                Text(p.name).font(.caption)
                Slider(value: parameterBinding(deviceID, p), in: parameterRange(p))
            }
        }
    }

    private func parameterBinding(_ deviceID: UUID, _ p: HostedPlugin.ParameterInfo) -> Binding<Double> {
        let address = p.address
        let fallback = Double(p.value)
        return Binding<Double>(
            get: {
                let param = model.plugin(deviceID)?.au.parameterTree?.parameter(withAddress: address)
                return param.map { Double($0.value) } ?? fallback
            },
            set: { newValue in
                let param = model.plugin(deviceID)?.au.parameterTree?.parameter(withAddress: address)
                param?.value = AUValue(newValue)
            })
    }

    private func parameterRange(_ p: HostedPlugin.ParameterInfo) -> ClosedRange<Double> {
        let lo = Double(p.min)
        return lo...max(Double(p.max), lo + 0.0001)
    }

    private func inputPicker(_ track: Track) -> some View {
        let n = model.audioStatus.inputChannels
        return Picker("Input", selection: Binding(get: { track.audioInputs }, set: { v in model.updateTrack(track.id) { $0.audioInputs = v } })) {
            Text("None").tag([Int]())
            ForEach(stereoPairs(n), id: \.self) { Text("In \(pairName($0)) (stereo)").tag($0) }
            ForEach(0..<n, id: \.self) { Text("In \($0 + 1)").tag([$0]) }
        }
    }

    private func midiOutPicker(_ track: Track) -> some View {
        Group {
            Picker("MIDI Out", selection: Binding(get: { track.midiOutput }, set: { v in model.updateTrack(track.id) { $0.midiOutput = v } })) {
                Text("None").tag(EndpointID?.none)
                Text("FM-1 Out (to AUM/Koala…)").tag(EndpointID?.some(.fm1VirtualOut))
                ForEach(model.midiDestinations) { d in Text(d.id.name).tag(EndpointID?.some(d.id)) }
            }
            Picker("MIDI Channel", selection: Binding(get: { track.midiOutputChannel }, set: { v in model.updateTrack(track.id) { $0.midiOutputChannel = v } })) {
                Text("Keep").tag(UInt8?.none)
                ForEach(0..<16, id: \.self) { c in Text("\(c + 1)").tag(UInt8?.some(UInt8(c))) }
            }
        }
    }

    private func icon(_ role: PluginRole) -> String {
        switch role {
        case .instrument, .generator: return "pianokeys"
        case .midiProcessor: return "pianokeys.inverse"
        case .audioEffect, .musicEffect: return "dial.medium"
        case .other: return "puzzlepiece"
        }
    }
}

struct PluginBrowser: View {
    @EnvironmentObject var catalog: PluginCatalog
    @Environment(\.dismiss) private var dismiss
    let onPick: (PluginCatalog.Entry) -> Void
    @State private var search = ""
    @State private var role: PluginRole? = nil

    var body: some View {
        NavigationStack {
            List {
                Picker("Type", selection: $role) {
                    Text("All").tag(PluginRole?.none)
                    Text("Instruments").tag(PluginRole?.some(.instrument))
                    Text("Effects").tag(PluginRole?.some(.audioEffect))
                    Text("Music FX").tag(PluginRole?.some(.musicEffect))
                    Text("MIDI FX").tag(PluginRole?.some(.midiProcessor))
                }
                .pickerStyle(.segmented)
                ForEach(filtered) { e in
                    Button { onPick(e) } label: {
                        VStack(alignment: .leading) {
                            Text(e.component.name)
                            Text("\(e.component.manufacturerName) · \(PluginComponentID.fourCCString(e.component.type))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if catalog.entries.isEmpty {
                    Text("No AUv3 plugins found. Install some from the App Store (anything that loads in AUM or GarageBand works here).")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search)
            .navigationTitle("AUv3 Plugins")
            .toolbar {
                Button("Refresh") { catalog.refresh() }
                Button("Close") { dismiss() }
            }
        }
    }

    private var filtered: [PluginCatalog.Entry] {
        catalog.entries(for: role).filter {
            search.isEmpty || $0.component.name.localizedCaseInsensitiveContains(search)
                || $0.component.manufacturerName.localizedCaseInsensitiveContains(search)
        }
    }
}
