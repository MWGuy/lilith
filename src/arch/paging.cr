require "./fastmem.cr"
require "./frame_allocator.cr"

lib PageStructs
  alias Page = UInt32

  struct PageTable
    pages : Page[1024]
  end

  struct PageDirectory
    tables : UInt32[1024]
  end

  fun kenable_paging(addr : UInt32)
  fun kdisable_paging
end

USERSPACE_START = 0x4000_0000u32
KERNEL_TABLES = USERSPACE_START.unsafe_div(0x400000)

module Paging
  extend self

  # present, us, rw, global
  PT_MASK_GLOBAL = 0x107
  # present, us, rw
  PT_MASK = 0x7

  @@usable_physical_memory = 0u64
  def usable_physical_memory
    @@usable_physical_memory
  end

  @@current_page_dir = Pointer(PageStructs::PageDirectory).null

  def current_page_dir
    @@current_page_dir
  end

  def current_page_dir=(@@current_page_dir); end

  @@kernel_page_dir = Pointer(PageStructs::PageDirectory).null

  def init_table(
    text_start : Void*, text_end : Void*,
    data_start : Void*, data_end : Void*,
    stack_start : Void*, stack_end : Void*,
    mboot_header : Multiboot::MultibootInfo*
  )
    cur_mmap_addr = mboot_header.value.mmap_addr
    mmap_end_addr = cur_mmap_addr + mboot_header.value.mmap_length

    while cur_mmap_addr < mmap_end_addr
      cur_entry = Pointer(Multiboot::MemoryMapTable).new(cur_mmap_addr.to_u64)

      if cur_entry.value.base_addr != 0 && cur_entry.value.type == MULTIBOOT_MEMORY_AVAILABLE
        entry = cur_entry.value
        FrameAllocator.add_region entry.base_addr, entry.length
        @@usable_physical_memory += entry.length
      end

      cur_mmap_addr += cur_entry[0].size + sizeof(UInt32)
    end

    FrameAllocator.each_region do |region|
      Serial.puts region, '\n'
    end

    @@current_page_dir = Pointer(PageStructs::PageDirectory).pmalloc_a
    @@kernel_page_dir = @@current_page_dir

    # vga
    alloc_page_init false, false, 0xb8000

    # text segment
    i = text_start.address.to_u32
    while i < text_end.address.to_u32
      alloc_frame false, false, i
      i += 0x1000
    end
    # data segment
    i = data_start.address.to_u32
    while i < data_end.address.to_u32
      alloc_frame true, false, i
      i += 0x1000
    end
    # stack segment
    i = stack_start.address.to_u32
    while i < stack_end.address.to_u32
      alloc_frame true, false, i
      i += 0x1000
    end
    # claim placement heap segment
    # we do this because the kernel's page table lies here:
    i = PMALLOC_STATE.start.to_u64
    while i <= aligned(PMALLOC_STATE.addr)
      FrameAllocator.initial_claim(i)
      i += 0x1000
    end
    # -- switch page directory
    enable
  end

  def aligned(x : UInt32) : UInt32
    (x & 0xFFFF_F000) + 0x1000
  end

  # state
  @[AlwaysInline]
  def enable
    addr = @@current_page_dir.address.to_u32
    PageStructs.kenable_paging(addr)
  end

  @[AlwaysInline]
  def disable
    PageStructs.kdisable_paging
  end

  # allocate page when pg is enabled
  # returns page address
  def alloc_page_pg(virt_addr_start : UInt32, rw : Bool, user : Bool, npages : UInt32 = 1) : UInt32
    Idt.disable
    disable

    virt_addr = virt_addr_start & 0xFFFF_F000
    virt_addr_end = virt_addr_start + npages * 0x1000

    # claim
    while virt_addr < virt_addr_end
      # Serial.puts "virt addr: ", Pointer(Void).new(virt_addr.to_u64), "\n"
      # allocate page frame
      iaddr, addr = FrameAllocator.claim_with_addr

      # create new page
      page_addr = virt_addr.unsafe_div 0x1000
      table_idx = page_addr.unsafe_div 0x1000
      if @@current_page_dir.value.tables[table_idx] == 0
        # page table isn't present
        # claim a page for storing the page table
        pt_iaddr, pt_addr = FrameAllocator.claim_with_addr
        zero_page Pointer(UInt8).new(pt_addr.to_u64)
        if user
          pt_addr |= PT_MASK
        else
          pt_addr |= PT_MASK_GLOBAL
        end
        @@current_page_dir.value.tables[table_idx] = pt_addr
      end
      alloc_page(rw, user, virt_addr, addr)

      virt_addr += 0x1000
    end

    enable
    Idt.enable

    # return page
    virt_addr_start
  end

  def free_page_pg(virt_addr_start : UInt32, npages : UInt32 = 1)
    Idt.disable
    disable

    virt_addr_end = virt_addr_start + npages * 0x1000
    virt_addr = virt_addr_start

    while virt_addr < virt_addr_end
      address = free_page virt_addr
      idx = frame_index_for_address address
      declaim_frame idx
      virt_addr += 0x1000
    end

    enable
    Idt.enable
  end

  # allocate page directories for processes
  # NOTE: paging must be disabled for these to work
  def alloc_process_page_dir
    # claim frame for page directory
    iaddr, pd_addr = FrameAllocator.claim_with_addr
    pd = Pointer(PageStructs::PageDirectory).new(pd_addr.to_u64)
    zero_page Pointer(UInt8).new(pd_addr.to_u64)

    # copy lower half (kernel half)
    KERNEL_TABLES.times do |i|
      pd.value.tables[i] = @@kernel_page_dir.value.tables[i]
    end

    # return
    pd.address
  end

  def free_process_page_dir(pda : UInt32)
    Paging.disable

    pd = Pointer(PageStructs::PageDirectory).new(pda.to_u64)
    # free the higher half
    i = KERNEL_TABLES
    while i < 1024
      pta = pd.value.tables[i] & 0xFFFF_F000
      pt = Pointer(PageStructs::PageTable).new(pta.to_u64)
      # free tables
      if pta != 0
        j = 0
        while j < 1024
          if pt.value.pages[j] != 0
            frame = pt.value.pages[j] & 0xFFFF_F000
            FrameAllocator.declaim_addr(frame.to_u64)
          end
          j += 1
        end
        FrameAllocator.declaim_addr(pta.to_u64)
      end
      i += 1
    end

    # free itself
    FrameAllocator.declaim_addr(pda.to_u64)

    Paging.enable
  end

  # page creation
  private def page_create(rw : Bool, user : Bool, phys : UInt32) : UInt32
    page = 0x1u32
    if rw # second bit
      page |= 0x2u32
    end
    if user # third bit
      page |= 0x4u32
    end
    page |= phys & 0xFFFF_F000
    page
  end

  # page alloc at init
  private def alloc_page_init(rw : Bool, user : Bool, address : UInt32)
    phys = address
    address = address.unsafe_div(0x1000)
    table_idx = address.unsafe_div(0x1000).to_i32
    if @@current_page_dir.value.tables[table_idx] == 0
      ptr = Pointer(PageStructs::PageTable).pmalloc_a
      pt_addr = ptr.address.to_u32
      if user
        pt_addr |= PT_MASK
      else
        pt_addr |= PT_MASK_GLOBAL
      end
      @@current_page_dir.value.tables[table_idx] = pt_addr
    else
      ptr = Pointer(PageStructs::PageTable).new((@@current_page_dir.value.tables[table_idx] & 0xFFFF_F000).to_u64)
    end
    page = page_create(rw, user, phys)
    ptr.value.pages[address.unsafe_mod 0x1000] = page
  end

  private def alloc_frame(rw : Bool, user : Bool, address : UInt32)
    FrameAllocator.initial_claim(address.to_u64)
    alloc_page_init(rw, user, address)
  end

  # page alloc at runtime
  private def alloc_page(rw : Bool, user : Bool, address : UInt32, phys : UInt32)
    address = address.unsafe_div(0x1000)
    table_idx = address.unsafe_div(0x1000).to_i32
    page = page_create(rw, user, phys)
    panic "no table for page" if @@current_page_dir.value.tables[table_idx] == 0
    ptr = Pointer(PageStructs::PageTable).new((@@current_page_dir.value.tables[table_idx] & 0xFFFF_F000).to_u64)
    ptr.value.pages[address.unsafe_mod 0x1000] = page
  end

  private def free_page(address : UInt32)
    address = address.unsafe_div(0x1000)
    table_idx = address.unsafe_div(0x1000).to_i32
    panic "no table for page" if @@current_page_dir.value.tables[table_idx].null?
    @@current_page_dir.value.tables[table_idx].value.pages[address.unsafe_mod 0x1000] = 0
  end
end
