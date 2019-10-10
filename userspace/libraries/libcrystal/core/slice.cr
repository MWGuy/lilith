struct Slice(T)
  getter size

  def initialize(@buffer : Pointer(T), @size : Int32)
  end

  def [](idx : Int)
    abort "Slice: out of range" if idx >= @size || idx < 0
    @buffer[idx]
  end

  def []=(idx : Int, value : T)
    abort "Slice: out of range" if idx >= @size || idx < 0
    @buffer[idx] = value
  end

  def [](range : Range(Int, Int))
    abort "Slice: out of range" if range.begin > range.end || range.start + range.end >= @size
    Slice(T).new(@buffer + range.begin, range.size)
  end

  def [](start : Int, count : Int)
    abort "Slice: out of range" if start + count >= @size
    Slice(T).new(@buffer + start, count)
  end

  def to_unsafe
    @buffer
  end

  def each(&block)
    i = 0
    while i < @size
      yield @buffer[i]
      i += 1
    end
  end

  def ==(other)
    return false if other.size != self.size
    i = 0
    other.each do |ch|
      return false if ch != self[i]
      i += 1
    end
    true
  end

  def to_s(io)
    io.print "Slice(", @buffer, " ", @size, ")"
  end
end

alias Bytes = Slice(UInt8)
