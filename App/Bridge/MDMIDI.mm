#import "MDMIDI.h"
#import "MDLiveEngine.h"

#import <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>

#include <map>
#include <memory>
#include <mutex>
#include <vector>

// The packet-list API is deprecated in favour of MIDIEventList (UMP), but it is still fully
// supported and carries MIDI 1.0 bytes and SysEx directly, which is all the Machinedrum speaks.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface MDMIDIEndpoint ()
@property (nonatomic, readwrite) int32_t uniqueID;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) BOOL enabled;
@end

@implementation MDMIDIEndpoint
@end

namespace
{
	NSString* const g_disabledKey = @"MDMIDIDisabledEndpoints";
	NSString* const g_networkKey = @"MDMIDINetworkEnabled";

	// Byte-stream parser for one source: running status, SysEx across packets, and real-time
	// bytes (clock, start, stop...) that may arrive in the middle of other messages.
	struct Parser
	{
		__weak MDLiveEngine* engine = nil;
		uint8_t status = 0;
		uint8_t data[2]{};
		int count = 0;
		int need = 0;
		bool inSysex = false;
		std::vector<uint8_t> sysex;

		static int dataLength(const uint8_t _status)
		{
			if(_status < 0xf0)
				return ((_status & 0xf0) == 0xc0 || (_status & 0xf0) == 0xd0) ? 1 : 2;
			switch(_status)
			{
			case 0xf1: case 0xf3: return 1;
			case 0xf2: return 2;
			default: return 0;
			}
		}

		void emit(const uint8_t* _bytes, const size_t _len, const uint64_t _time) const
		{
			MDLiveEngine* e = engine;
			[e receiveMIDI:_bytes length:_len hostTime:_time];
		}

		void feed(const uint8_t _b, const uint64_t _time)
		{
			if(_b >= 0xf8)						// real-time: never disturbs the running message
			{
				emit(&_b, 1, _time);
				return;
			}
			if(_b == 0xf0)
			{
				sysex.clear();
				sysex.push_back(_b);
				inSysex = true;
				status = 0;
				return;
			}
			if(_b == 0xf7)
			{
				if(inSysex)
				{
					sysex.push_back(_b);
					emit(sysex.data(), sysex.size(), _time);
					inSysex = false;
				}
				return;
			}
			if(inSysex)
			{
				if(!(_b & 0x80))
				{
					if(sysex.size() < (1u << 20))
						sysex.push_back(_b);
					return;
				}
				inSysex = false;				// unterminated SysEx: drop it, take the new status
			}
			if(_b & 0x80)
			{
				status = _b;
				count = 0;
				need = dataLength(_b);
				if(need == 0)
				{
					emit(&_b, 1, _time);			// tune request etc.
					status = 0;
				}
				return;
			}
			if(!status)
				return;
			data[count++] = _b;
			if(count < need)
				return;
			const uint8_t msg[3] = {status, data[0], data[1]};
			emit(msg, size_t(1 + need), _time);
			count = 0;
			if(status >= 0xf0)
				status = 0;						// system common messages cancel running status
		}

		void feed(const MIDIPacketList* _list)
		{
			const MIDIPacket* p = &_list->packet[0];
			for(UInt32 i = 0; i < _list->numPackets; ++i)
			{
				const uint64_t t = p->timeStamp ? p->timeStamp : mach_absolute_time();
				for(UInt16 k = 0; k < p->length; ++k)
					feed(p->data[k], t);
				p = MIDIPacketNext(p);
			}
		}
	};

	NSString* endpointName(MIDIEndpointRef _e)
	{
		CFStringRef name = nullptr;
		if(MIDIObjectGetStringProperty(_e, kMIDIPropertyDisplayName, &name) == noErr && name)
			return (__bridge_transfer NSString*)name;
		return @"MIDI";
	}

	int32_t endpointID(MIDIEndpointRef _e)
	{
		SInt32 id = 0;
		MIDIObjectGetIntegerProperty(_e, kMIDIPropertyUniqueID, &id);
		return id;
	}
}

