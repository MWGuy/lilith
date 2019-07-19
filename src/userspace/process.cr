require "./file_descriptor.cr"

private lib Kernel
    fun kset_stack(address : UInt32)
    fun kswitch_usermode()
end


module Multiprocessing
    extend self

    USER_STACK_TOP = 0xf000_0000u32
    USER_STACK_BOTTOM = 0x8000_0000u32

    @@current_process : Process | Nil = nil
    def current_process; @@current_process; end
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
    def fxsave_region; @@fxsave_region; end
    def fxsave_region=(@@fxsave_region); end

    enum ProcessStatus
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

        @stack_bottom : UInt32 = USER_STACK_TOP - 0x1000u32
        property stack_bottom

        @initial_addr : UInt32 = 0x8000_0000u32
        property initial_addr

        # physical location of the process' page directory
        @phys_page_dir : UInt32 = 0
        property phys_page_dir

        # interrupt frame for preemptive multitasking
        @frame : IdtData::Registers | Nil = nil
        property frame

        # sse state
        getter fxsave_region

        @kernel_process = false
        property kernel_process

        # files
        MAX_FD = 16
        getter fds

        # status
        @status = Multiprocessing::ProcessStatus::Normal
        property status

        def initialize(@kernel_process=false, &on_setup_paging)
            # file descriptors
            # BUG: must be initialized here or the GC won't catch it
            @fds = GcArray(FileDescriptor).new MAX_FD
            @fxsave_region = GcPointer(UInt8).malloc(512)
            # panic @fxsave_region.ptr, '\n'

            Multiprocessing.n_process += 1

            Idt.disable

            @pid = Multiprocessing.pids
            last_page_dir = Pointer(PageStructs::PageDirectory).null
            if !@kernel_process
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
            end
            if !Multiprocessing.last_process.nil?
                Multiprocessing.last_process.not_nil!.next_process = self
            end
            @prev_process = Multiprocessing.last_process
            Multiprocessing.last_process = self

            if !last_page_dir.null? && !@kernel_process
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
            asm("jmp kswitch_usermode" :: "{ecx}"(@initial_addr) : "volatile")
        end

        # new register frame for multitasking
        def new_frame
            frame = IdtData::Registers.new
            # Stack
            frame.useresp = USER_STACK_TOP
            frame.esp = USER_STACK_TOP
            # Pushed by the processor automatically.
            frame.eip = @initial_addr
            if @kernel_process
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
            frame.eip = @initial_addr
            if @kernel_process
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
            0
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

        # control
        def remove
            Multiprocessing.n_process -= 1
            if @prev_process.nil?
                Multiprocessing.first_process = @next_process
            else
                @prev_process.not_nil!.next_process = @next_process
            end
        end

    end

    @[AlwaysInline]
    def setup_tss
        esp0 = 0u32
        asm("mov %esp, $0;" : "=r"(esp0) :: "volatile")
        Kernel.kset_stack esp0
    end

    private def can_switch(process)
        process.status == Multiprocessing::ProcessStatus::Normal ||
        process.status == Multiprocessing::ProcessStatus::IoUnwait
    end

    # round robin scheduling algorithm
    def next_process : Process | Nil
        if @@current_process.nil?
            return @@current_process = @@first_process
        end
        proc = @@current_process.not_nil!
        # look from middle to end
        @@current_process = proc.next_process
        while !@@current_process.nil? && !can_switch(@@current_process.not_nil!)
            #Serial.puts Pointer(Void).new(@@current_process.object_id), "\n"
            @@current_process = @@current_process.not_nil!.next_process
        end
        # look from start to middle
        if @@current_process.nil?
            @@current_process = @@first_process
            while !can_switch(@@current_process.not_nil!)
                @@current_process = @@current_process.not_nil!.next_process
                break if @@current_process == proc
            end
        end
        if @@current_process.nil?
            # no tasks left, use idle
            @@current_process = @@first_process
        else
            @@current_process
        end
    end

    # context switch
    # NOTE: this must be a macro so that it will be inlined,
    # and frame will the a reference to the frame on the stack
    macro switch_process(frame, remove=false)
        {% if frame == nil %}
        current_process = Multiprocessing.current_process.not_nil!
        current_page_dir = current_process.phys_page_dir
        next_process = Multiprocessing.next_process.not_nil!
        {% if remove %}
        current_process.remove
        {% end %}
        {% else %}
        # save current process' state
        current_process = Multiprocessing.current_process.not_nil!
        current_process.frame = {{ frame }}
        memcpy current_process.fxsave_region.ptr, Multiprocessing.fxsave_region, 512
        # load process's state
        next_process = Multiprocessing.next_process.not_nil!
        {% end %}
        if next_process.pid != 0
            Serial.puts next_process.pid, "<--\n"
        end

        process_frame = if next_process.frame.nil?
            next_process.new_frame
        else
            next_process.frame.not_nil!
        end
        if next_process.status == Multiprocessing::ProcessStatus::IoUnwait
            # transition state from async io syscall
            process_frame.eip = Pointer(UInt32).new(process_frame.ecx.to_u64)[0]
            process_frame.useresp = process_frame.ecx
            next_process.status = Multiprocessing::ProcessStatus::Normal
        end
        {% if frame != nil %}
            {% for id in [
                "ds",
                "edi", "esi", "ebp", "esp", "ebx", "edx", "ecx", "eax",
                "eip", "cs", "eflags", "useresp", "ss"
            ] %}
            {{ frame }}.{{ id.id }} = process_frame.{{ id.id }}
            {% end %}
        {% end %}
        memcpy Multiprocessing.fxsave_region, next_process.fxsave_region.ptr, 512

        if !next_process.kernel_process
            dir = next_process.phys_page_dir # this must be stack allocated
            # because it's placed in the virtual kernel heap
            {% if frame == nil && remove %}
            Paging.disable
            Paging.free_process_page_dir(current_page_dir)
            current_process.phys_page_dir = 0u32
            {% end %}
            Paging.current_page_dir = Pointer(PageStructs::PageDirectory).new(dir.to_u64)
            Paging.enable
        end

        {% if frame == nil %}
        asm("jmp kcpuint_end" :: "{esp}"(pointerof(process_frame)) : "volatile")
        {% end %}
    end

end