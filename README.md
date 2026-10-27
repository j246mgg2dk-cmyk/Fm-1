# FM-1 GLITCH (a Felucca fork)

Custom firmware for the M-VAVE FM-1, built on [Felucca](https://github.com/hugelton/Felucca) 1.6.1 by Leo Kuroshita /
Hügelton Instruments (GPL-3.0-only). It keeps everything Felucca does and adds glitch effects to the **FX layer** and JUNGLE breakbeat tools to SLICE.
Felucca's authors don't endorse or support it, so please don't send them reports about this fork.

## The new effects

Hold **FX** and press a key. The effect lasts while you hold the key (or toggles, with MENU > FX LATCH ON). Everything
stacks: hold as many as you have fingers for.

| Key | Effect | What it does |
|---|---|---|
| **F5** | **GLITCH** | An automatic beat-mangler. On every 1/16 it grabs what just played and picks a random move: repeat it, roll it at 1/2, 1/4, 1/8 or 1/16 length, CHOP it (a stutter with every other hit dropped), ACCEL (a roll that speeds up), reverse it, an octave down or up, tape-stop it, or drop it to silence. Repeats chain on the same slice, so stutters build. It stays in time with the sequencer. **While GLITCH plays, KNOB 4 is CHAOS**: low means the odd repeat, 60 % (untouched) is plenty, 100 % never plays clean and lives on short rolls, chops and dropouts. |
| **G5** | **BEND** | Circuit-bent wreckage. It boosts each sample until it wraps like a 16-bit integer overflow, so loud parts fold into hard digital edges and silence stays silent. It adds random sample-hold grit, and the settings re-roll every 1/32. |
| **D#4** | **8-BIT** | An 8-bit crush at 11 kHz: an old sampler. |
| **F#4** | **CHOP** | Random dropouts. Every 1/32 the sound is cut or let through at random, with quick fades so it doesn't click. |
| **G#4** | **RING MOD** | A ring modulator that jumps to a random pitch (30 Hz to 7 kHz) every 1/16: from metallic clang to robot gargle. |
| **A#4** | **ROLL** | A drum-roll build-up. It catches a 1/16 and rolls it at 1/16 for a beat, then 1/32, 1/64, 1/128, until it's a buzz. |
| **C#5** | **MELTDOWN** | GLITCH + BEND + 8-BIT + CHOP + RING MOD all at once. Experimental chaotic anomaly button. |

The other FX-layer tools still work on top: KNOB 1 FILTER, KNOB 2 CRUSH, KNOB 3 THROW (into delay and reverb), plus
REPEAT, REVERSE, TAPE STOP, FREEZE, OCT UP/DN, FLANGER, PHASER and the throws on the other white keys. **KNOB 4 (DEPTH)**
sets how much you hear of BEND, 8-BIT, CHOP, RING MOD and ROLL. While GLITCH plays, those run at full and KNOB 4 is CHAOS.

Any effect can go on any white key: hold FX, hold the key, turn PRESETS. The black keys F#3 to C#4 are still the
track mutes. D#5 and F#5 do nothing.

## JUNGLE: breakbeat tools

Three track parameters for chopping breaks. Everything is OFF or 0 by default, so old projects and sounds play exactly
as before. All three can be **p-locked** per step like any other sound parameter: open the JUNGLE page, then on SEQ > STEP hold a
step and turn the knob.

On a **SLICE** track they're on **EDIT > JUNGLE** (KNOB 1 to 3). DRILL works on every engine and is also on
**EDIT > VOICE 3**, KNOB 2.

| Parameter | Values | What it does |
|---|---|---|
| **BSYNC** (BREAK SYNC) | OFF, HALF, SYNC, DBL | Plays a loop at the song tempo, from BPM or the external MIDI clock. Each loop's tempo is worked out from its length: it assumes the loop is a whole number of beats and picks the tempo between 120 and 240 BPM. A 2-bar 180 loop reads as 180, a 1-bar 174 as 174, and half a bar of 86 as 172 (use HALF for 86). Each zone of a user slot gets its own tempo, and the built-in BREAK is 120. HALF plays at half the song tempo and DBL at double. PTCH, BRAIN's jumps and DRILL's pitch still change the speed on top, like an old sampler. Zones shorter than 1/4 s, such as one-shots, play at their own rate. |
| **BRAIN** (AMEN BRAIN) | 0–100 % | Re-cuts the break as it plays. When a sample is scanned, every slice is sorted as KICK, SNARE, HAT or GHOST by its sound. Then each note has a chance of a random move: swap for another slice of the same kind, swap for any slice (above 60 %), reverse, jump pitch (−12, −5, +7 or +12), stutter (replay the slice before), or drop (never a kick). Below 50 %, kicks, snares and the quarter-note steps rarely move, so the groove holds while the ghosts and hats get mangled. At 100 % nothing is safe. |
| **DRILL** | OFF, x2, x4, x8, UP, x2UP … x8DN | Multiplies a step's RATCH by 2, 4 or 8, so an x8 drill on a RATCH x4 step gives 32 hits in a 1/16: a buzz roll. UP and DN slide the roll's pitch up or down an octave from the first hit to the last. Lock x8UP on the last step of a bar for an instant snare roll. |

Load your breaks into USR1..3 (`tools/fm1_sample_upload.py`), put a SLICE track on that slot with DIV 16 or AUTO, set
BSYNC to SYNC and play the slices from the keys or the sequencer at any tempo.

Projects saved with JUNGLE parameters need this firmware: stock Felucca 1.6.1 shows them as EMPTY. Projects from stock
1.6.1 load fine here, with the three parameters OFF.

## Install

Every push builds the firmware on GitHub Actions (`.github/workflows/firmware.yml`) and runs Felucca's full host test
suite against it.

1. **Get the package.** Go to the repository's **Actions** tab, open the latest green **firmware** run and download the
   `firmware-…` artifact. It contains `felucca-<version>.fwsc` and `installer-site-<version>.zip`. A tagged release
   (`v1.6.1-glitch1`, etc.) puts the same files on the **Releases** page.
2. **Flash it.** Pick one of these:
   - **Browser (easiest):** enable GitHub Pages for this repository (Settings > Pages > Source: **GitHub Actions**). The
     next push publishes the installer at `https://<your-user>.github.io/<repo>/`. Open it in Chrome or Edge with the
     FM-1 connected by USB and press Install. It offers to back up first.
   - **Command line:** `pip3 install mido python-rtmidi`, then `python3 tools/fm1_install.py felucca-<version>.fwsc`.
3. **Going back.** The installer's *Return to official V15* (with M-VAVE's `FM-1.fwsc`) or M-VAVE's own updater restores
   the stock firmware. If an install is cut off, hold **OCT−** while switching on to get USB update mode, then install
   again.

