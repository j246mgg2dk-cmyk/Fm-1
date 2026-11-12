import AudioToolbox
import FM1Core
import SwiftUI

/// Bottom panel: the selected track's controls and its device chain
/// (MIDI FX → instrument → effects), like Ableton's device view.
struct DeviceStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: UIRouter

    var body: some View {
        Group {
            if let track = model.selectedTrack {
                HStack(spacing: 10) {
                    TrackCard(track: track)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(track.devices.enumerated()), id: \.element.id) { i, slot in
                                if i > 0 { chainArrow }
                                DeviceCard(track: track, slot: slot, index: i)
                            }
                            if !track.devices.isEmpty && track.kind != .audio { chainArrow }
                            addCards(track)
                        }
                        .padding(.vertical, 2)
                        .animation(.snappy(duration: 0.22), value: track.devices.map(\.id))
                    }
                }
            } else {
                HStack {
                    Caps("Select a track to see its devices")
                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(height: 196)
        .background(Theme.surface)
    }

    private var chainArrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
    }

    @ViewBuilder
    private func addCards(_ track: Track) -> some View {
        let hasInstrument = track.devices.contains { $0.component.role == .instrument || $0.component.role == .generator }
        VStack(spacing: 6) {
            if track.kind == .instrument && !hasInstrument {
                AddDeviceCard(title: "Instrument", icon: "pianokeys", prominent: true) {
                    router.browser = .init(trackID: track.id, role: .instrument)
                }
            }
            if track.kind != .midi {
                AddDeviceCard(title: "Effect", icon: "dial.medium", prominent: false) {
                    router.browser = .init(trackID: track.id, role: .audioEffect)
                }
            }
            if track.kind != .audio && track.kind != .group {
                AddDeviceCard(title: "MIDI FX", icon: "arrow.triangle.branch", prominent: false) {
                    router.browser = .init(trackID: track.id, role: .midiProcessor)
                }
            }
        }
    }
}

struct AddDeviceCard: View {
    let title: String
    let icon: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Image(systemName: icon).font(.system(size: 12))
                Text(title.uppercased()).font(Theme.caps(10)).tracking(1)
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.dim)
            .frame(width: 150, height: prominent ? 116 : 52)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Theme.accent : Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Track card

