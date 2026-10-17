# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # "Room": a floor, walls and a roof drawn round the kitchen that is in the model, with the doors and windows you ask for. The room is the box that holds every
  # cabinet and part; a side of it where the backs of cabinets stand against is a wall right behind them, a side with no backs (the open side of a straight kitchen,
  # say) is a wall `open_distance` away. The walls stand on the floor, up to the room height (the top of the highest cabinet or loft, at least 2600 mm); the floor
  # is under the room and the walls, the roof over them. The doors and windows are openings cut through the walls, a door with its leaf in it and a window with its
  # glass.
  #
  # It is drawn as groups of their own, not one: the floor, the walls (one solid ring, the openings cut in it), the roof, and a group for each door and each window, each
  # on a tag of its own (Room Floor, Room Walls, Room Roof, Room Doors, Room Windows). A door or window can be moved like any group: the opening in the wall moves with
  # it (see after_move). Build Room draws it again, Update Room does so after a move, Remove Room takes it away.
  #
  # The geometry that decides the room is plain arithmetic (RoomShell.plan, .boxes, .ring, .openings; mm) so that it can be tested without SketchUp.
  module RoomShell
    DICTIONARY = 'KitchenCabinetMaster'
    KEY = 'room_part'
    TOL = 6.0            # mm: a back this close to the side of the box stands against it
    MIN_HEIGHT = 2600.0  # mm
    DEFAULTS = { 'wall_thickness' => 150.0, 'floor_thickness' => 100.0, 'roof_thickness' => 150.0, 'room_height' => 0.0, 'open_distance' => 1200.0 }.freeze
    TAGS = { 'Floor' => 'Room Floor', 'Walls' => 'Room Walls', 'Roof' => 'Room Roof', 'Doors' => 'Room Doors', 'Windows' => 'Room Windows' }.freeze
    COLOURS = { 'Floor' => [168, 160, 148, 1.0], 'Walls' => [236, 233, 226, 1.0], 'Roof' => [244, 244, 242, 1.0],
                'Doors' => [150, 110, 70, 1.0], 'Windows' => [170, 210, 230, 0.35] }.freeze
    SIDES = { 'west' => :min_x, 'east' => :max_x, 'south' => :min_y, 'north' => :max_y }.freeze
    FRAME_WIDTH = 50.0      # mm: how wide the frame round a door or window is
    LEAF_THICKNESS = 40.0   # mm
    GLASS_THICKNESS = 10.0  # mm
    TRIM_WIDTH = 70.0       # mm: the boards round a door on the faces of the wall
    TRIM_THICKNESS = 14.0
    PANEL_RAISE = 8.0       # mm: how far the panels of a door stand out of its leaf
    WINDOW_FRAME = 60.0     # mm: the frame of a window
    SILL_IN = 35.0          # mm: how far the sill board of a window comes into the room
    SILL_OUT = 45.0         # mm: and how far the one outside comes out of the wall
    MOVED = 1.0             # mm: a door or window that is this far from where it was drawn has been moved

    # items: [{ min: [x, y], max: [x, y], top: z, origin: [x, y], front: [x, y] }] in mm (the box of each cabinet or part, where its origin is,
    # which way its front faces). => { x0:, y0:, x1:, y1:, height:, backs: { min_x:, max_x:, min_y:, max_y: } } or nil without items. (x0..x1, y0..y1) is the
    # inside of the room.
    def self.plan(items, options = {})
      return nil if items.empty?

      opts = DEFAULTS.merge(options.compact)
      box = { min_x: items.map { |i| i[:min][0] }.min, max_x: items.map { |i| i[:max][0] }.max,
              min_y: items.map { |i| i[:min][1] }.min, max_y: items.map { |i| i[:max][1] }.max }
      backs = { min_x: false, max_x: false, min_y: false, max_y: false }
      items.each do |item|
        next if item[:island] || item[:cabinet] == false # (the back of an island is not against a wall, and a part (worktop, side panel, toe kick) is no back: the side is open, and gets the distance)

        fx, fy = item[:front]
        ox, oy = item[:origin]
        if fx.abs > 0.99 # the front along x: the back is the other way
          side = fx.positive? ? :min_x : :max_x
          backs[side] = true if (ox - box[side]).abs <= TOL
        elsif fy.abs > 0.99
          side = fy.positive? ? :min_y : :max_y
          backs[side] = true if (oy - box[side]).abs <= TOL
        end
      end
      open_x = (opts['open_x'] || opts['open_distance']).to_f # (an open side across the red axis: the distance in x; across the green axis: the distance in y)
      open_y = (opts['open_y'] || opts['open_distance']).to_f
      grow = ->(side, sign) { box[side] + (backs[side] ? 0.0 : sign * (%i[min_x max_x].include?(side) ? open_x : open_y)) }
      height = opts['room_height'].to_f.positive? ? opts['room_height'].to_f : [MIN_HEIGHT, items.map { |i| i[:top] }.max].max
      { x0: grow.call(:min_x, -1), x1: grow.call(:max_x, 1), y0: grow.call(:min_y, -1), y1: grow.call(:max_y, 1), height: height, backs: backs }
    end

    # The floor and the roof as boxes: [{ name:, from: [x, y, z], to: [x, y, z] }] in mm. The floor is under the room and the walls, the roof over them.
    def self.boxes(plan, options = {})
      opts = DEFAULTS.merge(options.compact)
      wall = opts['wall_thickness'].to_f
      floor = opts['floor_thickness'].to_f
      roof = opts['roof_thickness'].to_f
      x0 = plan[:x0] - wall
      x1 = plan[:x1] + wall
      y0 = plan[:y0] - wall
      y1 = plan[:y1] + wall
      list = []
      list << { name: 'Floor', from: [x0, y0, -floor], to: [x1, y1, 0.0] } if opts['floor'] != false && floor.positive?
      list << { name: 'Roof', from: [x0, y0, plan[:height]], to: [x1, y1, plan[:height] + roof] } if opts['roof'] != false && roof.positive?
      list
    end
    # The walls as one ring: the outside and the inside rectangle ([x0, y0, x1, y1] each) and the height. nil when the walls are not wanted.
    def self.ring(plan, options = {})
      opts = DEFAULTS.merge(options.compact)
      wall = opts['wall_thickness'].to_f
      return nil if opts['walls'] == false || !wall.positive?

      { outer: [plan[:x0] - wall, plan[:y0] - wall, plan[:x1] + wall, plan[:y1] + wall], inner: [plan[:x0], plan[:y0], plan[:x1], plan[:y1]], height: plan[:height] }
    end

    # The doors and windows: `specs` is [{ 'kind' => 'Door' / 'Window', 'wall' => 'auto' / 'west' / 'east' / 'south' / 'north', 'from' => mm along the inside of the wall
    # from its start (south and north walls: from the west end; west and east walls: from the south end; nil: in the middle), 'width' =>, 'sill' =>, 'height' => }].
    # A door stands on the floor. 'auto': a door goes in the first open side, a window in the first side with the cabinets' backs against it. => [openings, error]; each
    # opening is { kind:, wall:, from: [x, y, z], to: [x, y, z] } (the box cut through the wall, mm) with `out` (the way out through the wall) and `thickness`.
    def self.openings(plan, specs, options = {})
      opts = DEFAULTS.merge(options.compact)
      wall = opts['wall_thickness'].to_f
      found = []
      Array(specs).each do |spec|
        kind = spec['kind'].to_s == 'Door' ? 'Door' : 'Window'
        choice = spec['wall'].to_s
        name = SIDES.key?(choice) ? choice : auto_side(plan[:backs], kind)
        side = SIDES[name]
        length = %i[min_x max_x].include?(side) ? plan[:y1] - plan[:y0] : plan[:x1] - plan[:x0]
        width = spec['width'].to_f
        height = spec['height'].to_f
        sill = kind == 'Door' ? 0.0 : spec['sill'].to_f
        return [nil, "The #{kind.downcase} must have a width and a height."] unless width.positive? && height.positive?
        return [nil, "The #{kind.downcase} is wider than the #{name} wall (#{format('%g', length.round)} mm)."] if width > length

        from = spec['from'].nil? || spec['from'].to_s.strip.empty? ? (length - width) / 2.0 : spec['from'].to_f
        return [nil, "The #{kind.downcase} on the #{name} wall does not fit: it would run past the end of the wall."] if from.negative? || from + width > length + 0.01
        return [nil, "The #{kind.downcase} on the #{name} wall is higher than the wall (#{format('%g', plan[:height].round)} mm)."] if sill + height > plan[:height] + 0.01

        found << { kind: kind, wall: name, side: side, from: from, width: width, sill: sill, height: height, length: length }
      end
      found.group_by { |o| o[:wall] }.each_value do |list|
        list.sort_by { |o| o[:from] }.each_cons(2) do |a, b|
          return [nil, "Two openings on the #{a[:wall]} wall overlap: move or narrow one of them."] if b[:from] < a[:from] + a[:width] - 0.01 && b[:sill] < a[:sill] + a[:height] && a[:sill] < b[:sill] + b[:height]
        end
      end
      [found.map { |o| box_of(o, plan, wall) }, nil]
    end

    # The frame and what is in it for one opening (the box that goes through the wall, see openings): { frame: [boxes], infill: box } in mm. The frame is
    # `width` wide: a jamb on each side and a head over the opening, and a sill under a window; a door's leaf stands on the floor, a window's glass is in the
    # frame. Both are thin and in the middle of the thickness of the wall.
    def self.frame_parts(cut, width = FRAME_WIDTH)
      along = cut[:out][0].zero? ? 0 : 1 # the axis along the wall: x for a south or north wall, y for a west or east one
      across = along.zero? ? 1 : 0
      from = cut[:from]
      to = cut[:to]
      door = cut[:kind] == 'Door'
      u0 = from[along]
      u1 = to[along]
      z0 = from[2]
      z1 = to[2]
      width = [width, (u1 - u0) / 4.0, (z1 - z0) / 4.0].min
      box = lambda do |a0, a1, b0, b1|
        low = from.dup
        high = to.dup
        low[along] = a0
        high[along] = a1
        low[2] = b0
        high[2] = b1
        { from: low, to: high }
      end
      frame = [box.call(u0, u0 + width, z0, z1), box.call(u1 - width, u1, z0, z1), box.call(u0 + width, u1 - width, z1 - width, z1)]
      frame << box.call(u0 + width, u1 - width, z0, z0 + width) unless door
      infill = box.call(u0 + width, u1 - width, door ? z0 : z0 + width, z1 - width)
      thickness = door ? LEAF_THICKNESS : GLASS_THICKNESS
      middle = (from[across] + to[across]) / 2.0
      infill[:from][across] = middle - (thickness / 2.0)
      infill[:to][across] = middle + (thickness / 2.0)
      { frame: frame, infill: infill }
    end

    # The numbers the parts of an opening are drawn from: `mk` makes a box from its coordinates along the wall (a), across it (c) and up (z); the wall fills
    # c0..c1, `sign` says whether the way out is towards the larger c (1) or the smaller (-1).
    def self.opening_space(cut)
      along = cut[:out][0].zero? ? 0 : 1
      across = along.zero? ? 1 : 0
      mk = lambda do |a0, a1, c0, c1, z0, z1|
        low = [0.0, 0.0, z0]
        high = [0.0, 0.0, z1]
        low[along] = a0
        high[along] = a1
        low[across] = c0
        high[across] = c1
        { from: low, to: high }
      end
      { mk: mk, u0: cut[:from][along], u1: cut[:to][along], c0: cut[:from][across], c1: cut[:to][across], z0: cut[:from][2], z1: cut[:to][2],
        mid: (cut[:from][across] + cut[:to][across]) / 2.0, sign: cut[:out][across].positive? ? 1 : -1 }
    end

    # A panel door: the frame (jambs, head, and boards on both faces of the wall), the leaf (stiles, rails and two raised panels on each face) and the lever
    # handle. => { 'Frame' => [boxes], 'Leaf' => [boxes], 'Handle' => [boxes] } in mm; the boxes of one group never overlap.
    def self.door_parts(cut)
      s = opening_space(cut)
      mk = s[:mk]
      u0, u1, c0, c1, z0, z1, mid = s.values_at(:u0, :u1, :c0, :c1, :z0, :z1, :mid)
      fw = [FRAME_WIDTH, (u1 - u0) / 4.0, (z1 - z0) / 4.0].min
      frame = [mk.call(u0, u0 + fw, c0, c1, z0, z1), mk.call(u1 - fw, u1, c0, c1, z0, z1), mk.call(u0 + fw, u1 - fw, c0, c1, z1 - fw, z1)]
      [[c0 - TRIM_THICKNESS, c0], [c1, c1 + TRIM_THICKNESS]].each do |a, b|
        frame << mk.call(u0 - TRIM_WIDTH, u0, a, b, z0, z1) << mk.call(u1, u1 + TRIM_WIDTH, a, b, z0, z1) << mk.call(u0 - TRIM_WIDTH, u1 + TRIM_WIDTH, a, b, z1, z1 + TRIM_WIDTH)
      end
      lu0 = u0 + fw + 3.0
      lu1 = u1 - fw - 3.0
      lz0 = z0 + 10.0
      lz1 = z1 - fw - 3.0
      half = LEAF_THICKNESS / 2.0
      leaf = [mk.call(lu0, lu1, mid - half, mid + half, lz0, lz1)]
      stile = 110.0
      if (lu1 - lu0) > (2 * stile) + 150.0 && (lz1 - lz0) > 700.0
        zm = lz0 + ((lz1 - lz0) * 0.55)
        [[zm + 65.0, lz1 - 110.0], [lz0 + 180.0, zm - 65.0]].each do |za, zb|
          next unless zb - za > 100.0

          [[mid + half, mid + half + PANEL_RAISE], [mid - half - PANEL_RAISE, mid - half]].each { |a, b| leaf << mk.call(lu0 + stile, lu1 - stile, a, b, za, zb) }
        end
      end
      hx = lu1 - 70.0
      hz = [z0 + 1000.0, lz1 - 200.0].min
      handle = []
      [[mid + half, 1], [mid - half, -1]].each do |face, dir|
        handle << mk.call(hx - 25.0, hx + 25.0, *(dir.positive? ? [face, face + 6.0] : [face - 6.0, face]), hz - 25.0, hz + 25.0)
        handle << mk.call(hx - 110.0, hx + 8.0, *(dir.positive? ? [face + 6.0, face + 22.0] : [face - 22.0, face - 6.0]), hz - 9.0, hz + 9.0)
      end
      { 'Frame' => frame, 'Leaf' => leaf, 'Handle' => handle }
    end

    # A casement window: the frame (and boards on the room face), one or two sashes with their glass, a handle, and a sill board inside and one outside.
    # => { 'Frame' =>, 'Sash' =>, 'Glass' =>, 'Handle' =>, 'Sill' => } (boxes, mm).
    def self.window_parts(cut)
      s = opening_space(cut)
      mk = s[:mk]
      u0, u1, c0, c1, z0, z1, mid = s.values_at(:u0, :u1, :c0, :c1, :z0, :z1, :mid)
      fw = [WINDOW_FRAME, (u1 - u0) / 4.0, (z1 - z0) / 4.0].min
      frame = [mk.call(u0, u0 + fw, c0, c1, z0, z1), mk.call(u1 - fw, u1, c0, c1, z0, z1), mk.call(u0 + fw, u1 - fw, c0, c1, z1 - fw, z1), mk.call(u0 + fw, u1 - fw, c0, c1, z0, z0 + fw)]
      room_face = s[:sign].positive? ? [c0 - TRIM_THICKNESS, c0] : [c1, c1 + TRIM_THICKNESS]
      frame << mk.call(u0 - 60.0, u0, *room_face, z0 + fw, z1) << mk.call(u1, u1 + 60.0, *room_face, z0 + fw, z1) << mk.call(u0 - 60.0, u1 + 60.0, *room_face, z1, z1 + 60.0)
      iu0 = u0 + fw
      iu1 = u1 - fw
      iz0 = z0 + fw
      iz1 = z1 - fw
      leaves = (iu1 - iu0) > 900.0 ? 2 : 1
      span = (iu1 - iu0) / leaves
      sw = 45.0
      half = 22.0
      sash = []
      glass = []
      leaves.times do |k|
        lu0 = iu0 + (k * span) + 2.0
        lu1 = iu0 + ((k + 1) * span) - 2.0
        lz0 = iz0 + 2.0
        lz1 = iz1 - 2.0
        sash << mk.call(lu0, lu0 + sw, mid - half, mid + half, lz0, lz1) << mk.call(lu1 - sw, lu1, mid - half, mid + half, lz0, lz1)
        sash << mk.call(lu0 + sw, lu1 - sw, mid - half, mid + half, lz1 - sw, lz1) << mk.call(lu0 + sw, lu1 - sw, mid - half, mid + half, lz0, lz0 + sw)
        glass << mk.call(lu0 + sw, lu1 - sw, mid - 3.0, mid + 3.0, lz0 + sw, lz1 - sw)
      end
      hx = iu0 + span - 2.0 - (sw / 2.0)
      hz = z0 + ((z1 - z0) * 0.5)
      handle = [mk.call(hx - 12.0, hx + 12.0, mid + half, mid + half + 5.0, hz - 35.0, hz + 35.0), mk.call(hx - 7.0, hx + 7.0, mid + half + 5.0, mid + half + 25.0, hz - 80.0, hz + 5.0)]
      inner = s[:sign].positive? ? [c0 - SILL_IN, c0] : [c1, c1 + SILL_IN]
      outer = s[:sign].positive? ? [c1, c1 + SILL_OUT] : [c0 - SILL_OUT, c0]
      sill = [mk.call(u0 - 40.0, u1 + 40.0, *inner, z0 + fw - 28.0, z0 + fw), mk.call(u0 - 30.0, u1 + 30.0, *outer, z0 + fw - 28.0, z0 + fw)]
      { 'Frame' => frame, 'Sash' => sash, 'Glass' => glass, 'Handle' => handle, 'Sill' => sill }
    end

    # A door or window that was moved: it goes to the wall nearest to where it now is, parallel to it, and its place along the wall (and, for a window, its sill
    # height) follow. `x`, `y` is the middle of it and `z` its bottom (mm). => the spec with the new 'wall', 'from' and 'sill'.
    def self.relocate(plan, spec, x, y, z)
      distances = { 'west' => (x - plan[:x0]).abs, 'east' => (x - plan[:x1]).abs, 'south' => (y - plan[:y0]).abs, 'north' => (y - plan[:y1]).abs }
      wall = distances.min_by { |_, d| d }.first
      across = %i[min_x max_x].include?(SIDES[wall])
      along = across ? y - plan[:y0] : x - plan[:x0]
      length = across ? plan[:y1] - plan[:y0] : plan[:x1] - plan[:x0]
      width = spec['width'].to_f
      from = (along - (width / 2.0)).clamp(0.0, [length - width, 0.0].max)
      sill = spec['kind'] == 'Door' ? 0.0 : z.clamp(0.0, [plan[:height] - spec['height'].to_f, 0.0].max)
      spec.merge('wall' => wall, 'from' => from, 'sill' => sill)
    end

    def self.auto_side(backs, kind)
      order = %w[south north west east]
      wanted = order.find { |name| kind == 'Door' ? !backs[SIDES[name]] : backs[SIDES[name]] }
      wanted || order.first
    end
    private_class_method :auto_side

    # The box that goes through the wall for one opening.
    def self.box_of(o, plan, wall)
      u0 = o[:from]
      u1 = o[:from] + o[:width]
      z0 = o[:sill]
      z1 = o[:sill] + o[:height]
      case o[:side]
      when :min_x then from = [plan[:x0] - wall, plan[:y0] + u0, z0]; to = [plan[:x0], plan[:y0] + u1, z1]; out = [-1.0, 0.0]
      when :max_x then from = [plan[:x1], plan[:y0] + u0, z0]; to = [plan[:x1] + wall, plan[:y0] + u1, z1]; out = [1.0, 0.0]
      when :min_y then from = [plan[:x0] + u0, plan[:y0] - wall, z0]; to = [plan[:x0] + u1, plan[:y0], z1]; out = [0.0, -1.0]
      else from = [plan[:x0] + u0, plan[:y1], z0]; to = [plan[:x0] + u1, plan[:y1] + wall, z1]; out = [0.0, 1.0]
      end
      { kind: o[:kind], wall: o[:wall], from: from, to: to, out: out, thickness: wall,
        spec: { 'kind' => o[:kind], 'wall' => o[:wall], 'from' => o[:from], 'width' => o[:width], 'sill' => o[:sill], 'height' => o[:height] } }
    end
    private_class_method :box_of

    # ---- SketchUp ----------------------------------------------------------------

    def self.perform(action, raw)
      case action
      when 'build_room' then build(raw)
      when 'remove_room' then remove
      when 'update_room' then update
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    def self.stringify(raw) = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}

    def self.number(raw, key, label, min, max)
      text = raw[key].to_s.strip
      return [nil, nil] if text.empty?

      value = ValidationManager.to_float(text)
      return [nil, "#{label} must be between #{format('%g', min)} and #{format('%g', max)} mm."] unless value && value.between?(min, max)

      [value, nil]
    end

    # What the model holds of the kitchen, as the items of `plan`.
    def self.items_of(model)
      model.entities.grep(Sketchup::ComponentInstance).filter_map do |item|
        next unless AttributeManager.cabinet?(item) || AttributeManager.part?(item)

        bounds = item.bounds
        t = item.transformation
        { min: [bounds.min.x.to_mm, bounds.min.y.to_mm], max: [bounds.max.x.to_mm, bounds.max.y.to_mm], top: bounds.max.z.to_mm,
          origin: [t.origin.x.to_mm, t.origin.y.to_mm], front: [t.xaxis.x, t.xaxis.y], island: !item.get_attribute(AttributeManager::DICTIONARY, 'island_seating').nil?, cabinet: AttributeManager.cabinet?(item) }
      end
    end

    def self.parts_in(model)
      model.entities.grep(Sketchup::Group).select { |group| group.get_attribute(DICTIONARY, KEY) }
    end

    # The doors and windows the panel asks for ([{ 'kind', 'on', 'wall', 'from', 'width', 'sill', 'height' }]) as specs; [specs, error].
    def self.specs_of(raw)
      list = raw['openings'].is_a?(Array) ? raw['openings'] : []
      specs = []
      list.each do |entry|
        entry = stringify(entry)
        next unless ValidationManager.truthy_value?(entry['on'])

        kind = entry['kind'].to_s == 'Door' ? 'Door' : 'Window'
        label = kind.downcase
        width, problem = number(entry, 'width', "The #{label} width", 200.0, 6000.0)
        return [nil, problem] if problem
        height, problem = number(entry, 'height', "The #{label} height", 200.0, 4000.0)
        return [nil, problem] if problem
        sill, problem = number(entry, 'sill', "The #{label} sill height", 0.0, 3500.0)
        return [nil, problem] if problem
        from, problem = number(entry, 'from', "The #{label} distance along the wall", 0.0, 50_000.0)
        return [nil, problem] if problem

        specs << { 'kind' => kind, 'wall' => entry['wall'].to_s, 'from' => from, 'width' => width, 'sill' => sill, 'height' => height }
      end
      [specs, nil]
    end

    def self.build(raw)
      raw = stringify(raw)
      limits = { 'wall_thickness' => ['The wall thickness', 20.0, 1000.0], 'floor_thickness' => ['The floor thickness', 20.0, 1000.0],
                 'roof_thickness' => ['The roof thickness', 20.0, 1000.0], 'room_height' => ['The room height', 1500.0, 10_000.0],
                 'open_distance' => ['The distance to an open side', 0.0, 10_000.0] }
      options = {}
      limits['open_x'] = ['The distance to an open side in x', 0.0, 10_000.0]
      limits['open_y'] = ['The distance to an open side in y', 0.0, 10_000.0]
      limits.each do |key, (label, min, max)|
        value, problem = number(raw, key, label, min, max)
        return Response.fail(problem, [{ 'field' => key, 'message' => problem }]) if problem

        options[key] = value
      end
      %w[floor walls roof].each { |key| options[key] = ValidationManager.truthy_value?(raw[key]) if raw.key?(key) }
      return Response.fail('Choose at least one of the floor, the walls and the roof.') if %w[floor walls roof].none? { |key| options[key] != false }

      specs, problem = specs_of(raw)
      return Response.fail(problem) if problem

      model = Sketchup.active_model
      plan = plan(items_of(model), options)
      return Response.fail('There is no kitchen in the model yet: the room is drawn round the cabinets.') unless plan

      cuts, problem = options['walls'] == false ? [[], nil] : openings(plan, specs, options)
      return Response.fail(problem) if problem

      model.start_operation('Build Room', true)
      begin
        parts_in(model).each(&:erase!)
        draw_room(model, plan, options, cuts)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      sides = plan[:backs].count { |_, back| back }
      Response.ok("Room drawn: #{format('%g', (plan[:x1] - plan[:x0]).round)} x #{format('%g', (plan[:y1] - plan[:y0]).round)} mm inside, #{format('%g', plan[:height].round)} mm high" \
                  "#{", walls right behind the cabinets on #{sides} side#{'s' unless sides == 1}" if sides.positive?}" \
                  "#{", #{cuts.count { |c| c[:kind] == 'Door' }} door(s) and #{cuts.count { |c| c[:kind] == 'Window' }} window(s)" unless cuts.empty?}.")
    end

    # The room: a group for the floor, one for the walls, one for the roof and one for each door and window, in the model, each on its own tag. What it was made from is
    # kept on the model, so that it can be drawn again when a door or window is moved.
    def self.draw_room(model, plan, options, cuts)
      inside = model.entities
      boxes(plan, options).select { |b| b[:name] == 'Floor' }.each { |box| solid(model, inside, box) }
      if (ring = ring(plan, options))
        walls = part(model, inside, 'Walls')
        wall_ring(walls.entities, ring)
        cuts.each { |cut| cut_wall(walls.entities, cut) }
      end
      boxes(plan, options).select { |b| b[:name] == 'Roof' }.each { |box| solid(model, inside, box) }
      counts = Hash.new(0)
      cuts.each_with_index do |cut, index|
        counts[cut[:kind]] += 1
        draw_opening(model, inside, cut, index, "#{cut[:kind]} #{counts[cut[:kind]]}")
      end
      model.set_attribute(DICTIONARY, 'room_plan', JSON.generate(plan))
      model.set_attribute(DICTIONARY, 'room_options', JSON.generate(options))
      model.set_attribute(DICTIONARY, 'room_specs', JSON.generate(cuts.map { |c| c[:spec] }))
    end
    private_class_method :draw_room

    # A group for a part of the room, on its tag and with its colour.
    def self.part(model, entities, name)
      group = entities.add_group
      group.name = name
      group.set_attribute(DICTIONARY, KEY, name)
      group.layer = model.layers[TAGS[name]] || model.layers.add(TAGS[name])
      colour = COLOURS.fetch(name, [230, 230, 230, 1.0])
      material = model.materials["Room #{name}"] || model.materials.add("Room #{name}")
      material.color = Sketchup::Color.new(*colour[0, 3])
      material.alpha = colour[3]
      group.material = material
      group
    end
    private_class_method :part

    # A box drawn as a group of its own (the floor, the roof).
    def self.solid(model, entities, box)
      group = part(model, entities, box[:name])
      slab(group.entities, box[:from], box[:to])
      group
    end
    private_class_method :solid

    # A box: a face at the bottom pushed up.
    def self.slab(entities, from, to)
      points = [[from[0], from[1]], [to[0], from[1]], [to[0], to[1]], [from[0], to[1]]].map { |x, y| Geom::Point3d.new(x.mm, y.mm, from[2].mm) }
      face = entities.add_face(points)
      face.reverse! if face.normal.z.negative?
      face.pushpull((to[2] - from[2]).mm)
    end
    private_class_method :slab

    # The walls: the outside rectangle with the inside one cut out of it, pushed up to the height.
    def self.wall_ring(entities, ring)
      o = ring[:outer]
      i = ring[:inner]
      rectangle = ->(r) { [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]].map { |x, y| Geom::Point3d.new(x.mm, y.mm, 0) } }
      entities.add_face(rectangle.call(o))
      hole = entities.add_face(rectangle.call(i))
      entities.erase_entities(hole)
      face = entities.grep(Sketchup::Face).max_by(&:area)
      face.reverse! if face.normal.z.negative?
      face.pushpull(ring[:height].mm)
    end
    private_class_method :wall_ring

    # An opening cut through the wall: a rectangle drawn on the inside face of the wall, pushed through it.
    def self.cut_wall(entities, cut)
      from = cut[:from]
      to = cut[:to]
      out = Geom::Vector3d.new(cut[:out][0], cut[:out][1], 0)
      inner_x = cut[:out][0].zero? ? nil : (cut[:out][0].negative? ? to[0] : from[0])
      inner_y = cut[:out][1].zero? ? nil : (cut[:out][1].negative? ? to[1] : from[1])
      points =
        if inner_x # a west or east wall: the rectangle in the plane x = inner_x
          [[from[1], from[2]], [to[1], from[2]], [to[1], to[2]], [from[1], to[2]]].map { |y, z| Geom::Point3d.new(inner_x.mm, y.mm, z.mm) }
        else
          [[from[0], from[2]], [to[0], from[2]], [to[0], to[2]], [from[0], to[2]]].map { |x, z| Geom::Point3d.new(x.mm, inner_y.mm, z.mm) }
        end
      face = entities.add_face(points)
      distance = cut[:thickness].mm
      face.pushpull(face.normal.dot(out).positive? ? distance : -distance)
    end
    private_class_method :cut_wall

    METAL = [190, 190, 196].freeze
    PART_MATERIALS = { 'Frame' => 'Room Frame', 'Sash' => 'Room Frame', 'Sill' => 'Room Frame', 'Leaf' => 'Room Doors', 'Glass' => 'Room Windows', 'Handle' => 'Room Metal' }.freeze

    # A door or a window: a group of its own (on the tag Room Doors or Room Windows) holding a group for each of its parts, each in its material. It can be moved
    # (see after_move): the opening in the wall goes with it, turned parallel to the wall it is nearest to.
    def self.draw_opening(model, entities, cut, index, name)
      kind = cut[:kind]
      group = entities.add_group
      group.name = name
      group.set_attribute(DICTIONARY, KEY, name)
      group.layer = model.layers[TAGS[kind == 'Door' ? 'Doors' : 'Windows']] || model.layers.add(TAGS[kind == 'Door' ? 'Doors' : 'Windows'])
      (kind == 'Door' ? door_parts(cut) : window_parts(cut)).each do |part_name, boxes|
        sub = group.entities.add_group
        sub.name = part_name
        sub.material = opening_material(model, PART_MATERIALS.fetch(part_name))
        boxes.each { |box| slab(sub.entities, box[:from], box[:to]) }
      end
      bounds = group.bounds
      group.set_attribute(DICTIONARY, 'room_opening', index)
      group.set_attribute(DICTIONARY, 'home', [bounds.center.x.to_mm, bounds.center.y.to_mm, bounds.min.z.to_mm])
      watch(group)
      group
    end
    private_class_method :draw_opening

    def self.opening_material(model, name)
      material = model.materials[name] || model.materials.add(name)
      case name
      when 'Room Frame' then material.color = Sketchup::Color.new(246, 246, 244)
      when 'Room Metal' then material.color = Sketchup::Color.new(*METAL)
      when 'Room Doors' then material.color = Sketchup::Color.new(*COLOURS['Doors'][0, 3])
      when 'Room Windows'
        material.color = Sketchup::Color.new(*COLOURS['Windows'][0, 3])
        material.alpha = COLOURS['Windows'][3]
      end
      material
    end
    private_class_method :opening_material

    # ---- moving a door or a window -------------------------------------------------------

    def self.load_plan(model)
      raw = JSON.parse(model.get_attribute(DICTIONARY, 'room_plan', '{}'))
      return nil unless raw['x0']

      { x0: raw['x0'], y0: raw['y0'], x1: raw['x1'], y1: raw['y1'], height: raw['height'], backs: (raw['backs'] || {}).transform_keys(&:to_sym) }
    rescue JSON::ParserError
      nil
    end
    private_class_method :load_plan

    # What became of the doors and windows, from [[index, [x, y, z] now, [x, y, z] drawn at]] (one entry for each door or window group in the model): a group that is
    # not where it was drawn has been MOVED; a second group with the same index is a COPY (a door or window copied and pasted: it is a new opening of its own, as
    # big as the first). Of the groups with one index the one still where it was drawn is the original, else the first. => [{ index => now }, [[index, now], ...]].
    def self.classify_openings(entries)
      moved = {}
      copies = []
      entries.group_by(&:first).each do |index, group|
        original = group.find { |_, now, home| now.zip(home).none? { |a, b| (a - b).abs > MOVED } } || group.first
        group.each { |entry| copies << [index, entry[1]] unless entry.equal?(original) }
        moved[index] = original[1] if original[1].zip(original[2]).any? { |a, b| (a - b).abs > MOVED }
      end
      [moved, copies]
    end

    def self.opening_entries(model, specs)
      model.entities.grep(Sketchup::Group).filter_map do |group|
        index = group.get_attribute(DICTIONARY, 'room_opening')
        home = group.get_attribute(DICTIONARY, 'home')
        next unless index && home && specs[index]

        bounds = group.bounds
        [index, [bounds.center.x.to_mm, bounds.center.y.to_mm, bounds.min.z.to_mm], home]
      end
    end
    private_class_method :opening_entries

    # A move is over (or Update Room): a door or window that is not where it was drawn takes the opening of the wall with it, one that was copied and pasted gets an
    # opening of its own where it is, and the room is drawn again (every opening drawn square to its wall). => how many were moved or added.
    def self.after_move(model)
      return 0 if @busy || model.nil?

      plan = load_plan(model)
      return 0 unless plan

      specs = JSON.parse(model.get_attribute(DICTIONARY, 'room_specs', '[]'))
      options = JSON.parse(model.get_attribute(DICTIONARY, 'room_options', '{}'))
      moved, copies = classify_openings(opening_entries(model, specs))
      return 0 if moved.empty? && copies.empty?

      redo_room(model, plan, options, specs, moved, copies)
      moved.length + copies.length
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not move a door or window of the room: #{e.message}"
      0
    end

    def self.redo_room(model, plan, options, specs, moved, copies = [])
      changed = specs.map(&:dup)
      moved.each { |index, (x, y, z)| changed[index] = relocate(plan, changed[index], x, y, z) }
      copies.each { |index, (x, y, z)| changed << relocate(plan, specs[index].dup, x, y, z) } # (a copy: one more opening of the same size)
      cuts, problem = openings(plan, changed, options)
      unless cuts # it does not fit there: it goes back where it was
        DialogManager.push('notice', { 'message' => "#{problem} The door or window went back (a copy was taken away)." }) if defined?(DialogManager)
        cuts, problem = openings(plan, specs, options)
        return if problem
      end
      @busy = true
      model.start_operation('Move Door or Window', true)
      begin
        parts_in(model).each(&:erase!)
        draw_room(model, plan, options, cuts)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @busy = false
      end
      DialogManager.push('info', { 'message' => copies.empty? ? 'The opening in the wall moved with the door or window.' : 'The pasted door or window has an opening in the wall of its own.' }) if defined?(DialogManager) && !problem
    end
    private_class_method :redo_room

    if defined?(Sketchup::ToolsObserver)
      # The Move tool lets go (or the tool changes): look at the doors and windows after a moment, outside whatever SketchUp is doing.
      class ToolWatcher < Sketchup::ToolsObserver
        def onToolStateChanged(_tools, _name, tool_id, tool_state)
          RoomShell.request if tool_id == SnapManager::MOVE_TOOL_ID && tool_state.zero?
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Room watcher failed: #{e.message}"
        end

        def onActiveToolChanged(_tools, _name, _tool_id)
          RoomShell.request
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Room watcher failed: #{e.message}"
        end
      end

      # A door or window that changes (it is moved, rotated ...): the room is looked at after a moment.
      class OpeningWatcher < Sketchup::EntityObserver
        def onChangeEntity(_entity)
          RoomShell.request
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Room watcher failed: #{e.message}"
        end
      end

      # A group is added (a door or window pasted, say): the room is looked at after a moment.
      class AddedWatcher < Sketchup::EntitiesObserver
        def onElementAdded(_entities, entity)
          RoomShell.request if entity.is_a?(Sketchup::Group)
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Room watcher failed: #{e.message}"
        end
      end

      class AppWatcher < Sketchup::AppObserver
        def expectsStartupModelNotifications = true
        def onNewModel(model) = RoomShell.attach(model)
        def onOpenModel(model) = RoomShell.attach(model)
        def onActivateModel(model) = RoomShell.attach(model)
      end
    end

    # A door or window tells when it changes.
    def self.watch(group)
      group.add_observer(OpeningWatcher.new) if defined?(OpeningWatcher)
    end
    private_class_method :watch

    # Call once when the extension loads.
    def self.install
      @attached = {}
      @tool_watcher = ToolWatcher.new
      @added_watcher = AddedWatcher.new
      Sketchup.add_observer(AppWatcher.new)
      attach(Sketchup.active_model)
    end

    def self.attach(model)
      return unless model

      key = model.guid
      return if @attached[key]

      model.tools.add_observer(@tool_watcher)
      model.entities.add_observer(@added_watcher)
      model.entities.grep(Sketchup::Group).each { |group| watch(group) if group.get_attribute(DICTIONARY, 'room_opening') } # (the doors and windows of a model that was opened)
      @attached[key] = true
    end

    def self.request
      return if @timer || @busy

      @timer = UI.start_timer(0.5, false) do
        @timer = nil
        after_move(Sketchup.active_model)
      end
    end

    # Update Room: the doors and windows that were moved take their openings along (this is also done by itself when a move is over).
    def self.update
      model = Sketchup.active_model
      return Response.fail('There is no room in the model yet: press Build Room.') if parts_in(model).empty?

      count = after_move(model)
      Response.ok(count.zero? ? 'The doors and windows are where they were drawn: nothing to move.' : "#{count} door or window moved or copied: the openings in the walls follow them.")
    end

    def self.remove
      model = Sketchup.active_model
      found = parts_in(model)
      return Response.ok('There is no room to remove.') if found.empty?

      model.start_operation('Remove Room', true)
      begin
        found.each(&:erase!)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      %w[room_plan room_options room_specs].each { |key| model.delete_attribute(DICTIONARY, key) }
      Response.ok('The room (floor, walls, roof, doors and windows) was removed.')
    end
  end
end
