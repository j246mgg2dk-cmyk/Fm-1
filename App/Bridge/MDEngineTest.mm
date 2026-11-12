#import "MDEngineTest.h"

#include "mdLib/mddevice.h"
#include "mdLib/mdhardware.h"
#include "mdLib/mdfrontpanel.h"
#include "mdLib/mdpanel.h"
#include "mdLib/mdromloader.h"
#include "mdLib/mdtypes.h"
#include "baseLib/filesystem.h"
#include "synthLib/plugin.h"
#include "dsp56kEmu/assembler.h"
#include "dsp56kEmu/dsp.h"
#include "dsp56kEmu/dspconfig.h"

#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

@implementation MDTestResult
@end

namespace
{
	using Clock = std::chrono::steady_clock;
	double since(Clock::time_point t) { return std::chrono::duration<double>(Clock::now() - t).count(); }

	void writeWav(const std::string& path, const std::vector<float>& interleaved)
	{
		FILE* f = std::fopen(path.c_str(), "wb");
		if(!f) return;
		auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
		auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
		const auto n = static_cast<uint32_t>(interleaved.size());
		std::fwrite("RIFF", 1, 4, f); w32(36 + n * 2); std::fwrite("WAVEfmt ", 1, 8, f);
		w32(16); w16(1); w16(2); w32(44100); w32(44100 * 4); w16(4); w16(16);
		std::fwrite("data", 1, 4, f); w32(n * 2);
		for(const float v : interleaved)
			w16(static_cast<uint16_t>(static_cast<int16_t>(std::max(-1.0f, std::min(1.0f, v)) * 32767)));
		std::fclose(f);
	}
}

@implementation MDEngineTest

+ (double)measureRawDspMips
{
	using namespace dsp56k;
	DefaultMemoryValidator validator;
	Memory mem{validator, 0x10000};
	PeripheralsNop px, py;
	DSP dsp{mem, &px, &py};
	Assembler as;
	const char* prog[] = {"mac x0,y0,a", "mac x1,y1,b", "add x0,b", "move a,x:$10", "move x:$11,x1",
	                      "asl a", "sub y0,a", "move b,y:$20", "nop", "jmp $100"};
	TWord pc = 0x100;
	for(auto* line : prog)
	{
		const auto r = as.assemble(line);
		if(!r.success()) return 0;
		for(uint32_t i = 0; i < r.wordCount; ++i) mem.set(MemArea_P, pc++, r.word[i]);
	}
	dsp.setPC(0x100);
	for(int i = 0; i < 200000; ++i) dsp.exec();
	const auto i0 = dsp.getInstructionCounter();
	const auto t0 = Clock::now();
	for(int i = 0; i < 30'000'000; ++i) dsp.exec();
	return double(dsp.getInstructionCounter() - i0) / since(t0) / 1e6;
}

+ (BOOL)isSupportedFirmware:(NSString *)path
{
	std::vector<uint8_t> fw;
	if(!baseLib::filesystem::readFile(fw, path.UTF8String)) return NO;
	return md::RomLoader::isRomForModel(fw, md::MachineModel::Machinedrum);
}

