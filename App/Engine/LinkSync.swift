import Foundation

#if canImport(LinkKit)
import LinkKit
import UIKit
#endif

/// Ableton Link: shared tempo + phase + start/stop with AUM, Koala, Drambo,
/// Ableton Live, Bitwig and anything else on the same Wi-Fi / USB network.
///
/// LinkKit is free for iOS apps but is distributed by Ableton under its own
/// licence, so it is not vendored here. Download LinkKit.xcframework from
/// https://github.com/Ableton/LinkKit/releases, drop it into `Vendor/`, and
/// this file switches on automatically (`canImport(LinkKit)`).
final class LinkSync {
    struct BlockState {
        var tempo: Double
        var beat: Double
        var isPlaying: Bool
    }

    let quantum: Double = 4

    var isAvailable: Bool {
        #if canImport(LinkKit)
        return true
        #else
        return false
        #endif
    }

    #if canImport(LinkKit)
    private let link: OpaquePointer

    init(tempo: Double) {
        link = ABLLinkNew(tempo)
        ABLLinkSetActive(link, false)
    }

    deinit { ABLLinkDelete(link) }

    var isEnabled: Bool {
        get { ABLLinkIsEnabled(link) }
        set { ABLLinkSetActive(link, newValue) }
    }

    /// Ableton's own Link settings screen (required by the Link guidelines).
    func settingsViewController() -> UIViewController? {
        ABLLinkSettingsViewController.instance(link) as? UIViewController
    }

    /// Audio thread, once per block.
    /// - Parameters:
    ///   - hostTime: mach host time at which this block's first sample is heard.
    ///   - requestedTempo: local tempo change to push to peers, if any.
    ///   - requestedPlaying: local start/stop to push to peers, if any.
    func beginBlock(hostTime: UInt64, requestedTempo: Double?, requestedPlaying: Bool?) -> BlockState? {
        guard ABLLinkIsEnabled(link) else { return nil }
        let state = ABLLinkCaptureAudioSessionState(link)
        if let t = requestedTempo { ABLLinkSetTempo(state, t, hostTime) }
        if let p = requestedPlaying {
            ABLLinkSetIsPlaying(state, p, hostTime)
            if p { ABLLinkRequestBeatAtStartPlayingTime(state, 0, quantum) }
        }
        if requestedTempo != nil || requestedPlaying != nil {
            ABLLinkCommitAudioSessionState(link, state)
        }
        return BlockState(
            tempo: ABLLinkGetTempo(state),
            beat: ABLLinkBeatAtTime(state, hostTime, quantum),
            isPlaying: ABLLinkIsPlaying(state))
    }
    #else
    init(tempo: Double) {}
    var isEnabled: Bool {
        get { false }
        set { _ = newValue }
    }
    func beginBlock(hostTime: UInt64, requestedTempo: Double?, requestedPlaying: Bool?) -> BlockState? { nil }
    #endif
}
