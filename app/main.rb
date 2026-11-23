# Runtime jigsaw cuts. Original JPEGs remain unchanged.
module JigsawCuts
  extend self

  COLUMNS = 5
  ROWS = 3
  EDGE = 192
  BOARD_X = 160
  BOARD_Y = 72
  SOURCE_WIDTH = 640
  SOURCE_HEIGHT = 360
  SCALE = ROWS * EDGE / SOURCE_HEIGHT.to_f
  CROP_X = (SOURCE_WIDTH - COLUMNS * EDGE / SCALE) * 0.5
  EPSILON = 0.000001

  # Narrow shoulders lead into a circular head. The middle four curves
  # trace 270 degrees of a circle; one radius keeps both axes equally round.
  # Neighbours traverse these exact sampled points in reverse.
  CURVES = [
    [-1.4, 0, -0.54, 0, -0.55, 0.2854, -0.7071, 0.4429].freeze,
    [-0.7071, 0.4429, -0.8946, 0.6304, -1, 0.8848, -1, 1.15].freeze,
    [-1, 1.15, -1, 1.7023, -0.5523, 2.15, 0, 2.15].freeze,
    [0, 2.15, 0.5523, 2.15, 1, 1.7023, 1, 1.15].freeze,
    [1, 1.15, 1, 0.8848, 0.8946, 0.6304, 0.7071, 0.4429].freeze,
    [0.7071, 0.4429, 0.55, 0.2854, 0.54, 0, 1.4, 0].freeze
  ].freeze

  def outlines
    horizontal = []
    (ROWS + 1).times do |row|
      horizontal << COLUMNS.times.map do |column|
        edge(column * EDGE, row * EDGE, 1, 0, row == 0 || row == ROWS)
      end
    end
    vertical = []
    ROWS.times do |row|
      vertical << (COLUMNS + 1).times.map do |column|
        edge(column * EDGE, row * EDGE, 0, 1, column == 0 || column == COLUMNS)
      end
    end
    result = []
    ROWS.times do |row|
      COLUMNS.times do |column|
        contour = []
        sides = [horizontal[row][column], vertical[row][column + 1],
                 horizontal[row + 1][column].reverse, vertical[row][column].reverse]
        sides.each do |side|
          # Omit the final point: the next side supplies the shared corner.
          side[0...-1].each do |point|
            contour << { x: point.x - column * EDGE, y: point.y - row * EDGE }
          end
        end
        result << { row: row, column: column, points: contour }
      end
    end
    result
  end

  def edge x, y, dx, dy, flat
    points = [{ x: x, y: y }]
    unless flat
      center = EDGE * 0.5 + rand * 20 - 10
      radius = 28 + rand * 4
      polarity = rand < 0.5 ? -1 : 1
      offset = center - radius * 1.4
      points << { x: x + dx * offset, y: y + dy * offset }
      CURVES.each do |curve|
        8.times do |step|
          t = (step + 1) / 8.0
          u = 1 - t
          along = center + radius * (u**3 * curve[0] + 3 * u*u*t * curve[2] +
                                     3 * u*t*t * curve[4] + t**3 * curve[6])
          across = radius * polarity * (u**3 * curve[1] + 3 * u*u*t * curve[3] +
                             3 * u*t*t * curve[5] + t**3 * curve[7])
          points << { x: x + dx * along - dy * across,
                      y: y + dy * along + dx * across }
        end
      end
    end
    points << { x: x + dx * EDGE, y: y + dy * EDGE }
    points
  end

  def cross a, b, c
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  end

  # Ear clipping supports concave sockets; a center fan would cover the holes.
  def triangulate points
    remaining = points.dup
    triangles = []
    while remaining.length > 3
      ear = nil
      remaining.each_with_index do |b, index|
        a = remaining[(index - 1) % remaining.length]
        c = remaining[(index + 1) % remaining.length]
        next if cross(a, b, c) <= EPSILON
        blocked = remaining.any? do |p|
          next false if p.equal?(a) || p.equal?(b) || p.equal?(c)
          cross(a, b, p) >= -EPSILON && cross(b, c, p) >= -EPSILON &&
            cross(c, a, p) >= -EPSILON
        end
        unless blocked
          ear = index
          triangles << [a, b, c]
          break
        end
      end
      raise 'Jigsaw cut could not be triangulated.' unless ear
      remaining.delete_at ear
    end
    triangles << remaining
    triangles
  end
end

