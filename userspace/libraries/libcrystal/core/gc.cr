lib LibCrystal
  fun type_offsets="__crystal_malloc_type_offsets"(type_id : UInt32) : UInt32
  fun type_size="__crystal_malloc_type_size"(type_id : UInt32) : UInt32

  struct GcNode
    next_node : GcNode*
    magic : USize
  end
end

lib LibC
  fun fprintf(file : Void*, x0 : UInt8*, ...) : Int
  fun malloc(size : LibC::SizeT) : Void*
  fun free(data : Void*)

  fun __libc_heap_start : Void*
  fun __libc_heap_placement : Void*
  $stderr : Void*
end

fun __crystal_malloc64(size : UInt64) : Void*
  Gc.unsafe_malloc size
end

fun __crystal_malloc_atomic64(size : UInt64) : Void*
  Gc.unsafe_malloc size, true
end

# white nodes
private GC_NODE_MAGIC        = 0x45564100
private GC_NODE_MAGIC_ATOMIC = 0x45564101
# gray nodes
private GC_NODE_MAGIC_GRAY        = 0x45564102
private GC_NODE_MAGIC_GRAY_ATOMIC = 0x45564103
# black
private GC_NODE_MAGIC_BLACK        = 0x45564104
private GC_NODE_MAGIC_BLACK_ATOMIC = 0x45564105

