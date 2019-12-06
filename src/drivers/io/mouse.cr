class Mouse
  @mousefs : MouseFS? = nil
  property mousefs

  def initialize
    Idt.register_irq 12, ->callback
  end

  @[Flags]
  enum AttributeByte
    LeftBtn   = 1 << 0
    RightBtn  = 1 << 1
    MiddleBtn = 1 << 2
    AlwaysOne = 1 << 3
    XSign     = 1 << 4
    YSign     = 1 << 5
    XOverflow = 1 << 6
    YOverflow = 1 << 7
  end

  @cycle = 0
  @attr_byte = AttributeByte::None
  @fourth_byte : Int8 = 0.to_i8
  @x = 0
  @y = 0
  @available = false
  getter available

  def flush
    tuple = {@x, @y, @attr_byte, @fourth_byte}
    @fourth_byte = 0.to_i8
    @attr_byte = AttributeByte::None
    @x = 0
    @y = 0
    @available = false
    tuple
  end

  def callback
    packet_finished = false

    # build the packet
    case @cycle
    when 0
      @attr_byte = AttributeByte.new(X86.inb(0x60).to_i32)
      unless @attr_byte.includes?(AttributeByte::AlwaysOne)
        @cycle = 0
        return
      end
      @cycle += 1
    when 1
      @x = X86.inb(0x60)
      @cycle += 1
    when 2
      @y = X86.inb(0x60)
      if PS2.mouse_id == 3 # scrollable
        @cycle += 1
      else
        @cycle = 0
        packet_finished = true
      end
    when 3
      @fourth_byte = X86.inb(0x60).to_i8
      @cycle = 0
      packet_finished = true
      # TODO
    end

    # process it
    if packet_finished
      # complete the packet
      @available = true
      if @attr_byte.includes?(AttributeByte::XSign)
        @x = (@x.to_u32 | 0xFFFFFF00).to_i32
      end
      if @attr_byte.includes?(AttributeByte::YSign)
        @y = (@y.to_u32 | 0xFFFFFF00).to_i32
      end
      if @attr_byte.includes?(AttributeByte::XOverflow) ||
         @attr_byte.includes?(AttributeByte::YOverflow)
        @x = 0
        @y = 0
      end
    end
  end
end
