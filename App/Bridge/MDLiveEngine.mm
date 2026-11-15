#import "MDLiveEngine.h"

#import <AVFoundation/AVFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <mach/task.h>
#include <os/workgroup.h>
#include <pthread.h>

#include "mdLib/mddevice.h"
#include "mdLib/mdhardware.h"
#include "mdLib/mdpanel.h"
#include "mdLib/mdromloader.h"
#include "mdLib/mdtypes.h"
#include "baseLib/filesystem.h"
#include "synthLib/plugin.h"

#include <algorithm>
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
	constexpr uint32_t g_renderBlock = 256;			// frames the render thread produces per step
	constexpr uint32_t g_fifoFrames = 16384;		// capacity of the safety buffer (power of two)

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

	uint64_t secondsToMach(const double _s)
	{
		static const double scale = []
		{
			mach_timebase_info_data_t tb{};
			mach_timebase_info(&tb);
			return double(tb.denom) / double(tb.numer) * 1e9;
		}();
		return uint64_t(std::max(0.0, _s) * scale);
	}

	// Workgroup of the current audio output; the render thread and the DSP worker join it so
	// the scheduler treats them as part of the real-time audio work (P-core placement, clocks).
	os_workgroup_t g_audioWorkgroup = nullptr;
	std::atomic<bool> g_workgroupJoined{false};

	struct WorkgroupMembership
	{
		os_workgroup_t group = nullptr;
		os_workgroup_join_token_s token{};
		~WorkgroupMembership() { if(group) os_workgroup_leave(group, &token); }
	};
	thread_local WorkgroupMembership t_membership;

	bool joinAudioWorkgroup()
	{
		if(!g_audioWorkgroup || t_membership.group)
			return t_membership.group != nullptr;
		if(os_workgroup_join(g_audioWorkgroup, &t_membership.token) != 0)
			return false;
		t_membership.group = g_audioWorkgroup;
		return true;
	}

	// One short MIDI message (status + up to two data bytes) with its host time.
	struct ShortMidi
	{
		uint64_t time = 0;
		uint8_t len = 0;
		uint8_t bytes[3]{};
	};

	// Single-producer single-consumer ring (MIDI thread <-> render thread).
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

	// A MIDI message waiting for the block whose output time covers it.
	struct PendingMidi
	{
		uint64_t due = 0;				// host time it should sound at
		std::vector<uint8_t> bytes;
	};

	// Everything the audio threads touch. Owned by MDLiveEngine (shared with the MIDI threads).
	//
	// Threads:
	//  - render thread: runs the emulator ahead of the output into a stereo FIFO (the safety
	//    buffer), so a heavy moment (a burst of knob turns, a kit change) is absorbed rather
	//    than heard. It schedules incoming MIDI by output time and time-stamps MIDI out.
	//  - CoreAudio IO thread: only copies from the FIFO. It can never be made late by the
	//    emulator, and a short FIFO costs a click, never a stalled output.
	struct LiveState
	{
		std::unique_ptr<md::Device> device;
		std::unique_ptr<synthLib::Plugin> plugin;
		std::array<std::array<float, g_maxFrames>, 6> out{};
		std::array<float, g_maxFrames> inL{}, inR{};
		std::atomic<bool> ready{false};
		std::atomic<float> volume{1.0f};

		// ---- Safety buffer -------------------------------------------------------------
		std::vector<float> fifoL = std::vector<float>(g_fifoFrames), fifoR = std::vector<float>(g_fifoFrames);
		alignas(128) std::atomic<uint64_t> fifoWrite{0};
		alignas(128) std::atomic<uint64_t> fifoRead{0};
		uint32_t safetyFrames = 768;					// fill the render thread keeps ahead
		std::atomic<bool> primed{false};				// output starts once the buffer is full
		semaphore_t wake = 0;							// callback -> render thread
		pthread_t renderThread{};
		bool renderThreadStarted = false;
		std::atomic<bool> renderRun{false};

		// Output clock: the host time at which FIFO sample `anchorIndex` plays, as last seen
		// by the IO callback (sequence-locked pair).
		std::atomic<uint32_t> anchorSeq{0};
		uint64_t anchorIndex = 0;
		uint64_t anchorTime = 0;

		// ---- Statistics ----------------------------------------------------------------
		std::atomic<int64_t> callbacks{0}, underruns{0}, framesPlayed{0}, lastFrames{0};
		std::atomic<double> rate{48000};
		std::atomic<double> busySeconds{0}, renderedSeconds{0};		// render thread, totals
		std::atomic<double> windowBusy{0}, windowAudio{0};				// since the last stats read
		std::atomic<double> peakBlockLoad{0}, recentPeakBlockLoad{0};
		std::atomic<int64_t> fifoMin{g_fifoFrames};					// lowest fill seen recently
		std::atomic<int64_t> audioRestarts{0};

		// ---- MIDI ----------------------------------------------------------------------
		MidiRing<1024> midiIn;
		std::mutex midiInProducer;
		std::mutex sysexInLock;
		std::deque<SysexMessage> sysexIn;
		MidiRing<4096> midiOut;
		std::mutex sysexOutLock;
		std::deque<SysexMessage> sysexOut;
		std::vector<synthLib::SMidiEvent> midiOutScratch;
		std::vector<PendingMidi> pending;				// render thread only
		std::atomic<int64_t> midiInCount{0}, midiOutCount{0};

		// ---- Front panel (main thread only) ---------------------------------------------
		md::PanelRowState panelRows;
		md::FrontPanel panelSnapshot;
		uint64_t panelHash = 0;

		LiveState()
		{
			semaphore_create(mach_task_self(), &wake, SYNC_POLICY_FIFO, 0);
			pending.reserve(256);
			midiOutScratch.reserve(256);
		}

		~LiveState()
		{
			stopRenderThread();
			if(wake)
				semaphore_destroy(mach_task_self(), wake);
		}

		uint32_t fill() const
		{
			return uint32_t(fifoWrite.load(std::memory_order_acquire) - fifoRead.load(std::memory_order_acquire));
		}

		// Host time at which FIFO sample _index will play (0 if the output hasn't run yet).
		uint64_t playTime(const uint64_t _index) const
		{
			for(;;)
			{
				const uint32_t s0 = anchorSeq.load(std::memory_order_acquire);
				if(s0 & 1)
					continue;
				const uint64_t idx = anchorIndex, t = anchorTime;
				std::atomic_thread_fence(std::memory_order_acquire);
				if(anchorSeq.load(std::memory_order_relaxed) != s0)
					continue;
				if(!t)
					return 0;
				const double dt = (double(int64_t(_index - idx))) / g_emuRate;
				return dt >= 0 ? t + secondsToMach(dt) : t - secondsToMach(-dt);
			}
		}

		// ---- IO callback: copy only --------------------------------------------------------
		void pull(const uint32_t _frames, float* _left, float* _right, const uint64_t _outputTime)
		{
			callbacks.fetch_add(1, std::memory_order_relaxed);
			lastFrames.store(_frames, std::memory_order_relaxed);
			const uint64_t r = fifoRead.load(std::memory_order_relaxed);
			if(_outputTime)
			{
				anchorSeq.fetch_add(1, std::memory_order_acq_rel);
				anchorIndex = r;
				anchorTime = _outputTime;
				anchorSeq.fetch_add(1, std::memory_order_release);
			}
			const uint64_t avail = fifoWrite.load(std::memory_order_acquire) - r;
			if(!primed.load(std::memory_order_acquire))
			{
				if(avail < safetyFrames)
				{
					std::fill_n(_left, _frames, 0.0f);
					std::fill_n(_right, _frames, 0.0f);
					semaphore_signal(wake);
					return;
				}
				primed.store(true, std::memory_order_release);
			}
			const uint32_t n = uint32_t(std::min<uint64_t>(avail, _frames));
			for(uint32_t i = 0; i < n; ++i)
			{
				const uint32_t k = uint32_t((r + i) & (g_fifoFrames - 1));
				_left[i] = fifoL[k];
				_right[i] = fifoR[k];
			}
			if(n < _frames)
			{
				std::fill_n(_left + n, _frames - n, 0.0f);
				std::fill_n(_right + n, _frames - n, 0.0f);
				underruns.fetch_add(1, std::memory_order_relaxed);
			}
			fifoRead.store(r + n, std::memory_order_release);
			framesPlayed.fetch_add(_frames, std::memory_order_relaxed);
			const int64_t left = int64_t(avail - n);
			if(left < fifoMin.load(std::memory_order_relaxed))
				fifoMin.store(left, std::memory_order_relaxed);
			semaphore_signal(wake);
		}

		// ---- Render thread ------------------------------------------------------------------
		void startRenderThread()
		{
			renderRun.store(true, std::memory_order_release);
			pthread_attr_t attr;
			pthread_attr_init(&attr);
			pthread_attr_setstacksize(&attr, 8 << 20);
			pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
			renderThreadStarted = pthread_create(&renderThread, &attr, [](void* _p) -> void*
			{
				static_cast<LiveState*>(_p)->renderThreadMain();
				return nullptr;
			}, this) == 0;
			pthread_attr_destroy(&attr);
		}

		void stopRenderThread()
		{
			if(!renderThreadStarted)
				return;
			renderRun.store(false, std::memory_order_release);
			semaphore_signal(wake);
			pthread_join(renderThread, nullptr);
			renderThreadStarted = false;
		}

		void renderThreadMain()
		{
			pthread_setname_np("md.render");
			joinAudioWorkgroup();
			while(renderRun.load(std::memory_order_acquire))
			{
				if(fill() + g_renderBlock > safetyFrames + g_renderBlock / 2)
				{
					// Ahead enough: wait until the output takes some (or 20 ms at most).
					mach_timespec_t ts{0, 20 * 1000 * 1000};
					semaphore_timedwait(wake, ts);
					continue;
				}
				renderBlock(g_renderBlock);
			}
		}

		void renderBlock(const uint32_t _n)
		{
			const uint64_t t0 = mach_absolute_time();
			const uint64_t w = fifoWrite.load(std::memory_order_relaxed);
			// When this block will be heard. Before the output has run, assume it plays after
			// the current fill.
			uint64_t blockTime = playTime(w);
			if(!blockTime)
				blockTime = t0 + secondsToMach(double(fill()) / g_emuRate);

			deliverMidiIn(_n, blockTime);

			const synthLib::TAudioInputs inputs{inL.data(), inR.data(), nullptr, nullptr};
			synthLib::TAudioOutputs outputs{};
			for(size_t c = 0; c < out.size(); ++c)
				outputs[c] = out[c].data();
			plugin->process(inputs, outputs, _n, 120.0f, 0, false);

			const float g = volume.load(std::memory_order_relaxed);
			for(uint32_t i = 0; i < _n; ++i)
			{
				const uint32_t k = uint32_t((w + i) & (g_fifoFrames - 1));
				fifoL[k] = out[0][i] * g;
				fifoR[k] = out[1][i] * g;
			}
			fifoWrite.store(w + _n, std::memory_order_release);

			collectMidiOut(_n, blockTime);

			const double busy = machToSeconds(mach_absolute_time() - t0);
			const double audio = double(_n) / g_emuRate;
			busySeconds.store(busySeconds.load(std::memory_order_relaxed) + busy, std::memory_order_relaxed);
			renderedSeconds.store(renderedSeconds.load(std::memory_order_relaxed) + audio, std::memory_order_relaxed);
			windowBusy.store(windowBusy.load(std::memory_order_relaxed) + busy, std::memory_order_relaxed);
			windowAudio.store(windowAudio.load(std::memory_order_relaxed) + audio, std::memory_order_relaxed);
			const double load = busy / audio;
			if(load > peakBlockLoad.load(std::memory_order_relaxed)) peakBlockLoad.store(load, std::memory_order_relaxed);
			if(load > recentPeakBlockLoad.load(std::memory_order_relaxed)) recentPeakBlockLoad.store(load, std::memory_order_relaxed);
		}

		// Incoming MIDI sounds a fixed latency after it was played (the safety buffer plus one
		// block), at its original spacing: steady timing instead of jitter.
		void deliverMidiIn(const uint32_t _n, const uint64_t _blockTime)
		{
			const uint64_t latency = secondsToMach(double(safetyFrames + g_renderBlock) / g_emuRate);
			const uint64_t now = mach_absolute_time();
			auto take = [&](const uint8_t* _b, size_t _len, uint64_t _t)
			{
				pending.push_back({(_t ? _t : now) + latency, std::vector<uint8_t>(_b, _b + _len)});
			};
			ShortMidi m;
			while(midiIn.pop(m))
				take(m.bytes, m.len, m.time);
			{
				std::unique_lock lock(sysexInLock, std::try_to_lock);
				if(lock.owns_lock())
				{
					for(auto& sx : sysexIn)
						pending.push_back({(sx.time ? sx.time : now) + latency, std::move(sx.bytes)});
					sysexIn.clear();
				}
			}
			if(pending.empty())
				return;
			const uint64_t blockEnd = _blockTime + secondsToMach(double(_n) / g_emuRate);
			size_t kept = 0;
			for(size_t i = 0; i < pending.size(); ++i)
			{
				auto& p = pending[i];
				if(p.due >= blockEnd)
				{
					if(kept != i) pending[kept] = std::move(p);
					++kept;
					continue;
				}
				const uint32_t offset = p.due <= _blockTime ? 0
					: std::min<uint32_t>(_n - 1, uint32_t(machToSeconds(p.due - _blockTime) * g_emuRate));
				synthLib::SMidiEvent ev;
				ev.assignRawData(p.bytes.data(), p.bytes.size(), synthLib::MidiEventSource::Physical, offset);
				plugin->addMidiEvent(ev);
			}
			pending.resize(kept);
		}

		void collectMidiOut(const uint32_t _n, const uint64_t _blockTime)
		{
			midiOutScratch.clear();
			plugin->getMidiOut(midiOutScratch);
			for(const auto& ev : midiOutScratch)
			{
				const uint64_t t = _blockTime + secondsToMach(double(std::min(ev.offset, _n)) / g_emuRate);
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
	};
}

@implementation MDLiveEngine
{
	AVAudioEngine* _engine;
	AVAudioSourceNode* _source;
	AVAudioFormat* _format;
	// Shared so MIDI threads can hold the state while they use it (std::atomic_load/store).
	std::shared_ptr<LiveState> _state;
	BOOL _secondCore;
	float _volume;
	NSInteger _safetyFrames;
	NSMutableArray* _observers;
	NSTimer* _watchdog;
	// What the IO callback reads: a plain atomic pointer (no Objective-C or shared_ptr work on
	// the real-time thread). Cleared before the state is released.
	std::shared_ptr<std::atomic<LiveState*>> _audioState;
	int64_t _watchdogCallbacks;
	int _watchdogStalls;
	void (^_log)(NSString*);
}

- (instancetype)init
{
	if((self = [super init]))
	{
		_volume = 1.0f;
		_safetyFrames = 768;
		_observers = [NSMutableArray array];
		_audioState = std::make_shared<std::atomic<LiveState*>>(nullptr);
	}
	return self;
}

- (float)volume { return _volume; }

- (void)setVolume:(float)volume
{
	_volume = std::max(0.0f, std::min(1.0f, volume));
	if(const auto st = std::atomic_load(&_state))
		st->volume.store(_volume, std::memory_order_relaxed);
}

- (NSInteger)safetyFrames { return _safetyFrames; }
- (void)setSafetyFrames:(NSInteger)safetyFrames
{
	_safetyFrames = std::max<NSInteger>(256, std::min<NSInteger>(4096, safetyFrames));
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

// ---- Audio output: build, start, recover ----------------------------------------------------

- (BOOL)buildAudioEngine:(NSError**)err
{
	_engine = [AVAudioEngine new];
	_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:g_emuRate channels:2];
	const auto holder = _audioState;
	_source = [[AVAudioSourceNode alloc] initWithFormat:_format renderBlock:
		^OSStatus(BOOL* isSilence, const AudioTimeStamp* ts, AVAudioFrameCount frameCount, AudioBufferList* abl)
		{
			if(abl->mNumberBuffers < 2 || frameCount == 0)
				return noErr;
			float* l = static_cast<float*>(abl->mBuffers[0].mData);
			float* r = static_cast<float*>(abl->mBuffers[1].mData);
			LiveState* s = holder->load(std::memory_order_acquire);
			if(!s || !s->ready.load(std::memory_order_acquire))
			{
				std::fill_n(l, frameCount, 0.0f);
				std::fill_n(r, frameCount, 0.0f);
				*isSilence = YES;
				return noErr;
			}
			const uint64_t outputTime = (ts && (ts->mFlags & kAudioTimeStampHostTimeValid)) ? ts->mHostTime : 0;
			s->pull(frameCount, l, r, outputTime);
			*isSilence = NO;
			return noErr;
		}];
	[_engine attachNode:_source];
	[_engine connect:_source to:_engine.mainMixerNode format:_format];
	return [_engine startAndReturnError:err];
}

- (void)restartAudio:(NSString*)why
{
	if(!_engine)
		return;
	if(const auto st = std::atomic_load(&_state))
		st->audioRestarts.fetch_add(1, std::memory_order_relaxed);
	[[AVAudioSession sharedInstance] setActive:YES error:nil];
	[_engine stop];
	[_engine connect:_source to:_engine.mainMixerNode format:_format];
	NSError* err = nil;
	if(![_engine startAndReturnError:&err])
	{
		// The output graph itself is gone (media services reset): build a new one.
		[_engine stop];
		_engine = nil;
		_source = nil;
		[self buildAudioEngine:&err];
	}
	if(_log)
		_log([NSString stringWithFormat:@"Audio restarted (%@)%@", why,
			err ? [NSString stringWithFormat:@": %@", err.localizedDescription] : @"."]);
}

- (void)watchAudio
{
	__weak MDLiveEngine* weakSelf = self;
	AVAudioSession* session = [AVAudioSession sharedInstance];
	auto observe = [&](NSNotificationName name, id object, void (^block)(NSNotification*))
	{
		[_observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:object
			queue:NSOperationQueue.mainQueue usingBlock:block]];
	};
	// Calls, Siri and other apps can interrupt audio; start again when they're done.
	observe(AVAudioSessionInterruptionNotification, session, ^(NSNotification* n)
	{
		const auto type = AVAudioSessionInterruptionType([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]);
		if(type == AVAudioSessionInterruptionTypeEnded)
			[weakSelf restartAudio:@"after an interruption"];
	});
	// Headphones, Bluetooth and sample-rate changes stop the engine: start it again.
	observe(AVAudioEngineConfigurationChangeNotification, _engine, ^(NSNotification*)
	{
		[weakSelf restartAudio:@"the audio route or format changed"];
	});
	observe(AVAudioSessionRouteChangeNotification, session, ^(NSNotification*)
	{
		MDLiveEngine* me = weakSelf;
		if(me && me->_engine && !me->_engine.isRunning)
			[me restartAudio:@"the audio route changed"];
	});
	observe(AVAudioSessionMediaServicesWereResetNotification, session, ^(NSNotification*)
	{
		[weakSelf restartAudio:@"iPadOS reset its audio services"];
	});
	// Watchdog: if the output stops calling for audio for a second, restart it.
	_watchdogCallbacks = -1;
	_watchdogStalls = 0;
	_watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer*)
	{
		MDLiveEngine* me = weakSelf;
		const auto st = me ? std::atomic_load(&me->_state) : nullptr;
		if(!me || !st)
			return;
		const int64_t c = st->callbacks.load();
		if(c == me->_watchdogCallbacks)
		{
			if(++me->_watchdogStalls >= 2)
			{
				me->_watchdogStalls = 0;
				[me restartAudio:@"the output stalled"];
			}
		}
		else
			me->_watchdogStalls = 0;
		me->_watchdogCallbacks = c;
	}];
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
	_log = [progress copy];
	auto state = std::make_shared<LiveState>();
	LiveState* const s = state.get();
	s->safetyFrames = uint32_t(_safetyFrames);

	// 1. Audio output first (silence), so the workgroup exists before the threads start.
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
	__block BOOL audioOK = NO;
	__block NSError* audioErr = nil;
	dispatch_block_t buildAudio = ^{
		NSError* e = nil;
		audioOK = [self buildAudioEngine:&e];
		audioErr = e;
		if(audioOK)
			[self watchAudio];
	};
	if([NSThread isMainThread]) buildAudio(); else dispatch_sync(dispatch_get_main_queue(), buildAudio);
	if(!audioOK)
	{
		progress([NSString stringWithFormat:@"Could not start audio: %@", audioErr.localizedDescription]);
		_engine = nil; _source = nil;
		return NO;
	}
	progress([NSString stringWithFormat:@"Audio running: %.0f Hz hardware, %.1f ms buffer (%ld frames requested), %.1f ms safety buffer.",
		session.sampleRate, session.IOBufferDuration * 1000.0, long(bufferFrames), double(_safetyFrames) / g_emuRate * 1000.0]);

	// 2. The render thread and the DSP worker join the output's audio workgroup.
	g_workgroupJoined = false;
	g_audioWorkgroup = nullptr;
	if(@available(iOS 14.0, *))
		g_audioWorkgroup = _engine.outputNode.AUAudioUnit.osWorkgroup;
	md::Hardware::setDspWorkerThreadStartHook([]
	{
		pthread_setname_np("md.dsp1-worker");
		if(joinAudioWorkgroup())
			g_workgroupJoined = true;
	});

	// 3. Boot the Machinedrum off the audio threads.
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

	// 4. Hand over: the render thread fills the safety buffer, then the output starts.
	std::atomic_store(&_state, state);
	state->ready.store(true, std::memory_order_release);
	state->startRenderThread();
	_audioState->store(state.get(), std::memory_order_release);
	progress(@"Playing live. The render thread runs ahead into the safety buffer; the output only copies.");
	return YES;
}

