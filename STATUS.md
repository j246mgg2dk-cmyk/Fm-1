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

### Measured on your M1 iPad Pro with two cores (2026-11-14): REAL TIME
| | One core | Two cores (DSP1 on a worker) |
|---|---|---|
| Real-time factor | 0.69× | **1.09×** (+58%) |
| DSP throughput | 108.3 M/s | 170.5 M/s (needs 149.8) |
| Boot (12 s machine time) | 14.7 s | 10.0 s |
| Audio | sound (peak 0.56) | sound (peak 0.55) |

- **Genuine Machinedrum emulation, no JIT, faster than real time on the iPad.**
- The first two-core build ran at 0.18× on iPadOS, because `sched_yield` in the spin fallbacks depresses
  thread priority on Apple platforms. Pure spinning plus 128-byte cache-line padding fixed it.
- Headroom is still thin. A real-time audio thread needs margin for OS jitter, UI and the AUv3 host, so the
  remaining speed work still matters.

### Real-time readiness (2026-11-14)
- **Live playback test:** the test app streams the emulator through AVAudioEngine in real time. You choose
  128–1024-frame buffers and one or two cores. The DSP worker joins the output's audio workgroup, and the
  panel shows per-callback load, peak load, overruns (callbacks longer than their buffer) and memory.
- **Worker sleep:** the worker spins up to 2 ms when idle, then sleeps until the scheduler wakes it.
  In paced tests, sleeping across every callback gap cost about 12% of the buffer budget:

  | Worker behaviour between buffers | Average load | 99th percentile |
  |---|---|---|
  | Sleep after 200 µs | 84% | about 120% |
  | Spin | 72% | 101% |

- **Data race fixed:** with DSP1 on the worker, its codec-input callback read the host-input timeline while
  the scheduler appended to it, causing an intermittent runaway in `append`. A per-receiver lock fixes it.
- **Memory:** total footprint (PSS) is now about 160 MB, down from about 1.2 GB. Output is byte-identical.

  | Change | Saving |
  |---|---|
  | Interpreter opcode and cycle caches use lazily committed zero pages (unresolved = all-zero bits) | about 800 MB |
  | ESSI rings use 2048 frames on iPad instead of 32768 (the MD peaks at about 114 frames) | about 150 MB |
  | md::Dsp's memory buffer uses lazily committed zero pages | about 66 MB |

  The emulated DSP RAM is mapped about 1,000 times (mirrors), so RSS overstates it. PSS is the real figure.

### Live test on the M1 struggled; headroom work (2026-11-14)
- **Your live test:** 512-frame buffers, two cores: 95% average load, 113% peak, 91 overruns in 4186
  callbacks. Clean audio needs about 1.3× rather than 1.09×.
- **Who waits for whom.** New timing in the stats line: the worker thread (DSP1, the mixer) executes 91% of
  the time, and the main thread (ColdFire plus DSP2) waits for it 40% of the time. **DSP1 alone is the
  ceiling.** It retires about 52 M instructions/s of its real code on the lab Xeon, against 216 M on the
  synthetic loop.
- **Where the DSPs spend their instructions** (per-address histogram, factory pattern playing):
  - DSP2: 98.5% in waits. 84% is a NOP delay loop in external memory ($100090) and 12% polls Port C bit 1
    ($bb).
  - DSP1: 9.5% polls DMA0's destination pointer until a ping-pong half fills ($3c).
- **Fix 1, exact ESSI deadlines (the big one).** The MD clocked its ESSIs in DSP cycles but polled them in
  instructions, with a "half the remaining cycles" guess. Each 96-cycle link slot was serviced 5 to 7
  times, and half of all peripheral calls came less than 4 instructions apart. The engine already had an
  exact cycle-deadline mode, used by the Monomachine; the MD now uses it as well.
  - Each link slot gets one service, at its exact cycle (more accurate, not less).
  - Audio checked against the reference render: spectrum within 0.9 dB and no dropouts or clicks. That
    matches the already-verified two-core mode (sample-exact comparison isn't meaningful here, since
    timing changes shift trig and LFO phases).
- **Fix 2, exact idle skipping.** Side-effect-free waits are fast-forwarded by whole iterations, never past
  a peripheral service, a pending interrupt or the slice limit. The machine state afterwards is exactly
  what interpreting them would give: one-core renders are byte-identical with skipping on and off.
  - Covers DSP2's NOP delay loops (generic: any DO loop whose body is only NOPs) and DSP1's DMA poll
    (verified word for word, so other OS versions just run normally).
  - `GEARMULATOR_MD_IDLE_SKIP=0` turns it off.
- **Also:** MPY/MAC with operands specialised at compile time (byte-identical, small effect), and timing
  stats in the live panel.

| Lab (2-core Xeon) | Before | Now |
|---|---|---|
| One core | 0.42× | 0.53× (+26%) |
| Two cores | 0.56–0.60× | 0.66× (+13%) |
| DSP1 throughput on the worker | 51 M instr/s | 59 M instr/s |

