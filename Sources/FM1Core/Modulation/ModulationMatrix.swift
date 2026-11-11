import Foundation

/// Anything a modulator can drive.
public enum ModulationTarget: Codable, Hashable, Sendable {
    /// An AUv3 parameter, by the plugin's own parameter address.
    case pluginParameter(track: UUID, device: UUID, address: UInt64)
    case trackVolume(track: UUID)
    case trackPan(track: UUID)
    case sendLevel(track: UUID, send: Int)
    /// A DC-coupled output channel (modulator -> modular as CV).
    case cvOutput(channel: Int)
}

public struct ModulationConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var modulator: UUID
    public var target: ModulationTarget
    /// -1...1, fraction of the target's full range.
    public var depth: Double
    /// The knob position (normalised 0...1) the modulation swings around, captured
    /// when the connection is made. Modulation never overwrites it, so the
    /// parameter doesn't drift when the project is saved mid-wobble.
    public var base: Double?

    public init(id: UUID = UUID(), modulator: UUID, target: ModulationTarget, depth: Double, base: Double? = nil) {
        self.id = id
        self.modulator = modulator
        self.target = target
        self.depth = min(max(depth, -1), 1)
        self.base = base.map { min(max($0, 0), 1) }
    }
}

/// The routing table compiled to flat arrays so the audio thread can apply it
/// without hashing or allocating. Rebuilt on the main thread whenever the user
/// changes a connection, then handed to the render graph.
public struct CompiledModulationMatrix: Sendable {
    public let modulatorIDs: [UUID]
    public let targets: [ModulationTarget]
    /// (modulatorIndex, targetIndex, depth)
    public let links: [(Int, Int, Double)]
    /// Base value per target from its first connection that has one.
    public let bases: [Double?]

    public init(modulators: [ModulatorDefinition], connections: [ModulationConnection]) {
        let ids = modulators.map(\.id)
        var modIndex: [UUID: Int] = [:]
        for (i, id) in ids.enumerated() { modIndex[id] = i }

        var targets: [ModulationTarget] = []
        var targetIndex: [ModulationTarget: Int] = [:]
        var links: [(Int, Int, Double)] = []
        var bases: [Double?] = []
        for c in connections {
            guard let m = modIndex[c.modulator] else { continue }
            let t: Int
            if let existing = targetIndex[c.target] {
                t = existing
                if bases[t] == nil { bases[t] = c.base }
            } else {
                t = targets.count
                targets.append(c.target)
                bases.append(c.base)
                targetIndex[c.target] = t
            }
            links.append((m, t, c.depth))
        }
        self.modulatorIDs = ids
        self.targets = targets
        self.links = links
        self.bases = bases
    }

    /// Final normalised value for each target: base + Σ depth·mod, clamped to 0...1.
    /// `out` must have `targets.count` elements; `bases` likewise (normalised 0...1).
    public func apply(modulatorOutputs: [Double], bases: [Double], into out: inout [Double]) {
        precondition(out.count == targets.count && bases.count == targets.count)
        for i in 0..<out.count { out[i] = bases[i] }
        for (m, t, depth) in links where m < modulatorOutputs.count {
            out[t] += depth * modulatorOutputs[m]
        }
        for i in 0..<out.count { out[i] = min(max(out[i], 0), 1) }
    }
}

extension CompiledModulationMatrix {
    public static func empty() -> CompiledModulationMatrix {
        CompiledModulationMatrix(modulators: [], connections: [])
    }
}
