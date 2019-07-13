require "../drivers/cpumsr.cr"

lib SyscallData

    @[Packed]
    struct Registers
        # Pushed by pushad:
        # ecx is unused
        edi, esi, ebp, esp, ebx, edx, ecx_, eax : UInt32
    end

    struct SyscallStringArgument
        str : UInt32
        len : Int32
    end

end

# checked inputs
private def checked_pointer(addr : UInt32) : Void* | Nil
    if addr < 0x8000_0000
        nil
    else
        Pointer(Void).new(addr.to_u64)
    end
end

private def checked_slice(addr : UInt32, len : Int32) : Slice(UInt8) | Nil
    end_addr = addr + len
    if addr < 0x8000_0000 || addr < end_addr
        nil
    else
        Slice(UInt8).new(Pointer(UInt8).new(addr.to_u64), len.to_i32)
    end
end

# path parser
private def parse_path_into_segments(path, &block)
    i = 0
    pslice_start = 0
    while i < path.size
        #Serial.puts path[i].unsafe_chr
        if path[i] == '/'.ord
            # ignore multi occurences of slashes
            if pslice_start - i != 0
                # search for root subsystems
                yield path[pslice_start..i]
            end
            pslice_start = i + 1
        else
        end
        i += 1
    end
    if pslice_start < path.size
        yield path[pslice_start..path.size]
    end
end

# consts
SYSCALL_ERR = 255u32

fun ksyscall_handler(frame : SyscallData::Registers)
    case frame.eax
    when 0 # open
        path = NullTerminatedSlice.new(checked_pointer(frame.ebx).not_nil!.as(UInt8*))
        vfs_node : VFSNode | Nil = nil
        parse_path_into_segments(path) do |segment|
            if vfs_node.nil? # no path specifier
                ROOTFS.each do |fs|
                    if segment == fs.name
                        node = fs.root
                        if node.nil?
                            frame.eax = SYSCALL_ERR
                        else
                            frame.eax = Multiprocessing.current_process.not_nil!.install_fd(node.not_nil!)
                            # panic "opened! ", frame.eax, '\n'
                        end
                        return
                    end
                end
            else
                # TODO
            end
        end
        frame.eax = SYSCALL_ERR
    when 1 # read
        frame.eax = SYSCALL_ERR
    when 2 # write
        fdi = frame.ebx.to_i32
        frame.eax = SYSCALL_ERR
        arg = checked_pointer(frame.edx).not_nil!.as(SyscallData::SyscallStringArgument*)
        str = Slice.new(checked_pointer(arg.value.str).not_nil!.as(UInt8*), arg.value.len)
        if (fd = Multiprocessing.current_process.not_nil!.get_fd(fdi)).nil?
            frame.eax = SYSCALL_ERR
        else
            frame.eax = fd.not_nil!.node.not_nil!.write(str)
        end
    when 3 # getpid
        frame.eax = Multiprocessing.current_process.not_nil!.pid
    else
        frame.eax = SYSCALL_ERR
    end
end