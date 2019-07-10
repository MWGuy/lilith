require "./vfs.cr"

private lib Fat16Structs

    @[Packed]
    struct Fat16BootSector
        jmp                 : UInt8[3]
        oem                 : UInt8[8]
        sector_size         : UInt16
        sectors_per_cluster : UInt8
        reserved_sectors    : UInt16
        number_of_fats      : UInt8
        root_dir_entries    : UInt16
        total_sectors_short : UInt16
        media_descriptor    : UInt8
        fat_size_sectors    : UInt16
        sectors_per_track   : UInt16
        number_of_heads     : UInt16
        hidden_sectors      : UInt32
        total_sectors_long  : UInt32

        drive_number        : UInt8
        current_head        : UInt8
        boot_signature      : UInt8
        volume_id           : UInt32
        volume_label        : UInt8[11]
        fs_type             : UInt8[8]
        boot_code           : UInt8[448]
        boot_sector_signature : UInt16
    end

    @[Packed]
    struct Fat16Entry
        name             : UInt8[8]
        ext              : UInt8[3]
        attributes       : UInt8
        reserved         : UInt8[10]
        modify_time      : UInt16
        modify_date      : UInt16
        starting_cluster : UInt16
        file_size        : UInt32
    end

end

class Fat16Node < Gc

    @parent : Fat16Node | Nil = nil
    property parent

    @next_node : Fat16Node | Nil = nil
    property next_node
    property name

    @name : CString | Nil = nil
    property name

    @first_child : Fat16Node | Nil = nil
    getter first_child

    @starting_cluster = 0
    property starting_cluster

    @size = 0u32
    property size

    def initialize(@name = nil,
            @next_node = nil, @first_child = nil)
    end

    def add_child(child : Fat16Node)
        return if @parent == self
        child.next_node = @first_child
        @first_child = child
        child.parent = self
    end

    def read(fs : Fat16FS, &block)
        sector = fs.data_sector + fs.sectors_per_cluster * (starting_cluster - 2)
        i = 0
        j = 0
        while i < size
            s = sector + i.unsafe_div(512)
            Ide.read_sector(s) do |word|
                u8 = word.unsafe_shr(8) & 0xFF
                u8_1 = word & 0xFF
                return if j >= size
                yield u8_1
                return if j >= size
                yield u8
                j += 2
            end
            i += 512
        end
    end

end

struct Fat16FS < VFS

    FS_TYPE = "FAT16   "
    @root = Fat16Node.new
    getter root

    @data_sector = 0u32
    getter data_sector

    @sectors_per_cluster = 0u32
    getter sectors_per_cluster

    def initialize(partition)
        debug "initializing FAT16 filesystem\n"
        bs = uninitialized Fat16Structs::Fat16BootSector
        begin
            ptr = Pointer(UInt16).new pointerof(bs).address
            Ide.read_sector_pointer(ptr, partition.first_sector)
        end
        idx = 0
        bs.fs_type.each do |ch|
            panic "only FAT16 is accepted" if ch != FS_TYPE[idx]
            idx += 1
        end

        root_dir_sectors = ((bs.root_dir_entries * 32) + (bs.sector_size - 1)).unsafe_div bs.sector_size
        sector = partition.first_sector + bs.reserved_sectors + bs.fat_size_sectors * bs.number_of_fats
        @data_sector = sector + root_dir_sectors
        @sectors_per_cluster = bs.sectors_per_cluster.to_u32

        bs.root_dir_entries.times do |i|
            entries = uninitialized Fat16Structs::Fat16Entry[16]
            ptr = Pointer(UInt16).new pointerof(entries).address
            break if sector + i > @data_sector
            Ide.read_sector_pointer(ptr, sector + i)
            entries.each do |entry|
                next if !dir_entry_exists entry
                next if is_volume_label entry

                # append children
                node = Fat16Node.new(CString.new(entry.name, 8))
                node.starting_cluster = entry.starting_cluster.to_i32
                node.size = entry.file_size
                @root.add_child node
            end
        end
    end

    def read(path, &block)
    end

    def debug(*args)
        VGA.puts *args
    end

    #
    private def dir_entry_exists(entry : Fat16Structs::Fat16Entry)
        # 0x0 : null entry, 0xE5 : deleted
        entry.name[0] != 0x0 && entry.name[0] != 0xE5
    end

    private def is_volume_label(entry : Fat16Structs::Fat16Entry)
        (entry.attributes & 0x08) == 0x08
    end

    private def is_file(entry : Fat16Structs::Fat16Entry)
        (entry.attributes & 0x18) == 0
    end

    private def is_dir(entry : Fat16Structs::Fat16Entry)
        (entry.attributes & 0x18) == 0x10
    end

end