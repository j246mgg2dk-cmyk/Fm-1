#pragma once

#include <atomic>
#include <cstdint>
#include <thread>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif

namespace md
{
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
	class RecursiveSpinLock
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
			uintptr_t expected = 0;
			uint32_t spins = 0;
			while(!m_owner.compare_exchange_weak(expected, me,
				std::memory_order_acquire, std::memory_order_relaxed))
			{
				expected = 0;
				if(++spins < 4096)
					cpuRelax();
				else
					std::this_thread::yield();
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
