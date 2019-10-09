lib LibCrystal
  fun type_offsets="__crystal_malloc_type_offsets"(type_id : UInt32) : UInt32
  fun type_size="__crystal_malloc_type_size"(type_id : UInt32) : UInt32
end

fun __crystal_malloc64(size : UInt64) : Void*
  Gc.unsafe_malloc size
end

fun __crystal_malloc_atomic64(size : UInt64) : Void*
  Gc.unsafe_malloc size, true
end

module Gc
  extend self

  def cycle
    # TODO
  end

  def unsafe_malloc(size : UInt64, atomic=false)
    Pointer(Void).null
  end

end
