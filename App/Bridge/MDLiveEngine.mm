#import "MDLiveEngine.h"

#import <AVFoundation/AVFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/workgroup.h>

#include "mdLib/mddevice.h"
#include "mdLib/mdhardware.h"
#include "mdLib/mdpanel.h"
#include "mdLib/mdromloader.h"
#include "mdLib/mdtypes.h"
#include "baseLib/filesystem.h"
#include "synthLib/plugin.h"

#include <array>
#include <atomic>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

@implementation MDLiveStats
@end

namespace
{
	constexpr double g_emuRate = 44100.0;
	constexpr uint32_t g_maxFrames = 4096;

	double footprintMB()
	{
		task_vm_info_data_t info{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		if(task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
			return 0;
		return double(info.phys_footprint) / (1024.0 * 1024.0);
	}

	double machToSeconds(uint64_t _ticks)
	{
		static const double scale = []
		{
			mach_timebase_info_data_t tb{};
			mach_timebase_info(&tb);
			return double(tb.numer) / double(tb.denom) * 1e-9;
		}();
		return double(_ticks) * scale;
	}

	// Workgroup of the current audio output; the DSP worker thread joins it so the
	// scheduler treats it as part of the real-time audio work (P-core placement, clocks).
	os_workgroup_t g_audioWorkgroup = nullptr;
	std::atomic<bool> g_workgroupJoined{false};

	struct WorkgroupMembership
	{
		os_workgroup_t group = nullptr;
		os_workgroup_join_token_s token{};
		~WorkgroupMembership() { if(group) os_workgroup_leave(group, &token); }
	};
	thread_local WorkgroupMembership t_membership;

	// One short MIDI message (status + up to two data bytes) with its host time.
	struct ShortMidi
	{
		uint64_t time = 0;
		uint8_t len = 0;
		uint8_t bytes[3]{};
	};

	// Single-producer single-consumer ring (MIDI thread <-> audio thread).
	template<size_t N> struct MidiRing
	{
		static_assert((N & (N - 1)) == 0, "power of two");
		std::array<ShortMidi, N> buf{};
		alignas(128) std::atomic<size_t> w{0};
		alignas(128) std::atomic<size_t> r{0};

		bool push(const ShortMidi& _m)
		{
			const size_t wi = w.load(std::memory_order_relaxed);
			if(wi - r.load(std::memory_order_acquire) >= N)
				return false;
			buf[wi & (N - 1)] = _m;
			w.store(wi + 1, std::memory_order_release);
			return true;
		}
		bool pop(ShortMidi& _m)
		{
			const size_t ri = r.load(std::memory_order_relaxed);
			if(ri == w.load(std::memory_order_acquire))
				return false;
			_m = buf[ri & (N - 1)];
			r.store(ri + 1, std::memory_order_release);
			return true;
		}
	};

	struct SysexMessage
	{
		uint64_t time = 0;
		std::vector<uint8_t> bytes;
	};

	uint64_t secondsToMach(const double _s)
	{
		static const double scale = []
		{
			mach_timebase_info_data_t tb{};
			mach_timebase_info(&tb);
			return double(tb.denom) / double(tb.numer) * 1e9;
		}();
		return uint64_t(_s * scale);
	}

	// Everything the audio callback touches. Owned by MDLiveEngine; the render block
	// holds a raw pointer that stays valid until the engine is stopped.
	struct LiveState
	{
		std::unique_ptr<md::Device> device;
		std::unique_ptr<synthLib::Plugin> plugin;
		std::array<std::array<float, g_maxFrames>, 6> out{};
		std::array<float, g_maxFrames> inL{}, inR{};
		std::atomic<bool> ready{false};

		std::atomic<int64_t> callbacks{0}, overruns{0};
		std::atomic<int64_t> framesPlayed{0};
		std::atomic<double> loadSum{0}, peakLoad{0}, recentPeak{0};
		std::atomic<int64_t> lastFrames{0};
		std::atomic<double> rate{48000};
		std::atomic<float> volume{1.0f};

		// MIDI. In: short messages through a ring (the producer side is serialised by
		// midiInProducer), SysEx through a locked queue. Out: the same in reverse.
		MidiRing<1024> midiIn;
		std::mutex midiInProducer;
		std::mutex sysexInLock;
		std::deque<SysexMessage> sysexIn;
		MidiRing<4096> midiOut;
		std::mutex sysexOutLock;
		std::deque<SysexMessage> sysexOut;
		std::vector<synthLib::SMidiEvent> midiOutScratch;
		std::vector<SysexMessage> sysexInScratch;
		uint64_t lastCallbackTime = 0;
		std::atomic<int64_t> midiInCount{0}, midiOutCount{0};

		// Front panel (main thread only).
		md::PanelRowState panelRows;
		md::FrontPanel panelSnapshot;
		uint64_t panelHash = 0;

		void deliverMidiIn(const uint32_t _frames, const uint64_t _now)
		{
			// Map arrival times inside the previous callback period onto this block:
			// a constant one-buffer delay that keeps the original spacing.
			const uint64_t start = lastCallbackTime ? lastCallbackTime : _now;
			const double window = double(std::max<uint64_t>(_now - start, 1));
			auto offsetOf = [&](uint64_t _t)
			{
				if(!_t || _t > _now) _t = _now;
				if(_t < start) _t = start;
				const double f = double(_t - start) / window * double(_frames);
				return std::min<uint32_t>(uint32_t(f), _frames ? _frames - 1 : 0);
			};
			ShortMidi m;
			while(midiIn.pop(m))
			{
				synthLib::SMidiEvent ev;
				ev.assignRawData(m.bytes, m.len, synthLib::MidiEventSource::Physical, offsetOf(m.time));
				plugin->addMidiEvent(ev);
			}
			{
				std::unique_lock lock(sysexInLock, std::try_to_lock);
				if(lock.owns_lock())
				{
					while(!sysexIn.empty())
					{
						sysexInScratch.push_back(std::move(sysexIn.front()));
						sysexIn.pop_front();
					}
				}
			}
			for(auto& sx : sysexInScratch)
			{
				synthLib::SMidiEvent ev;
				ev.assignRawData(sx.bytes.data(), sx.bytes.size(), synthLib::MidiEventSource::Physical, offsetOf(sx.time));
				plugin->addMidiEvent(ev);
			}
			sysexInScratch.clear();
			lastCallbackTime = _now;
		}

		void collectMidiOut(const uint32_t _frames, const uint64_t _outputTime, const double _sampleRate)
		{
			midiOutScratch.clear();
			plugin->getMidiOut(midiOutScratch);
			for(const auto& ev : midiOutScratch)
			{
				const uint64_t t = _outputTime + secondsToMach(double(std::min(ev.offset, _frames)) / _sampleRate);
				midiOutCount.fetch_add(1, std::memory_order_relaxed);
				if(!ev.sysex.empty())
				{
					std::lock_guard lock(sysexOutLock);
					sysexOut.push_back({t, std::vector<uint8_t>(ev.sysex.begin(), ev.sysex.end())});
					continue;
				}
				ShortMidi m;
				m.time = t;
				m.bytes[0] = ev.a; m.bytes[1] = ev.b; m.bytes[2] = ev.c;
				const uint8_t st = ev.a;
				m.len = st >= 0xf8 ? 1 : (st == 0xf1 || st == 0xf3) ? 2 : st == 0xf2 ? 3
					: (st & 0xf0) == 0xc0 || (st & 0xf0) == 0xd0 ? 2 : 3;
				midiOut.push(m);
			}
		}

		void render(const uint32_t _frames, float* _left, float* _right, const double _sampleRate,
			const uint64_t _outputTime = 0)
		{
			if(!ready.load(std::memory_order_acquire))
			{
				std::fill_n(_left, _frames, 0.0f);
				std::fill_n(_right, _frames, 0.0f);
				return;
			}
			const uint64_t t0 = mach_absolute_time();
			deliverMidiIn(std::min(_frames, g_maxFrames), t0);
			uint32_t done = 0;
			while(done < _frames)
			{
				const uint32_t n = std::min(_frames - done, g_maxFrames);
				const synthLib::TAudioInputs inputs{inL.data(), inR.data(), nullptr, nullptr};
				synthLib::TAudioOutputs outputs{};
				for(size_t c = 0; c < out.size(); ++c) outputs[c] = out[c].data();
				plugin->process(inputs, outputs, n, 120.0f, 0, false);
				const float g = volume.load(std::memory_order_relaxed);
				for(uint32_t i = 0; i < n; ++i)
				{
					_left[done + i] = out[0][i] * g;
					_right[done + i] = out[1][i] * g;
				}
				done += n;
			}
			collectMidiOut(_frames, _outputTime ? _outputTime : t0, _sampleRate);
			const double seconds = machToSeconds(mach_absolute_time() - t0);
			const double load = seconds / (double(_frames) / _sampleRate);
			callbacks.fetch_add(1, std::memory_order_relaxed);
			framesPlayed.fetch_add(_frames, std::memory_order_relaxed);
			lastFrames.store(_frames, std::memory_order_relaxed);
			rate.store(_sampleRate, std::memory_order_relaxed);
			if(load > 1.0)
				overruns.fetch_add(1, std::memory_order_relaxed);
			loadSum.store(loadSum.load(std::memory_order_relaxed) + load, std::memory_order_relaxed);
			if(load > peakLoad.load(std::memory_order_relaxed)) peakLoad.store(load, std::memory_order_relaxed);
			if(load > recentPeak.load(std::memory_order_relaxed)) recentPeak.store(load, std::memory_order_relaxed);
		}
	};
}

@implementation MDLiveEngine
{
	AVAudioEngine* _engine;
	AVAudioSourceNode* _source;
	// Shared so MIDI threads can hold the state while they use it (std::atomic_load/store).
	std::shared_ptr<LiveState> _state;
	BOOL _secondCore;
	float _volume;
	id _interruptionObserver;
}

- (void)resumeAudio
{
	if(!_engine)
		return;
	[[AVAudioSession sharedInstance] setActive:YES error:nil];
	if(!_engine.isRunning)
		[_engine startAndReturnError:nil];
}

- (instancetype)init
{
	if((self = [super init]))
		_volume = 1.0f;
	return self;
}

- (float)volume { return _volume; }

- (void)setVolume:(float)volume
{
	_volume = std::max(0.0f, std::min(1.0f, volume));
	if(const auto st = std::atomic_load(&_state))
		st->volume.store(_volume, std::memory_order_relaxed);
}

- (BOOL)isRunning
{
	const auto st = std::atomic_load(&_state);
	return st && st->ready.load(std::memory_order_acquire);
}

- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
                 progress:(void (^)(NSString *))progress
{
	return [self startWithFirmware:firmwarePath homePath:homePath secondCore:secondCore
		bufferFrames:bufferFrames restoreState:nil autoPlay:YES progress:progress];
}

- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
             restoreState:(NSData *)restoreState
                 autoPlay:(BOOL)autoPlay
                 progress:(void (^)(NSString *))progress
{
	[self stop];
	_secondCore = secondCore;
	auto state = std::make_shared<LiveState>();
	LiveState* const s = state.get();

	// 1. Audio output first (silence), so the workgroup exists before the DSP worker starts.
	NSError* err = nil;
	AVAudioSession* session = [AVAudioSession sharedInstance];
	// Playback that keeps running in the background and mixes with other apps' audio.
	[session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
	[session setPreferredSampleRate:g_emuRate error:nil];
	[session setPreferredIOBufferDuration:double(bufferFrames) / g_emuRate error:nil];
	[session setActive:YES error:&err];
	if(err)
	{
		progress([NSString stringWithFormat:@"Audio session error: %@", err.localizedDescription]);
		return NO;
	}

	AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:g_emuRate channels:2];
	_engine = [AVAudioEngine new];
	_source = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
		^OSStatus(BOOL* isSilence, const AudioTimeStamp* ts, AVAudioFrameCount frameCount, AudioBufferList* abl)
		{
			if(abl->mNumberBuffers < 2 || frameCount == 0)
				return noErr;
			const uint64_t outputTime = (ts && (ts->mFlags & kAudioTimeStampHostTimeValid)) ? ts->mHostTime : 0;
			s->render(frameCount, static_cast<float*>(abl->mBuffers[0].mData),
				static_cast<float*>(abl->mBuffers[1].mData), g_emuRate, outputTime);
			*isSilence = NO;
			return noErr;
		}];
	[_engine attachNode:_source];
	[_engine connect:_source to:_engine.mainMixerNode format:format];
	if(![_engine startAndReturnError:&err])
	{
		progress([NSString stringWithFormat:@"Could not start audio: %@", err.localizedDescription]);
		_engine = nil; _source = nil;
		return NO;
	}
	// Calls, Siri and other apps can interrupt audio; start again when they're done.
	__weak MDLiveEngine* weakSelf = self;
	_interruptionObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification
		object:session queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* n)
		{
			const auto type = AVAudioSessionInterruptionType([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]);
			if(type == AVAudioSessionInterruptionTypeEnded)
				[weakSelf resumeAudio];
		}];
	progress([NSString stringWithFormat:@"Audio running: %.0f Hz hardware, %.1f ms buffer requested (%ld frames).",
		session.sampleRate, session.IOBufferDuration * 1000.0, long(bufferFrames)]);

	// 2. The DSP worker joins the output's audio workgroup when it starts.
	g_workgroupJoined = false;
	g_audioWorkgroup = nullptr;
	if(@available(iOS 14.0, *))
		g_audioWorkgroup = _engine.outputNode.AUAudioUnit.osWorkgroup;
	md::Hardware::setDspWorkerThreadStartHook([]
	{
		if(!g_audioWorkgroup)
			return;
		if(os_workgroup_join(g_audioWorkgroup, &t_membership.token) == 0)
		{
			t_membership.group = g_audioWorkgroup;
			g_workgroupJoined = true;
		}
	});

	// 3. Boot the Machinedrum off the audio thread.
	setenv("GEARMULATOR_MD_DSP_WORKER", secondCore ? "1" : "0", 1);
	setenv("GEARMULATOR_MD_DSP_SKEW", "2", 1);
	setenv("GEARMULATOR_MD_LOW_POWER_WAIT", self.lowPowerWait ? "1" : "0", 1);
	std::vector<uint8_t> fw;
	if(!baseLib::filesystem::readFile(fw, firmwarePath.UTF8String))
	{
		progress(@"Could not read the firmware.");
		[self stop];
		return NO;
	}
	synthLib::DeviceCreateParams params;
	params.romData = fw;
	params.romName = firmwarePath.UTF8String;
	params.customData = md::deviceCustomData(md::MachineModel::Machinedrum);
	params.homePath = std::string(homePath.UTF8String) + "/";
	s->device = std::make_unique<md::Device>(params);
	if(!s->device->isValid())
	{
		progress(@"The engine could not create a Machinedrum from this firmware.");
		[self stop];
		return NO;
	}
	if(restoreState.length)
	{
		const auto* b = static_cast<const uint8_t*>(restoreState.bytes);
		const std::vector<uint8_t> st(b, b + restoreState.length);
		const bool ok = s->device->setState(st, synthLib::StateTypeGlobal);
		progress(ok ? @"Restored your kits, patterns and songs."
			: [NSString stringWithFormat:@"Could not restore the saved state (%s); starting from the machine's own memory.",
				s->device->projectStateRestoreError().c_str()]);
	}
	s->volume.store(_volume, std::memory_order_relaxed);
	s->plugin = std::make_unique<synthLib::Plugin>(s->device.get(), [](synthLib::Device*) {});
	s->plugin->reserveMidiEventCapacity();
	s->plugin->setHostSamplerate(float(g_emuRate), float(g_emuRate));
	s->plugin->setBlockSize(g_maxFrames);

	const synthLib::TAudioInputs inputs{s->inL.data(), s->inR.data(), nullptr, nullptr};
	synthLib::TAudioOutputs outputs{};
	for(size_t c = 0; c < s->out.size(); ++c) outputs[c] = s->out[c].data();
	constexpr uint32_t block = 128;
	progress(@"Booting the Machinedrum (12 s of machine time)…");
	for(int i = 0; i < int(g_emuRate * 12 / block); ++i)
		s->plugin->process(inputs, outputs, block, 120.0f, 0, false);
	if(auto play = autoPlay ? md::panelPacket(md::MachineModel::Machinedrum, md::PanelControl::Play) : std::nullopt)
	{
		s->device->getHardware().sendPanelEvent(play->row, play->mask);
		for(int i = 0; i < 20; ++i) s->plugin->process(inputs, outputs, block, 120.0f, 0, false);
		s->device->getHardware().sendPanelEvent(play->row, 0);
	}
	const bool threaded = s->device->getHardware().isDspThreaded();
	progress(secondCore
		? (threaded ? @"DSP1 is running on a second core." : @"Second core requested but not active.")
		: @"Running on one core.");
	if(secondCore)
		progress(g_workgroupJoined ? @"The DSP worker joined the audio workgroup." : @"The DSP worker could not join the audio workgroup (it still runs at high priority).");

	// 4. Hand over to the audio thread.
	std::atomic_store(&_state, state);
	state->ready.store(true, std::memory_order_release);
	progress(@"Playing live. Listen for clicks or dropouts; the numbers update every second.");
	return YES;
}