@implementation MDMIDI
{
	__weak MDLiveEngine* _engine;
	MIDIClientRef _client;
	MIDIPortRef _inPort;
	MIDIPortRef _outPort;
	MIDIEndpointRef _virtualIn;		// other apps send to the Machinedrum here
	MIDIEndpointRef _virtualOut;	// the Machinedrum's MIDI out, for other apps
	std::mutex _lock;
	// One parser per source, kept for the app's lifetime: CoreMIDI may still be delivering to
	// one while devices come and go, so they are never freed.
	std::map<int32_t, std::unique_ptr<Parser>> _parsers;
	std::vector<MIDIEndpointRef> _connected;
	std::unique_ptr<Parser> _virtualParser;
	std::vector<MIDIEndpointRef> _sendTo;
	NSMutableSet<NSNumber*>* _disabled;
	dispatch_source_t _sendTimer;
	NSArray<MDMIDIEndpoint*>* _sources;
	NSArray<MDMIDIEndpoint*>* _destinations;
}

- (instancetype)initWithEngine:(MDLiveEngine *)engine
{
	if((self = [super init]))
	{
		_engine = engine;
		NSArray* d = [NSUserDefaults.standardUserDefaults arrayForKey:g_disabledKey];
		_disabled = d ? [NSMutableSet setWithArray:d] : [NSMutableSet set];
		_sources = @[];
		_destinations = @[];
	}
	return self;
}

- (NSArray<MDMIDIEndpoint*>*)sources { return _sources; }
- (NSArray<MDMIDIEndpoint*>*)destinations { return _destinations; }

- (void)start
{
	if(_client)
		return;
	__weak MDMIDI* weakSelf = self;
	if(MIDIClientCreateWithBlock(CFSTR("Machinedrum"), &_client, ^(const MIDINotification* n)
		{
			if(n->messageID == kMIDIMsgSetupChanged)
				dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
		}) != noErr)
	{
		_client = 0;
		return;
	}

	MIDIInputPortCreateWithBlock(_client, CFSTR("Machinedrum In"), &_inPort,
		^(const MIDIPacketList* list, void* refCon)
		{
			if(auto* parser = static_cast<Parser*>(refCon))
				parser->feed(list);
		});
	MIDIOutputPortCreate(_client, CFSTR("Machinedrum Out"), &_outPort);

	_virtualParser = std::make_unique<Parser>();
	_virtualParser->engine = _engine;
	Parser* vp = _virtualParser.get();
	MIDIDestinationCreateWithBlock(_client, CFSTR("Machinedrum"), &_virtualIn,
		^(const MIDIPacketList* list, void*) { vp->feed(list); });
	MIDISourceCreate(_client, CFSTR("Machinedrum"), &_virtualOut);

	self.networkEnabled = [NSUserDefaults.standardUserDefaults boolForKey:g_networkKey];
	[self refresh];

	// Sender: every millisecond, hand the Machinedrum's MIDI out to CoreMIDI with the time
	// stamps the engine gave it (lined up with the audio output). CoreMIDI delivers on time.
	dispatch_queue_t q = dispatch_queue_create("md.midi.out",
		dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
	_sendTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, q);
	dispatch_source_set_timer(_sendTimer, DISPATCH_TIME_NOW, NSEC_PER_MSEC, 100 * NSEC_PER_USEC);
	dispatch_source_set_event_handler(_sendTimer, ^{ [weakSelf sendPending]; });
	dispatch_resume(_sendTimer);
}

