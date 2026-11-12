# Mod-Lab: status and test plan (update of 2026-11-11)

How things were checked: the app is compiled with Xcode 16.4 / iOS 18.5 SDK on
GitHub's macOS build machines, and the core library's 33 unit tests pass on
macOS and Linux. **Nothing in this update has been run on a real iPad yet.**
Everything below that touches sound, MIDI, plugins or the microphone is
"built, reviewed, not yet verified on device" until it has been tried on the iPad.

## What changed in this update

### Microphone / audio input
- The app opens with input **off**. The audio session is `.playback` (output only), so the
  microphone, and the orange mic dot, are not used at launch, when playing AUv3
  instruments, when sequencing, or when using effects.
- No microphone permission prompt at launch. The prompt appears the first time an input
  feature is switched on.
- Input turns on only when one of these is true:
  - the **Audio input** switch on the Audio I/O page is on;
  - an Audio or External Synth track is **armed** (● key);
  - an Audio or External Synth track's monitor is set to **On**.
- Input is released (the session goes back to `.playback`) as soon as none of those
  are true any more.
- Opening a project never turns input on: arm and monitor-On on audio tracks are not
  restored. New Audio tracks are created unarmed.
- An **INPUT** chip in the transport bar always shows whether input is running and from
  which device.
- The Audio I/O page lists the available input devices (USB interface, built-in mic…)
  once input is on, and remembers your choice. Each Audio track picks its own input
  channels (mono or stereo pair) on its track card.
- "Run alongside AUM, Koala…" (mix with others) is kept in both session modes.

### AUv3 hosting
- Added the **Inter-App Audio** entitlement. Without it, iPadOS shows a host only Apple's
  built-in units. This was the reason only AUSampler, AUReverb2 and so on appeared.
- The browser has categories (Instruments / Effects / Music FX / MIDI FX), search,
  a "Your plugins" section and an "Apple built-in" section, and a warning if only Apple
  units are visible.
- Plugins that are mono or don't accept stereo now load: Mod-Lab tries stereo, then mono.
- MIDI-only plugins no longer silence the track's audio.
- The plugin's own interface opens with **Edit** on its device card. A plugin without
  its own interface gets a panel of knobs, one per parameter.

### Workflow
- Session: tap a track header to select it. Its device chain appears along the bottom.
- **+ Track** → Instrument creates the track, selects and arms it, and opens the plugin
  browser on Instruments.
- Device strip:
  - track volume and pan, arm, solo and mute;
  - input or MIDI-out settings;
  - a card per plugin: Edit, bypass, mix knob for effects, and Move, Retry and Remove on
    long-press;
  - **+ Instrument / + Effect / + MIDI FX**.
- The on-screen **keyboard** (toggle with the keys button in the transport) plays the
  selected track. It is multi-touch, with octave and velocity controls.
- Selecting an instrument or MIDI track arms it. Every connected MIDI keyboard then plays
  it, including keyboards plugged in after the track was made.
- Clip editor:
  - tap an empty slot on an instrument track to create a 1-bar clip and draw notes;
  - the pencil on a clip edits it;
  - grid of 1/16 steps, note length 1/16, 1/8 or 1/4, clip length 1, 2 or 4 bars;
  - tapping a row label auditions the pitch;
  - changes apply on **Done**, and a playing clip restarts at the next launch boundary.

### Design
Every screen is restyled in one graphite theme:
- one orange signal colour, a muted track palette, uppercase caption labels and
  monospaced readouts;
- custom key caps, knobs (drag up and down, double-tap to reset), long-throw faders
  (double-tap for 0 dB), segmented LED meters, haptic ticks and short animations;
- an LCD-style position and tempo display (drag the tempo to change it), and a
  mode rail instead of a sidebar.

The settings pages (MIDI Routing, Modulators, CV, Sync, Connect, Projects) have the
theme, headers and colours but keep their list layout. They have not been rebuilt
control by control.

## Test plan on the iPad (do these in order)

1. **Mic stays off.** Launch Mod-Lab. There's no microphone prompt, no orange dot in the
   status bar, and the transport chip says INPUT · Off.
2. **Plugins are found.** Session → + Track → Instrument. The browser lists your
   third-party AUv3s under "Your plugins".
3. **Load and hear.** Pick an instrument. The card shows Loading, then Running. Play the
   on-screen keys and you hear it. The mic dot still doesn't appear.
4. **Plugin UI.** Tap Edit on the card. The plugin's own panel opens; turn something and
   hear it change.
5. **Effects.** Tap + Effect, pick a reverb or delay, and play. Turn the Mix knob, and
   try bypass (the power key).
6. **Hardware MIDI.** Plug in a USB or Bluetooth keyboard and play. The selected track
   responds.
7. **Clip.** Tap an empty slot on that track, draw a few notes, and tap Done. Tap the clip
   to launch it, and press stop.
8. **Input on demand.** Add an Audio track. The mic is still off. Arm it (●). Now the
   permission prompt appears (first time only), the INPUT chip turns red, and the orange
   dot appears. Disarm it, and input goes back to Off and the dot disappears.
9. **USB interface.** With an interface plugged in, turn the input on and choose the
   interface under Audio I/O › Device. Its channel meters move, and the track card's
   "In" menu chooses channels.
10. **Alongside AUM.** Run AUM at the same time; both should keep playing sound.

## Known gaps (not done yet)
- Not verified on device (all of the above).
- There's a short audio dropout when input switches on or off, because the audio unit
  restarts with the new session.
- The clip editor has no playhead, no velocity editing, and no drag to lengthen notes.
- Audio clips can't be edited; there's no arrangement view and no undo/redo.
- No plugin delay compensation; no plugin presets browser (save/restore of plugin state
  with the project does exist).
- The settings pages are themed, but not redesigned control by control.
- Ableton Link needs LinkKit.xcframework added by hand (Ableton's licence).
- A free Apple ID install expires after 7 days; press ▶ in Xcode again to renew it.
