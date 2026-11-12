import FM1Core
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case session = "Session"
    case mixer = "Mixer"
    case routing = "MIDI"
    case audio = "Audio I/O"
    case modulators = "Mod"
    case cv = "CV"
    case sync = "Sync"
    case connect = "Connect"
    case projects = "Projects"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .session: return "square.grid.3x3.fill"
        case .mixer: return "slider.vertical.3"
        case .routing: return "point.3.connected.trianglepath.dotted"
        case .audio: return "cable.connector"
        case .modulators: return "waveform.path"
        case .cv: return "bolt.horizontal"
        case .sync: return "metronome"
        case .connect: return "antenna.radiowaves.left.and.right"
        case .projects: return "folder"
        }
    }

    /// Pages where the selected track's device chain sits underneath.
    var showsDeviceStrip: Bool { self == .session || self == .mixer }
}

/// Sheets and pop-ups any screen can open.
@MainActor
final class UIRouter: ObservableObject {
    struct BrowserRequest: Identifiable {
        let id = UUID()
        let trackID: UUID
        let role: PluginRole?
    }
    struct PluginWindowRequest: Identifiable {
        var id: UUID { deviceID }
        let deviceID: UUID
        let trackID: UUID
        let vc: UIViewController?
    }
    struct ClipRequest: Identifiable {
        var id: String { "\(trackID)-\(slot)" }
        let trackID: UUID
        let slot: Int
    }

    @Published var browser: BrowserRequest?
    @Published var pluginWindow: PluginWindowRequest?
    @Published var clipEditor: ClipRequest?
    @Published var showKeys = true
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var router = UIRouter()
    @State private var section: AppSection = .session

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                ModeRail(section: $section)
                Rectangle().fill(Theme.line).frame(width: 1)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .id(section)
            }
            .animation(.easeOut(duration: 0.18), value: section)
            if section.showsDeviceStrip {
                Rectangle().fill(Theme.line).frame(height: 1)
                DeviceStrip()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if router.showKeys {
                Rectangle().fill(Theme.line).frame(height: 1)
                KeyboardStrip()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: router.showKeys)
        .animation(.snappy(duration: 0.25), value: section.showsDeviceStrip)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .environmentObject(router)
        .sheet(item: $router.browser) { req in
            PluginBrowser(initialRole: req.role) { entry in
                model.addPlugin(entry, to: req.trackID)
                router.browser = nil
            }
            .environmentObject(model)
            .environmentObject(model.catalog)
        }
        .sheet(item: $router.pluginWindow) { req in
            PluginWindow(request: req)
                .environmentObject(model)
                .environmentObject(router)
        }
        .sheet(item: $router.clipEditor) { req in
            ClipEditor(trackID: req.trackID, slot: req.slot)
                .environmentObject(model)
                .environmentObject(model.live)
        }
        .alert("Mod-Lab", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .session: SessionView()
        case .mixer: MixerView()
        case .routing: settingsPage("MIDI Routing", "Patchbay · every input to every destination") { RoutingView() }
        case .audio: AudioIOView()
        case .modulators: settingsPage("Modulators", "LFO · envelopes · steps · macros") { ModulatorsView() }
        case .cv: settingsPage("CV / Modular", "DC-coupled outputs") { CVView() }
        case .sync: settingsPage("Sync & Clock", "Internal · MIDI clock · Link") { SyncView() }
        case .connect: settingsPage("Connect", "Bluetooth & network MIDI") { ConnectView() }
        case .projects: settingsPage("Projects", model.project.name) { ProjectsView() }
        }
    }

    private func settingsPage<V: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle)
            content().modLabFormStyle()
        }
        .background(Theme.bg)
    }
}

// MARK: - Mode rail

