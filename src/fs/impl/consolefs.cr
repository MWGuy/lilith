class ConsoleFsNode < VFSNode
  getter fs

  def initialize(@fs : ConsoleFS)
  end

  def open(path : Slice) : VFSNode?
    nil
  end

  def create(name : Slice) : VFSNode?
    nil
  end

  def read(slice : Slice, offset : UInt32,
           process : Multiprocessing::Process? = nil) : Int32
    0
  end

  def write(slice : Slice, offset : UInt32,
            process : Multiprocessing::Process? = nil) : Int32
    VFS_WAIT
  end

  def ioctl(request : Int32, data : UInt32) : Int32
    case request
    when SC_IOCTL_TIOCGWINSZ
      unless (ptr = checked_pointer32(IoctlData::Winsize, data)).nil?
        IoctlHandler.winsize(ptr.not_nil!, Console.width, Console.height, 1, 1)
      else
        -1
      end
    else
      -1
    end
  end

  def read_queue
    nil
  end
end

class ConsoleFS < VFS
  getter name

  def root
    @root.not_nil!
  end

  def initialize
    @name = GcString.new "con"
    @root = ConsoleFsNode.new self

    # setup process-local variables
    @process = Multiprocessing::Process
      .spawn_kernel(->(ptr : Void*) { ptr.as(ConsoleFS).process },
                    self.as(Void*),
                    stack_pages: 4) do |process|
    end
    @queue = VFSQueue.new(@process)
    @process_msg = nil
  end

  # queue
  getter queue

  # process
  @process_msg : VFSMessage? = nil
  protected def process
    while true
      @process_msg = @queue.not_nil!.dequeue
      unless (msg = @process_msg).nil?
        case msg.type
        when VFSMessage::Type::Write
          msg.read do |ch|
            Console.puts ch.unsafe_chr
          end
          msg.unawait(msg.slice_size)
        end
      else
        Multiprocessing.sleep_drv
      end
    end
  end
end
