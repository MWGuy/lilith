lib LibCrystal
  $__crystal_gc_globals : Void***
  fun type_offsets = "__crystal_malloc_type_offsets"(type_id : UInt32) : UInt32
  fun type_size = "__crystal_malloc_type_size"(type_id : UInt32) : UInt32
end

fun __crystal_malloc64(size : UInt64) : Void*
  Gc.unsafe_malloc size
end

fun __crystal_malloc_atomic64(size : UInt64) : Void*
  Gc.unsafe_malloc size, true
end

module Gc
  extend self

  lib Data
    struct GrayNode
      prev_node : GrayNode*
      next_node : GrayNode*
      ptr : Void*
    end
  end

  # whether the gc is enabled
  @@enabled = false
  class_property enabled

  GRAY_SIZE = 256
  @@front_grays = uninitialized Void*[GRAY_SIZE]
  @@front_grays_idx = 0
  @@back_grays = uninitialized Void*[GRAY_SIZE]
  @@back_grays_idx = 0
  @@use_front_grays = true

  # whether the opposite gray stack is full enough for 1 more allocation
  # (we need that for a newly allocated object)
  private def opposite_gray_full?
    if @@use_front_grays
      @@back_grays_idx == GRAY_SIZE - 2
    else
      @@front_grays_idx == GRAY_SIZE - 2
    end
  end

  # whether the current gray stack is empty
  private def gray_empty?
    if @@use_front_grays
      @@front_grays_idx == 0
    else
      @@back_grays_idx == 0
    end
  end

  # pushes a node to the current gray stack
  private def push_gray(ptr : Void*)
    return if Arena.marked? ptr
    Arena.mark ptr
    if @@use_front_grays
      @@front_grays[@@front_grays_idx] = ptr
      @@front_grays_idx += 1
    else
      @@back_grays[@@back_grays_idx] = ptr
      @@back_grays_idx += 1
    end
  end

  # pushes a node to the opposite gray stack
  private def push_opposite_gray(ptr : Void*)
    return if Arena.marked? ptr
    Arena.mark ptr
    if @@use_front_grays
      @@back_grays[@@back_grays_idx] = ptr
      @@back_grays_idx += 1
    else
      @@front_grays[@@front_grays_idx] = ptr
      @@front_grays_idx += 1
    end
  end

  # pops a node from the current gray stack
  private def pop_gray(n : Int = 1)
    if @@use_front_grays
      return nil if @@front_grays_idx == 0
      ptr = @@front_grays[@@front_grays_idx - 1]
      @@front_grays_idx -= n
      ptr
    else
      return nil if @@back_grays_idx == 0
      ptr = @@back_grays[@@back_grays_idx - 1]
      @@back_grays_idx -= n
      ptr
    end
  end

  # swap gray stacks
  private def swap_grays
    @@use_front_grays = !@@use_front_grays
    if @@use_front_grays
      @@back_grays_idx = 0
    else
      @@front_grays_idx = 0
    end
  end

  private enum State
    ScanRoot
    ScanGray
    Sweep
  end
  @@state = State::ScanRoot

  @@stack_start = Pointer(Void).null
  @@stack_end = Pointer(Void).null

  def init(@@stack_start : Void*, @@stack_end : Void*)
    @@enabled = true
  end

  private def scan_globals
    global_ptr = LibCrystal.__crystal_gc_globals
    while (ptr = global_ptr.value) && !opposite_gray_full?
      root_ptr = ptr.value
      if Arena.contains_ptr? root_ptr
        push_gray root_ptr
      end
      global_ptr += 1
    end
  end

  private def scan_stack
    sp = 0u64
    asm("" : "={rsp}"(sp))
    while sp < @@stack_end.address && !opposite_gray_full?
      root_ptr = Pointer(Void*).new(sp).value
      if Arena.contains_ptr? root_ptr
        push_gray root_ptr
      end
      sp += 8
    end
  end

  private def scan_gray_nodes
    while ptr = pop_gray
      scan_object ptr
    end
  end

  private def scan_object(ptr : Void*)
    # TODO: atomic ptrs and arrays
    pushed = 0
    id = ptr.as(UInt32*).value
    offsets = LibCrystal.type_offsets id
    pos = 0
    size = LibCrystal.type_size id
    while pos < size
      if (offsets & 1) != 0
        ivar = Pointer(Void*).new(ptr.address + pos).value
        if Arena.contains_ptr? ivar
          push_opposite_gray ivar
        end
      end
      offsets >>= 1
      pos += sizeof(Void*)
    end
    # size = LibCrystal.type_size
    # TODO
  end

  def cycle
    case @@state
    when State::ScanRoot
      Serial.print "scan root!\n"
      scan_globals
      scan_stack
      @@state = State::ScanGray
      false
    when State::ScanGray
      Serial.print "scan!\n"
      scan_gray_nodes
      swap_grays
      if gray_empty?
        @@state = State::Sweep
      end
      false
    when State::Sweep
      Serial.print "sweep!\n"
      Arena.sweep
      @@state = State::ScanRoot
      true
    end
  end

  def full_cycle
    while true
      return if cycle
    end
  end

  def unsafe_malloc(size : UInt64, atomic = false)
    if enabled
      cycle
      dump Serial
    end
    ptr = Arena.malloc(size)
    push_gray ptr
    ptr
  end

  def dump(io)
    io.print "Gc {\n"
    if @@use_front_grays
      io.print "  [front_grays] (",  @@front_grays_idx, "): "
    else
      io.print "  front_grays (",  @@front_grays_idx, "): "
    end
    @@front_grays_idx.times do |i|
      io.print @@front_grays[i]
    end
    io.print "\n"
    if !@@use_front_grays
      io.print "  [back_grays] (",  @@back_grays_idx, "): "
    else
      io.print "  back_grays (",  @@back_grays_idx, "): "
    end
    @@back_grays_idx.times do |i|
      io.print @@back_grays[i]
    end
    io.print "\n}\n"
  end
end
