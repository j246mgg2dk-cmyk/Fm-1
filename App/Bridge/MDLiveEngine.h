#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Snapshot of the live engine's real-time behaviour.
@interface MDLiveStats : NSObject
@property (nonatomic) BOOL running;               // audio is coming from the emulator
@property (nonatomic) BOOL secondCore;            // the DSP worker thread is active
@property (nonatomic) BOOL workgroupJoined;       // the worker joined the audio workgroup
@property (nonatomic) NSInteger bufferFrames;     // frames per audio callback (actual)
@property (nonatomic) double sampleRate;          // hardware rate the callback runs at
@property (nonatomic) NSInteger callbacks;
@property (nonatomic) NSInteger overruns;         // underruns: the output found the safety buffer short (a click)
@property (nonatomic) double averageLoad;         // emulation time / audio time since start, 0..1+
@property (nonatomic) double peakLoad;            // worst single render block since start
@property (nonatomic) double recentPeakLoad;      // worst render block since the last stats call
@property (nonatomic) double recentLoad;          // emulation time / audio time since the last stats call
@property (nonatomic) NSInteger safetyFrames;     // safety buffer target, frames
@property (nonatomic) NSInteger safetyFill;       // frames in the safety buffer now
@property (nonatomic) NSInteger safetyMinFill;    // lowest fill since the last stats call
@property (nonatomic) NSInteger audioRestarts;    // automatic output restarts (route changes, stalls)
// Two cores, since the last stats call: which thread is the limit.
@property (nonatomic) double schedulerWait;       // share of the render thread's emulation time spent waiting for DSP1
@property (nonatomic) double workerBusy;          // share of that time the DSP1 thread was executing
@property (nonatomic) double dsp2Busy;            // three cores: share of that time the DSP2 thread was executing
@property (nonatomic) BOOL threeCores;            // DSP2 runs on its own core too
@property (nonatomic) double dsp1Mips;            // DSP1 instructions per second while executing (millions)
@property (nonatomic) double footprintMB;         // app memory footprint
@property (nonatomic) double secondsPlayed;
@property (nonatomic, copy) NSString *threadStats;  // two-core timing: who waits for whom
@property (nonatomic) NSInteger midiInCount;      // MIDI messages received so far
@property (nonatomic) NSInteger midiOutCount;     // MIDI messages the Machinedrum sent so far
@end

/// Plays the real Machinedrum emulator through the iPad's audio output in real time, and is
/// the bridge for its front panel (LCD, LEDs, buttons, encoders), MIDI and saved state.
@interface MDLiveEngine : NSObject

/// Two cores only: the threads wait for each other with WFE (low power) instead of spinning.
/// Set before starting.
@property (nonatomic) BOOL lowPowerWait;

/// With the second core on: DSP2 also gets its own core (three emulation threads: ColdFire,
/// DSP1, DSP2). Set before starting.
@property (nonatomic) BOOL thirdCore;

/// Safety buffer in frames (256-4096): how far the render thread runs ahead of the output.
/// Heavy moments shorter than this are absorbed instead of heard. Set before starting.
@property (nonatomic) NSInteger safetyFrames;

/// Output gain applied after the emulator, 0...1 (the Machinedrum's analogue VOLUME knob).
@property (nonatomic) float volume;

/// Starts audio output (silence), boots the firmware off the audio thread, presses PLAY and
/// then streams the emulator. Blocks until playing or failed: call it off the main thread.
- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
                 progress:(void (^)(NSString *line))progress;

/// As above. `state` (from -copyState) restores kits, patterns, songs and settings before the
/// boot; nil starts from the machine's flash as it is. `autoPlay` presses PLAY after the boot.
- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
             restoreState:(nullable NSData *)state
                 autoPlay:(BOOL)autoPlay
                 progress:(void (^)(NSString *line))progress;

/// Stops audio and releases the emulator.
- (void)stop;

/// YES once booted and producing audio.
@property (nonatomic, readonly) BOOL isRunning;

/// Current statistics (thread-safe; resets the recent peak).
- (MDLiveStats *)stats;

/// CPU use of this app's busy threads as the kernel reports it ("total 170%; md.render 88%;
/// md.dsp1-worker 72%; ..."; 100% = one core).
+ (NSString *)threadCPUReport;

// ---- Front panel (main thread) -------------------------------------------------------------

/// Press or release a panel control. `control` is the md::PanelControl value
/// (0-15 trig keys 1-16, then the function keys in the engine's order).
- (void)setControl:(NSInteger)control pressed:(BOOL)pressed;

/// Turn an encoder by whole detents (negative = anticlockwise).
/// 0-7 = data entry A-H, 8 = LEVEL, 9 = sound selection.
- (void)turnEncoder:(NSInteger)encoder steps:(NSInteger)steps;

/// Push or release a data entry encoder (0-7).
- (void)setEncoder:(NSInteger)encoder pressed:(BOOL)pressed;

/// Copies the LCD (128 x 64 bytes, row-major, 1 = lit) and the LED state into the caller's
/// buffers. leds[0] = step LEDs 1-16 (bit n = step n+1), leds[1] = track LEDs 1-16,
/// leds[2] = status bank (page 1-3, pattern, song, routing, effects, synthesis),
/// leds[3] = mode bank (classic, extended, bank group A-D, E-H, record, tempo, page 4).
/// Returns NO when nothing changed since the last call (the buffers are then untouched).
- (BOOL)copyPanelLCD:(uint8_t *)lcd leds:(uint32_t *)leds;

// ---- MIDI ----------------------------------------------------------------------------------

/// One complete MIDI message (or SysEx, F0...F7) from any input, any thread. `hostTime` is
/// its mach_absolute_time (0 = now). Events reach the emulator one audio buffer later at
/// their original spacing, so timing is a fixed delay rather than jitter.
- (void)receiveMIDI:(const uint8_t *)bytes length:(NSUInteger)length hostTime:(uint64_t)hostTime;

/// Hands every MIDI message the Machinedrum sent to `handler` with the host time it should
/// leave at (lined up with the audio output). Call from one thread only.
- (void)drainMIDIOut:(void (NS_NOESCAPE ^)(const uint8_t *bytes, NSUInteger length, uint64_t hostTime))handler;

// ---- Saved state ---------------------------------------------------------------------------

/// Kits, patterns, songs and global settings as the Machinedrum holds them now.
- (nullable NSData *)copyState;

@end

NS_ASSUME_NONNULL_END
