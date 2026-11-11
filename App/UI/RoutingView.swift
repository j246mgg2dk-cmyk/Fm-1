import FM1Core
import SwiftUI

/// The patchbay: any MIDI source to any destination, with channel filters,
/// key splits, transpose, velocity curves and CC remapping per route.
struct RoutingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @State private var editing: MIDIRoute?

    var body: some View {
        List {
            SwiftUI.Section("Monitor") {
                Text(live.lastMIDI.isEmpty ? "Play something…" : live.lastMIDI).font(.system(.caption, design: .monospaced))
            }
            SwiftUI.Section("Routes") {
                ForEach(model.project.midiRoutes) { r in
                    Button { editing = r } label: {
                        HStack {
                            Image(systemName: r.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(r.isEnabled ? .green : .secondary)
                            Text(label(r.source))
                            Image(systemName: "arrow.right")
                            Text(label(r.destination))
                            Spacer()
                            Text(summary(r)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    model.project.midiRoutes.remove(atOffsets: idx)
                    model.rebuild()
                }
                Button {
                    let src = model.midiSources.first?.id ?? .fm1VirtualIn
                    let dst = model.midiDestinations.first?.id ?? .fm1VirtualOut
                    editing = MIDIRoute(source: src, destination: dst)
                } label: { Label("New Route", systemImage: "plus") }
            }
            SwiftUI.Section("Devices") {
                ForEach(model.midiSources) { s in
                    Label("\(s.id.name)  ·  \(s.id.kind.rawValue)\(s.isOnline ? "" : " (offline)")", systemImage: "arrow.down.circle")
                }
                ForEach(model.midiDestinations) { d in
                    Label("\(d.id.name)  ·  \(d.id.kind.rawValue)", systemImage: "arrow.up.circle")
                }
                Text("FM-1 also appears to other apps as \"FM-1 In\" / \"FM-1 Out\".").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { route in
            RouteEditor(route: route) { updated in
                if let i = model.project.midiRoutes.firstIndex(where: { $0.id == updated.id }) {
                    model.project.midiRoutes[i] = updated
                } else {
                    model.project.midiRoutes.append(updated)
                }
                model.rebuild()
                editing = nil
            }
        }
    }

    func label(_ e: EndpointID) -> String {
        switch e.kind {
        case .track:
            return "Track: " + (model.project.tracks.first { $0.endpoint == e }?.name ?? "?")
        case .plugin:
            for t in model.project.tracks {
                if let d = t.devices.first(where: { EndpointID.plugin($0.id) == e }) { return "\(t.name) › \(d.component.name)" }
            }
            return "Plugin"
        default:
            return e.name
        }
    }

    private func summary(_ r: MIDIRoute) -> String {
        var parts: [String] = []
        if !r.filter.channels.isEmpty { parts.append("ch " + r.filter.channels.sorted().map { "\($0 + 1)" }.joined(separator: ",")) }
        if r.filter.lowestNote > 0 || r.filter.highestNote < 127 { parts.append("keys \(noteName(r.filter.lowestNote))–\(noteName(r.filter.highestNote))") }
        if let c = r.transform.outputChannel { parts.append("→ch\(c + 1)") }
        if r.transform.transpose != 0 { parts.append("\(r.transform.transpose > 0 ? "+" : "")\(r.transform.transpose) st") }
        if !r.filter.clock { parts.append("no clock") }
        return parts.joined(separator: " · ")
    }
}

func noteName(_ n: UInt8) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return "\(names[Int(n) % 12])\(Int(n) / 12 - 2)"
}

struct RouteEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var route: MIDIRoute
    let onSave: (MIDIRoute) -> Void

    init(route: MIDIRoute, onSave: @escaping (MIDIRoute) -> Void) {
        _route = State(initialValue: route)
        self.onSave = onSave
    }

    var sourceOptions: [(String, EndpointID)] {
        var out = model.midiSources.map { ($0.id.name, $0.id) }
        out.append(("FM-1 In (from other apps)", .fm1VirtualIn))
        for t in model.project.tracks {
            for d in t.devices { out.append(("\(t.name) › \(d.component.name) MIDI out", .plugin(d.id))) }
        }
        return out
    }

    var destinationOptions: [(String, EndpointID)] {
        var out = model.midiDestinations.map { ($0.id.name, $0.id) }
        out.append(("FM-1 Out (to other apps)", .fm1VirtualOut))
        for t in model.project.tracks where t.kind != .audio { out.append(("Track: \(t.name)", t.endpoint)) }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Enabled", isOn: $route.isEnabled)
                Picker("From", selection: $route.source) {
                    ForEach(sourceOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("To", selection: $route.destination) {
                    ForEach(destinationOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                SwiftUI.Section("Filter") {
                    channelGrid
                    Stepper("Lowest key: \(noteName(route.filter.lowestNote))", value: $route.filter.lowestNote, in: 0...127)
                    Stepper("Highest key: \(noteName(route.filter.highestNote))", value: $route.filter.highestNote, in: 0...127)
                    Toggle("Notes", isOn: $route.filter.notes)
                    Toggle("Control changes", isOn: $route.filter.controlChanges)
                    Toggle("Pitch bend", isOn: $route.filter.pitchBend)
                    Toggle("Aftertouch", isOn: $route.filter.aftertouch)
                    Toggle("Program change", isOn: $route.filter.programChanges)
                    Toggle("Clock", isOn: $route.filter.clock)
                    Toggle("Start/Stop/SPP", isOn: $route.filter.transport)
                    Toggle("SysEx", isOn: $route.filter.sysex)
                }
                SwiftUI.Section("Transform") {
                    Picker("Output channel", selection: $route.transform.outputChannel) {
                        Text("Keep").tag(UInt8?.none)
                        ForEach(0..<16, id: \.self) { c in Text("\(c + 1)").tag(UInt8?.some(UInt8(c))) }
                    }
                    Stepper("Transpose: \(route.transform.transpose) st", value: $route.transform.transpose, in: -48...48)
                    Picker("Velocity", selection: $route.transform.velocity) {
                        Text("Linear").tag(VelocityCurve.linear)
                        Text("Soft").tag(VelocityCurve.soft)
                        Text("Hard").tag(VelocityCurve.hard)
                        Text("Fixed 100").tag(VelocityCurve.fixed(100))
                        Text("Fixed 127").tag(VelocityCurve.fixed(127))
                    }
                    ccRemapEditor
                }
            }
            .navigationTitle("Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(route) } }
            }
        }
    }

    private var channelGrid: some View {
        VStack(alignment: .leading) {
            Text("Input channels (none selected = all)").font(.caption)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8)) {
                ForEach(0..<16, id: \.self) { c in
                    let ch = UInt8(c)
                    let on = route.filter.channels.contains(ch)
                    Button("\(c + 1)") {
                        if on { route.filter.channels.remove(ch) } else { route.filter.channels.insert(ch) }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .gray)
                }
            }
        }
    }

    @State private var ccFrom = 1
    @State private var ccTo = 74

    private var ccRemapEditor: some View {
        VStack(alignment: .leading) {
            ForEach(route.transform.ccRemap.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                HStack {
                    Text("CC \(pair.key) → CC \(pair.value)")
                    Spacer()
                    Button(role: .destructive) { route.transform.ccRemap[pair.key] = nil } label: { Image(systemName: "trash") }
                }
            }
            HStack {
                Stepper("CC \(ccFrom)", value: $ccFrom, in: 0...127)
                Stepper("→ \(ccTo)", value: $ccTo, in: 0...127)
                Button("Add") { route.transform.ccRemap[UInt8(ccFrom)] = UInt8(ccTo) }
            }
        }
    }
}
