require "./file_descriptor.cr"

module Multiprocessing
  extend self

  # must be page aligned
  USER_STACK_TOP        = 0xFFFF_F000u32
  USER_STACK_SIZE       =   0x80_0000u32 # 8 mb
  USER_STACK_BOTTOM_MAX = USER_STACK_TOP - USER_STACK_SIZE
  USER_STACK_BOTTOM     = 0x8000_0000u32

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

    @initial_eip : UInt32 = 0x8000_0000u32
    property initial_eip

    @initial_esp : UInt32 = USER_STACK_TOP
    property initial_esp

    # physical location of the process' page directory
    @phys_pg_struct : USize = 0u64
    property phys_pg_struct

    # interrupt frame for preemptive multitasking
    @frame : IdtData::Registers? = nil
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
        @fxsave_region = Pointer(UInt8).malloc(512)
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
      dir = @phys_pg_struct # this must be stack allocated
      # because it's placed in the virtual kernel heap
      panic "page dir is nil" if dir == 0
      Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable).new(dir.to_u64)
      Paging.flush
      asm("jmp kswitch_usermode32"
          :: "{rcx}"(@initial_eip),
             "{rsp}"(@initial_esp)
          : "volatile")
    end

    # new register frame for multitasking
    def new_frame
      frame = IdtData::Registers.new
      # Stack
      frame.userrsp = @initial_esp
      # Pushed by the processor automatically.
      frame.rip = @initial_eip
      if kernel_process?
        frame.rflags = 0x202u32
        frame.cs = 0x08u32
        frame.ds = 0x10u32
        frame.ss = 0x10u32
      else
        frame.rflags = 0x212u32
        frame.cs = 0x1Bu32
        frame.ds = 0x23u32
        frame.ss = 0x23u32
      end
      @frame = frame
      @frame.not_nil!
    end

    # create a frame for when the process wakes up
    def new_frame(syscall_frame : SyscallData::Registers)
      frame = IdtData::Registers.new
      # Stack (this should be restored by interrupt handler automatically)
      frame.userrsp = USER_STACK_TOP
      # Pushed by the processor automatically.
      frame.rip = @initial_eip
      frame.rflags = 0x212u32
      frame.cs = 0x1Bu32
      frame.ss = 0x23u32
      # registers
      {% for id in [
          "rdi", "rsi",
          "r15", "r14", "r13", "r12", "r11", "r10", "r9", "r8",
          "rdx", "rcx", "rbx", "rax"
        ] %}
      frame.{{ id.id }} = syscall_frame.{{ id.id }}
      {% end %}
      @frame = frame
      @frame.not_nil!
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
      io.puts "Process {"
      io.puts " pid: ", pid, ", "
      io.puts " prev_process: ", prev_process.nil? ? "nil" : prev_process.not_nil!.pid, ", "
      io.puts " next_process: ", next_process.nil? ? "nil" : next_process.not_nil!.pid, ", "
      io.puts "}"
    end
  end

  def setup_tss
    rsp0 = 0u64
    asm("mov %rsp, $0" : "=r"(rsp0) :: "volatile")
    Gdt.stack = rsp0
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
  # NOTE: this must be a macro so that it will be inlined so that
  # the "frame" argument will a reference to the register frame on the stack
  def switch_process(frame, remove = false)
    panic "not impl"
  end

  {% if false %}
  macro switch_process(frame, remove = false)
    {% if false %}
    {% if frame == nil %}
      current_process = Multiprocessing.current_process.not_nil!
      {% if remove %}
        current_process.status = Multiprocessing::Process::Status::Removed
      {% end %}
        next_process = Multiprocessing.next_process.not_nil!
      {% if remove %}
        current_process.remove
      {% end %}
    {% else %}
      # save current process' state
      current_process = Multiprocessing.current_process.not_nil!
      current_process.frame = {{ frame }}
      if !current_process.fxsave_region.null?
        memcpy current_process.fxsave_region, Multiprocessing.fxsave_region, 512
      end
      # load process's state
      next_process = Multiprocessing.next_process.not_nil!
    {% end %}

    process_frame = if next_process.frame.nil?
      next_process.new_frame
    else
      next_process.frame.not_nil!
    end

    # switch page directory
    if !next_process.kernel_process?
      dir = next_process.phys_pg_struct # this must be stack allocated
      # because it's placed in the virtual kernel heap
      panic "null page directory" if dir == 0
      Paging.current_pdpt = Pointer(PageStructs::PageDirectoryPointerTable).new(dir.to_u64)
      {% if remove %}
        current_page_dir = current_process.phys_pg_struct
        Paging.free_process_pdpt(current_page_dir)
        current_process.phys_pg_struct = 0u64
      {% else %}
        Paging.enable
      {% end %}
    end

    # wake up process
    if next_process.status == Multiprocessing::Process::Status::Unwait
      # transition state from kernel syscall
      process_frame.eip = Pointer(UInt32).new(process_frame.ecx.to_u64)[0]
      process_frame.useresp = process_frame.ecx
      next_process.status = Multiprocessing::Process::Status::Normal
    end

    # swap back registers
    {% if frame != nil %}
      {% for id in [
                     "ds",
                     "edi", "esi", "ebp", "esp", "ebx", "edx", "ecx", "eax",
                     "eip", "cs", "eflags", "useresp", "ss",
                   ] %}
        {{ frame }}.{{ id.id }} = process_frame.{{ id.id }}
      {% end %}
    {% end %}
    if !next_process.fxsave_region.null?
      memcpy Multiprocessing.fxsave_region, next_process.fxsave_region, 512
    end

    {% if frame == nil %}
    asm("jmp kcpuint_end" :: "{esp}"(pointerof(process_frame)) : "volatile")
    {% end %}
    {% end %}
  end
  {% end %}

  def switch_process_no_save
    Multiprocessing.switch_process(nil)
  end

  def switch_process_and_terminate
    Multiprocessing.switch_process(nil, true)
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