struct ModeRail: View {
    @Binding var section: AppSection

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppSection.allCases) { s in
                let on = s == section
                Button {
                    Haptics.tick()
                    section = s
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: s.icon).font(.system(size: 17, weight: .medium))
                        Text(s.rawValue.uppercased()).font(Theme.caps(8)).tracking(0.8).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.dim)
                    .frame(width: 64, height: 54)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.raised : .clear))
                    .overlay(alignment: .leading) {
                        if on { Capsule().fill(Theme.accent).frame(width: 3, height: 22).offset(x: -6) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 7)
        .background(Theme.surface)
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: UIRouter
    @State private var tempoDragStart: Double?

    var body: some View {
        HStack(spacing: 14) {
            wordmark
            transportButtons
            lcd
            KeyCap(isOn: model.project.metronomeOn, width: 36, height: 34, action: {
                model.project.metronomeOn.toggle(); model.rebuild()
            }) { Image(systemName: "metronome").font(.system(size: 14, weight: .semibold)) }
            ChipMenu(title: "Launch", value: model.project.launchQuantization.label) {
                ForEach(LaunchQuantization.allCases, id: \.self) { q in
                    Button(q.label) { model.project.launchQuantization = q; model.rebuild() }
                }
            }
            Spacer(minLength: 8)
            inputChip
            VStack(alignment: .trailing, spacing: 2) {
                Caps("CPU", size: 8)
                Text("\(Int(live.cpu * 100))%").font(Theme.mono(11))
                    .foregroundStyle(live.cpu > 0.8 ? Theme.record : Theme.text)
            }
            StereoMeter(left: live.masterPeak.0, right: live.masterPeak.1, vertical: true, segments: 12)
                .frame(width: 10, height: 34)
            KeyCap(isOn: router.showKeys, width: 36, height: 34, action: { router.showKeys.toggle() }) {
                Image(systemName: "pianokeys").font(.system(size: 14, weight: .semibold))
            }
            Button {
                Haptics.click()
                model.panic()
            } label: {
                Text("PANIC").font(Theme.caps(10)).tracking(1).foregroundStyle(Theme.record)
                    .frame(width: 58, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.record.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(Theme.surface)
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 10, height: 10)
            Text("MOD-LAB").font(.system(size: 13, weight: .heavy)).tracking(2.4)
        }
        .padding(.trailing, 4)
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            transportButton(on: live.isPlaying, color: Theme.accent, action: model.togglePlay) {
                Image(systemName: live.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            transportButton(on: false, color: Theme.accent, action: model.stop) {
                Image(systemName: "stop.fill")
            }
            transportButton(on: model.isRecording, color: Theme.record, action: model.toggleRecord) {
                Image(systemName: "circle.fill")
            }
        }
    }

    private func transportButton<L: View>(on: Bool, color: Color, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button {
            Haptics.click()
            action()
        } label: {
            label()
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : (color == Theme.record ? Theme.record : Theme.text))
                .frame(width: 44, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? color : Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? .clear : Theme.line, lineWidth: 1))
                .shadow(color: on ? color.opacity(0.5) : .clear, radius: 8)
        }
        .buttonStyle(PressStyle(scale: 0.93))
        .animation(.snappy(duration: 0.15), value: on)
    }

    /// The "display": position, tempo (drag to change), time signature, clock source.
    private var lcd: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Caps("Position", size: 8)
                Text(live.position).font(Theme.mono(19, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 92, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 1) {
                Caps(model.project.clock.source == .internalClock ? "Tempo · drag" : "Tempo · \(model.project.clock.source.label)", size: 8)
                HStack(spacing: 6) {
                    Text(String(format: "%.1f", live.tempo)).font(Theme.mono(19, weight: .semibold))
                        .frame(width: 70, alignment: .leading)
                    VStack(spacing: 2) {
                        nudge("plus") { model.setTempo((model.project.tempo + 1).rounded()) }
                        nudge("minus") { model.setTempo((model.project.tempo - 1).rounded()) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            guard model.project.clock.source == .internalClock else { return }
                            if tempoDragStart == nil { tempoDragStart = model.project.tempo }
                            model.setTempo(((tempoDragStart ?? 120) - g.translation.height / 4).rounded(toPlaces: 1))
                        }
                        .onEnded { _ in tempoDragStart = nil }
                )
            }
            VStack(alignment: .leading, spacing: 1) {
                Caps("Sig", size: 8)
                Text("\(model.project.timeSignature.beatsPerBar)/\(model.project.timeSignature.noteValue)")
                    .font(Theme.mono(15)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func nudge(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                .frame(width: 18, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.raised))
        }
        .buttonStyle(PressStyle())
        .disabled(model.project.clock.source != .internalClock)
    }

    /// Always shows whether the hardware input (microphone or interface) is running.
    private var inputChip: some View {
        let on = model.audioStatus.inputActive
        return HStack(spacing: 6) {
            Circle().fill(on ? Theme.record : Theme.faint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Caps("Input", size: 8)
                Text(on ? model.audioStatus.inputName : "Off").font(Theme.mono(10))
                    .foregroundStyle(on ? Theme.text : Theme.dim).lineLimit(1)
            }
        }
        .frame(maxWidth: 150, alignment: .leading)
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(on ? Theme.record.opacity(0.5) : Theme.line, lineWidth: 1))
        .accessibilityLabel(on ? "Audio input on: \(model.audioStatus.inputName)" : "Audio input off")
    }
}
