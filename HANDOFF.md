# Handoff: iPad DAW project (working name "FM-1")

Paste this whole document into Claude Code on the Mac. It explains what the project is, where the code lives and what to do next.

---

## 1. Get the code (it lives on GitHub, not on this Mac yet)

```bash
git clone https://github.com/j246mgg2dk-cmyk/Fm-1
cd Fm-1
git checkout claude/ipad-daw-plugins-i87gra
```

All work so far is on branch **`claude/ipad-daw-plugins-i87gra`**. The `main` branch only has an empty README.

Tools needed: the full Xcode app (Mac App Store), then `brew install xcodegen`.

## 2. What the user wants

An iPad DAW you buy once and own, with no subscription. It should combine Ableton Suite with Bitwig features and work as a reliable studio workhorse that is also portable:

- Host **all their AUv3 plugins** (anything that works in AUM).
- Be the **brain of a large external synth rig**: MIDI control and routing, sequencing hardware, MIDI clock out, audio from a USB multichannel interface.
- Or work simply as a **jam recorder**.
- **Experimental modular / Eurorack**: CV out over DC-coupled interfaces.
- **Bluetooth MIDI, USB MIDI, network MIDI**: "anything and everything".
- Work alongside **AUM** and **Koala Sampler** (virtual MIDI ports, Ableton Link, shared files, hosting Koala's AUv3).

**The name is not decided.** "FM-1" only came from the GitHub repo name. Ask the user what to call it before or after the first successful build, then rename it everywhere:
- the target and product name in `project.yml`;
- the virtual MIDI port names `"FM-1 In"`/`"FM-1 Out"` in `Sources/FM1Core/Session/Project.swift` and `App/MIDI/MIDIManager.swift`;
- the UI strings;
- the `.fm1` file extension.

## 3. Current status: written, never compiled

About 5,000 lines of Swift were written in a cloud container that had **no Swift compiler**. The code has **never been built or run**, so expect compile errors on the first build. GitHub Actions CI exists (`.github/workflows/ci.yml`), but it never ran: no macOS runner was available on the account.

**First job:**
```bash
swift test          # core library + unit tests (MIDI, router, clock, clips, modulators, CV, project)
xcodegen            # generates FM1.xcodeproj from project.yml
xcodebuild -project FM1.xcodeproj -scheme FM1 -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Fix errors until both pass. Keep the fixes minimal and don't redesign. Then help the user run it on their iPad:
- signing team (a free Apple ID works, but installs expire after 7 days);
- a unique bundle ID;
- plug in the iPad and press Run;
- trust the developer in iPad Settings → General → VPN & Device Management.

**APIs I wasn't 100% sure of** (check these first if errors point there):
- `UnsafePointer<MIDIEventList>.unsafeSequence()` and `MIDIEventPacket.words` access in `App/MIDI/MIDIManager.swift`
- `MIDIEventListAdd`/`MIDIEventListInit` usage in `MIDIManager.send`
- `AUAudioUnit` RemoteIO setup in `App/Engine/AudioIO.swift`:
  - `inputBusses[0]` = output to hardware;
  - `outputBusses[1]` = hardware input, pulled via `renderBlock` bus 1 inside `outputProvider`.
- `ManagedAtomic<Unmanaged<T>?>` in `Sources/FM1Core/Realtime/RealtimePrimitives.swift` (swift-atomics)
- Swift concurrency / `@MainActor` isolation in `App/Model/AppModel.swift`, in particular the `@Sendable` `midi.onMessage` closure
- `musicalContextBlock`/`transportStateBlock` closure signatures in `App/Engine/HostedPlugin.swift`
- `AVAudioApplication` (iOS 17) in `AudioIO.swift`

## 4. Architecture (short)

```
Package.swift            SwiftPM package "FM1Core" (depends on apple/swift-atomics)
Sources/FM1Core/         platform-independent, unit-tested
  MIDI/                  MIDIMessage + parser, UMP<->MIDI1, MIDIRouter (patchbay, stuck-note safe), MonoNoteTracker
  Transport/             Transport, MIDIClockGenerator, MIDIClockFollower, LaunchQuantization
  Modulation/            Bitwig-style modulators (LFO/ADSR/steps/random/macro/follower) + CompiledModulationMatrix
  CV/                    CVCalibration, CVOutputConfig (1V/oct), ScaleQuantizer
  Session/               Project model (tracks, clips, scenes, routes, CV, macros), MIDIClipPlayer/Recorder
  Realtime/              SPSCQueue, FloatRingBuffer, AtomicFloat/Double/Int/Flag, AtomicReference
Tests/FM1CoreTests/      XCTest
App/                     iPad app (built via XcodeGen, project.yml; Info.plist is generated)
  Engine/AudioIO         RemoteIO full duplex, all USB interface channels, route-change handling
  Engine/AudioEngine     the render callback: commands, sync (internal/MIDI/Link), clock out, modulators,
                         tracks (MIDI, clips, input, AUv3 chain, fader, sends), groups, master, metronome, CV
  Engine/RenderGraph     immutable graph snapshot swapped atomically from main thread; TrackNode runtime state
  Engine/HostedPlugin    manual AUv3 rendering (AUM-style), host tempo/transport blocks, MIDI out, state save
  Engine/Recorder        lock-free ring -> background WAV writer, latency compensation
  Engine/LinkSync        Ableton Link adapter; activates only if LinkKit.xcframework is added (licence: download from Ableton)
  MIDI/MIDIManager       CoreMIDI client, USB/BLE/network endpoints, virtual "FM-1 In/Out", router delivery, 1 ms sender
  MIDI/BluetoothMIDI     CABTMIDICentral/LocalPeripheral view controllers
  Model/AppModel         project -> render graph, plugins, recording, save/load (Documents, visible in Files), clock follow, MIDI learn
  Plugins/PluginCatalog  AUv3 discovery + plugin UI embedding
  UI/                    SwiftUI: Session grid, Mixer, Track devices, MIDI Routing, Audio I/O, Modulators, CV, Sync, Bluetooth, Projects
```

Realtime rules on the audio thread:
- no locks;
- no file I/O;
- avoid allocation;
- cross-thread data goes through SPSC queues and atomics only.

## 5. Next work, in priority order

1. Get it compiling, then running on the user's iPad (see section 3).
2. Rename the app once the user picks a name.
3. Test with real gear: USB interface channels, a Bluetooth MIDI device, MIDI clock to hardware, an AUv3 instrument, Koala's AUv3, and AUM receiving "Out" MIDI.
4. Roadmap from README.md:
   - arrangement view;
   - piano-roll/step editor;
   - audio warping;
   - plugin delay compensation;
   - built-in devices (Grid/modular, drum rack, sampler);
   - CV in / MPE;
   - controller scripts;
   - undo/redo;
   - moving the render core to C++ for strict realtime.

## 6. Notes about working with this user

- They are a musician, not a programmer. Give them plain steps and don't use jargon.
- They hate subscriptions; the app must be fully owned and offline.
- Be honest about platform limits:
  - desktop VST plugins can't run on iPad;
  - Inter-App Audio is deprecated;
  - CV needs a DC-coupled interface;
  - a free Apple ID install lasts 7 days.
- Commit work on branch `claude/ipad-daw-plugins-i87gra` and push it.

---

## 7. Status update (2026-11-11)

- **Name decided: Mod-Lab.** Renamed everywhere:
  - Xcode target and scheme `ModLab`, app name "Mod-Lab";
  - bundle ID `com.modularmayhem.modlab`;
  - MIDI ports "Mod-Lab In" / "Mod-Lab Out";
  - project files `.modlab`.
  The internal Swift library keeps the name `FM1Core` (not visible to users).
- `swift test`: all 33 tests pass on Linux (Swift 6.0.2) and on macOS CI.
- The iPad app builds on GitHub Actions (Xcode 16.4, iOS 18.5 SDK) after three small fixes:
  - `hasCustomView` is macOS-only;
  - the parameter slider expression was too complex to type-check;
  - a missing `AudioToolbox` import.
- CI uses `macos-15-intel`: the arm64 macOS pool never picked the jobs up.
- Still untested on a real iPad. Next step: install Xcode on the Mac and run the app on the iPad (see section 3).

## 8. Update 2026-11-11 (evening): redesign + microphone + AUv3

See **TESTING.md** for the full status, the on-device test plan and the known gaps.

- **Microphone:** the audio session is `.playback` by default and input is off. Input runs
  only for an explicit input feature: the Audio I/O switch, an armed audio track, or
  monitor On. Permission is requested on first use, not at launch. Logic is in
  `AppModel.updateInputState()` and `AudioIO.configureSession()`.
- **AUv3:** added the Inter-App Audio entitlement (required for iPadOS to show
  third-party AUv3s to a host); stereo→mono bus negotiation.
- **UI:**
  - new `Theme.swift` / `Controls.swift` design system;
  - rebuilt RootView (transport, mode rail), Session, Mixer, DeviceStrip (replaces
    TrackDetailView), PluginBrowser, KeyboardView and ClipEditor.
- **Engine:** `EngineCommand.liveMIDI` carries on-screen keyboard notes to a track on
  the audio thread.
- **Signing:** `DEVELOPMENT_TEAM` is set to the user's personal team (LXPC6567AX) in
  project.yml.
- Builds clean on CI. **Not yet run on a device.**