- (void)stop
{
	if(_interruptionObserver)
	{
		[NSNotificationCenter.defaultCenter removeObserver:_interruptionObserver];
		_interruptionObserver = nil;
	}
	if(const auto st = std::atomic_load(&_state))
		st->ready.store(false, std::memory_order_release);
	if(_engine)
	{
		[_engine stop];
		_engine = nil;
		_source = nil;
	}
	std::atomic_store(&_state, std::shared_ptr<LiveState>());	// joins the DSP worker (Device -> Hardware destructor)
	md::Hardware::setDspWorkerThreadStartHook({});
	unsetenv("GEARMULATOR_MD_DSP_WORKER");
	unsetenv("GEARMULATOR_MD_DSP_SKEW");
	unsetenv("GEARMULATOR_MD_LOW_POWER_WAIT");
}

- (MDLiveStats *)stats
{
	MDLiveStats* r = [MDLiveStats new];
	r.footprintMB = footprintMB();
	r.workgroupJoined = g_workgroupJoined;
	const auto st = std::atomic_load(&_state);
	if(!st)
		return r;
	auto& s = *st;
	r.running = s.ready.load();
	r.secondCore = s.device && s.device->getHardware().isDspThreaded();
	r.callbacks = s.callbacks.load();
	r.overruns = s.overruns.load();
	r.averageLoad = r.callbacks ? s.loadSum.load() / double(r.callbacks) : 0;
	r.peakLoad = s.peakLoad.load();
	r.recentPeakLoad = s.recentPeak.exchange(0);
	r.bufferFrames = s.lastFrames.load();
	r.sampleRate = s.rate.load();
	r.secondsPlayed = double(s.framesPlayed.load()) / g_emuRate;
	r.threadStats = (s.device && r.secondCore)
		? [NSString stringWithUTF8String:s.device->getHardware().dspWorkerStats().c_str()] : @"";
	r.midiInCount = s.midiInCount.load();
	r.midiOutCount = s.midiOutCount.load();
	return r;
}

