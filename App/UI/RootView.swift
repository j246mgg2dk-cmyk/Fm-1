import FM1Core
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case session = "Session"
    case mixer = "Mixer"
    case devices = "Devices"
    case routing = "MIDI Routing"
    case audio = "Audio I/O"
    case modulators = "Modulators"
    case cv = "CV / Modular"
    case sync = "Sync & Clock"
    case connect = "Bluetooth & Network"
    case projects = "Projects"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .session: return "square.grid.3x3"
        case .mixer: return "slider.vertical.3"
        case .devices: return "pianokeys"
        case .routing: return "point.3.connected.trianglepath.dotted"
        case .audio: return "cable.connector"
        case .modulators: return "waveform.path"
        case .cv: return "bolt.horizontal"
        case .sync: return "metronome"
        case .connect: return "antenna.radiowaves.left.and.right"
        case .projects: return "folder"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: AppSection? = .session
    @State private var selectedTrack: UUID?

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationTitle("FM-1")
        } detail: {
            VStack(spacing: 0) {
                TransportBar()
                Divider()
                Group {
                    switch section ?? .session {
                    case .session: SessionView(selectedTrack: $selectedTrack)
                    case .mixer: MixerView(selectedTrack: $selectedTrack)
                    case .devices: TrackDetailView(trackID: selectedTrack ?? model.project.tracks.first?.id)
                    case .routing: RoutingView()
                    case .audio: AudioIOView()
                    case .modulators: ModulatorsView()
                    case .cv: CVView()
                    case .sync: SyncView()
                    case .connect: ConnectView()
                    case .projects: ProjectsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("FM-1", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @State private var tempoText = ""

    var body: some View {
        HStack(spacing: 16) {
            Button { model.togglePlay() } label: {
                Image(systemName: live.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { model.stop() } label: { Image(systemName: "stop.fill").font(.title2) }
            Button { model.toggleRecord() } label: {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(model.isRecording ? .red : .primary)
            }
            Text(live.position).font(.system(.title3, design: .monospaced)).frame(width: 90, alignment: .leading)

            HStack(spacing: 4) {
                Button { model.setTempo(model.project.tempo - 1) } label: { Image(systemName: "minus") }
                TextField("BPM", text: $tempoText)
                    .onSubmit { if let t = Double(tempoText) { model.setTempo(t) } }
                    .frame(width: 64)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.project.clock.source != .internalClock)
                Button { model.setTempo(model.project.tempo + 1) } label: { Image(systemName: "plus") }
                Text("BPM").font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { tempoText = String(format: "%.1f", model.project.tempo) }
            .onChange(of: live.tempo) { _, t in tempoText = String(format: "%.1f", t) }

            Text(model.project.clock.source.label).font(.caption).padding(4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))

            Toggle(isOn: Binding(get: { model.project.metronomeOn }, set: { model.project.metronomeOn = $0; model.rebuild() })) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button)

            Picker("Quantize", selection: Binding(get: { model.project.launchQuantization },
                                                  set: { model.project.launchQuantization = $0; model.rebuild() })) {
                ForEach(LaunchQuantization.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            Spacer()
            MeterBar(left: live.masterPeak.0, right: live.masterPeak.1).frame(width: 80, height: 14)
            Text("CPU \(Int(live.cpu * 100))%").font(.caption.monospacedDigit())
                .foregroundStyle(live.cpu > 0.8 ? .red : .secondary)
            Button(role: .destructive) { model.panic() } label: { Text("PANIC").font(.caption.bold()) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct MeterBar: View {
    var left: Float
    var right: Float

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 2) {
                bar(left, width: geo.size.width)
                bar(right, width: geo.size.width)
            }
        }
    }

    private func bar(_ v: Float, width: CGFloat) -> some View {
        let db = 20 * log10(max(Double(v), 1e-5))
        let norm = CGFloat(max(0, min(1, (db + 60) / 60)))
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.gray.opacity(0.2))
            Rectangle().fill(db > -0.5 ? Color.red : (db > -6 ? Color.yellow : Color.green))
                .frame(width: width * norm)
        }
    }
}

extension ClockSource {
    var label: String {
        switch self {
        case .internalClock: return "Internal"
        case .externalMIDI: return "Ext MIDI"
        case .abletonLink: return "Link"
        }
    }
}

extension LaunchQuantization {
    var label: String {
        switch self {
        case .none: return "None"
        case .sixteenth: return "1/16"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        case .bar: return "1 Bar"
        case .twoBars: return "2 Bars"
        case .fourBars: return "4 Bars"
        case .eightBars: return "8 Bars"
        }
    }
}

extension TrackKind {
    var label: String {
        switch self {
        case .audio: return "Audio"
        case .instrument: return "Instrument"
        case .midi: return "MIDI"
        case .externalInstrument: return "External Synth"
        case .group: return "Group"
        }
    }
}

let trackPalette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
func trackColor(_ i: Int) -> Color { trackPalette[((i % trackPalette.count) + trackPalette.count) % trackPalette.count] }

func channelName(_ c: Int) -> String { "\(c + 1)" }
func pairName(_ chs: [Int]?) -> String {
    guard let chs, let f = chs.first else { return "Master" }
    return chs.count > 1 ? "\(f + 1)/\(chs[1] + 1)" : "\(f + 1)"
}
