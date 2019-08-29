require "./syscall_defs.cr"
require "./addr_sanitizer.cr"
require "./argv_builder.cr"

lib SyscallData
  struct Registers
    ds : UInt64
    rbp, rdi, rsi,
    r15, r14, r13, r12, r11, r10, r9, r8,
    rdx, rcx, rbx, rax : UInt64
    rsp : UInt64
  end

  @[Packed]
  struct StringArgument32
    str : UInt32
    len : Int32
  end

  @[Packed]
  struct SeekArgument32
    offset : Int32
    whence : Int32
  end

  alias Ino32 = Int32

  @[Packed]
  struct DirentArgument32
    # Inode number
    d_ino : Ino32
    # Length of this record
    d_reclen : UInt16
    # Type of file; not supported by all filesystem types
    d_type : UInt8
    # Null-terminated filename
    d_name : UInt8[256]
  end

  @[Packed]
  struct WaitPidArgument32
    status : Int32*
    options : UInt32
  end

  @[Packed]
  struct IoctlArgument32
    request : Int32
    data    : UInt32
  end
end

lib Kernel
  fun ksyscall_sc_ret_driver(reg : SyscallData::Registers*) : NoReturn
end

# path parser
private def parse_path_into_segments(path, &block)
  i = 0
  pslice_start = 0
  while i < path.size
    # Serial.puts path[i].unsafe_chr
    if path[i] == '/'.ord
      # ignore multi occurences of slashes
      if i - pslice_start > 0
        # search for root subsystems
        yield path[pslice_start..i]
      end
      pslice_start = i + 1
    else
    end
    i += 1
  end
  if path.size - pslice_start > 0
    yield path[pslice_start..path.size]
  end
end

private def parse_path_into_vfs(path, cw_node = nil, create = false)
  vfs_node : VFSNode? = nil
  return nil if path.size < 1
  if path[0] != '/'.ord
    vfs_node = cw_node
  end
  parse_path_into_segments(path) do |segment|
    if vfs_node.nil? # no path specifier
      RootFS.each do |fs|
        if segment == fs.name
          if (vfs_node = fs.root).nil?
            return nil
          else
            break
          end
        end
      end
    elsif segment == "."
      # ignored
    elsif segment == ".."
      vfs_node = vfs_node.parent
    else
      cur_node = vfs_node.open(segment)
      if cur_node.nil? && create
        cur_node = vfs_node.create(segment)
      end
      return if cur_node.nil?
      vfs_node = cur_node
    end
  end
  vfs_node
end

private def append_paths(path, src_path, cw_node)
  return nil if path.size < 1
  if path[0] == '/'.ord
    vfs_node = nil
    cpath = GcString.new "/"
    idx = 0
  else
    vfs_node = cw_node
    cpath = GcString.new src_path
    idx = cpath.size
  end

  parse_path_into_segments(path) do |segment|
    if segment == "."
      # ignored
    elsif segment == ".."
      # pop
      if !vfs_node.nil?
        if vfs_node.not_nil!.parent.nil?
          return nil
        end
        while idx > 1
          idx -= 1
          if cpath[idx] == '/'.ord
            break
          end
        end
        vfs_node = vfs_node.not_nil!.parent
      end
    else
      cpath.insert(idx, '/'.ord.to_u8)
      idx += 1
      segment.each do |ch|
        cpath.insert(idx, ch)
        idx += 1
      end
      if vfs_node.nil?
        RootFS.each do |fs|
          if segment == fs.name
            # Serial.puts "goto ", fs.name, '\n'
            if (vfs_node = fs.root).nil?
              return nil
            else
              break
            end
          end
        end
      elsif (vfs_node = vfs_node.not_nil!.open(segment)).nil?
        # Serial.puts segment, '\n'
        return nil
      end
    end
  end

  Tuple.new(cpath, idx, vfs_node)
end

private macro fv
  frame.value
end

private macro try(expr)
  begin
    if !(x = {{ expr }}).nil?
      x.not_nil!
    else
      fv.rax = SYSCALL_ERR
      return
    end
  end
end

private def checked_string_argument(addr)
  ptr = checked_pointer32(SyscallData::StringArgument32, addr)
  return ptr if ptr.nil?
  checked_slice32(ptr.value.str, ptr.value.len)
end

