#pragma once

#include <atomic>
#include <cstdint>
#include <thread>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif

namespace md
{
	// Apple silicon has 128-byte cache lines; keeping each hot shared variable on its own
	// line stops the two threads from bouncing one line between cores.
	constexpr size_t g_cacheLine = 128;

	// Lab only (GEARMULATOR_MD_YIELD_WAITS): yield instead of spinning, for machines with fewer
	// cores than emulation threads, where spinning threads would starve the one with work.
	inline std::atomic<bool> g_yieldWaits{false};

	inline void cpuRelax() noexcept
	{
		if(g_yieldWaits.load(std::memory_order_relaxed))
		{
			std::this_thread::yield();
			return;
		}
#if defined(__aarch64__)
		asm volatile("yield" ::: "memory");
#elif defined(__x86_64__) || defined(_M_X64)
		_mm_pause();
#else
		std::this_thread::yield();
#endif
	}

	// Wait until _value may have changed from _seen. With _lowPower on 64-bit ARM this arms
	// the exclusive monitor on the value's cache line and executes WFE: the core idles until
	// another core writes that line (or any other event arrives) instead of spinning at full
	// power, so the busy core keeps more of the power budget. Otherwise a plain pause.
	template<typename T> inline void waitForChange(const std::atomic<T>& _value, const T _seen, const bool _lowPower) noexcept
	{
#if defined(__aarch64__)
		static_assert(sizeof(T) == 8, "64-bit values only");
		if(_lowPower)
		{
			uint64_t v;
			asm volatile("ldaxr %0, [%1]" : "=&r"(v) : "r"(&_value) : "memory");
			if(v == static_cast<uint64_t>(_seen))
				asm volatile("wfe" ::: "memory");
			return;
		}
#else
		(void)_value; (void)_seen; (void)_lowPower;
#endif
		cpuRelax();
	}

	// Small recursive spin lock used to hand ownership of DSP2 (and of the shared
	// inter-DSP link state) between the scheduler thread and the DSP2 worker.
	// Critical sections are short (a few dozen DSP instructions), so spinning is
	// cheaper than a kernel mutex and never blocks the audio thread on the OS.
	class alignas(g_cacheLine) RecursiveSpinLock
	{
	public:
		void lock() noexcept
		{
			const auto me = self();
			if(m_owner.load(std::memory_order_relaxed) == me)
			{
				++m_depth;
				return;
			}
			// Pure spin: the holder releases within a few dozen DSP instructions. Never call
			// sched_yield here: on Apple platforms it depresses the caller's priority, and
			// every hand-off can then stall for milliseconds.
			uintptr_t expected = 0;
			while(!m_owner.compare_exchange_weak(expected, me,
				std::memory_order_acquire, std::memory_order_relaxed))
			{
				expected = 0;
				cpuRelax();
			}
			m_depth = 1;
		}

		bool tryLock() noexcept
		{
			const auto me = self();
			if(m_owner.load(std::memory_order_relaxed) == me)
			{
				++m_depth;
				return true;
			}
			uintptr_t expected = 0;
			if(!m_owner.compare_exchange_strong(expected, me,
				std::memory_order_acquire, std::memory_order_relaxed))
				return false;
			m_depth = 1;
			return true;
		}

		void unlock() noexcept
		{
			if(--m_depth == 0)
				m_owner.store(0, std::memory_order_release);
		}

		bool ownedByCurrentThread() const noexcept
		{
			return m_owner.load(std::memory_order_relaxed) == self();
		}

	private:
		static uintptr_t self() noexcept
		{
			static thread_local char tag;
			return reinterpret_cast<uintptr_t>(&tag);
		}

		std::atomic<uintptr_t> m_owner{0};
		uint32_t m_depth = 0;	// only touched by the owner
	};

	// RAII guard that is a no-op when no lock is given.
	class OptionalLockGuard
	{
	public:
		explicit OptionalLockGuard(RecursiveSpinLock* _lock) noexcept : m_lock(_lock)
		{
			if(m_lock)
				m_lock->lock();
		}
		~OptionalLockGuard()
		{
			if(m_lock)
				m_lock->unlock();
		}
		OptionalLockGuard(const OptionalLockGuard&) = delete;
		OptionalLockGuard& operator=(const OptionalLockGuard&) = delete;

	private:
		RecursiveSpinLock* m_lock;
	};
}