// ---- Front panel -----------------------------------------------------------------------------

- (void)setControl:(NSInteger)control pressed:(BOOL)pressed
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->ready.load(std::memory_order_acquire) || control < 0 || control > NSInteger(md::PanelControl::ClassicExtended))
		return;
	const auto packet = md::panelPacket(md::MachineModel::Machinedrum, md::PanelControl(control));
	if(!packet)
		return;
	auto& s = *st;
	const auto combined = pressed ? s.panelRows.press(*packet) : s.panelRows.release(*packet);
	s.device->getHardware().sendPanelEvent(combined.row, combined.mask);
}

- (void)turnEncoder:(NSInteger)encoder steps:(NSInteger)steps
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->ready.load(std::memory_order_acquire) || steps == 0 || encoder < 0 || encoder > NSInteger(md::PanelEncoder::SoundSelection))
		return;
	const auto command = md::panelEncoderCommand(md::MachineModel::Machinedrum, md::PanelEncoder(encoder));
	if(!command)
		return;
	const uint8_t argument = steps > 0 ? 0x01 : 0xff;
	const NSInteger count = std::min<NSInteger>(std::abs(steps), 16);
	for(NSInteger i = 0; i < count; ++i)
		st->device->getHardware().sendPanelEvent(*command, argument);
}