module JigsawPieces
  extend self

  PIECE = { x: 0, y: 0, home_x: 0, home_y: 0, points: nil,
            artwork: nil, outline: nil, draw: nil, sprite_offset_x: 0, sprite_offset_y: 0,
            min_x: 0, min_y: 0, max_x: 0, max_y: 0,
            cell: nil, home_cell: 0, status: :queued, launch_at: 0,
            elapsed: 0, from_x: 0, from_y: 0, destination_x: 0,
            destination_y: 0, destination_cell: nil, arc_height: 0,
            dragged: false, displace: false }.freeze
  # A 192 px cell can have a tab of up to 2.15 * 32 px on each side.
  # A fixed size includes room for flooring, ceiling, and the outline strokes.
  TEXTURE_SIZE = 336
  CACHED_SPRITE = { x: 0, y: 0, w: 0, h: 0, source_x: 0, source_y: 0,
                    source_w: 0, source_h: 0, path: nil, r: 255, g: 255,
                    b: 255, a: 255, primitive_marker: :sprite }.freeze
  DARK_LINE = { r: 12, g: 17, b: 24, a: 255 }.freeze
  LIGHT_LINE = { r: 246, g: 240, b: 220, a: 235 }.freeze

  def generate path, output
    JigsawCuts.outlines.map do |cut|
      home_x = JigsawCuts::BOARD_X + cut.column * JigsawCuts::EDGE
      home_y = JigsawCuts::BOARD_Y + cut.row * JigsawCuts::EDGE
      piece = PIECE.merge(home_x: home_x, home_y: home_y, points: cut.points,
                          home_cell: cut.row * JigsawCuts::COLUMNS + cut.column)
      piece.min_x = cut.points.map { |point| point.x }.min
      piece.min_y = cut.points.map { |point| point.y }.min
      piece.max_x = cut.points.map { |point| point.x }.max
      piece.max_y = cut.points.map { |point| point.y }.max
      bake_piece(piece, cut, path, output)
      move(piece, home_x, home_y)
      piece
    end
  end

  def bake_piece piece, cut, path, output
    # Reuse the same two texture names per home cell on every round.
    art_name = "jigsaw_art_#{piece.home_cell}"
    outline_name = "jigsaw_outline_#{piece.home_cell}"
    art_target = output[art_name]
    outline_target = output[outline_name]
    art_target.set w: TEXTURE_SIZE, h: TEXTURE_SIZE, background_color: [0, 0, 0, 0]
    outline_target.set w: TEXTURE_SIZE, h: TEXTURE_SIZE, background_color: [0, 0, 0, 0]

    piece.sprite_offset_x = piece.min_x.floor - 2
    piece.sprite_offset_y = piece.min_y.floor - 2
    width = piece.max_x.ceil + 2 - piece.sprite_offset_x
    height = piece.max_y.ceil + 2 - piece.sprite_offset_y
    ox = -piece.sprite_offset_x
    oy = -piece.sprite_offset_y
    piece.artwork = CACHED_SPRITE.merge(path: art_name, w: width, h: height,
                                       source_w: width, source_h: height)
    piece.outline = piece.artwork.merge(path: outline_name)
    piece.draw = [piece.artwork, piece.outline]

    JigsawCuts.triangulate(cut.points).each do |a, b, c|
      art_target.sprites << {
        x: a.x + ox, y: a.y + oy, x2: b.x + ox, y2: b.y + oy, x3: c.x + ox, y3: c.y + oy,
        source_x: source_x(cut, a), source_y: source_y(cut, a),
        source_x2: source_x(cut, b), source_y2: source_y(cut, b),
        source_x3: source_x(cut, c), source_y3: source_y(cut, c), path: path
      }
    end

    highlights = []
    cut.points.each_with_index do |a, index|
      b = cut.points[(index + 1) % cut.points.length]
      dx = b.x - a.x
      dy = b.y - a.y
      length = Math.sqrt(dx * dx + dy * dy)
      nx = -dy / length
      ny = dx / length
      outline_target.lines << stroke(DARK_LINE, a, b, ox + nx, oy + ny)
      outline_target.lines << stroke(DARK_LINE, a, b, ox - nx, oy - ny)
      highlights << stroke(LIGHT_LINE, a, b, ox, oy)
    end
    outline_target.lines << highlights
  end

  def stroke color, a, b, ox, oy
    color.merge(x: a.x + ox, y: a.y + oy, x2: b.x + ox, y2: b.y + oy)
  end

  # 20..620 by 0..360 is the full-height source crop. Tabs sample the
  # neighbouring cell's artwork through the same mapping as their sockets.
  def source_x cut, point
    JigsawCuts::CROP_X + (cut.column * JigsawCuts::EDGE + point.x) / JigsawCuts::SCALE
  end

  def source_y cut, point
    (cut.row * JigsawCuts::EDGE + point.y) / JigsawCuts::SCALE
  end

  def move piece, x, y
    piece.x = x
    piece.y = y
    sprite_x = x + piece.sprite_offset_x
    sprite_y = y + piece.sprite_offset_y
    piece.artwork.x = piece.outline.x = sprite_x
    piece.artwork.y = piece.outline.y = sprite_y
  end

  # Test the actual cut, so clicking a socket can select the piece beneath it.
  def contains? piece, x, y
    x -= piece.x
    y -= piece.y
    return false if x < piece.min_x || x > piece.max_x || y < piece.min_y || y > piece.max_y
    inside = false
    previous = piece.points[-1]
    piece.points.each do |point|
      if (point.y > y) != (previous.y > y)
        crossing = (previous.x - point.x) * (y - point.y) / (previous.y - point.y) + point.x
        inside = !inside if x < crossing
      end
      previous = point
    end
    inside
  end
