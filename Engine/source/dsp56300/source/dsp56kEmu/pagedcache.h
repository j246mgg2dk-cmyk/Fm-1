#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace dsp56k
{
	// Per-P-address interpreter cache stored in lazily allocated pages.
	//
	// The interpreter keeps metadata for every P-memory address, but a program only
	// ever executes a few kilowords of a large (e.g. 8 M word) address space. A flat
	// vector touches every entry when it is filled with its default value, committing
	// hundreds of megabytes per DSP. Pages here are created the first time an address in
	// them is accessed for writing or execution; untouched pages read as the default.
	template<typename T, uint32_t PageBits = 12>
	class PagedCache
	{
	public:
		static constexpr size_t PageSize = size_t{1} << PageBits;
		static constexpr size_t PageMask = PageSize - 1;

		size_t size() const noexcept { return m_size; }
		bool empty() const noexcept { return m_size == 0; }

		void clear()
		{
			m_pages.clear();
			m_size = 0;
		}

		// Same meaning as std::vector::assign/resize with a fill value: every entry reads
		// as _value afterwards. Pages are released and recreated on demand.
		void assign(const size_t _size, const T& _value)
		{
			m_pages.clear();
			m_pages.resize((_size + PageMask) >> PageBits);
			m_size = _size;
			m_default = _value;
		}
		void resize(const size_t _size, const T& _value) { assign(_size, _value); }

		// Access for execution or writing: creates the page if needed.
		T& operator[](const size_t _index)
		{
			auto& page = m_pages[_index >> PageBits];
			if(page == nullptr)
				page = createPage();
			return page[_index & PageMask];
		}

		// Read-only access: an untouched page reads as the default value.
		const T& operator[](const size_t _index) const
		{
			const auto& page = m_pages[_index >> PageBits];
			return page ? page[_index & PageMask] : m_default;
		}

		// Reset one entry to the default without creating its page.
		void reset(const size_t _index)
		{
			if(_index >= m_size)
				return;
			if(auto& page = m_pages[_index >> PageBits])
				page[_index & PageMask] = m_default;
		}

		size_t allocatedPages() const
		{
			size_t n = 0;
			for(const auto& p : m_pages)
				n += p ? 1 : 0;
			return n;
		}

	private:
		std::unique_ptr<T[]> createPage() const
		{
			std::unique_ptr<T[]> page(new T[PageSize]);
			for(size_t i = 0; i < PageSize; ++i)
				page[i] = m_default;
			return page;
		}

		std::vector<std::unique_ptr<T[]>> m_pages;
		size_t m_size = 0;
		T m_default{};
	};
}

#include <cstdlib>
#include <cstring>
#include <type_traits>

namespace dsp56k
{
	// Flat per-address array whose "empty" value is all-zero bits, allocated with calloc.
	// Large calloc blocks come straight from the OS as zero pages that are only committed
	// when written, so a cache spanning an 8 M-word address space costs memory only for the
	// few kilowords a program actually executes, and lookups stay a single indexed load.
	template<typename T>
	class LazyZeroArray
	{
		static_assert(std::is_trivially_copyable<T>::value, "LazyZeroArray needs a trivially copyable type");
	public:
		LazyZeroArray() = default;
		LazyZeroArray(const size_t _size, const T& _zero)	// vector-style (size, value) with value zero
		{
			(void)_zero;	// only zero is supported: the storage is fresh zero pages
			assignZero(_size);
		}
		T* data() noexcept { return m_data; }
		const T* data() const noexcept { return m_data; }
		~LazyZeroArray() { std::free(m_data); }
		LazyZeroArray(const LazyZeroArray&) = delete;
		LazyZeroArray& operator=(const LazyZeroArray&) = delete;

		size_t size() const noexcept { return m_size; }
		bool empty() const noexcept { return m_size == 0; }

		void clear()
		{
			std::free(m_data);
			m_data = nullptr;
			m_size = 0;
		}

		// Every entry reads as zero afterwards. Fresh zero pages instead of a memset, which
		// would commit the whole array.
		void assignZero(const size_t _size)
		{
			clear();
			if(!_size)
				return;
			m_data = static_cast<T*>(std::calloc(_size, sizeof(T)));
			if(m_data)
				m_size = _size;
		}

		T& operator[](const size_t _index) noexcept { return m_data[_index]; }
		const T& operator[](const size_t _index) const noexcept { return m_data[_index]; }

		// Reset an entry to zero, writing only if it is not zero already (a write would
		// commit an untouched page).
		void reset(const size_t _index) noexcept
		{
			if(_index >= m_size)
				return;
			static const T zero{};
			if(std::memcmp(&m_data[_index], &zero, sizeof(T)) != 0)
				std::memcpy(&m_data[_index], &zero, sizeof(T));
		}

	private:
		T* m_data = nullptr;
		size_t m_size = 0;
	};
}
