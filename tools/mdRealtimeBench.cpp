// Boots the real MD firmware headless, plays notes, renders audio and reports
// the realtime factor (seconds of audio produced per second of CPU time).
#include "mdLib/mddevice.h"
#include "mdLib/mdromloader.h"
#include "mdLib/mdtypes.h"
#include "mdLib/mdpanel.h"
#include "mdLib/mdhardware.h"
#include "mdLib/mdfrontpanel.h" // ENSURE_LCD
#include "baseLib/filesystem.h"
#include "synthLib/plugin.h"
#include "dsp56kEmu/dspconfig.h"

#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>


static void dumpLcd(md::Device& d, const char* title)
{
	const auto fp = d.getFrontPanelSnapshot();
	printf("---- LCD: %s (lit=%u) ----\n", title, fp.countLitPixels());
	for(uint32_t y = 0; y < 64; y += 2)
	{
		char line[129];
		for(uint32_t x = 0; x < 128; ++x)
		{
			const bool a = fp.getLcdPixel(x, y), b = fp.getLcdPixel(x, y + 1);
			line[x] = a && b ? '#' : (a ? '"' : (b ? '.' : ' '));
		}
		line[128] = 0;
		printf("|%s|\n", line);
	}
	printf("drum LEDs: "); for(uint32_t i = 0; i < 16; ++i) printf("%d", (int)fp.getDrumLed(i));
	printf("  step LEDs: "); for(uint32_t i = 0; i < 16; ++i) printf("%d", (int)fp.getStepLed(i)); printf("\n");
}