end

# Incoming pieces choose random empty grid cells. Destinations remain available
# for player swaps; an obstructed flight redirects to another empty cell.
module JigsawArrivals
  extend self

  DURATION = 45.0
  INTERVAL = 18
  CORNERS = [0, JigsawCuts::COLUMNS - 1,
             (JigsawCuts::ROWS - 1) * JigsawCuts::COLUMNS,
             JigsawCuts::ROWS * JigsawCuts::COLUMNS - 1].freeze

  def prepare pieces
    order = pieces.dup
    # Preplace corners, then launch shuffled edge and interior groups.
    (order.length - 1).downto(1) do |index|
      other = rand(index + 1)
      order[index], order[other] = order[other], order[index]
    end
    corners = []
    edges = []
    interior = []
    order.each do |piece|
      cell = piece.home_cell
      column = cell % JigsawCuts::COLUMNS
      row = (cell / JigsawCuts::COLUMNS.to_f).floor
      if CORNERS.include?(cell)
        corners << piece
      elsif column == 0 || column == JigsawCuts::COLUMNS - 1 ||
            row == 0 || row == JigsawCuts::ROWS - 1
        edges << piece
      else
        interior << piece
      end
    end
    corners.each do |piece|
      piece.cell = piece.home_cell
      piece.destination_cell = piece.home_cell
      piece.status = :loose
      JigsawPieces.move(piece, piece.home_x, piece.home_y)
    end
    order = edges + interior
    order.each_with_index do |piece, index|
      piece.destination_cell = nil
      piece.from_x = rand < 0.5 ? -24 - piece.max_x : 1304 - piece.min_x
      piece.from_y = rand * 720 - 120
      piece.arc_height = 180 + rand * 80
      piece.launch_at = index * INTERVAL
      piece.elapsed = 0
      piece.status = :queued
      piece.cell = nil
      JigsawPieces.move(piece, piece.from_x, piece.from_y)
    end
  end

  def perimeter? cell
    column = cell % JigsawCuts::COLUMNS
    row = (cell / JigsawCuts::COLUMNS.to_f).floor
    column == 0 || column == JigsawCuts::COLUMNS - 1 ||
      row == 0 || row == JigsawCuts::ROWS - 1
  end

  def choose_destination piece, pieces
    eligible = []
    available = []
    corner_piece = CORNERS.include?(piece.home_cell)
    edge_piece = perimeter?(piece.home_cell)
    (JigsawCuts::COLUMNS * JigsawCuts::ROWS).times do |cell|
      next if corner_piece && cell != piece.home_cell
      next if edge_piece && !perimeter?(cell)
      occupant = pieces.find { |other| other.cell == cell }
      eligible << cell unless occupant && occupant.dragged
      available << cell unless occupant
    end
    # Prefer interior cells for interior pieces, leaving room for edge arrivals.
    unless edge_piece
      interior = available.reject { |cell| perimeter?(cell) }
      available = interior unless interior.empty?
    end
    piece.displace = available.empty?
    choices = piece.displace ? eligible : available
    return false if choices.empty?
    cell = choices[rand(choices.length)]
    piece.destination_cell = cell
    column = cell % JigsawCuts::COLUMNS
    row = (cell / JigsawCuts::COLUMNS.to_f).floor
    piece.destination_x = JigsawCuts::BOARD_X + column * JigsawCuts::EDGE
    piece.destination_y = JigsawCuts::BOARD_Y + row * JigsawCuts::EDGE
    true
  end

  def redirect piece, pieces
    return false unless choose_destination(piece, pieces)
    piece.from_x = piece.x
    piece.from_y = piece.y
    piece.elapsed = 0
    piece.arc_height = 90
    true
  end

  def land piece, pieces
    occupant = pieces.find { |other| other.cell == piece.destination_cell }
    if occupant
      # Never move the source of a live drag, including a limbo drag.
      if occupant.dragged
        redirect(piece, pieces)
        return
      end
      available = []
      (JigsawCuts::COLUMNS * JigsawCuts::ROWS).times do |cell|
        available << cell unless pieces.any? { |other| other.cell == cell }
      end
      return if available.empty?
      cell = available[rand(available.length)]
      x = JigsawCuts::BOARD_X + (cell % JigsawCuts::COLUMNS) * JigsawCuts::EDGE
      y = JigsawCuts::BOARD_Y + (cell / JigsawCuts::COLUMNS.to_f).floor * JigsawCuts::EDGE
      JigsawPieces.move(occupant, x, y)
      occupant.cell = cell
    end
    piece.cell = piece.destination_cell
    piece.status = :loose
  end

  def update pieces, clock, allow_launch
    pieces.each do |piece|
      if allow_launch && piece.status == :queued && clock >= piece.launch_at
        next unless choose_destination(piece, pieces)
        piece.status = :flying
      end
      next unless piece.status == :flying
      if !piece.displace && pieces.any? { |other| other.cell == piece.destination_cell }
        # Continue from the current position, without teleporting on obstruction.
        next unless redirect(piece, pieces)
      end
      piece.elapsed += 1.0
      t = (piece.elapsed / DURATION).clamp(0, 1)
      x = piece.from_x + (piece.destination_x - piece.from_x) * t
      y = piece.from_y + (piece.destination_y - piece.from_y) * t + 4 * t * (1 - t) * piece.arc_height
      JigsawPieces.move(piece, x, y)
      land(piece, pieces) if t >= 1
    end
  end
