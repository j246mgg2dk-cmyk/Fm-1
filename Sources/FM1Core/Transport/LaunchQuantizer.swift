/// Ableton-style launch quantization for clips and scenes.
public enum LaunchQuantization: String, Codable, Sendable, CaseIterable {
    case none, sixteenth, eighth, quarter, bar, twoBars, fourBars, eightBars

    public func gridBeats(_ ts: TimeSignature) -> Double {
        switch self {
        case .none: return 0
        case .sixteenth: return 0.25
        case .eighth: return 0.5
        case .quarter: return 1
        case .bar: return ts.quarterNotesPerBar
        case .twoBars: return ts.quarterNotesPerBar * 2
        case .fourBars: return ts.quarterNotesPerBar * 4
        case .eightBars: return ts.quarterNotesPerBar * 8
        }
    }

    /// Next grid line at or after `beat`. A tiny tolerance stops a launch that
    /// lands exactly on the grid from waiting a whole extra bar.
    public func nextLaunchBeat(after beat: Double, timeSignature ts: TimeSignature) -> Double {
        let g = gridBeats(ts)
        guard g > 0 else { return beat }
        let eps = 1e-6
        return (((beat - eps) / g).rounded(.up)) * g
    }
}
