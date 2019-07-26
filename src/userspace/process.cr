require "./file_descriptor.cr"

module Multiprocessing
  extend self

  USER_STACK_TOP        = 0xf000_0000u32
  USER_STACK_SIZE       =    0x800000u32
  USER_STACK_BOTTOM_MAX = USER_STACK_TOP - USER_STACK_SIZE
  USER_STACK_BOTTOM     = 0x8000_0000u32

  @@current_process : Process | Nil = nil

  def current_process
    @@current_process
  end

  def current_process=(@@current_process); end

  @@first_process : Process | Nil = nil
  mod_property first_process
  @@last_process : Process | Nil = nil
  mod_property last_process

  @@pids = 0u32
  mod_property pids
  @@n_process = 0u32
  mod_property n_process
  @@fxsave_region = Pointer(UInt8).null

  def fxsave_region
    @@fxsave_region
  end

  def fxsave_region=(@@fxsave_region); end

  enum ProcessStatus
    Removed
    Normal
    IoUnwait
    ReadWait
  end

  class Process < Gc
    @pid = 0u32
    getter pid

    @prev_process : Process | Nil = nil
    @next_process : Process | Nil = nil
    getter prev_process, next_process

    protected def prev_process=(@prev_process); end

    protected def next_process=(@next_process); end

    @initial_eip : UInt32 = 0x8000_0000u32
    property initial_eip

    @initial_esp : UInt32 = USER_STACK_TOP
    property initial_esp

    # physical location of the process' page directory
    @phys_page_dir : UInt32 = 0u32
    property phys_page_dir

    # interrupt frame for preemptive multitasking
    @frame : IdtData::Registers | Nil = nil
    property frame

    # sse state
    getter fxsave_region

    # status
    @status = Multiprocessing::ProcessStatus::Normal
    property status

    # ---------
    class UserData < Gc
      # files
      MAX_FD = 16
      property fds

      # working directory
      property cwd
      property cwd_node

      # heap location
      @heap_start = 0u32
      @heap_end = 0u32
      property heap_start, heap_end

      # argv
      property argv

      def initialize(@argv : GcArray(GcString), @cwd : GcString, @cwd_node : VFSNode)
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

      def get_fd(i : Int32) : FileDescriptor | Nil
        return nil if i > MAX_FD || i < 0
        fds[i]
      end

      def close_fd(i : Int32) : Bool
        return false if i > MAX_FD || i < 0
        fds[i]
        true
      end
    end

    @udata : UserData | Nil = nil

    def udata
      @udata.not_nil!
    end

    def kernel_process?
      @udata.nil?
    end

    def initialize(@udata : UserData | Nil, save_fx = true, &on_setup_paging)
      # user mode specific
      if save_fx
        @fxsave_region = GcPointer(UInt8).malloc(512)
      else
        @fxsave_region = GcPointer(UInt8).null
      end

      Multiprocessing.n_process += 1

      Idt.disable

      @pid = Multiprocessing.pids
      last_page_dir = Pointer(PageStructs::PageDirectory).null
      if !kernel_process?
        if @pid != 0
          Paging.disable
          last_page_dir = Paging.current_page_dir
          page_dir = Paging.alloc_process_page_dir
          Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new page_dir
          Paging.enable
          @phys_page_dir = page_dir.to_u32
        else
          @phys_page_dir = Paging.current_page_dir.address.to_u32
        end
      end
      Multiprocessing.pids += 1

      # setup pages
      yield self

      if Multiprocessing.first_process.nil?
        Multiprocessing.first_process = self
        Multiprocessing.last_process = self
      else
        Multiprocessing.last_process.not_nil!.next_process = self
        @prev_process = Multiprocessing.last_process
        Multiprocessing.last_process = self
      end

      if !last_page_dir.null? && !kernel_process?
        Paging.disable
        Paging.current_page_dir = last_page_dir
        Paging.enable
      end

      Idt.enable
    end

    def initial_switch
      Multiprocessing.current_process = self
      dir = @phys_page_dir # this must be stack allocated
      # because it's placed in the virtual kernel heap
      panic "page dir is nil" if dir == 0
      Paging.disable
      Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new(dir.to_u64)
      Paging.enable
      asm("jmp kswitch_usermode" :: "{edx}"(@initial_eip),
                                    "{ecx}"(@initial_esp),
                                    "{ebp}"(USER_STACK_TOP)
                                 : "volatile")
    end

    # new register frame for multitasking
    def new_frame
      frame = IdtData::Registers.new
      # Stack
      frame.useresp = @initial_esp
      frame.esp = @initial_esp
      # Pushed by the processor automatically.
      frame.eip = @initial_eip
      if kernel_process?
        frame.eflags = 0x202u32
        frame.cs = 0x08u32
        frame.ds = 0x10u32
        frame.ss = 0x10u32
      else
        frame.eflags = 0x212u32
        frame.cs = 0x1Bu32
        frame.ds = 0x23u32
        frame.ss = 0x23u32
      end
      @frame = frame
      @frame.not_nil!
    end

    def new_frame(syscall_frame)
      frame = IdtData::Registers.new
      # Stack
      frame.useresp = USER_STACK_TOP
      frame.esp = USER_STACK_TOP
      # Pushed by the processor automatically.
      frame.eip = @initial_eip
      if kernel_process?
        frame.eflags = 0x202u32
        frame.cs = 0x08u32
        frame.ds = 0x10u32
        frame.ss = 0x10u32
      else
        frame.eflags = 0x212u32
        frame.cs = 0x1Bu32
        frame.ds = 0x23u32
        frame.ss = 0x23u32
      end
      # registers
      {% for id in ["edi", "esi", "ebp", "esp", "ebx", "edx", "ecx", "eax"] %}
      frame.{{ id.id }} = syscall_frame.{{ id.id }}
      {% end %}
      @frame = frame
      @frame.not_nil!
    end

    # control
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
    esp0 = 0u32
    asm("mov %esp, $0;" : "=r"(esp0) :: "volatile")
    Gdt.stack = esp0
  end

  private def can_switch(process)
    process.status == Multiprocessing::ProcessStatus::Normal ||
      process.status == Multiprocessing::ProcessStatus::IoUnwait
  end

  # round robin scheduling algorithm
  def next_process : Process | Nil
    # Serial.puts Multiprocessing.n_process, "---\n"
    if @@current_process.nil?
      return @@current_process = @@first_process
    end
    proc = @@current_process.not_nil!
    # look from middle to end
    cur = proc.next_process
    while !cur.nil? && !can_switch(cur.not_nil!)
      cur = cur.next_process
    end
    @@current_process = cur
    # look from start to middle
    if @@current_process.nil?
      cur = @@first_process.not_nil!.next_process
      while !cur.nil? && !can_switch(cur.not_nil!)
        # Serial.puts cur.not_nil!.pid, ": ", cur.status, "\n"
        cur = cur.not_nil!.next_process
        break if cur == proc.prev_process
      end
      @@current_process = cur
    end
    if @@current_process.nil?
      # no tasks left, use idle
      # Serial.puts @@first_process.not_nil!.pid, "<- \n"
      @@current_process = @@first_process
    else
      # Serial.puts @@current_process.not_nil!.pid, "<- \n"
      @@current_process
    end
  end

  # context switch
  # NOTE: this must be a macro so that it will be inlined,
  # and the frame argument will the a reference to the frame on the stack
  macro switch_process(frame, remove = false)
        {% if frame == nil %}
        current_process = Multiprocessing.current_process.not_nil!

        {% if remove %}
        current_process.status = Multiprocessing::ProcessStatus::Removed
        {% end %}

        next_process = Multiprocessing.next_process.not_nil!

        {% if remove %}
        current_process.remove
        {% end %}

        {% else %}
        # save current process' state
        current_process = Multiprocessing.current_process.not_nil!
        current_process.frame = {{ frame }}
        if !current_process.fxsave_region.ptr.null?
            memcpy current_process.fxsave_region.ptr, Multiprocessing.fxsave_region, 512
        end
        # load process's state
        next_process = Multiprocessing.next_process.not_nil!
        {% end %}
        #Serial.puts Pointer(Void).new(next_process.object_id), ' ', offsetof(Multiprocessing::Process, @next_process), '\n'
        #if next_process.pid != 0
        #    Serial.puts next_process.pid, "<--\n"
        #end

        process_frame = if next_process.frame.nil?
            next_process.new_frame
        else
            next_process.frame.not_nil!
        end

        # switch page directory
        if !next_process.kernel_process?
            dir = next_process.phys_page_dir # this must be stack allocated
            # because it's placed in the virtual kernel heap
            panic "null page directory" if dir == 0
            Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new(dir.to_u64)
            {% if frame == nil && remove %}
            current_page_dir = current_process.phys_page_dir
            Paging.free_process_page_dir(current_page_dir)
            current_process.phys_page_dir = 0u32
            {% else %}
            Paging.enable
            {% end %}
        end

        # wake up process
        if next_process.status == Multiprocessing::ProcessStatus::IoUnwait
            # transition state from async io syscall
            process_frame.eip = Pointer(UInt32).new(process_frame.ecx.to_u64)[0]
            process_frame.useresp = process_frame.ecx
            next_process.status = Multiprocessing::ProcessStatus::Normal
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
        if !next_process.fxsave_region.ptr.null?
            memcpy Multiprocessing.fxsave_region, next_process.fxsave_region.ptr, 512
        end

        {% if frame == nil %}
        asm("jmp kcpuint_end" :: "{esp}"(pointerof(process_frame)) : "volatile")
        {% end %}
    end
end
