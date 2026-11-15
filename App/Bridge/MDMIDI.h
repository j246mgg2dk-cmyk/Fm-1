#import <Foundation/Foundation.h>

@class MDLiveEngine;

NS_ASSUME_NONNULL_BEGIN

/// A MIDI source (we listen to it) or destination (we send to it).
@interface MDMIDIEndpoint : NSObject
@property (nonatomic, readonly) int32_t uniqueID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL enabled;
@end

/// Connects the Machinedrum to the world through CoreMIDI: every USB, Bluetooth and network
/// MIDI device, plus a virtual "Machinedrum" input and output for other apps. Incoming MIDI
/// goes to the engine with its timestamp; the Machinedrum's MIDI out (notes, CCs, clock,
/// SysEx) is sent timestamped so it lines up with the audio.
@interface MDMIDI : NSObject

- (instancetype)initWithEngine:(MDLiveEngine *)engine;

/// Creates the client, ports and virtual endpoints and starts sending. Idempotent.
- (void)start;

/// Sources currently connected or available, and destinations. Refreshed when devices come
/// and go (then onChange runs on the main thread).
@property (nonatomic, readonly, copy) NSArray<MDMIDIEndpoint *> *sources;
@property (nonatomic, readonly, copy) NSArray<MDMIDIEndpoint *> *destinations;
@property (nonatomic, copy, nullable) void (^onChange)(void);

/// Listen to / send to an endpoint (remembered across launches).
- (void)setEndpoint:(int32_t)uniqueID enabled:(BOOL)enabled;

/// MIDI over Wi-Fi (Apple network session), visible to Macs and other iPads.
@property (nonatomic) BOOL networkEnabled;

@end

NS_ASSUME_NONNULL_END