module Gc
  extend self

  @@first_white_node = Pointer(LibCrystal::GcNode).null
  @@first_gray_node = Pointer(LibCrystal::GcNode).null
  @@first_black_node = Pointer(LibCrystal::GcNode).null
  @@enabled = false
  @@root_scanned = false
  
  # Number of garbage collection cycles performed
  @@ticks = 0
  # Last tick when sweep phase was performed
  @@last_sweep_tick = 0
  # Last tick when mark phase was started
  @@last_start_tick = 0

  def _init(@@data_start : UInt64, @@data_end : UInt64,
            @@bss_start : UInt64,  @@bss_end : UInt64,
            @@stack_end : UInt64)
    @@enabled = true
  end

  private macro push(list, node)
    if {{ list }}.null?
      # first node
      {{ node }}.value.next_node = Pointer(LibCrystal::GcNode).null
      {{ list }} = {{ node }}
    else
      # middle node
      {{ node }}.value.next_node = {{ list }}
      {{ list }} = {{ node }}
    end
  end

  # gc algorithm
  private def scan_region(start_addr : UInt64, end_addr : UInt64, move_list = true)
    # due to the way this rechains the linked list of white nodes
    # please set move_list=false when not scanning for root nodes
    # LibC.fprintf(LibC.stderr, "scan_region: %p %p\n", start_addr.to_usize, end_addr.to_usize)
    i = start_addr
    fix_white = false
    heap_start = LibC.__libc_heap_start.address
    heap_placement = LibC.__libc_heap_placement.address
    # LibC.fprintf(LibC.stderr, "heap: %p %p\n", heap_start.to_usize, heap_placement.to_usize)

    scan_end = end_addr - sizeof(Void*) + 1
    until scan_end.to_usize == i.to_usize
      word = Pointer(USize).new(i).value
      # subtract to get the pointer to the header
      word -= sizeof(LibCrystal::GcNode)
      # LibC.fprintf(LibC.stderr, "%p (%d) %p\n", i.to_usize, i.to_u32 == scan_end.to_u32, word.to_usize)
      if word >= heap_start && word <= heap_placement
        node = @@first_white_node
        prev = Pointer(LibCrystal::GcNode).null
        found = false
        while !node.null?
          if node.address == word
            # word looks like a valid gc header pointer!
            # remove from current list
            if move_list
              if !prev.null?
                prev.value.next_node = node.value.next_node
              else
                @@first_white_node = node.value.next_node
              end
            end
            # add to gray list
            # debug_mark Pointer(LibCrystal::GcNode).new(i), node, false
            case node.value.magic
            when GC_NODE_MAGIC
              node.value.magic = GC_NODE_MAGIC_GRAY
              if move_list
                push(@@first_gray_node, node) 
              end
              fix_white = true
            when GC_NODE_MAGIC_ATOMIC
              node.value.magic = GC_NODE_MAGIC_GRAY_ATOMIC
              if move_list
                push(@@first_gray_node, node) 
              end
              fix_white = true
            when GC_NODE_MAGIC_BLACK | GC_NODE_MAGIC_BLACK_ATOMIC
              abort "invariance broken"
            else
              # this node is gray
            end
            found = true
            break
          end
          # next it
          prev = node
          node = node.value.next_node
        end
        # LibC.fprintf(LibC.stderr, "%p", word.to_usize)
        # LibC.fprintf(LibC.stderr, " (found)") if found
        # LibC.fprintf(LibC.stderr, "\n")
      end
      i += 1
    end
    fix_white
  end

  private enum CycleType
    Mark
    Sweep
  end

  def cycle
    @@ticks += 1

    # marking phase
    if !@@root_scanned
      # we don't have any gray/black nodes at the beginning of a cycle
      # conservatively scan the stack for pointers
      scan_region @@data_start.not_nil!, @@data_end.not_nil!
      scan_region @@bss_start.not_nil!, @@bss_end.not_nil!

      stack_start = 0u64
      {% if flag?(:i686) %}
        asm("mov %esp, $0" : "=r"(stack_start) :: "volatile")
      {% else %}
        asm("mov %rsp, $0" : "=r"(stack_start) :: "volatile")
      {% end %}
      scan_region stack_start, @@stack_end.not_nil!

      @@root_scanned = true
      @@last_start_tick = @@ticks
      return CycleType::Mark
    elsif !@@first_gray_node.null?
      # second stage of marking phase: precisely marking gray nodes
      # new_first_gray_node = Pointer(LibCrystal::GcNode).null

      fix_white = false
      node = @@first_gray_node
      while !node.null?
        # LibC.fprintf(LibC.stderr, "node: %p\n", node)
        if node.value.magic == GC_NODE_MAGIC_GRAY_ATOMIC
          # skip atomic nodes
          # debug "skip\n"
          node.value.magic = GC_NODE_MAGIC_BLACK_ATOMIC
          node = node.value.next_node
          next
        end

        # LibC.fprintf(LibC.stderr, "magic: %x\n", node.value.magic.to_u32)
        abort "invariance broken" if node.value.magic == GC_NODE_MAGIC || node.value.magic == GC_NODE_MAGIC_ATOMIC

        node.value.magic = GC_NODE_MAGIC_BLACK

        buffer_addr = node.address + sizeof(LibCrystal::GcNode) + sizeof(Void*)
        header_ptr = Pointer(USize).new(node.address + sizeof(LibCrystal::GcNode))
        # get its type id
        type_id = header_ptr[0]
        # LibC.fprintf(LibC.stderr, "%d\n", type_id.to_u32)
        # skip strings (for some reason strings aren't allocated atomically)
        if type_id == String::TYPE_ID
          node = node.value.next_node
          next
        end
        # handle gc array
        if type_id == GC_ARRAY_HEADER_TYPE
          len = header_ptr[1]
          i = 0
          start = Pointer(USize).new(node.address + sizeof(LibCrystal::GcNode) + GC_ARRAY_HEADER_SIZE)
          while i < len
            addr = start[i]
            if addr != 0
              # mark the header as gray
              header = Pointer(LibCrystal::GcNode).new(addr.to_u64 - sizeof(LibCrystal::GcNode))
              # debug_mark node, header
              case header.value.magic
              when GC_NODE_MAGIC
                header.value.magic = GC_NODE_MAGIC_GRAY
                fix_white = true
              when GC_NODE_MAGIC_ATOMIC
                header.value.magic = GC_NODE_MAGIC_GRAY_ATOMIC
                fix_white = true
              else
                # this node is either gray or black
              end
            end
            i += 1
          end
          node = node.value.next_node
          next
        end
        # lookup its offsets
        offsets = LibCrystal.type_offsets type_id
        if offsets == 0
          # LibC.fprintf(LibC.stderr, "type_id doesn't have offset\n")
          node = node.value.next_node
          next
        end
        # precisely scan the struct based on the offsets
        pos = 0
        while offsets != 0
          if offsets & 1
            # lookup the buffer address in its offset
            addr = Pointer(USize).new(buffer_addr + pos * sizeof(Void*)).value.to_u64
            if addr == 0
              # must be a nil union, skip
              pos += 1
              offsets >>= 1
              next
            end
            scan_node = @@first_white_node
            header = Pointer(LibCrystal::GcNode).new(addr - sizeof(LibCrystal::GcNode))
            # LibC.fprintf(LibC.stderr, "%p\n", header)
            while !scan_node.null?
              if header.address == scan_node.address
                case header.value.magic
                when GC_NODE_MAGIC
                  header.value.magic = GC_NODE_MAGIC_GRAY
                  fix_white = true
                when GC_NODE_MAGIC_ATOMIC
                  header.value.magic = GC_NODE_MAGIC_GRAY_ATOMIC
                  fix_white = true
                else
                  # this node is either gray or black
                end
                break
              end
              scan_node = scan_node.value.next_node
            end
          end
          pos += 1
          offsets >>= 1
        end
        node = node.value.next_node
      end

      # nodes in @@first_gray_node are now black
      node = @@first_gray_node
      while !node.value.next_node.null?
        node = node.value.next_node
      end
      node.value.next_node = @@first_black_node
      @@first_black_node = @@first_gray_node
      @@first_gray_node = Pointer(LibCrystal::GcNode).null
      # some nodes in @@first_white_node are now gray
      if fix_white
        # debug "fix white nodes\n"
        node = @@first_white_node
        new_first_white_node = Pointer(LibCrystal::GcNode).null
        while !node.null?
          next_node = node.value.next_node
          if node.value.magic == GC_NODE_MAGIC || node.value.magic == GC_NODE_MAGIC_ATOMIC
            push(new_first_white_node, node)
            node = next_node
          elsif node.value.magic == GC_NODE_MAGIC_GRAY || node.value.magic == GC_NODE_MAGIC_GRAY_ATOMIC
            push(@@first_gray_node, node)
            node = next_node
          else
            abort "invariance broken"
          end
          node = next_node
        end
        @@first_white_node = new_first_white_node
      end

      if @@first_gray_node.null?
        # sweeping phase
        # debug "sweeping phase: ", self, "\n"
        @@last_sweep_tick = @@ticks
        # calc_cycles_per_alloc
        node = @@first_white_node
        while !node.null?
          abort "invariance broken" unless node.value.magic == GC_NODE_MAGIC || node.value.magic == GC_NODE_MAGIC_ATOMIC
          next_node = node.value.next_node
          # LibC.fprintf(LibC.stderr, "free %p\n", node+1)
          LibC.free node.as(Void*)
          node = next_node
        end
        @@first_white_node = @@first_black_node
        node = @@first_white_node
        while !node.null?
          case node.value.magic
          when GC_NODE_MAGIC_BLACK
            node.value.magic = GC_NODE_MAGIC
          when GC_NODE_MAGIC_BLACK_ATOMIC
            node.value.magic = GC_NODE_MAGIC_ATOMIC
          else
            abort "invariance broken"
          end
          node = node.value.next_node
        end
        @@first_black_node = Pointer(LibCrystal::GcNode).null
        @@root_scanned = false
        # begins a new cycle
        return CycleType::Sweep
      else
        return CycleType::Mark
      end
    end
  end

  def unsafe_malloc(size : UInt64, atomic = false)
    if @@enabled
      cycle
    end
    size += sizeof(LibCrystal::GcNode)
    header = LibC.malloc(size).as(LibCrystal::GcNode*)
    # move the barrier forwards by immediately graying out the header
    header.value.magic = atomic ? GC_NODE_MAGIC_GRAY_ATOMIC : GC_NODE_MAGIC_GRAY
    # append node to linked list
    if @@enabled
      push(@@first_gray_node, header)
    end
    # return
    ptr = Pointer(Void).new(header.address + sizeof(LibCrystal::GcNode))
    # dump_nodes if @@enabled
    ptr
  end

  # printing
  private def out_nodes(first_node)
    node = first_node
    while !node.null?
      body = node.as(USize*) + 2
      type_id = (node + 1).as(USize*)[0]
      LibC.fprintf(LibC.stderr, "%p (%d), ", body, type_id)
      node = node.value.next_node
    end
  end

  def dump_nodes
    LibC.fprintf(LibC.stderr, "Gc {\n")
    LibC.fprintf(LibC.stderr, "  white_nodes: ")
    out_nodes(@@first_white_node)
    LibC.fprintf(LibC.stderr, "\n")
    LibC.fprintf(LibC.stderr, "  gray_nodes: ")
    out_nodes(@@first_gray_node)
    LibC.fprintf(LibC.stderr, "\n")
    LibC.fprintf(LibC.stderr, "  black_nodes: ")
    out_nodes(@@first_black_node)
    LibC.fprintf(LibC.stderr, "\n}\n")
 end
end