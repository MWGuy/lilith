require "./core.cr"
require "./fs.cr"
require "./drivers/core/*"
require "./drivers/arch/*"
require "./drivers/**"
require "./arch/gdt.cr"
require "./arch/idt.cr"
require "./arch/paging.cr"
require "./arch/multiboot.cr"
require "./alloc/alloc.cr"
require "./alloc/gc.cr"
require "./userspace/syscalls.cr"
require "./userspace/process.cr"
require "./userspace/elf.cr"
require "./userspace/mmap_list.cr"

lib Kernel
  fun ksyscall_setup
  fun kidle_loop

  $fxsave_region_ptr : UInt8*
  $kernel_end : Void*
  $text_start : Void*; $text_end : Void*
  $data_start : Void*; $data_end : Void*
  $stack_start : Void*; $stack_end : Void*
end

ROOTFS = RootFS.new

fun idle_loop
  while true
  end
end

fun kmain(mboot_magic : UInt32, mboot_header : Multiboot::MultibootInfo*)
  if mboot_magic != MULTIBOOT_BOOTLOADER_MAGIC
    panic "Kernel should be booted from a multiboot bootloader!"
  end

  Multiprocessing.fxsave_region = Kernel.fxsave_region_ptr

  VGA.puts "Booting lilith...\n"

  VGA.puts "initializing gdtr...\n"
  Gdt.init_table

  # drivers
  Pit.init

  # interrupt tables
  VGA.puts "initializing idt...\n"
  Idt.init_interrupts
  Idt.init_table
  Idt.status_mask = true

  # paging
  VGA.puts "initializing paging...\n"
  Pmalloc.start = Paging.aligned(Kernel.kernel_end.address)
  Pmalloc.addr = Paging.aligned(Kernel.kernel_end.address)
  Paging.init_table(Kernel.text_start, Kernel.text_end,
                Kernel.data_start, Kernel.data_end,
                Kernel.stack_start, Kernel.stack_end,
                mboot_header)
  VGA.puts "physical memory detected: ", Paging.usable_physical_memory, " bytes\n"

  #
  VGA.puts "initializing kernel garbage collector...\n"
  KernelArena.start_addr = Kernel.stack_end.address + 0x1000
  Gc.init Kernel.data_start.address,
          Kernel.data_end.address,
          Kernel.stack_end.address

  #
  ide = nil

  VGA.puts "checking PCI buses...\n"
  PCI.check_all_buses do |bus, device, func, vendor_id|
    device_id = PCI.read_field bus, device, func, PCI::PCI_DEVICE_ID, 2
    if Ide.pci_device?(vendor_id, device_id)
      ide = Ide.new
    elsif BGA.pci_device?(vendor_id, device_id)
      # BGA.init_controller bus, device, func
    end
  end

  ide = ide.not_nil!
  ide.init_controller

  kbd = Keyboard.new
  ROOTFS.append(KbdFS.new(kbd))
  ROOTFS.append(VGAFS.new)

  mbr = MBR.read_ata(ide.device(0))
  main_bin : VFSNode? = nil
  if MBR.check_header(mbr)
    VGA.puts "found MBR header...\n"
    fs = Fat16FS.new ide.device(0), mbr.partitions[0]
    fs.root.each_child do |node|
      if node.name == "main.bin"
        main_bin = node
      end
    end
    ROOTFS.append(fs)
  end

  VGA.puts "setting up syscalls...\n"
  Kernel.ksyscall_setup

  rsp0 = 0u64
  asm("mov %rsp, $0" : "=r"(rsp0) :: "volatile")
  Gdt.stack = rsp0
  Gdt.flush_tss

  idle_process = Multiprocessing::Process.new(nil, false) do |process|
    process.initial_sp = rsp0
    process.initial_ip = (->idle_loop).pointer.address
  end

  if main_bin.nil?
    VGA.puts "no main.bin detected.\n"
  else
    VGA.puts "executing MAIN.BIN...\n"

    argv = GcArray(GcString).new 0
    argv.push GcString.new("/ata0/main.bin")
    udata = Multiprocessing::Process::UserData
              .new(argv,
                GcString.new("/ata0"),
                fs.not_nil!.root)
    m_process = Multiprocessing::Process.spawn_user(main_bin.not_nil!, udata)
    if m_process.nil?
      panic "unable to load main.bin"
    end

    Idt.status_mask = false

    m_process = m_process.not_nil!
    m_process.initial_switch
  end
end