int main(int argc, char** argv)
{
	setvbuf(stdout, nullptr, _IONBF, 0);
	const char* path = argc > 1 ? argv[1] : std::getenv("GEARMULATOR_MD_FIRMWARE_BIN");
	const double seconds = argc > 2 ? atof(argv[2]) : 10.0;
	std::vector<uint8_t> fw;
	if(!path || !baseLib::filesystem::readFile(fw, path)) { printf("no firmware\n"); return 77; }
	printf("engine: %s\n", dsp56k::g_jitSupported ? "JIT" : "INTERPRETER");
	printf("canonical MD image: %s\n", md::RomLoader::isRomForModel(fw, md::MachineModel::Machinedrum) ? "yes" : "NO");

	synthLib::DeviceCreateParams params;
	params.romData = fw;
	params.romName = path;
	params.customData = md::deviceCustomData(md::MachineModel::Machinedrum);
	if(const char* home = std::getenv("MD_HOME")) params.homePath = home;   // nvram/md-uw-1.63-factory-v2.cache
	auto t0 = std::chrono::steady_clock::now();
	auto device = std::make_unique<md::Device>(params);
	if(!device->isValid()) { printf("device invalid\n"); return 1; }
	synthLib::Plugin plugin(device.get(), [](synthLib::Device*) {});
	plugin.reserveMidiEventCapacity();
	constexpr uint32_t block = 128;
	std::array<float, block> inL{}, inR{};
	std::array<std::array<float, block>, 6> out{};
	synthLib::TAudioInputs inputs{inL.data(), inR.data(), nullptr, nullptr};
	synthLib::TAudioOutputs outputs{};
	for(size_t c = 0; c < out.size(); ++c) outputs[c] = out[c].data();
	plugin.setHostSamplerate(44100.0f, 44100.0f);
	plugin.setBlockSize(block);

	// boot: N s of audio, reporting speed every 0.25 s of audio
	const double bootSeconds = argc > 3 ? atof(argv[3]) : 3.0;
	{
		auto last = std::chrono::steady_clock::now();
		const int perReport = 44100 / 4 / block;
		for(int i = 0; i < int(44100 * bootSeconds / block); ++i)
		{
			plugin.process(inputs, outputs, block, 120.0f, 0, false);
			if((i + 1) % perReport == 0)
			{
				auto now = std::chrono::steady_clock::now();
				printf("  boot audio %.2f s, speed %.3fx realtime\n", (i + 1) * block / 44100.0,
					(perReport * block / 44100.0) / std::chrono::duration<double>(now - last).count());
				last = now;
			}
		}
	}
	auto t1 = std::chrono::steady_clock::now();
	if(std::getenv("MD_LCD")) dumpLcd(*device, "after boot");
	printf("boot (3 s audio) took %.2f s\n", std::chrono::duration<double>(t1 - t0).count());

	// press PLAY on the front panel: the sequencer runs the current pattern
	if(std::getenv("MD_PLAY"))
	{
		if(auto play = md::panelPacket(md::MachineModel::Machinedrum, md::PanelControl::Play))
		{
			device->getHardware().sendPanelEvent(play->row, play->mask);
			for(int i = 0; i < 20; ++i) plugin.process(inputs, outputs, block, 120.0f, 0, false);
			device->getHardware().sendPanelEvent(play->row, 0);
			printf("pressed PLAY\n");
		}
	}
	const int blocks = int(44100 * seconds / block);
	std::vector<float> capture;
	float peak = 0; double energy = 0;
	auto& hw = device->getHardware();
	const uint64_t i0a = hw.getDspMixer().dsp().getInstructionCounter(), i0b = hw.getDspProducer().dsp().getInstructionCounter();
	const uint64_t c0a = hw.getDspMixer().dsp().getCycles(), c0b = hw.getDspProducer().dsp().getCycles();
	auto t2 = std::chrono::steady_clock::now();
	for(int i = 0; i < blocks; ++i)
	{
		if(i % 40 == 0)   // ~8.6 notes/s across the 16 tracks
		{
			const uint8_t note = static_cast<uint8_t>(36 + (i / 40) % 16);
			plugin.addMidiEvent({synthLib::MidiEventSource::Host, synthLib::M_NOTEON, note, 110, 0});
			plugin.addMidiEvent({synthLib::MidiEventSource::Host, synthLib::M_NOTEOFF, note, 0, 64});
		}
		plugin.process(inputs, outputs, block, 120.0f, 0, false);
		for(uint32_t s = 0; s < block; ++s) { capture.push_back(out[0][s]); capture.push_back(out[1][s]); }
		for(size_t c = 0; c < out.size(); ++c) for(uint32_t s = 0; s < block; ++s) { peak = std::max(peak, std::abs(out[c][s])); energy += out[c][s] * out[c][s]; }
	}
	auto t3 = std::chrono::steady_clock::now();
	const double wall = std::chrono::duration<double>(t3 - t2).count();
	if(std::getenv("MD_LCD")) dumpLcd(*device, "after render");
	{
		const double ia = double(hw.getDspMixer().dsp().getInstructionCounter() - i0a), ib = double(hw.getDspProducer().dsp().getInstructionCounter() - i0b);
		const double ca = double(hw.getDspMixer().dsp().getCycles() - c0a), cb = double(hw.getDspProducer().dsp().getCycles() - c0b);
		printf("DSP work per second of audio: DSP1 %.1f M instr (%.1f M cycles), DSP2 %.1f M instr (%.1f M cycles), total %.1f M instr\n",
			ia / seconds / 1e6, ca / seconds / 1e6, ib / seconds / 1e6, cb / seconds / 1e6, (ia + ib) / seconds / 1e6);
		printf("emulator DSP throughput: %.1f M instr per wall-clock second\n", (ia + ib) / wall / 1e6);
	}
	printf("rendered %.1f s audio in %.2f s  ->  realtime factor %.2fx\n", seconds, wall, seconds / wall);
	printf("output peak %.4f  rms %.5f  (%s)\n", peak, std::sqrt(energy / (blocks * block)), peak > 1e-4 ? "SOUND" : "silent");
	if(const char* wav = std::getenv("MD_WAV"))
	{
		FILE* f = fopen(wav, "wb");
		auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
		auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
		const uint32_t n = uint32_t(capture.size());
		fwrite("RIFF", 1, 4, f); w32(36 + n * 2); fwrite("WAVEfmt ", 1, 8, f); w32(16); w16(1); w16(2); w32(44100); w32(44100 * 4); w16(4); w16(16);
		fwrite("data", 1, 4, f); w32(n * 2);
		for(float v : capture) { int x = int(std::max(-1.f, std::min(1.f, v)) * 32767); w16(uint16_t(int16_t(x))); }
		fclose(f);
		printf("wrote %s\n", wav);
	}
	return 0;
}