- (void)sendPending
{
	MDLiveEngine* engine = _engine;
	if(!engine)
		return;
	struct Msg { uint64_t time; std::vector<uint8_t> bytes; };
	__block std::vector<Msg> msgs;
	[engine drainMIDIOut:^(const uint8_t* bytes, NSUInteger length, uint64_t hostTime)
	{
		msgs.push_back({hostTime, std::vector<uint8_t>(bytes, bytes + length)});
	}];
	if(msgs.empty())
		return;
	std::vector<MIDIEndpointRef> targets;
	{
		std::lock_guard lock(_lock);
		targets = _sendTo;
	}
	alignas(8) static thread_local Byte buffer[65536];
	auto* list = reinterpret_cast<MIDIPacketList*>(buffer);
	MIDIPacket* packet = MIDIPacketListInit(list);
	bool any = false;
	auto flush = [&]
	{
		if(!any)
			return;
		for(auto dst : targets)
			MIDISend(_outPort, dst, list);
		if(_virtualOut)
			MIDIReceived(_virtualOut, list);
		packet = MIDIPacketListInit(list);
		any = false;
	};
	for(const auto& m : msgs)
	{
		// Long SysEx is split into chunks; receivers reassemble the byte stream.
		size_t done = 0;
		while(done < m.bytes.size())
		{
			const size_t chunk = std::min<size_t>(m.bytes.size() - done, 1024);
			MIDIPacket* next = MIDIPacketListAdd(list, sizeof(buffer), packet, m.time, chunk, m.bytes.data() + done);
			if(!next)
			{
				flush();
				next = MIDIPacketListAdd(list, sizeof(buffer), packet, m.time, chunk, m.bytes.data() + done);
				if(!next)
					break;
			}
			packet = next;
			any = true;
			done += chunk;
		}
	}
	flush();
}

- (void)refresh
{
	if(!_client)
		return;
	NSMutableArray<MDMIDIEndpoint*>* sources = [NSMutableArray array];
	NSMutableArray<MDMIDIEndpoint*>* destinations = [NSMutableArray array];
	std::vector<MIDIEndpointRef> sendTo;
	{
		std::lock_guard lock(_lock);
		for(auto src : _connected)
			MIDIPortDisconnectSource(_inPort, src);
		_connected.clear();

		const ItemCount ns = MIDIGetNumberOfSources();
		for(ItemCount i = 0; i < ns; ++i)
		{
			const MIDIEndpointRef src = MIDIGetSource(i);
			if(!src || src == _virtualOut)
				continue;
			MDMIDIEndpoint* e = [MDMIDIEndpoint new];
			e.uniqueID = endpointID(src);
			e.name = endpointName(src);
			e.enabled = ![_disabled containsObject:@(e.uniqueID)];
			[sources addObject:e];
			if(!e.enabled)
				continue;
			auto& parser = _parsers[e.uniqueID];
			if(!parser)
			{
				parser = std::make_unique<Parser>();
				parser->engine = _engine;
			}
			if(MIDIPortConnectSource(_inPort, src, parser.get()) == noErr)
				_connected.push_back(src);
		}
		const ItemCount nd = MIDIGetNumberOfDestinations();
		for(ItemCount i = 0; i < nd; ++i)
		{
			const MIDIEndpointRef dst = MIDIGetDestination(i);
			if(!dst || dst == _virtualIn)
				continue;
			MDMIDIEndpoint* e = [MDMIDIEndpoint new];
			e.uniqueID = endpointID(dst);
			e.name = endpointName(dst);
			e.enabled = ![_disabled containsObject:@(e.uniqueID)];
			[destinations addObject:e];
			if(e.enabled)
				sendTo.push_back(dst);
		}
		_sendTo = sendTo;
	}
	_sources = sources;
	_destinations = destinations;
	if(self.onChange)
		self.onChange();
}

- (void)setEndpoint:(int32_t)uniqueID enabled:(BOOL)enabled
{
	if(enabled)
		[_disabled removeObject:@(uniqueID)];
	else
		[_disabled addObject:@(uniqueID)];
	[NSUserDefaults.standardUserDefaults setObject:_disabled.allObjects forKey:g_disabledKey];
	[self refresh];
}

- (BOOL)networkEnabled
{
	return MIDINetworkSession.defaultSession.enabled;
}

- (void)setNetworkEnabled:(BOOL)networkEnabled
{
	MIDINetworkSession* s = MIDINetworkSession.defaultSession;
	s.enabled = networkEnabled;
	s.connectionPolicy = MIDINetworkConnectionPolicy_Anyone;
	[NSUserDefaults.standardUserDefaults setBool:networkEnabled forKey:g_networkKey];
}

- (void)dealloc
{
	if(_sendTimer)
		dispatch_source_cancel(_sendTimer);
	if(_client)
		MIDIClientDispose(_client);
}

@end
