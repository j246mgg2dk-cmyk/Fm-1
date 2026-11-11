import FM1Core
import SwiftUI

/// Bitwig-style modulation: create modulators, then point each one at any
/// number of targets (plugin parameters, volume, pan, sends) with a depth.
struct ModulatorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingTarget: UUID?

    var body: some View {
        List {
            ForEach(model.project.modulators) { m in
                SwiftUI.Section {
                    editor(m)
                    ForEach(model.project.modulation.filter { $0.modulator == m.id }) { c in
                        HStack {
                            Text(targetName(c.target)).font(.caption)
                            Slider(value: Binding(get: { c.depth }, set: { v in
                                if let i = model.project.modulation.firstIndex(where: { $0.id == c.id }) {
                                    model.project.modulation[i].depth = v
                                }
                            }), in: -1...1, onEditingChanged: { editing in if !editing { model.rebuild() } })
                            Text(String(format: "%+.0f%%", c.depth * 100)).font(.caption.monospacedDigit()).frame(width: 48)
                        }
                    }
                    .onDelete { idx in
                        let ids = model.project.modulation.filter { $0.modulator == m.id }
                        let remove = Set(idx.map { ids[$0].id })
                        model.project.modulation.removeAll { remove.contains($0.id) }
                        model.rebuild()
                    }
                    Button { addingTarget = m.id } label: { Label("Modulate…", systemImage: "arrow.triangle.branch") }
                } header: {
                    HStack {
                        TextField("Name", text: Binding(get: { m.name }, set: { v in
                            if let i = model.project.modulators.firstIndex(where: { $0.id == m.id }) { model.project.modulators[i].name = v }
                        }))
                        Spacer()
                        Button(role: .destructive) {
                            model.project.modulators.removeAll { $0.id == m.id }
                            model.project.modulation.removeAll { $0.modulator == m.id }
                            model.project.macroMappings.removeAll { $0.modulator == m.id }
                            model.rebuild()
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            SwiftUI.Section {
                Menu {
                    Button("LFO") { add("LFO", .lfo(shape: .sine, rate: .beats(4), phaseOffset: 0, bipolar: true)) }
                    Button("Envelope (ADSR)") { add("Env", .adsr(attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.4)) }
                    Button("Steps") { add("Steps", .steps(values: [0, 0.25, 0.5, 1, 0.75, 0.5, 0.25, 0], stepBeats: 0.25, glide: 0)) }
                    Button("Random") { add("Random", .random(rate: .beats(1), smoothing: 0.05)) }
                    Button("Macro Knob") { add("Macro", .macro(value: 0.5)) }
                    Button("Audio Follower") { add("Follower", .audioFollower(attack: 0.01, release: 0.2, gain: 2)) }
                } label: { Label("Add Modulator", systemImage: "plus") }
            }
        }
        .sheet(item: Binding(get: { addingTarget.map { IDBox(id: $0) } }, set: { addingTarget = $0?.id })) { box in
            TargetPicker { target, base in
                model.project.modulation.append(ModulationConnection(modulator: box.id, target: target, depth: 0.5, base: base))
                model.rebuild()
                addingTarget = nil
            }
        }
    }

    struct IDBox: Identifiable { let id: UUID }

    private func add(_ name: String, _ kind: ModulatorKind) {
        let n = model.project.modulators.filter { $0.name.hasPrefix(name) }.count + 1
        model.project.modulators.append(ModulatorDefinition(name: "\(name) \(n)", kind: kind,
                                                            sourceTrack: model.project.tracks.first?.id))
        model.rebuild()
    }

    private func update(_ id: UUID, _ kind: ModulatorKind) {
        guard let i = model.project.modulators.firstIndex(where: { $0.id == id }) else { return }
        model.project.modulators[i].kind = kind
    }

    @ViewBuilder
    private func editor(_ m: ModulatorDefinition) -> some View {
        switch m.kind {
        case let .lfo(shape, rate, phase, bipolar):
            Picker("Shape", selection: Binding(get: { shape }, set: { update(m.id, .lfo(shape: $0, rate: rate, phaseOffset: phase, bipolar: bipolar)); model.rebuild() })) {
                ForEach(LFOShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            rateEditor(rate) { update(m.id, .lfo(shape: shape, rate: $0, phaseOffset: phase, bipolar: bipolar)) }
            Toggle("Bipolar", isOn: Binding(get: { bipolar }, set: { update(m.id, .lfo(shape: shape, rate: rate, phaseOffset: phase, bipolar: $0)); model.rebuild() }))
        case let .adsr(a, d, s, r):
            trackPicker(m)
            knob("Attack", a, 0.001...5) { update(m.id, .adsr(attack: $0, decay: d, sustain: s, release: r)) }
            knob("Decay", d, 0.001...5) { update(m.id, .adsr(attack: a, decay: $0, sustain: s, release: r)) }
            knob("Sustain", s, 0...1) { update(m.id, .adsr(attack: a, decay: d, sustain: $0, release: r)) }
            knob("Release", r, 0.001...10) { update(m.id, .adsr(attack: a, decay: d, sustain: s, release: $0)) }
        case let .steps(values, stepBeats, glide):
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    Slider(value: Binding(get: { values[i] }, set: { v in
                        var nv = values; nv[i] = v
                        update(m.id, .steps(values: nv, stepBeats: stepBeats, glide: glide))
                    }), in: 0...1, onEditingChanged: { if !$0 { model.rebuild() } })
                    .rotationEffect(.degrees(-90))
                    .frame(width: 28, height: 90)
                }
            }
            .frame(height: 100)
            Stepper("Steps: \(values.count)", onIncrement: {
                update(m.id, .steps(values: values + [0.5], stepBeats: stepBeats, glide: glide)); model.rebuild()
            }, onDecrement: {
                guard values.count > 1 else { return }
                update(m.id, .steps(values: Array(values.dropLast()), stepBeats: stepBeats, glide: glide)); model.rebuild()
            })
            Picker("Step length", selection: Binding(get: { stepBeats }, set: { update(m.id, .steps(values: values, stepBeats: $0, glide: glide)); model.rebuild() })) {
                Text("1/32").tag(0.125); Text("1/16").tag(0.25); Text("1/8").tag(0.5); Text("1/4").tag(1.0); Text("1 bar").tag(4.0)
            }
            knob("Glide", glide, 0...0.5) { update(m.id, .steps(values: values, stepBeats: stepBeats, glide: $0)) }
        case let .random(rate, smoothing):
            rateEditor(rate) { update(m.id, .random(rate: $0, smoothing: smoothing)) }
            knob("Smooth", smoothing, 0...1) { update(m.id, .random(rate: rate, smoothing: $0)) }
        case let .macro(value):
            HStack {
                Slider(value: Binding(get: { value }, set: { model.setMacro(m.id, $0) }), in: 0...1)
                Button(model.learningMacro == m.id ? "Move a knob…" : "MIDI Learn") {
                    model.learningMacro = model.learningMacro == m.id ? nil : m.id
                }
                .buttonStyle(.bordered)
            }
            ForEach(model.project.macroMappings.filter { $0.modulator == m.id }) { map in
                Text("CC \(map.controller)\(map.channel.map { " ch\($0 + 1)" } ?? "") from \(map.source?.name ?? "any")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case let .audioFollower(a, r, gain):
            trackPicker(m)
            knob("Attack", a, 0.001...1) { update(m.id, .audioFollower(attack: $0, release: r, gain: gain)) }
            knob("Release", r, 0.01...2) { update(m.id, .audioFollower(attack: a, release: $0, gain: gain)) }
            knob("Gain", gain, 0.1...10) { update(m.id, .audioFollower(attack: a, release: r, gain: $0)) }
        }
    }

    private func knob(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range, onEditingChanged: { if !$0 { model.rebuild() } })
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 48)
        }
    }

    private func rateEditor(_ rate: ModulatorRate, _ set: @escaping (ModulatorRate) -> Void) -> some View {
        Picker("Rate", selection: Binding(get: { rate }, set: { set($0); model.rebuild() })) {
            Text("4 bars").tag(ModulatorRate.beats(16))
            Text("1 bar").tag(ModulatorRate.beats(4))
            Text("1/2").tag(ModulatorRate.beats(2))
            Text("1/4").tag(ModulatorRate.beats(1))
            Text("1/8").tag(ModulatorRate.beats(0.5))
            Text("1/16").tag(ModulatorRate.beats(0.25))
            Text("0.1 Hz").tag(ModulatorRate.hertz(0.1))
            Text("1 Hz").tag(ModulatorRate.hertz(1))
            Text("5 Hz").tag(ModulatorRate.hertz(5))
            Text("20 Hz").tag(ModulatorRate.hertz(20))
        }
    }

    private func trackPicker(_ m: ModulatorDefinition) -> some View {
        Picker("Source track", selection: Binding(get: { m.sourceTrack }, set: { v in
            if let i = model.project.modulators.firstIndex(where: { $0.id == m.id }) { model.project.modulators[i].sourceTrack = v; model.rebuild() }
        })) {
            Text("None").tag(UUID?.none)
            ForEach(model.project.tracks) { Text($0.name).tag(UUID?.some($0.id)) }
        }
    }

    func targetName(_ t: ModulationTarget) -> String {
        func track(_ id: UUID) -> String { model.project.track(id)?.name ?? "?" }
        switch t {
        case let .pluginParameter(tid, device, address):
            let dev = model.project.track(tid)?.devices.first { $0.id == device }?.component.name ?? "?"
            let name = model.plugin(device)?.au.parameterTree?.parameter(withAddress: address)?.displayName ?? "#\(address)"
            return "\(track(tid)) › \(dev) › \(name)"
        case let .trackVolume(id): return "\(track(id)) volume"
        case let .trackPan(id): return "\(track(id)) pan"
        case let .sendLevel(id, s): return "\(track(id)) send \(s + 1)"
        case let .cvOutput(ch): return "CV out \(ch + 1)"
        }
    }
}

/// Browse every track → device → parameter to pick a modulation target.
struct TargetPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (ModulationTarget, Double?) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.project.tracks) { t in
                    SwiftUI.Section(t.name) {
                        Button("Volume") { onPick(.trackVolume(track: t.id), 1) }
                        Button("Pan") { onPick(.trackPan(track: t.id), (t.pan + 1) / 2) }
                        ForEach(Array(t.sends.enumerated()), id: \.offset) { i, _ in
                            Button("Send \(i + 1)") { onPick(.sendLevel(track: t.id, send: i), 1) }
                        }
                        ForEach(t.devices) { d in
                            DisclosureGroup(d.component.name) {
                                ForEach(params(d.id)) { p in
                                    Button(p.name) {
                                        let range = max(p.max - p.min, 1e-9)
                                        onPick(.pluginParameter(track: t.id, device: d.id, address: p.address), Double((p.value - p.min) / range))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Filter parameters")
            .navigationTitle("Modulation Target")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func params(_ device: UUID) -> [HostedPlugin.ParameterInfo] {
        let all = model.plugin(device)?.parameters() ?? []
        return search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}