fun ksyscall_handler(frame : SyscallData::Registers*)
  process = Multiprocessing.current_process.not_nil!
  if process.kernel_process?
    case fv.rax
    when SC_MMAP_DRV
      virt_addr = fv.rbx
      Idt.lock do
        fv.rax = Paging.alloc_page_pg(
          fv.rbx, fv.rdx != 0, fv.r8 != 0,
          fv.r9
        )
      end
    when SC_PROCESS_CREATE_DRV
      Idt.lock do
        initial_ip = fv.rbx
        heap_start = fv.rdx
        udata = Pointer(Void).new(fv.r8).as(Multiprocessing::Process::UserData)
        process = Multiprocessing::Process.spawn_user_4gb(initial_ip, heap_start, udata)
        fv.rax = process.pid
      end
    when SC_SLEEP
      process.status = Multiprocessing::Process::Status::WaitIo
      Multiprocessing.switch_process(frame)
    else
      fv.rax = SYSCALL_ERR
    end
    return Kernel.ksyscall_sc_ret_driver(frame)
  end
  pudata = process.udata
  # Serial.puts "syscall ", fv.rax, " from ", process.pid, '\n'
  case fv.rax
  # files
  when SC_OPEN
    path = try(checked_string_argument(fv.rbx))
    vfs_node = parse_path_into_vfs path, pudata.cwd_node
    if vfs_node.nil?
      fv.rax = SYSCALL_ERR
    else
      Idt.lock do # may allocate
        fv.rax = pudata.install_fd(vfs_node.not_nil!)
      end
    end
  when SC_CREATE
    path = try(checked_string_argument(fv.rbx))
    vfs_node = parse_path_into_vfs path, pudata.cwd_node, true
    if vfs_node.nil?
      fv.rax = SYSCALL_ERR
    else
      Idt.lock do # may allocate
        fv.rax = pudata.install_fd(vfs_node.not_nil!)
      end
    end
  when SC_READ
    fdi = fv.rbx.to_i32
    fd = try(pudata.get_fd(fdi))
    str = try(checked_string_argument(fv.rdx))
    result = fd.not_nil!.node.not_nil!.read(str, fd.offset, process)
    case result
    when VFS_WAIT
      Idt.lock do # may allocate
        vfs_node = fd.not_nil!.node.not_nil!
        vfs_node.fs.queue.not_nil!
          .enqueue(VFSMessage.new(VFSMessage::Type::Read,
            str, process, fd, vfs_node))
      end
      process.status = Multiprocessing::Process::Status::WaitIo
      Multiprocessing.switch_process(frame)
    else
      fd.offset += result
      fv.rax = result
    end
  when SC_WRITE
    fdi = fv.rbx.to_i32
    fd = try(pudata.get_fd(fdi))
    str = try(checked_string_argument(fv.rdx))
    result = fd.not_nil!.node.not_nil!.write(str, fd.offset, process)
    case result
    when VFS_WAIT
      Idt.lock do # may allocate
        vfs_node = fd.not_nil!.node.not_nil!
        vfs_node.fs.queue.not_nil!
          .enqueue(VFSMessage.new(VFSMessage::Type::Write,
            str, process, fd, vfs_node))
      end
      process.status = Multiprocessing::Process::Status::WaitIo
      Multiprocessing.switch_process(frame)
    else
      fd.offset += result
      fv.rax = result
    end
  when SC_SEEK
    fdi = fv.rbx.to_i32
    fd = try(pudata.get_fd(fdi))
    arg = try(checked_pointer32(SyscallData::SeekArgument32, fv.rdx))

    case arg.value.whence
    when SC_SEEK_SET
      fd.offset = arg.value.offset.to_u32
      fv.rax = fd.offset
    when SC_SEEK_CUR
      fd.offset += arg.value.offset
      fv.rax = fd.offset
    when SC_SEEK_END
      fd.offset = (fd.node.not_nil!.size.to_i32 + arg.value.offset).to_u32
      fv.rax = fd.offset
    else
      fv.rax = SYSCALL_ERR
    end
  when SC_IOCTL
    fdi = fv.rbx.to_i32
    fd = try(pudata.get_fd(fdi))
    arg = try(checked_pointer32(SyscallData::IoctlArgument32, fv.rdx))
    request, data = arg.value.request, try(checked_pointer32(Void, arg.value.data))
    Idt.lock do
      fv.rax = fd.node.not_nil!.ioctl(request, data)
    end
  when SC_CLOSE
    fdi = fv.rbx.to_i32
    if pudata.close_fd(fdi)
      fv.rax = SYSCALL_SUCCESS
    else
      fv.rax = SYSCALL_ERR
    end
  # directories
  when SC_READDIR
    fdi = fv.rbx.to_i32
    fd = try(pudata.get_fd(fdi))
    retval = try(checked_pointer32(SyscallData::DirentArgument32, fv.rdx))
    if fd.cur_child_end
      fv.rax = 0
      return
    elsif fd.cur_child.nil?
      if (child = fd.node.not_nil!.first_child).nil?
        fv.rax = SYSCALL_ERR
        return
      end
      fd.cur_child = child
    end

    child = fd.cur_child.not_nil!

    dirent = SyscallData::DirentArgument32.new
    dirent.d_ino = 0
    dirent.d_reclen = sizeof(SyscallData::DirentArgument32)
    dirent.d_type = 0
    if (name = child.name).nil?
      dirent.d_name[0] = '/'.ord.to_u8
      dirent.d_name[1] = 0
    else
      name = name.not_nil!
      i = 0
      while i < min(name.size, dirent.d_name.size - 1)
        dirent.d_name[i] = name[i]
        i += 1
      end
      dirent.d_name[i] = 0
    end
    retval.value = dirent

    fd.cur_child = child.next_node
    if fd.cur_child.nil?
      fd.cur_child_end = true
    end
    fv.rax = SYSCALL_SUCCESS
  # process management
  when SC_GETPID
    fv.rax = process.pid
  when SC_SPAWN
    path = try(checked_string_argument(fv.rbx))
    argv = try(checked_pointer32(UInt32, fv.rdx))
    vfs_node = unless (path_env = pudata.getenv("PATH")).nil?
      # TODO: parse multiple paths
      unless (dir = parse_path_into_vfs(path_env)).nil?
        parse_path_into_vfs path, dir
      end
    end
    if vfs_node.nil?
      vfs_node = parse_path_into_vfs path, pudata.cwd_node
    end
    if vfs_node.nil?
      fv.rax = SYSCALL_ERR
    else
      Idt.lock do # may allocate
        # argv
        pargv = GcArray(GcString).new 0
        i = 0
        while i < SC_SPAWN_MAX_ARGS
          if argv[i] == 0
            break
          end
          arg = NullTerminatedSlice.new(try(checked_pointer32(UInt8, argv[i].to_u64)))
          pargv.push GcString.new(arg, arg.size)
          i += 1
        end

        udata = Multiprocessing::Process::UserData
          .new(pargv,
            pudata.cwd.clone,
            pudata.cwd_node)
        udata.pgid = pudata.pgid

        # copy file descriptors 0, 1, 2
        i = 0
        while i < 3
          if !(fd = process.udata.fds[i]).nil?
            udata.fds[i] = fd
          end
          i += 1
        end

        # create the process
        retval = vfs_node.not_nil!.spawn(udata)
        case retval
        when VFS_WAIT
          vfs_node.fs.queue.not_nil!
            .enqueue(VFSMessage.new(udata, vfs_node, process))
          process.status = Multiprocessing::Process::Status::WaitIo
          Multiprocessing.switch_process(frame)
        else
          fv.rax = retval
        end
      end
    end
  when SC_WAITPID
    pid = fv.rbx.to_i32
    # if fv.rdx != 0
    #   arg = try(checked_pointer32(SyscallData::WaitPidArgument32, fv.rdx))
    # end
    if pid <= 0
      # wait for any child process
      panic "unimplemented"
    else # pid > 0
      cprocess = nil
      Multiprocessing.each do |proc|
        if proc.pid == pid
          cprocess = proc
          break
        end
      end
      if cprocess.nil?
        fv.rax = SYSCALL_ERR
      else
        fv.rax = pid
        process.status = Multiprocessing::Process::Status::WaitProcess
        pudata.pwait = cprocess
        Multiprocessing.switch_process(frame)
      end
    end
  when SC_SLEEP
    process.status = Multiprocessing::Process::Status::WaitIo
    Multiprocessing.switch_process(frame)
  when SC_GETENV
    # TODO
  when SC_SETENV
    # TODO
  when SC_EXIT
    if process.pid == 1
      panic "init exited"
    end
    Multiprocessing.switch_process_and_terminate
  # working directory
  when SC_GETCWD
    str = try(checked_string_argument(fv.rbx))
    if str.size > PATH_MAX
      fv.rax = SYSCALL_ERR
      return
    end
    idx = 0
    pudata.cwd.each do |ch|
      break if idx == str.size - 1
      str[idx] = ch
      idx += 1
    end
    str[idx] = 0
    fv.rax = idx
  when SC_CHDIR
    path = try(checked_string_argument(fv.rbx))
    if (t = append_paths path, pudata.cwd, pudata.cwd_node).nil?
      fv.rax = SYSCALL_ERR
    else
      cpath, idx, vfs_node = t.not_nil!
      if !vfs_node.nil?
        pudata.cwd = GcString.new(cpath, idx)
        pudata.cwd_node = vfs_node.not_nil!
      end
    end
  # memory management
  when SC_SBRK
    incr = fv.rbx.to_i64
    # must be page aligned
    if (incr & 0xfff != 0) || pudata.mmap_heap.nil?
      fv.rax = SYSCALL_ERR
      return
    end
    mmap_heap = pudata.mmap_heap.not_nil!
    if incr > 0
      if !mmap_heap.next_node.nil?
        if mmap_heap.end_addr + incr >= mmap_heap.next_node.not_nil!.addr
          # out of virtual memory
          fv.rax = SYSCALL_ERR
          return
        end
      end
      npages = incr.unsafe_shr(12) + 1
      Paging.alloc_page_pg(mmap_heap.end_addr, true, true, npages: npages.to_u64)
      mmap_heap.size += incr
    elsif incr == 0 && mmap_heap.size == 0u64
      if !mmap_heap.next_node.nil?
        if mmap_heap.end_addr + 0x1000 >= mmap_heap.next_node.not_nil!.addr
          # out of virtual memory
          fv.rax = SYSCALL_ERR
          return
        end
      end
      Paging.alloc_page_pg(mmap_heap.addr, true, true)
      mmap_heap.size += 0x1000
    elsif incr < 0
      # TODO
      panic "decreasing heap not implemented"
    end
    fv.rax = mmap_heap.addr
  else
    fv.rax = SYSCALL_ERR
  end
end