- (void)setEncoder:(NSInteger)encoder pressed:(BOOL)pressed
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->ready.load(std::memory_order_acquire) || encoder < 0 || encoder > NSInteger(md::PanelEncoder::DataEntryH))
		return;
	const auto packet = md::panelEncoderPressPacket(md::MachineModel::Machinedrum, md::PanelEncoder(encoder));
	if(!packet)
		return;
	auto& s = *st;
	const auto combined = pressed ? s.panelRows.press(*packet) : s.panelRows.release(*packet);
	s.device->getHardware().sendPanelEvent(combined.row, combined.mask);
}

- (BOOL)copyPanelLCD:(uint8_t *)lcd leds:(uint32_t *)leds
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->device)
		return NO;
	auto& s = *st;
	if(!s.device->getHardware().tryGetFrontPanelSnapshot(s.panelSnapshot))
		return NO;
	const auto& p = s.panelSnapshot;
	uint64_t h = 1469598103934665603ull;
	auto mix = [&](uint64_t v) { h = (h ^ v) * 1099511628211ull; };
	for(uint32_t half = 0; half < 2; ++half)
		for(uint32_t page = 0; page < 8; ++page)
			for(uint32_t col = 0; col < 64; ++col)
				mix(p.getLcdVram(half, page, col));
	uint32_t l[4]{};
	l[0] = uint32_t(uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Step0)))
		| uint32_t(uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Step1))) << 8;
	l[1] = uint32_t(uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Drum0)))
		| uint32_t(uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Drum1))) << 8;
	l[2] = uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Status));
	l[3] = uint8_t(~p.getLedBankRaw(md::FrontPanel::LedBank::Mode));
	for(auto v : l) mix(v);
	if(h == s.panelHash)
		return NO;
	s.panelHash = h;
	for(uint32_t y = 0; y < 64; ++y)
		for(uint32_t x = 0; x < 128; ++x)
			lcd[y * 128 + x] = p.getLcdPixel(x, y) ? 1 : 0;
	for(int i = 0; i < 4; ++i)
		leds[i] = l[i];
	return YES;
}