- (void)stop
{
	// Timers and the audio graph belong to the main thread.
	if(![NSThread isMainThread])
	{
		dispatch_sync(dispatch_get_main_queue(), ^{ [self stop]; });
		return;
	}
	[_watchdog invalidate];
	_watchdog = nil;
	for(id o in _observers)
		[NSNotificationCenter.defaultCenter removeObserver:o];
	[_observers removeAllObjects];
	const auto st = std::atomic_load(&_state);
	if(st)
		st->ready.store(false, std::memory_order_release);
	_audioState->store(nullptr, std::memory_order_release);
	if(_engine)
	{
		[_engine stop];
		_engine = nil;
		_source = nil;
	}
	if(st)
		st->stopRenderThread();
	std::atomic_store(&_state, std::shared_ptr<LiveState>());	// joins the DSP worker (Device -> Hardware destructor)
	md::Hardware::setDspWorkerThreadStartHook({});
	unsetenv("GEARMULATOR_MD_DSP_WORKER");
	unsetenv("GEARMULATOR_MD_DSP_SKEW");
	unsetenv("GEARMULATOR_MD_LOW_POWER_WAIT");
}

+ (NSString *)threadCPUReport
{
	thread_act_array_t threads = nullptr;
	mach_msg_type_number_t count = 0;
	if(task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
		return @"";
	struct Entry { double pct; std::string name; };
	std::vector<Entry> entries;
	double total = 0;
	for(mach_msg_type_number_t i = 0; i < count; ++i)
	{
		thread_basic_info_data_t basic{};
		mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
		if(thread_info(threads[i], THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&basic), &n) == KERN_SUCCESS
			&& !(basic.flags & TH_FLAGS_IDLE))
		{
			const double pct = 100.0 * double(basic.cpu_usage) / double(TH_USAGE_SCALE);
			total += pct;
			if(pct >= 1.0)
			{
				thread_extended_info_data_t ext{};
				mach_msg_type_number_t m = THREAD_EXTENDED_INFO_COUNT;
				std::string name = "thread";
				if(thread_info(threads[i], THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&ext), &m) == KERN_SUCCESS && ext.pth_name[0])
					name = ext.pth_name;
				entries.push_back({pct, name});
			}
		}
		mach_port_deallocate(mach_task_self(), threads[i]);
	}
	vm_deallocate(mach_task_self(), vm_address_t(threads), count * sizeof(thread_act_t));
	std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) { return a.pct > b.pct; });
	std::string r = "total " + std::to_string(int(total + 0.5)) + "%";
	for(const auto& e : entries)
		r += "; " + e.name + " " + std::to_string(int(e.pct + 0.5)) + "%";
	return [NSString stringWithUTF8String:r.c_str()];
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
	r.overruns = s.underruns.load();
	const double rendered = s.renderedSeconds.load();
	r.averageLoad = rendered > 0 ? s.busySeconds.load() / rendered : 0;
	r.peakLoad = s.peakBlockLoad.load();
	r.recentPeakLoad = s.recentPeakBlockLoad.exchange(0);
	const double wa = s.windowAudio.exchange(0), wb = s.windowBusy.exchange(0);
	r.recentLoad = wa > 0 ? wb / wa : 0;
	r.safetyFrames = s.safetyFrames;
	r.safetyFill = s.fill();
	r.safetyMinFill = s.fifoMin.exchange(g_fifoFrames);
	r.audioRestarts = s.audioRestarts.load();
	r.bufferFrames = s.lastFrames.load();
	r.sampleRate = [AVAudioSession sharedInstance].sampleRate;
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