Expected on the M1 with two cores: roughly 1.2–1.25×, up from 1.09×. To be measured.

### Sustained load on the M1 (2026-11-14, evening)
- **Your runs after the headroom work:** 0 overruns for the first 74 s at 512 frames, 81% average load
  (about 1.23× real time). After 2–3 minutes the load sat at about 100% and clicks started, at 1024
  frames too. The thermal state stayed "nominal", but DSP1's speed fell from 110 to about 97 M
  instructions/s, while lab runs show no slowdown over 150 s. So the iPad lowers its clock under
  sustained two-core load, and the engine needs margin for that and for heavy use.
- **DSP1 is a fixed workload:** about 1,800 straight-line instructions per sample, each run once per
  sample, with no wait loops left. Only interpreter speed and per-slot overhead matter now.
- **Changes:**
  - Audio rings without semaphores on iPad (`DSP56K_AUDIO_RING_LOCK=0`), with producer and consumer
    counters on separate cache lines. The link carries about a million frames a second across cores.
  - DSP1's link-receive hook checks its own DMA state before taking the shared link lock.
  - Optional WFE-based waiting ("Low-power wait" in the live panel): the waiting core idles until the
    other core publishes progress, instead of spinning at full power.
  - One-core output stays byte-identical. Lab two-core DSP1 throughput went from 59 to about 64 M
    instructions/s.

### What is left to try, and what isn't worth it (2026-11-14, late)
- **Your run with the link changes and low-power wait** (512 frames, 250 s): 5 overruns, against 120 in
  160 s before. Average load 86%. Main-thread spin-waits fell from 6.8 billion to 0.2 billion.
- **Heavy use:** saturating the MIDI input costs about 6% (lab 0.67× → 0.63×). That's a trigger on every
  track plus constant parameter CCs, at the 31.25 kbaud wire limit. The extra work lands on the main
  thread, which still has slack; DSP1 stays the limit.
- **Ruled out:**
  - Ahead-of-time translation with inlined handlers. The straight-line code is 1.3 MB, and DSP1 runs
    through all of it every sample, so it thrashes the instruction cache. The interpreter's compact shared
    handlers win.
  - ThinLTO: no measurable difference.
- **Available:** profile-guided optimisation, +7% on one core and about +5% for DSP1 on two cores in the
  lab, with byte-identical output. It needs one profiling run on the iPad through Xcode.

### The real app (2026-11-14, night)
The test app is now the Machinedrum app (same bundle, so your imported firmware stays).
- **Front panel:**
  - dot-matrix LCD (Amber, Ice or Classic);
  - LEVEL and data entry encoders A–H (drag to turn, hold to push, hold and drag to turn while
    pushed);
  - 16 trig keys with step LEDs, plus track LEDs above them;
  - RECORD / PLAY / STOP;
  - FUNCTION, arrows, YES/ENTER, NO/EXIT, KIT, TEMPO, SYN/EFX/ROUT, CLASSIC/EXT,
    PATTERN/SONG, BANK GROUP, banks A–D and SCALE, each with its LEDs.
  - Keys send press and release separately, so holds and multi-finger combos work.
- **MIDI:**
  - every USB, Bluetooth and network device, switchable per device;
  - a virtual "Machinedrum" input and output for other apps;
  - Bluetooth pairing and network MIDI.
  - Incoming MIDI gets a fixed one-buffer delay at its original spacing (no jitter). Outgoing MIDI is
    time-stamped against the audio output.
- **Your data:** kits, patterns, songs and settings are restored at boot, and saved every two minutes
  and when you leave the app. Backup export and restore.
- **Audio:**
  - 1024-frame default, second core, low-power waiting;
  - background audio that mixes with other apps;
  - recovery after interruptions;
  - CPU meter and MIDI activity LEDs in the top bar.
- **Diagnostics:** the former test screens, under Settings.

### Dropouts that stuck, and the safety buffer (2026-11-14, late night)
- **What you saw:** after a heavy moment (a knob burst), the audio stopped until the route changed
  (earbuds out and in). The app hadn't crashed. The emulator ran inside the CoreAudio callback, so a
  late callback could stall the output, and nothing restarted it.
- **What the CPU figure was:** emulation time per buffer divided by the buffer's duration, *peak* over
  a quarter second, on the thread that runs the emulator. It wasn't the iPad's total CPU. The meter
  now shows the average over the quarter second (DSP) and the safety-buffer fill (SAFETY).
- **Fix:**
  - The emulator runs on its own render thread, joined to the audio workgroup, ahead of the output
    by a safety buffer. The callback only copies.
  - The output restarts by itself after configuration and route changes, interruptions and media
    resets, or if a watchdog sees it stall.
- **Lab, maximum MIDI stress (2-core Xeon, noisy neighbours, worst single block up to 7x budget):**

  | Average load | Direct (old) | Safety 768 | Safety 1536 |
  |---|---|---|---|
  | about 83% | 15% of buffers late | 0.15% short | 0 short |
  | about 90% | 37% of buffers late | 1% short | 0 short |

