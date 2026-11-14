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
emulator relies on its JIT for speed. On iPad the engine runs its interpreter instead
(`DSP56K_FORCE_INTERPRETER`: the JIT is compiled in but never executed, so no executable memory is requested).

## Where things stand (2026-11-11)
- **The no-JIT engine is functionally correct.** It boots your MD UW 1.63 firmware, plays the factory
  pattern, the sequencer and LEDs run, and it produces audio (peak 0.73, the same level as the JIT).
  The output is not sample-identical to the JIT build, because the JIT services peripherals per code block
  and the interpreter per instruction, so their timing differs slightly. Listening comparison is still to do.
- **The iPad build compiles and links** (GitHub Actions, `generic/platform=iOS`, arm64, Release).
- **Speed is the open question.** It needs to be measured on your iPad with the test app.

### Measurements (cloud Linux x86-64 Xeon, one core, your firmware, factory pattern playing)
| Build | Real-time factor | DSP throughput |
|---|---|---|
| Desktop JIT (reference, not possible on iPad) | 1.23× | 181.9 M instr/s |
| Interpreter after the correctness fixes, gcc | 0.36× | 53.5 M instr/s |
| + inlined interpreter fast path | 0.41× | 61.9 M instr/s |
| + inlined memory accessors | 0.45× | 66.7 M instr/s |
| **Same code built with clang (the iPad compiler)** | **0.48×** | **71.3 M instr/s** |

- Real-time needs about **150 M DSP instructions per second** (DSP1 79.2 M + DSP2 70.6 M).
- Every optimisation so far keeps the rendered audio **bit-identical** to the unoptimised interpreter
  (checked by comparing the 10-second WAV renders byte for byte).
- Profile of the interpreter (gdb sampling, before the optimisations):
  - about 48% fetch, decode, dispatch and cycle accounting;
  - about 25% actual instruction semantics (ALU, AGU, moves);
  - about 17% peripheral servicing (ESSI, timers, HI08 and DMA are polled about every 13 instructions);
  - about 5% ColdFire and about 5% scheduler.
  Most of the time is overhead, not the Machinedrum's own DSP work, which is why there is room to speed it up.

### Measured on your iPad Pro (M1), 2026-11-13
| Test | Result |
|---|---|
| Raw DSP interpreter, synthetic loop | 257.4 M instr/s (cloud Xeon with clang: 216) |
| Full Machinedrum, factory pattern playing, one core | **0.69× real time**, 109.3 M DSP instr/s, sound (peak 0.56) |
| Boot, 12 s of machine time | 14.5 s |

- The emulated LCD shows the real MD UI: tempo 125, kit 01, pattern A01 playing, a TRX-E2 track.
- **Genuine Machinedrum emulation runs natively on the iPad without JIT, at 69% of real-time speed.**
- Reaching real time needs about **1.45× more speed**.

### Profile of the full machine (callgrind, 1 s of audio, factory pattern playing)
| Component | Self time |
|---|---|
| DSP instruction semantics (ALU, moves, address decode) | about 29% |
| Interpreter loop (fetch, dispatch, cycle and loop checks) | about 19% |
| ColdFire CPU, its system peripherals (SIM), bus access, MIDI checks | about 17% |
| DSP peripherals (ESSI clocks, HI08, timers, DMA) | about 10% |
| Scheduler bookkeeping | about 6% |

The raw interpreter runs 216 M DSP instructions/s on the Xeon, but the full machine reaches only 71 M/s:
about two-thirds of the time goes to the rest of the machine (the ColdFire, peripherals, scheduling).

### Ahead-of-time translation prototype (2026-11-13): correct, but no faster
- Built a generator that translates the executed DSP program (DSP1: 2,225 addresses, DSP2: 3,489) into
  C++ with direct handler calls and constant instruction words. Only the 13 IFcc instructions stay with the
  interpreter.
- **The output is byte-identical to the interpreter, but it ran at 0.42× against 0.48×.** The compiler
  shares and calls the handlers rather than inlining them, so the translation only adds a switch.
- **Conclusion:** dispatch isn't the bottleneck, so this form of AOT isn't worth pursuing. A deeper
  translation (whole blocks, peripherals per block) could still help, but it would no longer be
  bit-identical, and the interpreter loop is only about 19% of the time.

### Memory: an issue for the AUv3
The interpreter's opcode cache has one 48-byte entry per P-memory word, and the MD maps 8 M P words. That is
about 384 MB per DSP, all of it touched at start-up, which is too much for an AUv3 extension. It needs a
sparse, two-level cache. The code only occupies a few kilowords.

### Second core (2026-11-13)
- One DSP can run on a worker thread once the machine reaches its steady-state link protocol. Boot stays
  single-threaded.
