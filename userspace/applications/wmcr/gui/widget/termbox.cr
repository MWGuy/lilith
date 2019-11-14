class G::Termbox < G::Widget

  @input_fd : IO::FileDescriptor? = nil
  @output_fd : IO::FileDescriptor? = nil
  getter input_fd, output_fd

  # sets the IO device which will be receiving input
  def input_fd=(@input_fd)
    if old_fd = @input_fd
      @app.not_nil!.unwatch_io old_fd
    end
    @app.not_nil!.watch_io @input_fd.not_nil!
  end

  # sets the IO device which output will be displayed
  def output_fd=(@output_fd)
    if old_fd = @output_fd
      @app.not_nil!.unwatch_io old_fd
    end
    @app.not_nil!.watch_io @output_fd.not_nil!
  end

  @bitmap = Pointer(UInt32).null
  getter bitmap
  def initialize(@x : Int32, @y : Int32,
                 width : Int32, height : Int32)
    resize width, height
    @line = Array(UInt8).new 128
  end

  def resize(@width : Int32, @height : Int32)
    @cwidth = @width // G::Fonts::WIDTH
    @cheight = @height // G::Fonts::HEIGHT
    if @bitmap.null?
      @bitmap = Painter.create_bitmap(@width, @height)
      @cbuffer = Slice(Char).new @cwidth * @cheight
    else
      @bitmap = @bitmap.realloc @width * @height
      @cbuffer = @cbuffer.realloc @cwidth * @cheight
    end
    redraw_all
  end

  def backspace(redraw? = true)
    if @line.pop.nil?
      return
    end
    if @cx == 0
      if @cy != 0
        @cy -= 1
      end
    else
      @cx -= 1
    end
    @cbuffer[@cy * @cwidth + @cx] = '\0'
    redraw_all
    if redraw?
      @app.not_nil!.redraw
    end
  end

  def scroll(redraw? = true)
    (@cheight - 1).times do |y|
      @cwidth.times do |x|
        @cbuffer[y * @cwidth + x] = @cbuffer[(y + 1) * @cwidth + x]
      end
    end
    @cwidth.times do |x|
      @cbuffer[(@cheight - 1) * @cwidth + x] = '\0'
    end
    redraw_all
    if redraw?
      @app.not_nil!.redraw
    end
  end

  def redraw_all
    Painter.blit_rect @bitmap,
                      @width, @height,
                      @width, @height,
                      0, 0, 0x00000000
    @cheight.times do |y|
      @cwidth.times do |x|
        G::Fonts.blit(@bitmap,
                      @width, @height,
                      x * G::Fonts::WIDTH,
                      y * G::Fonts::HEIGHT,
                      @cbuffer[y * @cwidth + x])
      end
    end
  end

  @cx = 0
  @cy = 0
  @cwidth = 0
  @cheight = 0
  @cbuffer = Slice(Char).empty
  def putc(ch : Char, redraw? = true)
    if @cx == @cwidth
      newline
    end
    if ch == '\n'
      newline
      return
    end
    @cbuffer[@cy * @cwidth + @cx] = ch
    G::Fonts.blit(self,
                  @cx * G::Fonts::WIDTH,
                  @cy * G::Fonts::HEIGHT,
                  ch)
    @cx += 1
    if redraw?
      @app.not_nil!.redraw
    end
  end

  def newline
    @cx = 0
    if @cy == @cheight - 1
      scroll
    else
      @cy += 1
    end
  end

  def key_event(ev : G::KeyboardEvent)
    return if @line.size + ev.ch.bytesize >= @line.capacity - 2
    if ev.ch == '\n'
      @line.push '\n'.ord.to_u8
      if fd = @input_fd
        fd.unbuffered_write @line.to_slice
      end
      @line.clear
      newline
      return
    end
    if ev.ch == '\b'
      backspace
    else
      ev.ch.each_byte do |byte|
        @line.push byte
      end
      putc ev.ch
    end
  end

  def io_event(io : IO::FileDescriptor)
    if io == @output_fd
      buffer = uninitialized UInt8[128]
      while (nread = io.unbuffered_read(buffer.to_slice)) > 0
        buffer.each_with_index do |u8, i|
          break if i == nread
          # FIXME: decode unicode chars
          putc u8.unsafe_chr, false
        end
      end
      app.redraw
    end
  end

end

