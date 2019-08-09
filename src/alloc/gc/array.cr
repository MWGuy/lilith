GC_ARRAY_HEADER_TYPE = 0xFFFF_FFFF_FFFF_FFFFu64
GC_ARRAY_HEADER_SIZE = 8

class GcArray(T)
  GC_GENERIC_TYPES = [
    GcArray(MemMapNode),
    GcArray(FileDescriptor),
    GcArray(AtaDevice),
    GcArray(GcString),
  ]

  @capacity : Int64 = 0
  getter capacity
  
  # array data is stored in buffer, and so is size
  def size
    @ptr[1].to_isize
  end

  private def size=(new_size)
    @ptr[1] = new_size.to_usize
  end

  # init
  def initialize(new_size : Int)
    malloc_size = new_size.to_usize * sizeof(Void*) + GC_ARRAY_HEADER_SIZE
    @ptr = Gc.unsafe_malloc(malloc_size).as(USize*)
    @ptr[0] = GC_ARRAY_HEADER_TYPE
    @ptr[1] = new_size.to_usize
    # clear array
    i = 0
    while i < new_size
      buffer.as(USize*)[i] = 0u64
      i += 1
    end
    # capacity
    recalculate_capacity
  end

  # helper
  private def buffer
    (@ptr + 2).as(T*)
  end

  private def recalculate_capacity
    @capacity = (KernelArena.block_size_for_ptr(@ptr) - GC_ARRAY_HEADER_SIZE)
      .unsafe_div(sizeof(Void*)).to_isize
  end

  # getter/setter
  def [](idx : Int) : T?
    panic "GcArray: out of range" if idx < 0 && idx > size
    if buffer.as(USize*)[idx] == 0
      nil
    else
      buffer[idx]
    end
  end

  def []=(idx : Int, value : T)
    panic "GcArray: out of range" if idx < 0 && idx > size
    buffer[idx] = value
  end

  # resizing
  private def new_buffer(new_size)
    malloc_size = new_size.to_usize * sizeof(Void*) + GC_ARRAY_HEADER_SIZE
    ptr = Gc.unsafe_malloc(malloc_size).as(USize*)
    ptr[0] = GC_ARRAY_HEADER_TYPE
    ptr[1] = new_size.to_usize
    new_buffer = Pointer(USize).new((ptr.address + GC_ARRAY_HEADER_SIZE).to_u64)
    # copy over
    i = 0
    while i < new_size
      new_buffer[i] = buffer.as(USize*)[i]
      i += 1
    end
    @ptr = ptr
    # capacity
    recalculate_capacity
  end

  def push(value : T)
    if size < capacity
      buffer[size] = value
      self.size += 1
    else
      panic "gcarray: resize?"
    end
  end

  # iterator
  def each(&block)
    i = 0
    while i < size
      if buffer.as(USize*)[i] == 0
        yield nil
      else
        yield buffer[i]
      end
      i += 1
    end
  end
end