struct TrackCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(trackColor(track.colorIndex)).frame(width: 4, height: 16)
                    Text(track.name).font(Theme.title(14)).lineLimit(1)
                }
                Caps(track.kind.label)
                routingControls
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    KeyCap("●", isOn: track.isArmed, onColor: Theme.record) { model.setArmed(track.id, !track.isArmed) }
                    KeyCap("S", isOn: track.isSoloed, onColor: Theme.solo) {
                        model.updateTrack(track.id, rebuildGraph: false) { $0.isSoloed.toggle() }
                    }
                    KeyCap("M", isOn: track.isMuted, onColor: Theme.mute) {
                        model.updateTrack(track.id, rebuildGraph: false) { $0.isMuted.toggle() }
                    }
                }
            }
            .frame(width: 168, alignment: .leading)
            if track.kind != .midi {
                VStack(spacing: 10) {
                    Knob(value: Binding(get: { track.volumeDB }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.volumeDB = v.rounded(toPlaces: 1) } }),
                         range: -60...6, defaultValue: 0, label: "Vol", size: 40, format: { dbText($0) })
                    Knob(value: Binding(get: { track.pan }, set: { v in model.updateTrack(track.id, rebuildGraph: false) { $0.pan = v } }),
                         range: -1...1, defaultValue: 0, label: "Pan", size: 34, bipolar: true, format: panText)
                }
                StereoMeter(left: live.trackPeaks[track.id]?.0 ?? 0, right: live.trackPeaks[track.id]?.1 ?? 0, segments: 16)
                    .frame(width: 10)
                    .padding(.vertical, 4)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .panel(Theme.raised, radius: 10)
    }

    @ViewBuilder private var routingControls: some View {
        switch track.kind {
        case .audio, .externalInstrument:
            VStack(alignment: .leading, spacing: 4) {
                ChipMenu(title: "In", value: track.audioInputs.isEmpty ? "None" : pairName(track.audioInputs)) {
                    inputChoices
                }
                Segmented(selection: Binding(get: { track.monitor }, set: { model.setMonitor(track.id, $0) }),
                          options: [(MonitorMode.auto, "Auto"), (.on, "On"), (.off, "Off")], height: 24)
                    .frame(width: 160)
                if !model.audioStatus.inputActive {
                    Text("Input off · arm or monitor On").font(.system(size: 9.5)).foregroundStyle(Theme.faint)
                }
            }
        case .midi, .instrument:
            if track.kind == .midi || track.midiOutput != nil {
                midiOutMenu
            } else {
                Text(model.plugin(track.devices.first { $0.component.role == .instrument }?.id ?? UUID()) != nil
                     ? "Plays from all MIDI inputs when selected" : "Load an instrument →")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(2)
            }
        case .group:
            EmptyView()
        }
    }

    @ViewBuilder private var inputChoices: some View {
        let n = max(model.audioStatus.inputChannels, 2)
        Button("None") { model.updateTrack(track.id) { $0.audioInputs = [] } }
        SwiftUI.Section("Stereo") {
            ForEach(stereoPairs(n), id: \.self) { p in
                Button("In \(pairName(p))") { model.updateTrack(track.id) { $0.audioInputs = p } }
            }
        }
        SwiftUI.Section("Mono") {
            ForEach(0..<n, id: \.self) { c in
                Button("In \(c + 1)") { model.updateTrack(track.id) { $0.audioInputs = [c] } }
            }
        }
    }

    private var midiOutMenu: some View {
        ChipMenu(title: "MIDI out", value: track.midiOutput?.name ?? "None") {
            Button("None") { model.updateTrack(track.id) { $0.midiOutput = nil } }
            Button("Mod-Lab Out (AUM, Koala…)") { model.updateTrack(track.id) { $0.midiOutput = .modLabVirtualOut } }
            ForEach(model.midiDestinations) { d in
                Button(d.id.name) { model.updateTrack(track.id) { $0.midiOutput = d.id } }
            }
            Menu("Channel: \(track.midiOutputChannel.map { "\($0 + 1)" } ?? "Keep")") {
                Button("Keep incoming") { model.updateTrack(track.id) { $0.midiOutputChannel = nil } }
                ForEach(0..<16, id: \.self) { c in
                    Button("\(c + 1)") { model.updateTrack(track.id) { $0.midiOutputChannel = UInt8(c) } }
                }
            }
        }
    }
}

// MARK: - Device card

struct DeviceCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: UIRouter
    let track: Track
    let slot: DeviceSlot
    let index: Int

    private var role: PluginRole { slot.component.role }
    private var loaded: Bool { model.plugin(slot.id) != nil }
    private var loading: Bool { model.loadingDevices.contains(slot.id) }
    private var error: String? { model.failedDevices[slot.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: role.glyph).font(.system(size: 11)).foregroundStyle(slot.isBypassed ? Theme.faint : Theme.accent)
                Caps(role.label, size: 8.5)
                Spacer(minLength: 0)
                KeyCap(isOn: !slot.isBypassed, width: 26, height: 22, action: {
                    model.updateTrack(track.id) { t in
                        if let i = t.devices.firstIndex(where: { $0.id == slot.id }) { t.devices[i].isBypassed.toggle() }
                    }
                }) { Image(systemName: "power").font(.system(size: 10, weight: .bold)) }
            }
            Text(slot.component.name).font(Theme.title(14)).foregroundStyle(slot.isBypassed ? Theme.dim : Theme.text).lineLimit(1)
            Text(slot.component.manufacturerName).font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
            status
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 10) {
                SlabButton(title: "Edit", systemImage: "slider.horizontal.3") { openEditor() }
                    .disabled(!loaded)
                    .opacity(loaded ? 1 : 0.4)
                Spacer(minLength: 0)
                if role.isEffect {
                    Knob(value: Binding(get: { slot.mix }, set: { v in
                        model.updateTrack(track.id) { t in if let i = t.devices.firstIndex(where: { $0.id == slot.id }) { t.devices[i].mix = v } }
                    }), range: 0...1, defaultValue: 1, label: "Mix", size: 30, format: { "\(Int($0 * 100))%" })
                }
            }
        }
        .padding(10)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .panel(Theme.raised, radius: 10)
        .opacity(slot.isBypassed ? 0.75 : 1)
        .contextMenu {
            Button("Open Editor") { openEditor() }
            if index > 0 { Button("Move Left") { model.moveDevice(in: track.id, from: IndexSet(integer: index), to: index - 1) } }
            if index < track.devices.count - 1 {
                Button("Move Right") { model.moveDevice(in: track.id, from: IndexSet(integer: index), to: index + 2) }
            }
            if error != nil { Button("Retry Loading") { Task { await model.load(slot) } } }
            Button("Remove", role: .destructive) { model.removePlugin(slot.id, from: track.id) }
        }
    }

    @ViewBuilder private var status: some View {
        if loading {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Caps("Loading", size: 8.5) }
        } else if let error {
            Text(error).font(.system(size: 9.5)).foregroundStyle(Theme.record).lineLimit(3)
        } else if loaded {
            HStack(spacing: 5) {
                Circle().fill(Theme.ok).frame(width: 5, height: 5)
                Caps(slot.isBypassed ? "Bypassed" : "Running", size: 8.5)
            }
        }
    }

    private func openEditor() {
        Task {
            let vc = await model.plugin(slot.id)?.requestViewController()
            router.pluginWindow = .init(deviceID: slot.id, trackID: track.id, vc: vc)
        }
    }
}

