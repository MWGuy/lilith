IDT_SIZE                   =     256
INTERRUPT_GATE             = 0x8Eu16
KERNEL_CODE_SEGMENT_OFFSET = 0x08u16

private lib Kernel
  {% for i in 0..31 %}
    fun kcpuex{{ i.id }}
  {% end %}
  {% for i in 0..15 %}
    fun kirq{{ i.id }}
  {% end %}

  @[Packed]
  struct Idt
    limit : UInt16
    base : UInt64
  end

  @[Packed]
  struct IdtEntry
    offset_1  : UInt16 # offset bits 0..15
    selector  : UInt16 # a code segment selector in GDT or LDT
    ist       : UInt8
    type_attr : UInt8  # type and attributes
    offset_2  : UInt16 # offset bits 16..31
    offset_3  : UInt32 # offset bits 32..63
    zero      : UInt32
  end

  fun kload_idt(idtr : UInt32)
end

lib IdtData
  @[Packed]
  struct Registers
    # Data segment selector
    ds : UInt16
    # Pushed by pushad:
    edi, esi, ebp, esp, ebx, edx, ecx, eax : UInt32
    # Interrupt number
    int_no : UInt32
    # Pushed by the processor automatically.
    eip, cs, eflags, useresp, ss : UInt32
  end

  struct ExceptionRegisters
    # Pushed by pushad:
    rdi, rsi,
    r15, r14, r13, r12, r11, r10, r9, r8,
    rdx, rcx, rbx, rax : UInt64
    # Interrupt number
    int_no, errcode : UInt64
    # Pushed by the processor automatically.
    ss, userrsp, rflags, cs, rip : UInt64
  end
end

alias InterruptHandler = -> Nil

module Idt
  extend self

  # initialize
  IRQ_COUNT = 16
  @@irq_handlers = uninitialized InterruptHandler[IRQ_COUNT]

  def initialize
    {% for i in 0...IRQ_COUNT %}
      @@irq_handlers[{{ i }}] = ->{ nil }
    {% end %}
  end

  def init_interrupts
    X86.outb 0x20, 0x11
    X86.outb 0xA0, 0x11
    X86.outb 0x21, 0x20
    X86.outb 0xA1, 0x28
    X86.outb 0x21, 0x04
    X86.outb 0xA1, 0x02
    X86.outb 0x21, 0x01
    X86.outb 0xA1, 0x01
    X86.outb 0x21, 0x0
    X86.outb 0xA1, 0x0
  end

  # table init
  IDT_SIZE = 256
  @@idtr = uninitialized Kernel::Idt
  @@idt = uninitialized Kernel::IdtEntry[IDT_SIZE]

  def init_table
    @@idtr.limit = sizeof(Kernel::IdtEntry) * IDT_SIZE - 1
    @@idtr.base = @@idt.to_unsafe.address

    # cpu exception handlers
    {% for i in 0..31 %}
      #init_idt_entry {{ i }}, KERNEL_CODE_SEGMENT_OFFSET, (->Kernel.kcpuex{{ i.id }}).pointer.address, INTERRUPT_GATE
    {% end %}

    # hw interrupts
    {% for i in 0..15 %}
      #init_idt_entry {{ i + 32 }}, KERNEL_CODE_SEGMENT_OFFSET, (->Kernel.kirq{{ i.id }}).pointer.address, INTERRUPT_GATE
    {% end %}

    Kernel.kload_idt pointerof(@@idtr).address.to_u32
  end

  def init_idt_entry(num : Int32, selector : UInt16, offset : UInt64, type : UInt16)
    idt = Kernel::IdtEntry.new
    idt.offset_1 = (offset & 0xFFFF)
    idt.ist = 0
    idt.selector = selector
    idt.type_attr = type
    idt.offset_2 = offset.unsafe_shr(16) & 0xFFFF
    idt.offset_3 = offset.unsafe_shr(32)
    idt.zero = 0
    @@idt[num] = idt
  end

  # handlers
  def irq_handlers
    @@irq_handlers
  end

  def register_irq(idx : Int, handler : InterruptHandler)
    @@irq_handlers[idx] = handler
  end

  # status
  @@status_mask = false

  def status_mask=(@@status_mask); end

  def enable
    if !@@status_mask
      asm("sti")
    end
  end

  def disable
    if !@@status_mask
      asm("cli")
    end
  end

  def lock(&block)
    if @@status_mask
      panic "multiple masks"
    end
    @@status_mask = true
    yield
    @@status_mask = false
  end
end

fun kirq_handler(frame : IdtData::Registers)
  # send EOI signal to PICs
  if frame.int_no >= 8
    # send to slave
    X86.outb 0xA0, 0x20
  end
  # send to master
  X86.outb 0x20, 0x20

  if frame.int_no == 0 && Multiprocessing.n_process > 1
    # preemptive multitasking...
    Multiprocessing.switch_process(frame)
  end

  if Idt.irq_handlers[frame.int_no].pointer.null?
    if frame.int_no != 0
      Serial.puts "no handler for ", frame.int_no, "\n"
    end
  else
    Idt.irq_handlers[frame.int_no].call
  end
end

EX_PAGEFAULT = 14

fun kcpuex_handler(frame : IdtData::ExceptionRegisters*)
  panic "unhandled: ", frame.value.int_no
  {% if false %}
  case frame.int_no
  when EX_PAGEFAULT
    faulting_address = 0u32
    asm("mov %cr2, $0" : "=r"(faulting_address) :: "volatile")

    present = (frame.errcode & 0x1) == 0
    rw = (frame.errcode & 0x2) != 0
    user = (frame.errcode & 0x4) != 0
    reserved = (frame.errcode & 0x8) != 0
    id = (frame.errcode & 0x10) != 0

    Serial.puts Pointer(Void).new(faulting_address.to_u64), user, " ", Pointer(Void).new(frame.eip.to_u64), "\n"
    if user
      if faulting_address < Multiprocessing::USER_STACK_TOP &&
         faulting_address > Multiprocessing::USER_STACK_BOTTOM_MAX
        # stack page fault
        Idt.lock do
          Paging.alloc_page_pg(faulting_address & 0xFFFF_F000, true, true)
        end
        return
      else
        Multiprocessing.switch_process_and_terminate
      end
    else
      panic "kernel space"
    end
  else
    panic "fault: ", frame.int_no, ' ', frame.errcode, '\n'
  end
  {% end %}
end
