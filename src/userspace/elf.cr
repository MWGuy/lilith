lib ElfStructs
  # http://www.skyfree.org/linux/references/ELF_Format.pdf
  # https://0x00sec.org/t/dissecting-and-exploiting-elf-files/7267

  @[Packed]
  struct Elf32Header
    e_ident : UInt8[16]
    e_type : Elf32EType
    e_machine : UInt16
    e_version : UInt32
    e_entry : UInt32
    e_phoff : UInt32
    e_shoff : UInt32
    e_flags : UInt32
    e_ehsize : UInt16
    e_phentsize : UInt16
    e_phnum : UInt16
    e_shentsize : UInt16
    e_shnum : UInt16
    e_shstrndx : UInt16
  end

  enum Elf32EType : UInt16
    ET_NONE = 0
    ET_REL  = 1
    ET_EXEC = 2
    ET_DYN  = 3
    ET_CORE = 4
  end

  @[Packed]
  struct Elf32ProgramHeader
    p_type : Elf32PType
    p_offset : UInt32
    p_vaddr : UInt32
    p_paddr : UInt32
    p_filesz : UInt32
    p_memsz : UInt32
    p_flags : Elf32PFlags
    p_align : UInt32
  end

  enum Elf32PType : UInt32
    NULL_TYPE    =          0
    LOAD         =          1
    DYNAMIC      =          2
    INTERP       =          3
    NOTE         =          4
    SHLIB        =          5
    PHDR         =          6
    TLS          =          7
    GNU_EH_FRAME = 1685382480
    GNU_STACK    = 1685382481
    GNU_RELRO    = 1685382482
    PAX_FLAGS    = 1694766464
    HIOS         = 1879048191
    ARM_EXIDX    = 1879048193
  end

  @[Flags]
  enum Elf32PFlags : UInt32
    PF_X = 0x1
    PF_W = 0x2
    PF_R = 0x4
  end

  #
  @[Packed]
  struct Elf32SectionHeader
    sh_name : UInt32
    sh_type : Elf32PType
    sh_flags : UInt32
    sh_addr : UInt32
    sh_offset : UInt32
    sh_size : UInt32
    sh_link : UInt32
    sh_info : UInt32
    sh_addralign : UInt32
    sh_entsize : UInt32
  end
end