// ---- MIDI ----------------------------------------------------------------------------------

- (void)receiveMIDI:(const uint8_t *)bytes length:(NSUInteger)length hostTime:(uint64_t)hostTime
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->ready.load(std::memory_order_acquire) || !bytes || !length)
		return;
	auto& s = *st;
	s.midiInCount.fetch_add(1, std::memory_order_relaxed);
	if(bytes[0] == 0xf0 || length > 3)
	{
		std::lock_guard lock(s.sysexInLock);
		s.sysexIn.push_back({hostTime, std::vector<uint8_t>(bytes, bytes + length)});
		return;
	}
	ShortMidi m;
	m.time = hostTime;
	m.len = uint8_t(length);
	std::copy_n(bytes, length, m.bytes);
	std::lock_guard lock(s.midiInProducer);
	s.midiIn.push(m);
}

- (void)drainMIDIOut:(void (NS_NOESCAPE ^)(const uint8_t *, NSUInteger, uint64_t))handler
{
	const auto st = std::atomic_load(&_state);
	if(!st)
		return;
	auto& s = *st;
	ShortMidi m;
	while(s.midiOut.pop(m))
		handler(m.bytes, m.len, m.time);
	std::deque<SysexMessage> sx;
	{
		std::lock_guard lock(s.sysexOutLock);
		sx.swap(s.sysexOut);
	}
	for(auto& x : sx)
		handler(x.bytes.data(), x.bytes.size(), x.time);
}

// ---- Saved state ---------------------------------------------------------------------------

- (NSData *)copyState
{
	const auto st = std::atomic_load(&_state);
	if(!st || !st->ready.load(std::memory_order_acquire))
		return nil;
	std::vector<uint8_t> data;
	if(!st->device->getState(data, synthLib::StateTypeGlobal) || data.empty())
		return nil;
	return [NSData dataWithBytes:data.data() length:data.size()];
}

- (void)dealloc
{
	[self stop];
}

@end
