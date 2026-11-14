#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of one engine test run on this device.
@interface MDTestResult : NSObject
@property (nonatomic) BOOL firmwareRecognised;
@property (nonatomic) BOOL deviceValid;
@property (nonatomic) BOOL usedFactoryCache;
@property (nonatomic, copy) NSString *engineMode;          // "INTERPRETER (no JIT)"
@property (nonatomic) double bootSeconds;                   // wall time to boot
@property (nonatomic) double audioSeconds;                  // audio rendered in the timed part
@property (nonatomic) double wallSeconds;                   // wall time for that audio
@property (nonatomic) double realtimeFactor;                // audio / wall
@property (nonatomic) double dspInstructionsPerAudioSecond; // millions, both DSPs
@property (nonatomic) double dspInstructionsPerWallSecond;  // millions, both DSPs
@property (nonatomic) double peak;
@property (nonatomic) double rms;
@property (nonatomic, copy) NSData *lcd;                    // 128*64 bytes, 1 = lit
@property (nonatomic, copy, nullable) NSString *wavPath;
@property (nonatomic, copy) NSString *log;
@end

/// Runs the real Machinedrum emulator (Gearmulator MD/MM engine, interpreter build) on this device.
@interface MDEngineTest : NSObject

/// Raw DSP56300 interpreter speed on a synthetic loop, in millions of instructions per second.
+ (double)measureRawDspMips;

/// True when the file is the MD 1.63 UW image the engine supports.
+ (BOOL)isSupportedFirmware:(NSString *)path;

/// Human-readable check of a candidate firmware file: whether it can be read, its size
/// against the required size, and its fingerprint against the supported MD UW 1.63 image.
+ (NSString *)describeFirmware:(NSString *)path;

/// Boots the firmware (home folder may contain nvram/md-uw-1.63-factory-v2.cache),
/// presses PLAY, renders `seconds` of audio and measures speed.
+ (MDTestResult *)runWithFirmware:(NSString *)firmwarePath
                         homePath:(NSString *)homePath
                      bootSeconds:(double)bootSeconds
                          seconds:(double)seconds
                          wavPath:(nullable NSString *)wavPath
                         progress:(void (^)(NSString *line))progress;

@end

NS_ASSUME_NONNULL_END
