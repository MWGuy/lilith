require "./file_descriptor.cr"

private lib Kernel
  fun ksyscall_switch(frame : IdtData::Registers*) : NoReturn
end

module Multiprocessing
  extend self

  # must be page aligned
  USER_STACK_TOP        = 0xFFFF_F000u64
  USER_STACK_SIZE       =   0x80_0000u64 # 8 mb
  USER_STACK_BOTTOM_MAX = USER_STACK_TOP - USER_STACK_SIZE
  USER_STACK_BOTTOM     = 0x8000_0000u32

  USER_CS_SEGMENT = 0x1b
  USER_SS_SEGMENT = 0x23
  USER_RFLAGS = 0x212

  KERNEL_CS_SEGMENT = 0x29
  KERNEL_SS_SEGMENT = 0x31
  KERNEL_RFLAGS = 0x202

  FXSAVE_SIZE = 512u64

  @@current_process : Process? = nil

  def current_process
    @@current_process
  end

  def current_process=(@@current_process); end

  @@first_process : Process? = nil
  mod_property first_process
  @@last_process : Process? = nil
  mod_property last_process

  @@pids = 0
  mod_property pids
  @@n_process = 0
  mod_property n_process
  @@fxsave_region = Pointer(UInt8).null

  def fxsave_region
    @@fxsave_region
  end

  def fxsave_region=(@@fxsave_region); end

  class Process
    @pid = 0
    getter pid

    @prev_process : Process? = nil
    @next_process : Process? = nil
    getter prev_process, next_process

    protected def prev_process=(@prev_process); end

    protected def next_process=(@next_process); end

    @initial_ip = 0x8000_0000u64
    property initial_ip

    @initial_sp = 0xFFFF_FFFFu64
    property initial_sp

    # physical location of the process' page directory
    @phys_pg_struct : USize = 0u64
    property phys_pg_struct

    # interrupt frame for preemptive multitasking
    @frame = Pointer(IdtData::Registers).null
    property frame

    # sse state
    getter fxsave_region

    # status
    enum Status
      Removed
      Normal
      Unwait
      WaitIo
      WaitProcess
    end

    @status = Status::Normal
    property status

    # user-mode process data
    class UserData
      # wait process
      # TODO: this should be a weak pointer once it's implemented
      @pwait : Process? = nil
      property pwait

      # group id
      @pgid = 0u64
      property pgid

      # files
      MAX_FD = 16
      property fds

      # working directory
      property cwd
      property cwd_node

      # heap location
      @heap_start = 0u64
      @heap_end = 0u64
      property heap_start, heap_end

      # argv
      property argv

      def initialize(@argv : GcArray(GcString),
          @cwd : GcString, @cwd_node : VFSNode)
        @fds = GcArray(FileDescriptor).new MAX_FD
      end

      # file descriptors
      def install_fd(node : VFSNode) : Int32
        i = 0
        f = fds.not_nil!
        while i < MAX_FD
          if f[i].nil?
            f[i] = FileDescriptor.new node
            return i
          end
          i += 1
        end
        -1
      end

      def get_fd(i : Int32) : FileDescriptor?
        return nil if i > MAX_FD || i < 0
        fds[i]
      end

      def close_fd(i : Int32) : Bool
        return false if i > MAX_FD || i < 0
        fds[i]
        true
      end
    end

    @udata : UserData? = nil

    def udata
      @udata.not_nil!
    end

    def kernel_process?
      @udata.nil?
    end

    def initialize(@udata : UserData?, save_fx = true, &on_setup_paging : Process -> _)
      # user mode specific
      if save_fx
        @fxsave_region = Pointer(UInt8).malloc(FXSAVE_SIZE)
        memset(@fxsave_region, 0x0, FXSAVE_SIZE)
      else
        @fxsave_region = Pointer(UInt8).null
      end

      Multiprocessing.n_process += 1

      Idt.disable

      @pid = Multiprocessing.pids
      last_pg_struct = Pointer(PageStructs::PageDirectoryPointerTable).null
      if !kernel_process?
        if @pid != 0
          last_pg_struct = Paging.current_pdpt
          page_struct = Paging.alloc_process_pdpt
          Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable).new page_struct
          Paging.flush
          @phys_pg_struct = page_struct
        else
          @phys_pg_struct = Paging.current_pdpt.address
        end
      end
      Multiprocessing.pids += 1

      # setup pages
      unless yield self
        # unable to setup, bailing
        if !last_pg_struct.null? && !kernel_process?
          Paging.current_pdpt = last_pg_struct
          Paging.flush
        end
        Idt.enable
        return
      end

      if Multiprocessing.first_process.nil?
        Multiprocessing.first_process = self
        Multiprocessing.last_process = self
      else
        Multiprocessing.last_process.not_nil!.next_process = self
        @prev_process = Multiprocessing.last_process
        Multiprocessing.last_process = self
      end

      if !last_pg_struct.null? && !kernel_process?
        Paging.current_pdpt = last_pg_struct
        Paging.flush
      end

      Idt.enable
    end

    def initial_switch
      Multiprocessing.current_process = self
      panic "page dir is nil" if @phys_pg_struct == 0
      Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable).new(@phys_pg_struct)
      Paging.flush
      new_frame
      asm("jmp kswitch_usermode32"
          :: "{rcx}"(@initial_ip),
             "{r11}"(@frame.value.rflags)
             "{rsp}"(@initial_sp)
          : "volatile", "memory")
    end

    # new register frame for multitasking
    def new_frame
      frame = IdtData::Registers.new
      frame.userrsp = @initial_sp
      frame.rip = @initial_ip
      if kernel_process?
        frame.rflags = KERNEL_RFLAGS
        frame.cs = KERNEL_CS_SEGMENT
        frame.ss = KERNEL_SS_SEGMENT
        frame.ds = KERNEL_SS_SEGMENT
      else
        frame.rflags = USER_RFLAGS
        frame.cs = USER_CS_SEGMENT
        frame.ds = USER_SS_SEGMENT
        frame.ss = USER_SS_SEGMENT
      end

      @frame = Pointer(IdtData::Registers).malloc
      @frame.value = frame
    end

    def new_frame_from_syscall(syscall_frame : SyscallData::Registers*)
      frame = IdtData::Registers.new

      {% for id in [
          "rbp", "rdi", "rsi",
          "r15", "r14", "r13", "r12", "r11", "r10", "r9", "r8",
          "rdx", "rcx", "rbx", "rax"
        ] %}
      frame.{{ id.id }} = syscall_frame.value.{{ id.id }}
      {% end %}
      frame.rflags = USER_RFLAGS
      frame.cs = USER_CS_SEGMENT
      frame.ss = USER_SS_SEGMENT
      frame.ds = USER_SS_SEGMENT

      @frame = Pointer(IdtData::Registers).malloc
      @frame.value = frame
    end

    # initialize
    def self.spawn_user(file, udata)
      built = false
      p = Multiprocessing::Process.new(udata) do |process|
        if (err = ElfReader.load(process, file.not_nil!)).nil?
          argv_builder = ArgvBuilder.new process
          udata.argv.each do |arg|
            argv_builder.from_string arg.not_nil!
          end
          argv_builder.build
          built = true
          true
        else
          false
        end
      end
      return p if built
    end

    # deinitialize
    def remove
      Multiprocessing.n_process -= 1
      @prev_process.not_nil!.next_process = @next_process
      if @next_process.nil?
        Multiprocessing.last_process = @prev_process
      else
        @next_process.not_nil!.prev_process = @prev_process
      end
      # cleanup userspace data so as to minimize leaks
      @udata = nil
    end

    # debugging
    def to_s(io)
      io.puts "Process {\n"
      io.puts " pid: ", @pid, ", \n"
      io.puts " status: ", @status, ", \n"
      io.puts " initial_ip: ", Pointer(Void).new(@initial_ip), ", \n"
      io.puts "}"
    end
  end

  private def can_switch(process)
    case process.status
    when Multiprocessing::Process::Status::Normal
      true
    when Multiprocessing::Process::Status::Unwait
      true
    when Multiprocessing::Process::Status::WaitProcess
      #Serial.puts process.udata.pwait.not_nil!.pid, ':', process.udata.pwait.not_nil!.status, '\n'
      if process.udata.pwait.nil? ||
         process.udata.pwait.not_nil!.status == Multiprocessing::Process::Status::Removed
        process.status = Multiprocessing::Process::Status::Unwait
        process.udata.pwait = nil
        true
      else
        false
      end
    else
      false
    end
  end

  # round robin scheduling algorithm
  def next_process : Process?
    if @@current_process.nil?
      return @@current_process = @@first_process
    end
    process = @@current_process.not_nil!
    # look from middle to end
    cur = process.next_process
    while !cur.nil? && !can_switch(cur.not_nil!)
      cur = cur.next_process
    end
    @@current_process = cur
    # look from start to middle
    if @@current_process.nil?
      cur = @@first_process.not_nil!.next_process
      while !cur.nil? && !can_switch(cur.not_nil!)
        cur = cur.not_nil!.next_process
        break if cur == process.prev_process
      end
      @@current_process = cur
    end
    if @@current_process.nil?
      # no tasks left, use idle
      @@current_process = @@first_process
    else
      @@current_process
    end
  end

  # context switch
  private def switch_process_save_and_load(remove = false, &block)
    # get next process
    current_process = Multiprocessing.current_process.not_nil!
    if remove
      current_process.status = Multiprocessing::Process::Status::Removed
    end
    next_process = Multiprocessing.next_process.not_nil!
    Multiprocessing.current_process = next_process
    current_process.remove if remove

    # save current process' state
    if current_process.pid != 0 && !remove
      yield current_process
      unless current_process.fxsave_region.null?
        memcpy current_process.fxsave_region, Multiprocessing.fxsave_region, FXSAVE_SIZE
      end
    end

    if next_process.pid == 0
      # halt the processor in pid 0
      rsp = Gdt.stack
      asm("mov $0, %rsp
           mov %rsp, %rbp
           sti" :: "r"(rsp) : "volatile", "{rsp}", "{rbp}")
      while true
        asm("hlt")
      end
    elsif next_process.frame.null?
      # create new frame if necessary
      next_process.new_frame
    end

    # switch page directory
    if next_process.kernel_process?
      # no need to change paging when transitioning to kernel mode
      # unless we're removing the current one
      if remove
        Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable)
          .new(first_process.not_nil!.phys_pg_struct)
        Paging.flush
      end
    else
      # switch to other user process' page
      Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable)
        .new(next_process.phys_pg_struct)
      Paging.flush
    end

    # wake up process
    if next_process.status == Multiprocessing::Process::Status::Unwait
      # transition state from kernel syscall
      next_process.frame.value.rip =
        Pointer(UInt32).new(next_process.frame.value.rcx).value
      next_process.frame.value.userrsp = next_process.frame.value.rcx
      next_process.status = Multiprocessing::Process::Status::Normal
    end

    # restore fxsave
    unless next_process.fxsave_region.null?
      memcpy Multiprocessing.fxsave_region, next_process.fxsave_region, FXSAVE_SIZE
    end

    next_process
  end

  def switch_process(frame : IdtData::Registers*)
    current_process = switch_process_save_and_load do |process|
      process.frame.value = frame.value
    end
    frame.value = current_process.frame.value
  end

  def switch_process(frame : SyscallData::Registers*)
    current_process = switch_process_save_and_load do |process|
      process.new_frame_from_syscall frame
    end
    Kernel.ksyscall_switch(current_process.frame)
  end
  
  def switch_process_and_terminate
    current_process = switch_process_save_and_load(true) {}
    Kernel.ksyscall_switch(current_process.frame)
  end

  # iteration
  def each
    process = @@first_process
    while !process.nil?
      process = process.not_nil!
      yield process
      process = process.next_process
    end
  end

end