- **DSP1 (the mixer) is the worker by default.** Measured on the worker, DSP1 is about 70% of the whole
  emulation cost; moving DSP2 alone gained only about 13%.
- **Ordering:** the clocks are kept as ColdFire <= DSP2 <= DSP1 <= DSP2 + 2 codec frames.
  - DSP2's link words never need DSP1 advanced, and DSP1 never runs DSP2.
  - The ColdFire's host-port polls find the DSP already at its time.
- **Synchronisation:** the threads exchange published cycle counters every 64 instructions.
  - The worker's DSP is owned through a spin lock, which ColdFire accesses take only when they must run that DSP.
  - Shared rendezvous flags use a separate link lock. The receive rings are lock-free.
- **Off by default.** The single-thread output stays byte-identical.

| Cloud Xeon, 2 cores, clang | Real-time factor |
|---|---|
| Single thread | 0.46× |
| DSP2 on a worker | 0.52–0.56× |
| **DSP1 on a worker** | **0.59×** (+28%) |

**Audio check (10 s renders, threaded vs single-thread interpreter):**
- same RMS (0.0758 vs 0.0756) and spectrum within 3% per band;
- loudness-envelope correlation 0.85 (for scale: the desktop JIT render correlates 0.49 with the interpreter);
- no clicks;
- a 60 s threaded run is stable to the end.

**Projection:** on your M1, 0.69× × about 1.28 is about 0.88×. Measure with the test app (it now runs one core,
then two cores).

**What limits it now:** DSP1 on the worker is busy about 91% of the time while the main thread waits, so the
next speed-ups must make DSP1 itself cheaper. Inside DSP1, parallel ALU+move instructions cost about 27% of
the whole program: 40 M per audio second at about 210 host instructions each, mostly dual X/Y reads with two
address updates, and multiply-accumulates.

## Engine changes made for iPad
1. **DO-loop deadlock fixed** (`dsp56kEmu/dsp.cpp`, `dsp.h`).
   - The interpreter ran each hardware DO loop to completion inside a single step. The MD runs the
     ColdFire and both DSPs on one thread, so a DSP loop that waits for ColdFire data could never end, and
     the interpreter build hung at about 1 s of boot.
   - DO now only sets up LA/LC/SS, as the real chip does, and the loop-end test runs after every
     instruction.
2. **MOVEP to or from a peripheral effective address fixed** (`dsp_ops_move.inl`). This was the cause of
   the silent output.
   - `movep x:<<M_HORX,x:<<M_DCO5` (DSP1, pc $9b1) wrote the DMA counter into plain X RAM instead of the
     DMA peripheral, so DMA channel 5 never started and DSP1 never produced audio.
   - Found by running the JIT and the interpreter in lockstep and diffing every instruction.
   - New unit tests fail without the fix and pass with it, on both the JIT and the interpreter.
3. **Interpreter speed-ups**, all bit-identical:
   - an inlined fetch, dispatch and cycle path;
   - the peripheral due-check inlined, as the JIT dispatcher already does;
   - header-inline X/Y/P memory accessors in release builds.
4. **iOS portability:**
   - asmjit cache flush uses `sys_icache_invalidate`;
   - `cowmemory` uses the portable path on iOS (it is only used by the JIT).

The interpreter test suite and all assembler tests pass, and so do the JIT unit and optimiser tests.

## Next steps, in order
1. ~~Measure on your iPad~~ Done: 0.69× on an M1 iPad Pro.
2. ~~A second core~~ Done (DSP1 on a worker thread, +28% in the lab). Measure on the M1.
   - The two DSPs exchange data every audio frame (the ESSI link), and the ColdFire synchronises with each
     of them on host-port access. This fork models that link word by word on one thread, so this needs a
     synchronisation design, not a switch.
   - It is the biggest remaining lever: up to about 1.6× in theory.
3. **Single-thread work that also helps a threaded engine:**
   - per-step overhead on the ColdFire side;
   - cheaper parallel-move instructions;
   - the sparse opcode cache (needed for the AUv3 anyway).
4. ~~Ahead-of-time translation~~ Prototyped: correct but not faster (see above).
5. **The real app:** then the touch UI and the AUv3, once real time is reached.

## Other notes
- **AUv3:** possible only once the engine is real time without JIT. Memory and CPU limits in extension
  processes still need checking.
- **Mac-powered interim version:** the fork contains Gearmulator's network "DSP bridge"
  (`source/bridge`), which could stream a Mac-hosted engine to an iPad app or AUv3. Not started, by your
  priority: effort goes to native first.

## What the test app does
- Imports your firmware, and optionally the factory cache, through Files. Nothing is bundled.
- Measures raw DSP interpreter speed on a performance core.
- Boots the real MD, presses PLAY, times 10 s of audio, and shows the emulated LCD, the real-time factor
  and the DSP throughput, and lets you play the recording.
