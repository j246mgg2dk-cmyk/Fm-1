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
#include <memory>
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

		void render(const uint32_t _frames, float* _left, float* _right, const double _sampleRate)
		{
			if(!ready.load(std::memory_order_acquire))
			{
				std::fill_n(_left, _frames, 0.0f);
				std::fill_n(_right, _frames, 0.0f);
				return;
			}
			const uint64_t t0 = mach_absolute_time();
			uint32_t done = 0;
			while(done < _frames)
			{
				const uint32_t n = std::min(_frames - done, g_maxFrames);
				const synthLib::TAudioInputs inputs{inL.data(), inR.data(), nullptr, nullptr};
				synthLib::TAudioOutputs outputs{};
				for(size_t c = 0; c < out.size(); ++c) outputs[c] = out[c].data();
				plugin->process(inputs, outputs, n, 120.0f, 0, false);
				std::copy_n(out[0].data(), n, _left + done);
				std::copy_n(out[1].data(), n, _right + done);
				done += n;
			}
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
	std::unique_ptr<LiveState> _state;
	BOOL _secondCore;
}

- (BOOL)startWithFirmware:(NSString *)firmwarePath
                 homePath:(NSString *)homePath
               secondCore:(BOOL)secondCore
             bufferFrames:(NSInteger)bufferFrames
                 progress:(void (^)(NSString *))progress
{
	[self stop];
	_secondCore = secondCore;
	auto state = std::make_unique<LiveState>();
	LiveState* const s = state.get();

	// 1. Audio output first (silence), so the workgroup exists before the DSP worker starts.
	NSError* err = nil;
	AVAudioSession* session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback error:&err];
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
		^OSStatus(BOOL* isSilence, const AudioTimeStamp*, AVAudioFrameCount frameCount, AudioBufferList* abl)
		{
			if(abl->mNumberBuffers < 2 || frameCount == 0)
				return noErr;
			s->render(frameCount, static_cast<float*>(abl->mBuffers[0].mData),
				static_cast<float*>(abl->mBuffers[1].mData), g_emuRate);
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
	if(auto play = md::panelPacket(md::MachineModel::Machinedrum, md::PanelControl::Play))
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
	_state = std::move(state);
	_state->ready.store(true, std::memory_order_release);
	progress(@"Playing live. Listen for clicks or dropouts; the numbers update every second.");
	return YES;
}

- (void)stop
{
	if(_state)
		_state->ready.store(false, std::memory_order_release);
	if(_engine)
	{
		[_engine stop];
		_engine = nil;
		_source = nil;
	}
	_state.reset();		// joins the DSP worker thread (Device -> Hardware destructor)
	md::Hardware::setDspWorkerThreadStartHook({});
	unsetenv("GEARMULATOR_MD_DSP_WORKER");
	unsetenv("GEARMULATOR_MD_DSP_SKEW");
}

- (MDLiveStats *)stats
{
	MDLiveStats* r = [MDLiveStats new];
	r.footprintMB = footprintMB();
	r.workgroupJoined = g_workgroupJoined;
	if(!_state)
		return r;
	auto& s = *_state;
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
	return r;
}

- (void)dealloc
{
	[self stop];
}

@end
