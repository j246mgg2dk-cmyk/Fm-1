import AVFoundation
import AudioToolbox
import FM1Core
import SwiftUI

/// Lists every AUv3 installed on the iPad: instruments, effects, MIDI
/// processors. Any plugin that works in AUM / GarageBand / Cubasis works here,
/// including the ones you already own: no re-buying, no subscription.
@MainActor
final class PluginCatalog: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var id: PluginComponentID { component }
        let component: PluginComponentID
        let description: AudioComponentDescription
        let hasCustomView: Bool

        static func == (a: Entry, b: Entry) -> Bool { a.component == b.component }
        func hash(into h: inout Hasher) { h.combine(component) }
    }

    @Published private(set) var entries: [Entry] = []
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Fires when a plugin app is installed/removed/updated.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioUnitComponentManager.registrationsChangedNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func refresh() {
        let any = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: 0,
                                            componentFlags: 0, componentFlagsMask: 0)
        let wanted: Set<OSType> = [kAudioUnitType_MusicDevice, kAudioUnitType_Effect, kAudioUnitType_MusicEffect,
                                   kAudioUnitType_MIDIProcessor, kAudioUnitType_Generator]
        entries = AVAudioUnitComponentManager.shared().components(matching: any)
            .filter { wanted.contains($0.audioComponentDescription.componentType) }
            .map { c in
                let d = c.audioComponentDescription
                return Entry(
                    component: PluginComponentID(type: d.componentType, subtype: d.componentSubType,
                                                 manufacturer: d.componentManufacturer,
                                                 name: c.name, manufacturerName: c.manufacturerName),
                    description: d,
                    // iOS has no hasCustomView; requestViewController returns nil when there is no UI.
                    hasCustomView: true)
            }
            .sorted { ($0.component.manufacturerName, $0.component.name) < ($1.component.manufacturerName, $1.component.name) }
    }

    func entries(for role: PluginRole?) -> [Entry] {
        guard let role else { return entries }
        return entries.filter { $0.component.role == role }
    }

    static func description(for c: PluginComponentID) -> AudioComponentDescription {
        AudioComponentDescription(componentType: c.type, componentSubType: c.subtype,
                                  componentManufacturer: c.manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

/// Shows a plugin's own UI (the Moog/Korg/FabFilter panel) inside FM-1.
struct PluginView: UIViewControllerRepresentable {
    let viewController: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            viewController.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        viewController.didMove(toParent: host)
        return host
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
