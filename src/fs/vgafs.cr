class VGAFsNode < VFSNode

    def size : Int
        0
    end
    def name : CString | Nil
        nil
    end

    #
    def open(path : Slice) : VFSNode | Nil
        nil
    end

    def read(&block)
    end

    def read(slice : Slice, offset : UInt32) : Int32
        0
    end

    def write(slice : Slice) : Int32
        slice.each do |ch|
            VGA.puts ch.unsafe_chr
        end
        slice.size
    end
end

class VGAFS < VFS

    def name
        @name.not_nil!
    end

    @next_node : VFS | Nil = nil
    property next_node

    def initialize
        VGA.puts "initializing vgafs...\n"
        @name = CString.new("vga", 3)
        @root = VGAFsNode.new
    end

    def root
        @root.not_nil!
    end

end