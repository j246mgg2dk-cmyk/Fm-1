import FM1Core
import SwiftUI

/// Every AUv3 the system reports to Mod-Lab, grouped by kind. Your own
/// plugins first, Apple's built-ins in their own section.
struct PluginBrowser: View {
    @EnvironmentObject var catalog: PluginCatalog
    @Environment(\.dismiss) private var dismiss
    let onPick: (PluginCatalog.Entry) -> Void

    @State private var role: PluginRole?
    @State private var search = ""
    @State private var showApple = true

    init(initialRole: PluginRole? = nil, onPick: @escaping (PluginCatalog.Entry) -> Void) {
        self._role = State(initialValue: initialRole)
        self.onPick = onPick
    }

    private let categories: [(PluginRole?, String, String)] = [
        (nil, "All", "square.grid.2x2"),
        (.instrument, "Instruments", "pianokeys"),
        (.audioEffect, "Effects", "dial.medium"),
        (.musicEffect, "Music FX", "waveform.badge.plus"),
        (.midiProcessor, "MIDI FX", "arrow.triangle.branch"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Theme.line).frame(width: 1)
                grid
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugins").font(.system(size: 20, weight: .semibold))
                Caps("\(catalog.entries.filter { !$0.isApple }.count) yours · \(catalog.entries.filter(\.isApple).count) Apple")
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Search name or maker", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 10)
            .frame(width: 280, height: 34)
            .panel(Theme.raised, radius: 8)
            SlabButton(title: "Rescan", systemImage: "arrow.clockwise") { catalog.refresh() }
            SlabButton(title: "Close") { dismiss() }
        }
        .padding(14)
        .background(Theme.surface)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(categories, id: \.1) { cat in
                let on = cat.0 == role
                Button {
                    Haptics.tick()
                    withAnimation(.snappy(duration: 0.18)) { role = cat.0 }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: cat.2).frame(width: 18)
                        Text(cat.1).font(.system(size: 14, weight: on ? .semibold : .regular))
                        Spacer()
                        Text("\(count(cat.0))").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    .foregroundStyle(on ? Theme.text : Theme.dim)
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.raised : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
            Spacer()
            Toggle(isOn: $showApple) { Caps("Show Apple built-ins") }
                .toggleStyle(.switch)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: 230)
        .background(Theme.surface)
    }

    private var grid: some View {
        let list = filtered
        let mine = list.filter { !$0.isApple }
        let apple = showApple ? list.filter(\.isApple) : []
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if catalog.onlyAppleUnits {
                    notice("Only Apple's built-in units are visible.",
                           "iPadOS hides other apps' plugins unless Mod-Lab is signed with the Inter-App Audio capability. In Xcode › Signing & Capabilities, check that Inter-App Audio is listed, then run again.")
                } else if catalog.entries.isEmpty {
                    notice("No plugins found.", "Install AUv3 instruments or effects from the App Store; anything that loads in AUM or GarageBand appears here.")
                }
                if !mine.isEmpty { section("Your plugins", mine) }
                if !apple.isEmpty { section("Apple built-in", apple) }
                if mine.isEmpty && apple.isEmpty && !catalog.entries.isEmpty {
                    Caps("Nothing matches").padding(.top, 30).frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: String, _ items: [PluginCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Caps(title)
                Text("\(items.count)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(items) { e in tile(e) }
            }
        }
    }

    private func tile(_ e: PluginCatalog.Entry) -> some View {
        Button {
            Haptics.click()
            onPick(e)
        } label: {
            HStack(spacing: 12) {
                Text(monogram(e.component.manufacturerName.isEmpty ? e.component.name : e.component.manufacturerName))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(swatch(e)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.component.name).font(Theme.title(14)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(e.component.manufacturerName).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                    Caps(e.component.role.label, color: Theme.faint, size: 8)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .panel(Theme.surface, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private func notice(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.mute)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.title(14))
                Text(body).font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.raised, radius: 10)
    }

    private var filtered: [PluginCatalog.Entry] {
        catalog.entries(for: role).filter {
            search.isEmpty || $0.component.name.localizedCaseInsensitiveContains(search)
                || $0.component.manufacturerName.localizedCaseInsensitiveContains(search)
        }
    }

    private func count(_ r: PluginRole?) -> Int {
        catalog.entries(for: r).filter { showApple || !$0.isApple }.count
    }

    private func monogram(_ s: String) -> String {
        let words = s.split(separator: " ").prefix(2)
        let m = words.compactMap(\.first).map(String.init).joined()
        return m.isEmpty ? "?" : m.uppercased()
    }

    private func swatch(_ e: PluginCatalog.Entry) -> Color {
        if e.isApple { return Theme.dim }
        var h: UInt32 = 5381
        for b in e.component.manufacturerName.utf8 { h = (h &* 33) &+ UInt32(b) }
        return trackPalette[Int(h % UInt32(trackPalette.count))]
    }
}