+ (MDTestResult *)runWithFirmware:(NSString *)firmwarePath
                         homePath:(NSString *)homePath
                      bootSeconds:(double)bootSeconds
                          seconds:(double)seconds
                          wavPath:(NSString *)wavPath
                         progress:(void (^)(NSString *))progress
{
	MDTestResult* r = [MDTestResult new];
	r.engineMode = dsp56k::g_jitSupported ? @"JIT" : @"INTERPRETER (no JIT)";
	NSMutableString* log = [NSMutableString string];
	auto say = [&](NSString* s) { [log appendFormat:@"%@\n", s]; progress(s); };

	std::vector<uint8_t> fw;
	if(!baseLib::filesystem::readFile(fw, firmwarePath.UTF8String))
	{
		say(@"Could not read the firmware file.");
		r.log = log;
		return r;
	}
	r.firmwareRecognised = md::RomLoader::isRomForModel(fw, md::MachineModel::Machinedrum);
	say(r.firmwareRecognised ? @"Firmware: Machinedrum UW OS 1.63 recognised." : @"Firmware NOT recognised as MD UW 1.63.");

	NSString* cache = [homePath stringByAppendingPathComponent:@"nvram/md-uw-1.63-factory-v2.cache"];
	r.usedFactoryCache = [[NSFileManager defaultManager] fileExistsAtPath:cache];

	synthLib::DeviceCreateParams params;
	params.romData = fw;
	params.romName = firmwarePath.UTF8String;
	params.customData = md::deviceCustomData(md::MachineModel::Machinedrum);
	params.homePath = std::string(homePath.UTF8String) + "/";

	const auto tBoot = Clock::now();
	auto device = std::make_unique<md::Device>(params);
	r.deviceValid = device->isValid();
	if(!r.deviceValid)
	{
		say(@"The engine could not create a Machinedrum from this firmware.");
		r.log = log;
		return r;
	}
	synthLib::Plugin plugin(device.get(), [](synthLib::Device*) {});
	plugin.reserveMidiEventCapacity();

	constexpr uint32_t block = 128;
	std::array<float, block> inL{}, inR{};
	std::array<std::array<float, block>, 6> out{};
	const synthLib::TAudioInputs inputs{inL.data(), inR.data(), nullptr, nullptr};
	synthLib::TAudioOutputs outputs{};
	for(size_t c = 0; c < out.size(); ++c) outputs[c] = out[c].data();
	plugin.setHostSamplerate(44100.0f, 44100.0f);
	plugin.setBlockSize(block);

	say([NSString stringWithFormat:@"Booting (%.0f s of machine time)…", bootSeconds]);
	const int bootBlocks = int(44100 * bootSeconds / block);
	for(int i = 0; i < bootBlocks; ++i)
	{
		plugin.process(inputs, outputs, block, 120.0f, 0, false);
		if((i + 1) % (44100 / block) == 0)
			say([NSString stringWithFormat:@"  booted %.0f s of machine time, %.1f s elapsed", (i + 1) * block / 44100.0, since(tBoot)]);
	}
	r.bootSeconds = since(tBoot);

	if(auto play = md::panelPacket(md::MachineModel::Machinedrum, md::PanelControl::Play))
	{
		device->getHardware().sendPanelEvent(play->row, play->mask);
		for(int i = 0; i < 20; ++i) plugin.process(inputs, outputs, block, 120.0f, 0, false);
		device->getHardware().sendPanelEvent(play->row, 0);
		say(@"Pressed PLAY.");
	}

	auto& hw = device->getHardware();
	const uint64_t i0 = hw.getDspMixer().dsp().getInstructionCounter() + hw.getDspProducer().dsp().getInstructionCounter();
	const int blocks = int(44100 * seconds / block);
	std::vector<float> capture;
	capture.reserve(size_t(blocks) * block * 2);
	double peak = 0, energy = 0;
	say([NSString stringWithFormat:@"Timing %.0f s of audio…", seconds]);
	const auto t0 = Clock::now();
	for(int i = 0; i < blocks; ++i)
	{
		plugin.process(inputs, outputs, block, 120.0f, 0, false);
		for(uint32_t s = 0; s < block; ++s)
		{
			capture.push_back(out[0][s]);
			capture.push_back(out[1][s]);
			peak = std::max(peak, double(std::abs(out[0][s])));
			energy += double(out[0][s]) * out[0][s];
		}
	}
	r.wallSeconds = since(t0);
	r.audioSeconds = blocks * double(block) / 44100.0;
	r.realtimeFactor = r.audioSeconds / r.wallSeconds;
	const uint64_t i1 = hw.getDspMixer().dsp().getInstructionCounter() + hw.getDspProducer().dsp().getInstructionCounter();
	r.dspInstructionsPerAudioSecond = double(i1 - i0) / r.audioSeconds / 1e6;
	r.dspInstructionsPerWallSecond = double(i1 - i0) / r.wallSeconds / 1e6;
	r.peak = peak;
	r.rms = std::sqrt(energy / std::max(1.0, double(blocks) * block));

	NSMutableData* lcd = [NSMutableData dataWithLength:128 * 64];
	const auto fp = device->getFrontPanelSnapshot();
	auto* px = static_cast<uint8_t*>(lcd.mutableBytes);
	for(uint32_t y = 0; y < 64; ++y)
		for(uint32_t x = 0; x < 128; ++x)
			px[y * 128 + x] = fp.getLcdPixel(x, y) ? 1 : 0;
	r.lcd = lcd;

	if(wavPath)
	{
		writeWav(wavPath.UTF8String, capture);
		r.wavPath = wavPath;
	}
	say([NSString stringWithFormat:@"Done: %.2fx real time, %.1f M DSP instructions/s, peak %.3f",
		r.realtimeFactor, r.dspInstructionsPerWallSecond, r.peak]);
	r.log = log;
	return r;
}

@end
