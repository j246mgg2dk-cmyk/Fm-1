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
@property (nonatomic) NSInteger overruns;         // callbacks that took longer than their buffer
@property (nonatomic) double averageLoad;         // render time / buffer duration, 0..1+
@property (nonatomic) double peakLoad;
@property (nonatomic) double recentPeakLoad;      // peak over the last ~second
@property (nonatomic) double footprintMB;         // app memory footprint
@property (nonatomic) double secondsPlayed;
@property (nonatomic, copy) NSString *threadStats;  // two-core timing: who waits for whom
@end

/// Plays the real Machinedrum emulator through the iPad's audio output in real time.
@interface MDLiveEngine : NSObject

/// Starts audio output (silence), boots the firmware off the audio thread, presses PLAY and
/// then streams the emulator. Blocks until playing or failed: call it off the main thread.
- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
                 progress:(void (^)(NSString *line))progress;

/// Stops audio and releases the emulator.
- (void)stop;

/// Current statistics (thread-safe; resets the recent peak).
- (MDLiveStats *)stats;

@end

NS_ASSUME_NONNULL_END
