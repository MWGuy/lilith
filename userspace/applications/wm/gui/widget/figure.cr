class G::Figure < G::Widget

  @img_width : Int32
  @img_height : Int32

  getter bitmap

  def self.new(x : Int32, y : Int32, path : String, text : String? = nil)
    self.new x, y, Painter.load_png(path).not_nil!, text
  end

  def initialize(@x : Int32, @y : Int32, image : Image, @text : String? = nil)
    @img_width = image.width
    @img_height = image.height
    @img_bitmap = image.bytes.to_unsafe.as(UInt32*)

    if text = @text
      @width = Math.max(@img_width, G::Fonts.text_width(@text))
      @height = @img_height + G::Fonts::HEIGHT
      @bitmap = Painter.create_bitmap(@width, @height)
      redraw
    else
      @width = @img_width
      @height = @img_height
      @bitmap = @img_bitmap
    end
  end

  def redraw
    Painter.blit_img @bitmap,
                     @width, @height,
                     @img_bitmap,
                     @img_width, @img_height,
                     0, 0
    G::Fonts.blit self, ((@width - G::Fonts.text_width(@text)) // 2), @img_height, @text
  end

end