- **Lab, sustained overload with a MIDI flood for 11 minutes:** no crash, no hang.
- **Also:**
  - Out-of-range memory-read errors are counted instead of logged: about 150/s during normal
    playback, 1,500/s under stress.
  - LED views redraw individually and the panel runs at 30 fps.
- **In-app tools:**
  - a performance log (a CSV line every 10 s: load, worst block, underruns, lowest buffer fill,
    restarts, memory, thermal, per-thread CPU);
  - a 5- or 30-minute stress test that restores your state afterwards.

## Three-core mode (2026-11-15, needs measuring on the iPad)
- **Why:** the M1 lowers its clock by about 15% after about 80 s of heavy load. In the two-core
  mode the render thread (ColdFire + DSP2) waited 22% of its time for DSP1 while DSP1 was busy 81%:
  neither thread is saturated, the hand-offs limit throughput.
- **What:** `GEARMULATOR_MD_DSP_WORKER=3` (app: Settings > "Use a third core") runs DSP2 on its
  own worker. The render thread then runs only the ColdFire.
  - Ordering: ColdFire <= DSP2 <= DSP1 <= DSP2 + skew, as before, plus DSP2 <= ColdFire + one
    scheduling quantum (125 us). The single-thread scheduler already keeps DSP2 within a quantum of
    the ColdFire; leading by a whole block made the firmware go silent.
  - The ColdFire publishes its position after every step so DSP2 follows it continuously.
  - DSP2 has its own lock, wake-up and statistics; ColdFire host accesses to DSP2 take that lock
    (`DspAccess` now covers either worker).
- **Lab results (2-core container, so correctness only; speed can't be measured here):**
  - single-thread output still byte-identical;
  - two-core mode unchanged (0.62x here);
  - three-core output matches the two-core output as closely as two-core matches single-thread
    (average spectrum difference 0.26 dB, same number of hits, no dropouts);
  - 20 s of MIDI flood plus knob turns: no hang, no dropouts.
  - `GEARMULATOR_MD_YIELD_WAITS=1` (lab only) makes waits yield, for machines with fewer cores
    than emulation threads.
- **Device test:** 5-minute stress test with the setting off, then on; compare the CSV columns
  `load_avg_pct`, `underruns`, `render_waits_for_dsp1_pct`, `dsp1_busy_pct`, `dsp2_busy_pct`.

## Device results, 2026-11-15
- **Two-core stress (twice):** about 84% before the clock drop, 98-99% after it (DSP1 116 -> 98 M
  instr/s, thermal nominal). Dropouts only while the clock falls; none once it has settled.
- **Three-core, normal play:** 76.6% load against 69.0% for two-core on the same pattern. The DSP2
  thread is busy 30% but holds a core at 100%; with three busy cores the M1 keeps a lower clock
  (DSP1 108 instead of 120 M instr/s). DSP1 is busy 95% in normal play: it is the floor.
- **Saving:** autosave is now off by default (Settings: off / 2 / 5 / 15 min); named projects with
  Save / Save As / Load; the session is saved once when the app leaves the foreground (setting).

## Three-core verdict and link skew (2026-11-15, new build)
- **Three-core stress, twice:** 75% load before the clock drop (two-core: 84%), but then the clock
  falls further, DSP1 118 -> 89-91 M instr/s (two-core: 98), total CPU 320% against 225%, and
  underruns recur every 20-40 s for the rest of the test (two-core: none once settled). On the
  M1 the sustained clock depends on how many cores are busy, so the third core costs more than it
  gives. The setting is removed and forced off; the engine code stays for the lab.
- **New build, two-core normal play (one sample):** 66.9% load at 124.5 M instr/s, against 69.0%
  at 120.3 before: about +3.5% on DSP1 on the M1 (the lab showed more).
- **Skew 2 -> 8 frames:** lab MIDI+knob stress, three alternating runs: render thread waiting
  30% -> 24%, throughput 0.63x -> 0.66x. Sound matches within the usual threading variation, no
  dropouts.

## Parallel-move fast path (2026-11-15)
- A sampled profile of DSP1's program shows no hot loop; time is spread over the mixer code, but
  `mac` with parallel moves is about 40% of it and ALU+move instructions about 43%.
- The interpreter ran every ALU+move instruction through `exec_parallel`: save A/B, ALU, restore
  A/B, move, compare and merge. That is only needed when the move touches A or B (the only
  registers a parallel ALU op writes). When it doesn't (XY moves into x0/x1/y0/y1, X: or Y: moves
  of x/y/r/n registers, register moves among those, immediates, address updates), the ALU now runs
  first and the move second, directly: exactly the latched result.
- **Lab:** single-thread output byte-identical; interpreter unit tests pass; whole-emulator
  single-thread time 14.38 -> 13.32 s for 8 s of audio (-7%, four alternating runs each); DSP1
  instruction rate on the worker about +14% (noisy 2-core machine).

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
2. ~~A second core~~ Done: 1.09× real time on the M1 (+58%).
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