Installing custom firmware is at your own risk. Keep the USB cable connected and close other MIDI apps (DAWs, the M-VAVE
app, editor tabs) while it writes. If you are on another custom firmware, return to official V15 first.

---

# Felucca

[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE)

## Maintenance Notice

What began as a personal experiment grew far beyond my expectations. I’m grateful to everyone who contributed, supported the project, and made music with Felucca.

I’ve decided to step back from active development to focus on creating new instruments and music.

Felucca will remain available with occasional maintenance, but new features, issue responses, and pull request reviews are not guaranteed.

Thank you for everything. I hope you’ll look forward to my next creations.

## Overview

Multi-engine synthesizer firmware for the M-VAVE FM-1, version 1.6.1. Connect the FM-1 to a computer by USB, open the
[web installer](https://hugelton.github.io/Felucca/) in Chrome or Edge and press Install; no extra hardware is needed.
Installing is at your own risk: M-VAVE's updater or the installer's **Return to official V15** takes you back.
[Try it in your browser](https://hugelton.github.io/Felucca/webapp/try/), no FM-1 needed.

- Install: [web installer](https://hugelton.github.io/Felucca/)
- Edit: [web editor](https://hugelton.github.io/Felucca/webapp/editor/) ([Felucca-WebApp](https://github.com/hugelton/Felucca-WebApp))
- Read: the manual and the release notes are in the [wiki](https://github.com/hugelton/Felucca/wiki/Home)
- Build: [BUILDING.md](BUILDING.md)
- Related: [Felucca-Engines](https://github.com/hugelton/Felucca-Engines) (the ANALOG, LOFI, TRIO, WHEEL and NOISE engines, MIT; still maintained) ·
  [felucca-bsp](https://github.com/hugelton/felucca-bsp) (the FM-1 hardware layer)

## AI disclaimer

Felucca is developed with the assistance of AI coding agents (code, tests, documentation, translation, maintenance). The
design, features, sound design and direction are the maintainer's or the community's, and no generative AI is used for music,
icons or artwork. See [On AI-Assisted Development and Responsibility](https://github.com/hugelton/Felucca/discussions/166).

## Credits and licence

Free software: [GPL-3.0-only](LICENSE); the Hügelton Sample Pack is CC0 1.0; the engines in `firmware/engines` are MIT
([Felucca-Engines](https://github.com/hugelton/Felucca-Engines)); the bundled fonts and ported DSP keep their own licences
([LICENSES/](LICENSES/), [LICENSING.md](LICENSING.md)). Thanks to everyone whose work and contributions are in it: [CREDITS.md](CREDITS.md).

M-VAVE and FM-1 are trademarks of their respective owners. Felucca is not affiliated with or endorsed by them.

Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments
