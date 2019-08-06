private lib Fat16Structs
  @[Packed]
  struct Fat16BootSector
    jmp : UInt8[3]
    oem : UInt8[8]
    sector_size : UInt16
    sectors_per_cluster : UInt8
    reserved_sectors : UInt16
    number_of_fats : UInt8
    root_dir_entries : UInt16
    total_sectors_short : UInt16
    media_descriptor : UInt8
    fat_size_sectors : UInt16
    sectors_per_track : UInt16
    number_of_heads : UInt16
    hidden_sectors : UInt32
    total_sectors_long : UInt32

    drive_number : UInt8
    current_head : UInt8
    boot_signature : UInt8
    volume_id : UInt32
    volume_label : UInt8[11]
    fs_type : UInt8[8]
    boot_code : UInt8[448]
    boot_sector_signature : UInt16
  end

  @[Packed]
  struct Fat16Entry
    name : UInt8[8]
    ext : UInt8[3]
    attributes : UInt8
    reserved : UInt8[10]
    modify_time : UInt16
    modify_date : UInt16
    starting_cluster : UInt16
    file_size : UInt32
  end
end

# entry attributes
private def entry_exists?(entry : Fat16Structs::Fat16Entry)
  # 0x0 : null entry, 0xE5 : deleted
  entry.name[0] != 0x0 && entry.name[0] != 0xE5
end

private def entry_volume_label?(entry : Fat16Structs::Fat16Entry)
  (entry.attributes & 0x08) == 0x08
end

private def entry_file?(entry : Fat16Structs::Fat16Entry)
  (entry.attributes & 0x18) == 0
end

private def entry_dir?(entry : Fat16Structs::Fat16Entry)
  (entry.attributes & 0x18) == 0x10
end

# entry naming
private def name_from_entry(entry)
  # name
  name_len = 7
  while name_len >= 0
    break if entry.name[name_len] != ' '.ord.to_u8
    name_len -= 1
  end

  # extension
  ext_len = 2
  while ext_len >= 0
    break if entry.ext[ext_len] != ' '.ord.to_u8
    ext_len -= 1
  end

  # filename
  if ext_len > 0
    fname = GcString.new(name_len + 2 + ext_len + 1)
  else
    fname = GcString.new(name_len + 1)
  end
  (name_len + 1).times do |i|
    if entry.name[i] >= 'A'.ord && entry.name[i] <= 'Z'.ord
      # to lower case
      fname[i] = entry.name[i] - 'A'.ord + 'a'.ord
    else
      fname[i] = entry.name[i]
    end
  end
  if ext_len > 0
    name_len += 1
    fname[name_len] = '.'.ord.to_u8
    name_len += 1
    (ext_len + 1).times do |i|
      if entry.ext[i] >= 'A'.ord && entry.ext[i] <= 'Z'.ord
        # to lower case
        fname[name_len + i] = entry.ext[i] - 'A'.ord + 'a'.ord
      else
        fname[name_len + i] = entry.ext[i]
      end
    end
  end

  fname
end

