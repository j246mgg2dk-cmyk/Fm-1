// Raw DSP56300 emulator throughput: instructions and DSP cycles executed per second.
#include "dsp56kEmu/assembler.h"
#include "dsp56kEmu/dsp.h"
#include "dsp56kEmu/dspconfig.h"
#include <chrono>
#include <cstdio>
using namespace dsp56k;
int main()
{
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
		auto r = as.assemble(line);
		if(!r.success()) { printf("asm failed: %s\n", line); return 1; }
		for(uint32_t i = 0; i < r.wordCount; ++i) mem.set(MemArea_P, pc++, r.word[i]);
	}
	dsp.setPC(0x100);
	for(int i = 0; i < 100000; ++i) dsp.exec();   // warm up / compile
	const auto i0 = dsp.getInstructionCounter(); const auto c0 = dsp.getCycles();
	auto t0 = std::chrono::steady_clock::now();
	for(int i = 0; i < 50'000'000; ++i) dsp.exec();
	const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	const double ips = (dsp.getInstructionCounter() - i0) / s;
	printf("%s: %.1f M instructions/s  (%.1f M exec calls/s, cycles counted: %llu)\n",
		g_jitSupported ? "JIT" : "INTERPRETER", ips / 1e6, 50.0 / s, (unsigned long long)(dsp.getCycles() - c0));
	printf("Machinedrum needs ~203 M DSP cycles/s (2 x 2304 cycles x 44100 Hz)\n");
	return 0;
}
