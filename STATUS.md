# Status: native Machinedrum on iPad (2026-11-11)

## Source
- The Machinedrum emulator is **not in upstream Gearmulator**. It's in the fork
  [joelanders/gearmulator-md-mm](https://github.com/joelanders/gearmulator-md-mm), branch
  `release/md-mm-alpha` @ 4050ce4, with submodules dsp56300-md-mm @ 1378c43 and mc68k-md-mm @ ace95b3.
- Hardware it emulates:
  - a ColdFire MCF5206E at 40 MHz (the Musashi core);
  - **two DSP56303 at 101.6 MHz** (dsp56kEmu; 2304 DSP cycles per 44.1 kHz frame);
  - an 8 MB flash running the original OS (the MD UW 1.63 image is supported).
- The engine (`mdLib`, `synthLib`, `dsp56kEmu`, `mc68k`, `hardwareLib`, `baseLib`) is plain C++17 with no UI
  dependencies. The desktop UI is JUCE + RmlUi and is **not** used on iPad.
- Licence: GPL-3.0. Personal builds are fine. Distributing the app means publishing its source under GPL-3.0,
  which also conflicts with App Store terms (the usual GPL/App Store problem). Firmware is Elektron's
  copyright and must never be bundled; the app imports the user's own file.

## The iPad blocker: JIT
iPadOS does not let normal apps or AUv3 extensions create executable code at run time. The desktop
emulator relies on its JIT for speed. Without it, the engine falls back to its interpreter.

### Measurements (cloud Linux x86-64 Xeon, single core, your MD UW 1.63 firmware)
| | JIT (desktop path) | Interpreter (iPad path) |
|---|---|---|
| Raw DSP speed, synthetic loop | 1433 M instr/s | 139 M instr/s (10× slower) |
| Full machine, factory pattern playing | **1.23× real time**, audible | 0.93× real time, but **silent** (see below) |
| DSP work needed per second of audio | **148.4 M instructions** (79.2 M + 69.2 M) | — |
| Emulator DSP throughput, real firmware | 181.9 M instr/s | 73.3 M instr/s (including ColdFire and scheduler) |
| Share of time in DSP code (JIT run, sampled) | 60% | — |

**Projection for a correct interpreter:**
- about 0.57× real time on this Xeon;
- an M4/M5 iPad Pro core is roughly 1.6–2× faster, which gives **about 0.9–1.15×**: borderline;
- with the two DSPs on separate cores (upstream Gearmulator does this; this fork interleaves everything on one
  thread for determinism), **about 1.5–1.9×**.

**This must be confirmed on the iPad with the test app in this repository.**

## Engine changes made for iPad
1. **DO-loop deadlock fixed** (`dsp56kEmu/dsp.cpp`, `dsp.h`).
   - The interpreter ran each hardware DO loop to completion inside a single step. The MD runs the
     ColdFire and both DSPs on one thread, so a DSP loop that waits for ColdFire data could never end, and
     the interpreter build hung at about 1 s of boot.
   - DO now only sets up LA/LC/SS, as the real chip does, and the loop-end test runs after every
     instruction.
   - The interpreter unit test that checked the old behaviour was updated to step the loop.
   - The DSP interpreter test suite and all 280 assembler tests pass.
2. The interpreter build is selected with `DSP56K_FORCE_INTERPRETER`. The JIT code is compiled in but never
   executed, so no executable memory is requested.

## Open problems (honest list)
- **Interpreter correctness:** with the deadlock fixed, the interpreter boots, but diverges from the JIT
  partway through boot.
  - DSP2 answers a ColdFire query with `03 03 02` where the JIT build answers `00 00`.
  - The OS then takes a different path, so audio stays silent.
  - Instruction-level unit tests pass, so this is an integration or timing difference. The suspect is
    peripheral servicing granularity (per JIT block versus per instruction) or a remaining interpreter edge
    case.
  - Next step: lockstep DSP comparison (JIT versus interpreter on the same state) to find the first
    differing instruction.
- **Speed:** borderline single-threaded. Options, in order of effort:
  1. ARM64-specific interpreter tuning: peripheral checks per block instead of per instruction, and
     cached decode.
  2. Run DSP2 on a second core, synchronised per audio frame.
  3. Ahead-of-time translation: the DSP program code comes from the user's firmware and is deterministic. It
     can be translated to C++ on the user's Mac at build time from their own firmware (never published) and
     compiled into their personal app. That gives JIT-class speed with no run-time code generation.
- **AUv3:** possible only once the engine is real time without JIT. Memory and CPU limits in extension
  processes still need checking.
- **Mac-powered interim version:** the fork contains Gearmulator's network "DSP bridge"
  (`source/bridge`), which could stream a Mac-hosted engine to an iPad app or AUv3. It hasn't been started,
  by choice: effort goes to native first.

## What the test app does
- Imports your firmware, and optionally the factory cache, through Files.
- Measures raw DSP interpreter speed.
- Boots the real MD, presses PLAY, times 10 s of audio, and shows the emulated LCD, the real-time
  factor, the DSP throughput and the projection, and lets you play the recording.
