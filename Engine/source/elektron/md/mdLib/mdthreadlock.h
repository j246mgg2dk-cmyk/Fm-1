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

	inline void cpuRelax() noexcept
	{
#if defined(__aarch64__)
		asm volatile("yield" ::: "memory");
#elif defined(__x86_64__) || defined(_M_X64)
		_mm_pause();
#else
		std::this_thread::yield();
#endif
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