class Fat16Node < VFSNode
  @parent : Fat16Node? = nil
  property parent

  @next_node : Fat16Node? = nil
  property next_node

  @name : GcString? = nil
  property name

  @first_child : Fat16Node? = nil
  property first_child

  @size = 0u32
  getter size

  # file system specific
  @starting_cluster = 0u32
  getter starting_cluster

  @directory = false
  @dir_populated = false

  def directory?
    @directory
  end

  getter fs

  def initialize(@fs : Fat16FS, @name = nil, @directory = false,
                 @next_node = nil, @first_child = nil,
                 @size = 0u32, @starting_cluster = 0u32)
    if @name.nil? && @directory
      @dir_populated = true
    end
  end

  # children
  def each_child(&block)
    return unless directory?
    populate_directory if !@dir_populated
    node = first_child
    while !node.nil?
      yield node.not_nil!
      node = node.next_node
    end
  end

  def add_child(child : Fat16Node)
    if @first_child.nil?
      # first node
      child.next_node = nil
      @first_child = child
    else
      # middle node
      child.next_node = @first_child
      @first_child = child
    end
    child.parent = self
    child
  end

  # read
  private def sector_for(cluster)
    fs.fat_sector + cluster.unsafe_div(fs.fat_sector_size)
  end

  private def ent_for(cluster)
    cluster.unsafe_mod(fs.fat_sector_size)
  end

  private def read_fat_table(fat_table, cluster, last_sector? = -1)
    fat_sector = sector_for cluster
    if last_sector? == fat_sector
      return fat_sector
    end

    # read fat table
    idx = 0
    fs.device.read_sector(fat_sector) do |word|
      if idx < fs.fat_sector_size
        fat_table[idx] = word
        idx += 1
      else
        break
      end
    end

    fat_sector
  end

  def read(read_size = 0, offset = 0, &block)
    return if directory?

    # check arguments
    if read_size == 0
      read_size = size
    elsif read_size < 0
      return
    end
    if offset + read_size > size
      read_size = size - offset
    end

    # setup
    fat_table = Slice(UInt16).malloc fs.fat_sector_size
    fat_sector = read_fat_table fat_table, starting_cluster

    cluster = starting_cluster
    remaining_bytes = read_size

    # skip clusters
    offset_factor = fs.sectors_per_cluster * 512
    offset_clusters = offset.unsafe_div(offset_factor)
    while offset_clusters > 0 && cluster < 0xFFF8
      fat_sector = read_fat_table fat_table, cluster, fat_sector
      cluster = fat_table[ent_for cluster]
      offset_clusters -= 1
    end
    offset_bytes = offset.unsafe_mod(offset_factor)

    # read file
    while remaining_bytes > 0 && cluster < 0xFFF8
      sector = ((cluster - 2) * fs.sectors_per_cluster) + fs.data_sector
      read_sector = 0
      while remaining_bytes > 0 && read_sector < fs.sectors_per_cluster
        fs.device.read_sector(sector + read_sector) do |word|
          u8 = word.unsafe_shr(8) & 0xFF
          u8_1 = word & 0xFF
          if remaining_bytes > 0
            if offset_bytes > 0
              offset_bytes -= 1
            else
              yield u8_1.to_u8
              remaining_bytes -= 1
            end
            if remaining_bytes > 0
              if offset_bytes > 0
                offset_bytes -= 1
              else
                yield u8.to_u8
                remaining_bytes -= 1
              end
            else
              break
            end
          else
            break
          end
        end
        read_sector += 1
      end
      fat_sector = read_fat_table fat_table, cluster, fat_sector
      cluster = fat_table[ent_for cluster]
    end
  end

  #
  private def populate_directory
    fat_table = Slice(UInt16).mmalloc fs.fat_sector_size
    fat_sector = read_fat_table fat_table, starting_cluster

    cluster = starting_cluster
    end_directory = false

    entries = Slice(Fat16Structs::Fat16Entry).mmalloc 16

    while cluster < 0xFFF8
      sector = ((cluster - 2) * fs.sectors_per_cluster) + fs.data_sector
      read_sector = 0
      while read_sector < fs.sectors_per_cluster
        fs.device.read_sector_pointer(entries.to_unsafe.as(UInt16*), sector + read_sector)
        entries.each do |entry|
          load_entry(entry)
        end
        read_sector += 1
      end

      break if end_directory
      fat_sector = read_fat_table fat_table, cluster, fat_sector
      cluster = fat_table[ent_for cluster]
    end

    entries.mfree
    fat_table.mfree
  end

  def open(path : Slice) : VFSNode?
    return unless directory?
    each_child do |node|
      if node.name == path
        return node
      end
    end
  end

  def read(slice : Slice, offset : UInt32,
           process : Multiprocessing::Process? = nil) : Int32
    i = 0
    read(slice.size, offset) do |ch|
      slice[i] = ch
      i += 1
    end
    i
  end

  def write(slice : Slice) : Int32
    VFS_ERR
  end

  def read_queue
  end

  # entry loading
  def load_entry(entry)
    return if !entry_exists? entry
    return if entry_volume_label? entry
    if entry_file? entry
      load_file_entry entry
    elsif entry_dir? entry
      load_dir_entry entry
    end
  end

  private def load_file_entry(entry)
    node = Fat16Node.new(fs, name_from_entry(entry),
      starting_cluster: entry.starting_cluster.to_u32,
      size: entry.file_size)
    add_child node
  end

  private def load_dir_entry(entry)
    node = Fat16Node.new(fs, name_from_entry(entry), true,
      starting_cluster: entry.starting_cluster.to_u32,
      size: entry.file_size)
    add_child node
  end
end

class Fat16FS < VFS
  FS_TYPE = "FAT16   "

  def root
    @root.not_nil!
  end

  @fat_sector = 0u32
  getter fat_sector
  @fat_sector_size = 0
  getter fat_sector_size

  @data_sector = 0u32
  getter data_sector

  @sectors_per_cluster = 0u32
  getter sectors_per_cluster

  # impl
  def name
    device.not_nil!.name.not_nil!
  end

  @next_node : VFS? = nil
  property next_node

  getter device

  def initialize(@device : AtaDevice, partition)
    VGA.puts "initializing FAT16 filesystem\n"
    bs = Pointer(Fat16Structs::Fat16BootSector).mmalloc

    device.read_sector_pointer(bs.as(UInt16*), partition.first_sector)
    idx = 0
    bs.value.fs_type.each do |ch|
      panic "only FAT16 is accepted" if ch != FS_TYPE[idx]
      idx += 1
    end

    @fat_sector = partition.first_sector + bs.value.reserved_sectors
    @fat_sector_size = bs.value.sector_size.to_i32.unsafe_div sizeof(UInt16)

    root_dir_sectors = ((bs.value.root_dir_entries * 32) + (bs.value.sector_size - 1)).unsafe_div bs.value.sector_size

    sector = fat_sector + bs.value.fat_size_sectors.to_i32 * bs.value.number_of_fats.to_i32
    @data_sector = sector + root_dir_sectors
    @sectors_per_cluster = bs.value.sectors_per_cluster.to_u32

    @root = Fat16Node.new self, nil, true
    entries = Slice(Fat16Structs::Fat16Entry).mmalloc 16

    bs.value.root_dir_entries.times do |i|
      break if sector + i > @data_sector
      device.read_sector_pointer(entries.to_unsafe.as(UInt16*), sector + i)
      entries.each do |entry|
        root.load_entry entry
      end
    end

    # cleanup
    entries.mfree
    bs.mfree
  end

  def debug(*args)
    Serial.puts *args
  end

  #
  def root
    @root.not_nil!
  end
end
