module Pmalloc
  extend self

  @@addr = 0u32
  def addr; @@addr; end
  def addr=(@@addr); end
  @@start = 0u32
  def start; @@start; end
  def start=(@@start); end

  def alloc(size : Int)
    last = @@addr
    @@addr += size.to_u32
    last
  end

  def alloca(size : Int)
    if (@@addr & 0xFFFF_F000) != 0
      @@addr = (@@addr & 0xFFFF_F000) + 0x1000
    end
    alloc(size)
  end
end

struct Pointer(T)
  def self.null
    new 0u64
  end

  # pre-pg malloc
  def self.pmalloc(size : Int)
    ptr = new Pmalloc.alloc(size.to_u32 * sizeof(T)).to_u64
    memset ptr.as(UInt8*), 0, size.to_u32 * sizeof(T)
    ptr
  end

  def self.pmalloc
    ptr = new Pmalloc.alloc(sizeof(T)).to_u64
    memset ptr.as(UInt8*), 0, sizeof(T).to_u32
    ptr
  end

  def self.pmalloc_a
    ptr = new Pmalloc.alloca(sizeof(T)).to_u64
    memset ptr.as(UInt8*), 0, sizeof(T).to_u32
    ptr
  end

  # pg malloc
  def self.malloc(size)
    Gc.unsafe_malloc(size.to_u32 * sizeof(T), true).as(T*)
  end

  def self.mmalloc(size = 1)
    new KERNEL_ARENA.malloc(size.to_u32 * sizeof(T)).to_u64
  end

  def mfree
    KERNEL_ARENA.free(self.address.to_u32)
  end

  # methods
  def to_s(io)
    io.puts "[0x"
    self.address.to_s io, 16
    io.puts "]"
  end

  def null?
    self.address == 0
  end

  # operators
  def [](offset : Int)
    (self + offset.to_i64).value
  end

  def []=(offset : Int, data : T)
    (self + offset.to_i64).value = data
  end

  def +(offset : Int)
    self + offset.to_i64
  end

  def -(offset : Int)
    self + (offset.to_i64 * -1)
  end

  def ==(other)
    self.address == other.address
  end

  def !=(other)
    self.address != other.address
  end
end