end

module Main
  MUSIC = {
    play: "sounds/tide_clock_puzzle_loop.ogg",
    win:  "sounds/bright_tiles_loop.ogg",
    lose: "sounds/quiet_library_loop.ogg"
  }.freeze
  IMAGES = [
    'sprites/folk-art/dawn-hudson/abstract-faces.jpg',
    'sprites/folk-art/dawn-hudson/folk-art-flower.jpg',
    'sprites/folk-art/dawn-hudson/doodle-pattern.jpg',
    'sprites/folk-art/dawn-hudson/city-doodle.jpg',
    'sprites/folk-art/dawn-hudson/abstract-doodle.jpg',
    'sprites/folk-art/dawn-hudson/love-flowers.jpg'
  ].freeze
  BACKGROUND = [72, 83, 98].freeze
  PICTURE = { x: JigsawCuts::BOARD_X, y: JigsawCuts::BOARD_Y,
              w: JigsawCuts::COLUMNS * JigsawCuts::EDGE,
              h: JigsawCuts::ROWS * JigsawCuts::EDGE,
              source_x: JigsawCuts::CROP_X, source_y: 0,
              source_w: JigsawCuts::SOURCE_WIDTH - 2 * JigsawCuts::CROP_X,
              source_h: JigsawCuts::SOURCE_HEIGHT,
              path: nil, a: 0, primitive_marker: :sprite }.freeze
  RUN_TICKS = 20 * 60
  SETTLE_TICKS = 18
  FADE_TICKS = 30
  PICTURE_REVEAL_TICKS = 290 # Ten times the previous 29-tick reveal.
  LABEL = { x: 640, y: 704, text: '', size_enum: -1, alignment_enum: 1,
            r: 235, g: 240, b: 247, primitive_marker: :label }.freeze
  GRID_LINE = { x: 0, y: 0, x2: 0, y2: 0, r: 170, g: 185, b: 205,
                a: 90, primitive_marker: :line }.freeze
  TARGET = { x: 0, y: 0, w: 192, h: 192, r: 100, g: 240, b: 150,
             a: 0, primitive_marker: :border }.freeze
  PANEL = { x: 0, y: 0, w: 1280, h: 720, path: :solid,
            r: 12, g: 17, b: 25, a: 0, primitive_marker: :sprite }.freeze

  def start
    @background = BACKGROUND.dup
    @picture = PICTURE.dup
    @picture_reveal_age = 0
    @timer = LABEL.merge(y: 711, size_enum: 5)
    @timer_clock = nil
    @timer_tenths = nil
    @message = LABEL.merge(y: 30)
    @timer_panel = PANEL.merge(x: 565, y: 665, w: 150, h: 55, a: 210)
    @target = TARGET.dup
    @shade = PANEL.merge(a: 140)
    @card = PANEL.merge(x: 400, y: 260, w: 480, h: 210, a: 245)
    @result = LABEL.merge(y: 438, size_enum: 4, text: 'Jigsaw Challenge', a: 255)

    # Timed mode button (default selection)
    @button = PANEL.merge(
      x: 400, y: 310, w: 220, h: 58,
      r: 56, g: 91, b: 115, a: 255
    )
    @button_label = LABEL.merge(
      x: 510, y: 353, text: '20 Second Mode',
      size_enum: 2, a: 255
    )

    # Untimed mode button
    @untimed_button = PANEL.merge(
      x: 660, y: 310, w: 220, h: 58,
      r: 56, g: 91, b: 115, a: 255
    )
    @untimed_label = LABEL.merge(
      x: 770, y: 353, text: 'Untimed Mode',
      size_enum: 2, a: 255
    )

    @again_help = LABEL.merge(
      y: 250, text: 'Choose a game mode',
      a: 255
    )

    @instructions = LABEL.merge(
      y: 398, text: 'Assemble the picture.',
      a: 255
    )

    # Timed mode remains the default.
    @timed_mode = true

    # Both buttons must be included in the menu rendering array.
    @menu_draw = [
      @shade, @card,
      @button, @untimed_button,
      @result, @instructions,
      @button_label, @untimed_label,
      @again_help
    ]    
    @end_draw = [@result, @button, @button_label, @again_help]
    @grid = []
    6.times do |column|
      x = JigsawCuts::BOARD_X + column * JigsawCuts::EDGE
      @grid << GRID_LINE.merge(x: x, y: 72, x2: x, y2: 648)
    end
    4.times do |row|
      y = JigsawCuts::BOARD_Y + row * JigsawCuts::EDGE
      @grid << GRID_LINE.merge(x: 160, y: y, x2: 1120, y2: y)
    end
    @pieces = []
    # Image history and the shuffle bag survive start/reset during hot reload.
    @held = nil
    @limbo = false
    @clock = 0
    @phase = :menu
    @prepare_pending = false
    @result_age = FADE_TICKS
    @game_scene = :menu
    update_hud
  end

  def new_puzzle
    @game_scene = :menu
    @grid.each { |line| line.a = GRID_LINE[:a] }
    @button.r = 56
    @button.g = 91
    @button.b = 115
    @held = nil
    @limbo = false
    @target.a = 0
    @clock = 0
    @arrival_clock = 0
    @timer_started = false
    @phase = :preview
    @settled_frames = 0
    @result_age = FADE_TICKS
    @end_draw.each { |primitive| primitive.a = 255 }
    # End-of-run controls stay entirely below the picture (which starts at y=72).
    @result.x = 320
    @result.y = 45
    @result.size_enum = 1
    @result.text = 'Study the picture'
    @button.x = 530
    @button.y = 12
    @button.w = 220
    @button.h = 44
    @button_label.x = 640
    @button_label.y = 45
    @button_label.size_enum = 1
    @button_label.text = 'Begin'
    @again_help.x = 960
    @again_help.y = 45
    @again_help.size_enum = 1
    @again_help.text = 'or press Enter' 
    # DR.reset reuses its seed. Give each round fresh entropy independently of
    # hot reload, and retain image history instead of clearing it in start.
    @round_serial = (@round_serial || 0) + 1
    DR.set_rng(((Time.now.to_f * 1_000_000).to_i + @round_serial) & 0x7fffffff)
    @image_bag ||= []
    if @image_bag.empty?
      @image_bag = (0...IMAGES.length).to_a
      (@image_bag.length - 1).downto(1) do |index|
        other = rand(index + 1)
        @image_bag[index], @image_bag[other] = @image_bag[other], @image_bag[index]
      end
      # Avoid an immediate repeat when one shuffled cycle meets the next.
      if @image_bag[-1] == @image_index
        other = rand(@image_bag.length - 1)
        @image_bag[-1], @image_bag[other] = @image_bag[other], @image_bag[-1]
      end
    end
    @image_index = @image_bag.pop
    puts "Jigsaw round #{@round_serial}: #{IMAGES[@image_index]}"
    @picture.path = IMAGES[@image_index]
    @picture.a = 255
    @picture_reveal_age = 0
    @pieces = JigsawPieces.generate(IMAGES[@image_index], outputs)
    JigsawArrivals.prepare(@pieces)
    update_hud
  end

  def tick
    update_music
    if inputs.keyboard.has_focus
      update_run
      update_picture
    end
    update_hud
    render
    @was_focused = inputs.keyboard.has_focus
  end
  
  def update_music
    desired = {
      menu: nil,
      play: MUSIC[:play],
      win:  MUSIC[:win],
      lose: MUSIC[:lose]
    }[@game_scene]

    music = args.audio[:music]

    # 1. Nothing playing? Start music if needed.
    if music.nil?
      args.audio[:music] = {
        input: desired,
        gain: 0.2,
        looping: true
      } if desired
      return
    end

    # 2. Existing music is muted? Delete it.
    if music.gain == 0.0
      args.audio.delete(:music)
      return
    end

    # 3. Wrong music (or menu)? Mute it.
    if music.input != desired
      music.gain = 0.0
      return
    end
  end
  
  def update_run
    if @prepare_pending
      # The previous tick rendered the acknowledgement. Keep that frame visible
      # while the existing synchronous puzzle generation runs unchanged.
      @prepare_pending = false
      new_puzzle
      return
    end
    if @phase == :menu || @phase == :preview || @phase == :result
      if @result_age < FADE_TICKS
        @result_age += 1
        opacity = @result_age / FADE_TICKS.to_f
        @end_draw.each { |primitive| primitive.a = (255 * opacity).to_i }
      end
      mouse = inputs.mouse
      timed_clicked = mouse.down && mouse.button_left &&
                      mouse.x >= @button.x &&
                      mouse.x <= @button.x + @button.w &&
                      mouse.y >= @button.y &&
                      mouse.y <= @button.y + @button.h

      untimed_clicked = mouse.down && mouse.button_left &&
                        mouse.x >= @untimed_button.x &&
                        mouse.x <= @untimed_button.x + @untimed_button.w &&
                        mouse.y >= @untimed_button.y &&
                        mouse.y <= @untimed_button.y + @untimed_button.h

      clicked = timed_clicked || untimed_clicked
      if @result_age >= FADE_TICKS &&
         (clicked || ( @phase == :menu && inputs.keyboard.key_down.enter))
        if @phase == :menu
          @timed_mode = !untimed_clicked
          @prepare_pending = true
          @button_label.text = 'Preparing...'
          @button.r = 90
          @button.g = 145
          @button.b = 170
          @untimed_button.r = 90
          @untimed_button.g = 145
          @untimed_button.b = 170
          return
        end 
        if @phase == :preview
          # Begin the already prepared round; do not reroll the preview image.
          @phase = :playing
          @game_scene = :play
          @clock = 0
          @picture.a = 0
          @result_age = 0
          @end_draw.each { |primitive| primitive.a = 0 }
          @button_label.text = 'Play Again'
        else
          return_to_menu
        end
      end
      return
    end

    # The player cannot act until the first non-corner piece has landed.
    handle_input if @timer_started
    return if @limbo
    JigsawArrivals.update(@pieces, @arrival_clock, @phase == :playing)
    @arrival_clock += 1 if @phase == :playing
    if @phase == :playing && puzzle_complete?
      @phase = :settling 
      @game_scene = :win
    end
    if @phase == :playing
      if @timer_started
        @clock += 1
      else
        @timer_started = @pieces.any? do |piece|
          piece.status == :loose && !JigsawArrivals::CORNERS.include?(piece.home_cell)
        end
      end
    end
    if @timed_mode && @phase == :playing && @clock >= RUN_TICKS
      @phase = @held ? :grace : :settling
    end
    @phase = :settling if @phase == :grace && !@held
    return unless @phase == :settling
    return if @pieces.any? { |piece| piece.status == :flying }
    return if puzzle_complete? && @picture.a < 255
    # Leave the final placement visible before beginning the result fade.
    @settled_frames += 1
    if @settled_frames >= SETTLE_TICKS
      @phase = :result
      
      @game_scene = :lose unless puzzle_complete?
      
      @result.text = puzzle_complete? ? 'Picture complete!' : "Time's up!"
    end
  end

  def puzzle_complete?
    @pieces.length == JigsawCuts::COLUMNS * JigsawCuts::ROWS && !@held &&
      @pieces.all? { |piece| piece.status == :loose && piece.cell == piece.home_cell }
  end

  def update_picture
    # Idle screens retain their final image without repeating completion checks
    # or allocating fade values. Preview opacity is set when the round is prepared.
    return if @phase == :menu || @phase == :preview || @phase == :result || @picture.a == 255
    return unless puzzle_complete?
    @picture_reveal_age += 1
    progress = @picture_reveal_age / PICTURE_REVEAL_TICKS.to_f
    @picture.a = (255 * progress).to_i
    # Fade the outline sprites separately so strokes outside the crop fade too.
    remaining = 1.0 - progress
    @grid.each { |line| line.a = (GRID_LINE[:a] * remaining).to_i }
    outline_alpha = (255 * remaining).to_i
    @pieces.each { |piece| piece.outline.a = outline_alpha }
  end

  def update_hud
    if @timed_mode
      if @timer_clock != @clock
        tenths = [((RUN_TICKS - @clock) / 6.0).ceil, 0].max
        if @timer_tenths != tenths
          @timer.text = "#{(tenths / 10.0).floor}.#{tenths % 10}"
          @timer_tenths = tenths
        end
        @timer_clock = @clock
      end
    else
      @timer.text = 'Untimed'
    end
    if @phase == :menu || @phase == :preview || @phase == :result
      @message.text = "" unless @message.text.empty?
      return
    end
    @message.text = if @limbo
                      'Click the outlined piece to resume dragging.'
                    elsif @phase == :menu || @phase == :preview || @phase == :result
                      ''
                    elsif !inputs.keyboard.has_focus
                      'Paused'
                    elsif @phase == :grace
                      'Place your held piece to finish.'
                    elsif puzzle_complete?
                      'Picture complete!'
                    elsif @phase == :playing && !@timer_started
                      'First edge piece incoming... '
                    elsif @phase == :playing
                      'Drag pieces into the grid.'
                    else
                      ''
                    end
  end

  def render
    outputs.background_color = @background
    # An opaque preview or completed image fully covers the piece geometry.
    if @picture.a < 255
      outputs.primitives << @grid
      # Render all grid artwork before any grid outlines. Incorrect neighbours
      # can overlap, but neither image may erase the other's tab/socket profile.
      @pieces.each do |piece|
        outputs.primitives << piece.artwork if piece.status == :loose && !piece.cell.nil? && !piece.equal?(@held)
      end
      if @picture_reveal_age == 0
        @pieces.each do |piece|
          outputs.primitives << piece.outline if piece.status == :loose && !piece.cell.nil? && !piece.equal?(@held)
        end
      end
      # Loose, flying, and held pieces remain above the assembled grid layer.
      @pieces.each do |piece|
        outputs.primitives << piece.draw if piece.status == :loose && piece.cell.nil? && !piece.equal?(@held)
      end
      @pieces.each { |piece| outputs.primitives << piece.draw if piece.status == :flying }
      outputs.primitives << @held.draw if @held
      outputs.primitives << @target
    end
    outputs.primitives << @picture if @picture.a > 0
    # During the reveal, composite fading outlines over the full picture.
    if @picture_reveal_age > 0 && @picture.a < 255
      @pieces.each { |piece| outputs.primitives << piece.outline }
    end
    # Submit HUD last so scattered pieces cannot cover timer or pause text.
    unless @phase == :menu || @phase == :preview
      outputs.primitives << @timer_panel
      outputs.primitives << @timer
      outputs.primitives << @message
    end
    outputs.primitives << @menu_draw if @phase == :menu
    outputs.primitives << @end_draw if @phase == :preview || @phase == :result
  end

  def handle_input
    mouse = inputs.mouse
    if @held && !@was_focused && !mouse.button_left
      @limbo = true
      @held.outline.g = 224
      @held.outline.b = 81
    end
    if @limbo
      return unless mouse.down && mouse.button_left && JigsawPieces.contains?(@held, mouse.x, mouse.y)
      @limbo = false
      @offset_x = mouse.x - @held.x
      @offset_y = mouse.y - @held.y
      @held.outline.g = 255
      @held.outline.b = 255
    elsif @phase == :playing && mouse.down && mouse.button_left && !@held
      # Hit testing follows the same front-to-back order as rendering.
      order = @pieces.reverse
      @held = order.find do |piece|
        piece.status == :loose && piece.cell.nil? && JigsawPieces.contains?(piece, mouse.x, mouse.y)
      end
      @held ||= order.find do |piece|
        piece.status == :loose && !piece.cell.nil? && JigsawPieces.contains?(piece, mouse.x, mouse.y)
      end
      if @held
        @offset_x = mouse.x - @held.x
        @offset_y = mouse.y - @held.y
        @origin_x = @held.x
        @origin_y = @held.y
        @origin_cell = @held.cell
        @held.dragged = true
        # The held piece still owns its source slot until the placement commits.
        # This keeps that slot available for the other half of a swap.
        @pieces.delete @held
        @pieces << @held
      end
    end
    return unless @held
    x = (mouse.x - @offset_x).clamp(2 - @held.min_x, 1278 - @held.max_x)
    y = (mouse.y - @offset_y).clamp(2 - @held.min_y, 718 - @held.max_y)
    JigsawPieces.move(@held, x, y)
    update_target
    drop_piece unless mouse.button_left
  end

  def update_target
    center_x = @held.x + JigsawCuts::EDGE * 0.5
    center_y = @held.y + JigsawCuts::EDGE * 0.5
    @target_cell = nil
    @target.a = 0
    return unless center_x >= 160 && center_x < 1120 && center_y >= 72 && center_y < 648
    column = ((center_x - 160) / 192.0).floor
    row = ((center_y - 72) / 192.0).floor
    @target_cell = row * 5 + column
    @swap_target = @pieces.find do |piece|
      !piece.equal?(@held) && piece.cell == @target_cell
    end
    @target.x = 160 + column * 192
    @target.y = 72 + row * 192
    @target.r = @swap_target ? 255 : 100
    @target.g = @swap_target ? 200 : 240
    @target.b = @swap_target ? 80 : 150
    @target.a = 255
  end

  def return_to_menu
    # Return to the original opening menu.
    @phase = :menu
    @game_scene = :menu

    # Restore default game mode.
    @timed_mode = true

    # Clear previous puzzle state.
    @pieces = []
    @held = nil
    @limbo = false
    @target.a = 0

    # Reset timer and round state.
    @clock = 0
    @arrival_clock = 0
    @timer_started = false
    @timer_clock = nil
    @timer_tenths = nil
    @settled_frames = 0

    # Restore original background and picture state.
    @background = BACKGROUND.dup
    @picture.path = nil
    @picture.a = 0
    @picture_reveal_age = 0

    # Restore grid.
    @grid.each { |line| line.a = GRID_LINE[:a] }

    # Restore title.
    @result.text = 'Jigsaw Challenge'
    @result.x = 640
    @result.y = 438
    @result.size_enum = 4

    # Restore original instruction.
    @instructions.text = 'Assemble the picture.'
    @instructions.x = 640
    @instructions.y = 398
    @instructions.size_enum = -1

    # Restore timed mode button.
    @button.x = 400
    @button.y = 310
    @button.w = 220
    @button.h = 58
    @button.r = 56
    @button.g = 91
    @button.b = 115

    @button_label.x = 510
    @button_label.y = 353
    @button_label.text = '20 Second Mode'
    @button_label.size_enum = 2

    # Restore untimed mode button.
    @untimed_button.x = 660
    @untimed_button.y = 310
    @untimed_button.w = 220
    @untimed_button.h = 58
    @untimed_button.r = 56
    @untimed_button.g = 91
    @untimed_button.b = 115

    @untimed_label.x = 770
    @untimed_label.y = 353
    @untimed_label.text = 'Untimed Mode'
    @untimed_label.size_enum = 2

    # Restore text underneath the menu.
    @again_help.text = 'Choose a game mode'
    @again_help.x = 640
    @again_help.y = 250
    @again_help.size_enum = -1

    # Restore original menu opacity.
    @shade.a = 140
    @card.a = 245

    @result.a = 255
    @instructions.a = 255
    @button.a = 255
    @button_label.a = 255
    @untimed_button.a = 255
    @untimed_label.a = 255
    @again_help.a = 255

    # Clear any pending preparation.
    @result_age = FADE_TICKS
    @prepare_pending = false
  end

  def drop_piece
    if @target_cell.nil?
      JigsawPieces.move(@held, @origin_x, @origin_y)
    else
      if @swap_target
        JigsawPieces.move(@swap_target, @origin_x, @origin_y)
        @swap_target.cell = @origin_cell
      end
      JigsawPieces.move(@held, @target.x, @target.y)
      @held.cell = @target_cell
    end
    @held.dragged = false
    @held = nil
    @swap_target = nil
    @target.a = 0
  end
end

DR.disable_framerate_warning!
DR.reset
