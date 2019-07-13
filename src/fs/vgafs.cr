class VGAFsNode < VFSNode

    def size : Int
        0
    end
    def name : CString | Nil
        nil
    end

    def read(ptr : UInt8*, len : UInt32) : UInt32
        0u32
    end
    def write(slice : NullTerminatedSlice) : UInt32
        slice.each do |ch|
            VGA.puts ch.unsafe_chr
        end
        slice.size.to_u32
    end
end

class VGAFS < VFS

    @name = "vga"
    getter name

    @next_node : VFS | Nil = nil
    property next_node

    def initialize
        VGA.puts "initializing vgafs...\n"
        @root = VGAFsNode.new
    end

    def open(path)
        @root.not_nil!
    end

end