module ElfReader
  extend self

  EI_MAG0       = 0 # 0x7F
  EI_MAG1       = 1 # 'E'
  EI_MAG2       = 2 # 'L'
  EI_MAG3       = 3 # 'F'
  EI_CLASS      = 4 # Architecture (32/64)
  EI_DATA       = 5 # Byte Order
  EI_VERSION    = 6 # ELF Version
  EI_OSABI      = 7 # OS Specific
  EI_ABIVERSION = 8 # OS Specific
  EI_PAD        = 9 # Padding

  private enum ParserState
    Byte
    ElfHeader
    ProgramHeader
    SegmentHeader
  end

  enum ParserError
    EmptyFile
    InvalidElfHdr
    InvalidProgramHdrSz
    ExpectedProgramHdr
  end

  def read(node : VFSNode, allocator = nil, &block)
    state = ParserState::ElfHeader
    header = uninitialized ElfStructs::Elf32Header
    pheader = uninitialized ElfStructs::Elf32ProgramHeader

    idx_h = 0u32
    n_pheader = 0u32
    total_bytes = 0u32
    node.read(allocator: allocator) do |byte|
      case state
      when ParserState::ElfHeader
        pointerof(header).as(UInt8*)[idx_h] = byte
        idx_h += 1
        if idx_h == sizeof(ElfStructs::Elf32Header)
          unless header.e_ident[0] == 127 &&
                 header.e_ident[1] == 69 &&
                 header.e_ident[2] == 76 &&
                 header.e_ident[3] == 70
            return ParserError::InvalidElfHdr
          end
          unless header.e_phentsize == sizeof(ElfStructs::Elf32ProgramHeader)
            return ParserError::InvalidProgramHdrSz
          end
          yield header
          if header.e_phoff == total_bytes + 1
            state = ParserState::ProgramHeader
            idx_h = 0
          else
            return ParserError::ExpectedProgramHdr
          end
        end
      when ParserState::ProgramHeader
        pointerof(pheader).as(UInt8*)[idx_h] = byte
        idx_h += 1
        if idx_h == sizeof(ElfStructs::Elf32ProgramHeader)
          yield pheader
          n_pheader += 1
          idx_h = 0
        end
        if n_pheader == header.e_phnum
          state = ParserState::Byte
          idx_h = 0
        end
      when ParserState::Byte
        if total_bytes < header.e_shoff
          yield Tuple.new(total_bytes, byte)
        else
          break
        end
        # TODO section headers
      else
        panic "unknown"
      end
      total_bytes += 1
    end
    if total_bytes < sizeof(ElfStructs::Elf32Header)
      return ParserError::InvalidElfHdr
    end
    nil
  end

  struct InlineMemMapNode
    getter file_offset, filesz, vaddr, memsz, attrs
    def initialize(@file_offset : UInt64, @filesz : UInt64, @vaddr : UInt64,
          @memsz : UInt64, @attrs : MemMapNode::Attributes)
    end
  end

  struct Result
    getter initial_ip, heap_start, mmap_list
    def initialize(@initial_ip : USize, @heap_start : USize, @mmap_list : Slice(InlineMemMapNode))
    end
  end

  # load process code from kernel thread
  def load_from_kernel_thread(node, allocator : StackAllocator)
    unless node.size > 0
      return ParserError::EmptyFile
    end
    mmap_list = Slice(InlineMemMapNode).null
    mmap_append_idx = 0
    mmap_idx = 0

    ret_initial_ip = 0u64
    ret_heap_start = 0u64

    result = ElfReader.read(node, allocator) do |data|
      case data
      when ElfStructs::Elf32Header
        data = data.as(ElfStructs::Elf32Header)
        ret_initial_ip = data.e_entry.to_usize
        sz = data.e_phnum.to_i32
        mmap_list = Slice(InlineMemMapNode).new(allocator.malloc(sz * sizeof(InlineMemMapNode)).as(InlineMemMapNode*), sz)
      when ElfStructs::Elf32ProgramHeader
        data = data.as(ElfStructs::Elf32ProgramHeader)
        if data.p_memsz > 0
          # mmap
          attrs = MemMapNode::Attributes::None
          if data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_R)
            attrs |= MemMapNode::Attributes::Read
          end
          if data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_W)
            attrs |= MemMapNode::Attributes::Write
          end
          if data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_X)
            attrs |= MemMapNode::Attributes::Execute
          end
          mmap_list[mmap_append_idx] =
            InlineMemMapNode.new(data.p_offset.to_u64, data.p_filesz.to_u64,
              data.p_vaddr.to_u64, data.p_memsz.to_u64, attrs)
          mmap_append_idx += 1

          if data.p_type == ElfStructs::Elf32PType::TLS
            # TODO
          elsif data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_R)
            section_start = Paging.t_addr(data.p_vaddr.to_u64)
            section_end = Paging.aligned(data.p_vaddr.to_u64 + data.p_memsz.to_u64)
            npages = (section_end - section_start) >> 12
            # create page and zero-initialize it
            # Serial.puts Pointer(Void).new(data.p_vaddr.to_u64), data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_W), '\n'
            page_start = Paging.alloc_page_pg_drv(section_start,
              data.p_flags.includes?(ElfStructs::Elf32PFlags::PF_W),
              true, npages)
            zero_page Pointer(UInt8).new(page_start), npages
          end
          # heap should start right after the last segment
          heap_start = Paging.aligned(data.p_vaddr.to_usize + data.p_memsz.to_usize)
          ret_heap_start = max ret_heap_start, heap_start
        end
      when Tuple(UInt32, UInt8)
        offset, byte = data.as(Tuple(UInt32, UInt8))
        if !mmap_list.null? && mmap_idx < mmap_append_idx
          mmap_node = mmap_list[mmap_idx]
          if offset == mmap_node.file_offset + mmap_node.filesz - 1
            mmap_idx += 1
          elsif offset >= mmap_node.file_offset && offset < mmap_node.file_offset + mmap_node.filesz
            ptr = Pointer(UInt8).new(mmap_node.vaddr.to_usize)
            ptr[offset - mmap_node.file_offset] = byte
          end
        end
      end
    end
    if result.nil?
      # pad heap offset
      ret_heap_start += 0x2000
      # allocate the stack
      Paging.alloc_page_pg_drv(Multiprocessing::USER_STACK_INITIAL - 0x1000 * 4, true, true, 4)
      Result.new(ret_initial_ip, ret_heap_start, mmap_list)
    else
      result
    end
  end
end