// MARK: - Plugin window

/// The plugin's own interface (or a knob panel when it has none).
struct PluginWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: UIRouter.PluginWindowRequest

    private var slot: DeviceSlot? {
        model.project.track(request.trackID)?.devices.first { $0.id == request.deviceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: slot?.component.role.glyph ?? "puzzlepiece").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot?.component.name ?? "Plugin").font(Theme.title(15))
                    Caps("\(slot?.component.manufacturerName ?? "") · \(model.project.track(request.trackID)?.name ?? "")", size: 8.5)
                }
                Spacer()
                if let slot {
                    KeyCap(isOn: !slot.isBypassed, width: 34, height: 30, action: {
                        model.updateTrack(request.trackID) { t in
                            if let i = t.devices.firstIndex(where: { $0.id == slot.id }) { t.devices[i].isBypassed.toggle() }
                        }
                    }) { Image(systemName: "power").font(.system(size: 12, weight: .bold)) }
                }
                SlabButton(title: "Done", prominent: true) { dismiss() }
            }
            .padding(12)
            .background(Theme.surface)
            Rectangle().fill(Theme.line).frame(height: 1)
            if let vc = request.vc {
                PluginView(viewController: vc)
                    .background(Color.black)
            } else {
                ParameterPanel(deviceID: request.deviceID)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
}

/// Fallback for plugins without their own UI: every writable parameter as a knob.
struct ParameterPanel: View {
    @EnvironmentObject var model: AppModel
    let deviceID: UUID

    var body: some View {
        let params = model.plugin(deviceID)?.parameters() ?? []
        ScrollView {
            if params.isEmpty {
                Caps("This plugin has no interface and no parameters").padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 18) {
                ForEach(params) { p in ParamKnob(deviceID: deviceID, info: p) }
            }
            .padding(20)
        }
        .background(Theme.bg)
    }
}

/// One plugin parameter. Keeps its own state because AU parameters don't
/// publish changes to SwiftUI.
struct ParamKnob: View {
    @EnvironmentObject var model: AppModel
    let deviceID: UUID
    let info: HostedPlugin.ParameterInfo
    @State private var value: Double = 0
    @State private var ready = false

    var body: some View {
        let lo = Double(info.min)
        let hi = max(Double(info.max), lo + 0.0001)
        Knob(value: Binding(get: { value }, set: { v in
                value = v
                model.plugin(deviceID)?.au.parameterTree?.parameter(withAddress: info.address)?.value = AUValue(v)
             }),
             range: lo...hi, defaultValue: Double(info.value), label: info.name, size: 46,
             format: { String(format: abs($0) >= 100 ? "%.0f" : "%.2f", $0) })
            .onAppear {
                guard !ready else { return }
                ready = true
                value = model.plugin(deviceID)?.au.parameterTree?.parameter(withAddress: info.address).map { Double($0.value) } ?? Double(info.value)
            }
    }
}
