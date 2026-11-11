# Mod-Lab

An iPad DAW you own outright. It can run your whole studio: the hub for a
big hardware and modular rig, or a simple machine for recording jams. It
hosts every AUv3 plugin you already own and sends MIDI, audio and CV
wherever you want. It works alongside AUM and Koala.

No subscription, no account, no server. You build it from source and it's yours.

> **Status: v0.1, a working foundation, not a finished Ableton/Bitwig rival.**
> The engine, routing, plugin hosting, clip launching, recording, sync,
> modulation and CV are written and designed for realtime use. The UI is
> functional but not polished yet. There's no arrangement timeline or
> piano-roll editor. See [Roadmap](#roadmap).

## What it does

| Area | What's in v0.1 |
|---|---|
| **Plugins** | Hosts any AUv3: instruments, effects, MIDI FX, music effects. That includes Koala Sampler's AUv3, Drambo, Moog, Korg, FabFilter, and so on: anything that loads in AUM. Plugin UIs open inside Mod-Lab. Plugins without their own UI get a slider for every parameter. Plugin state is saved with the project. Plugins get host tempo, beat and transport, so arps, delays and sequencers stay in sync. |
| **Session view** | Ableton-style clip grid, scenes (with optional tempo per scene), launch quantization from 1/16 up to 8 bars, stop buttons, MIDI and audio clips, per-note probability, quantize, double length. |
| **Track types** | Audio, Instrument, MIDI (sequences hardware or other apps), **External Instrument** (MIDI out to a synth, its audio back in through the interface, then effects and mixer), and Group buses. |
| **Audio I/O** | Uses *every* channel of a class-compliant USB interface. Choose input channels per track, direct outs per track, hardware sends (pre/post fader) for external effects loops or cue mixes, and pick the master pair. Input and output are processed in the same buffer, so monitoring latency is as low as AUM's. Buffer size goes from 32 to 1024. |
| **MIDI routing** | A patchbay that connects any source to any destination: USB, DIN interfaces, Bluetooth LE, network RTP, other apps, track inputs and plugin MIDI outs. Each route has channel filters, key splits, message-type filters, transpose, velocity curves, channel remap and CC remap. A note-off always reaches the device that got its note-on, so editing routes mid-performance never leaves stuck notes. There's a PANIC button. |
| **Other apps** | Mod-Lab publishes the virtual ports **"Mod-Lab In"** and **"Mod-Lab Out"**, so AUM, Koala and Drambo can sequence Mod-Lab or be sequenced and clocked by it. It runs in the background and in Split View, and shares the audio session with other apps. |
| **Bluetooth / network** | Apple's built-in Bluetooth MIDI pairing (both connecting to devices and advertising the iPad as one) and Network MIDI that accepts connections from any Mac or iPad. |
| **Sync** | Internal clock, follow external MIDI clock (with jitter filtering for Bluetooth), or **Ableton Link** (see below). Sends MIDI clock, start/stop and song position to any number of devices. Clock is timestamped against the audio output latency so drum machines line up with what you hear, and there's a per-rig offset to fine-tune it. |
| **Modulators (Bitwig-style)** | LFO (6 shapes, synced or Hz), ADSR triggered by a track's notes, step sequencer, smoothed random, audio envelope follower, and macro knobs with MIDI Learn. Any modulator can drive any number of plugin parameters, volumes, pans or sends, each with its own depth. |
| **CV / modular** | Uses DC-coupled outputs (Expert Sleepers ES-8/ES-9, MOTU UltraLite mk5…). Outputs: 1 V/oct pitch with scale quantizer and pitch bend, gate, trigger, velocity, clock (1/4, 1/8, 1/16 or 24 ppq), reset, any modulator as CV, or a fixed voltage for calibration. Each output has its own calibration: full-scale voltage, offset and scale trim. |
| **Recording** | Multitrack recording of armed inputs to 24-bit WAV, plus an optional stereo master-mix recording. Recordings are latency-compensated so overdubs land on the grid. MIDI recording into clips. Takes appear as clips. Everything lives in Files › On My iPad › Mod-Lab, ready for Koala, AUM, AudioShare or your desktop. |
| **Projects** | Readable JSON `.modlab` files with their audio next to them. Auto-saves when the app goes to the background. |

## Things to know up front

- **iPad plugins are AUv3 only.** Desktop VST/AU plugins and desktop
  subscriptions (Splice, Arturia, etc.) can't run on iPadOS; that's Apple's
  platform, not this app. If the developer ships an AUv3 version, it works here.
- **Ableton Link** is free for iOS apps, but Ableton distributes LinkKit under
  its own licence, so it isn't included here. Download `LinkKit.xcframework`
  from <https://github.com/Ableton/LinkKit/releases>, put it in `Vendor/`, and
  uncomment the line in `project.yml`. `LinkSync.swift` detects it
  automatically.
- **CV needs a DC-coupled interface.** Normal audio interfaces block DC. Don't
  send CV channels to speakers.
- **Inter-App Audio is dead** (Apple deprecated it). Apps share audio through
  AUv3. That's why Mod-Lab *hosts* Koala, Drambo and others as AUv3s, and talks to
  AUM through MIDI, Link and Files.

## Build it (one-time, free)

You need a Mac with Xcode 15 or later. A free Apple ID is enough to install
the app on your own iPad, but free provisioning expires after 7 days and then
you rebuild. A paid developer account ($99/yr) gives you 1-year installs and
TestFlight.

```bash
brew install xcodegen
git clone <this repo> && cd Fm-1
xcodegen                     # generates ModLab.xcodeproj from project.yml
open ModLab.xcodeproj
```

In Xcode: select the **ModLab** target › Signing & Capabilities › choose your
team, and change the bundle ID to something unique. Plug in your iPad, select
it as the destination, and press Run.

Run the core tests (MIDI parsing, routing, clock, clips, modulators, CV, project files):

```bash
swift test
```

CI (`.github/workflows/ci.yml`) runs those tests and builds the iPad app for
the simulator on every push.

## How it's put together

```
Sources/FM1Core/     platform-independent brain (unit-tested)
  MIDI/              parser, UMP <-> MIDI 1.0, router/patchbay, mono note tracker
  Transport/         transport, MIDI clock gen + follower, launch quantization
  Modulation/        LFO/ADSR/steps/random/macro/follower + compiled mod matrix
  CV/                calibration, 1V/oct, scale quantizer
  Session/           project model, MIDI clips (player/recorder)
  Realtime/          lock-free SPSC queues, sample ring buffers, atomics
App/                 the iPad app
  Engine/            RemoteIO duplex I/O, render graph, AUv3 hosting, recorder, Link
  MIDI/              CoreMIDI (USB/BLE/network/virtual ports), Bluetooth pairing UI
  Model/             AppModel: project → render graph, persistence, recording
  Plugins/           AUv3 discovery + plugin UI embedding
  UI/                SwiftUI: session, mixer, devices, routing, modulators, CV, sync…
```

**Realtime design:** one RemoteIO callback pulls the hardware input and
renders the output in the same cycle. Each AUv3 is rendered manually, the
same approach AUM takes, instead of going through `AVAudioEngine`. That's
what makes per-channel routing, direct outs, sends and CV possible. The main
thread builds an immutable `RenderGraph` and swaps it in atomically. MIDI,
commands and recorded audio cross threads through lock-free single-producer
queues. Fader moves go straight to atomics, so they don't need a graph
rebuild. The audio thread never takes a lock and never does file I/O.

## Roadmap

Honest list of what a "finished" Ableton + Bitwig on iPad still needs:

1. **Arrangement view** (linear timeline) and session-to-arrangement recording.
2. **Piano roll / step editor** for MIDI clips (clips can be recorded, quantized and launched today, but not drawn).
3. **Audio clip warping** (time-stretch to tempo) and an audio clip editor.
4. **Plugin multi-out and sidechain inputs**.
5. **Plugin delay compensation** across tracks; external-instrument latency compensation during playback.
6. **Built-in devices**: Bitwig-style Grid/modular patcher, drum rack, sampler, utility, EQ/comp.
7. **CV in** (audio inputs as modulators/gates), MPE, MIDI 2.0.
8. **Controller scripts** (Push, Launchpad, APC, Faderfox) and MIDI-mappable everything.
9. **Hardening**: move the render core to C++ for strict realtime guarantees, preallocate clip players, stress tests on real interfaces.
10. Undo/redo, project templates, CPU-saving freeze/bounce.

Contributions, bug reports from real rigs, and "my interface does X" notes are very welcome.

## Licence

Not chosen yet. Add a LICENSE file (MIT, GPL, …) before sharing builds publicly.
