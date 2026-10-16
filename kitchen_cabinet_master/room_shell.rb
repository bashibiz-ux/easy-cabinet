# frozen_string_literal: true

module KitchenCabinetMaster
  # "Room": a floor, walls and a roof drawn round the kitchen that is in the model, with the doors and windows you ask for. The room is the box that holds every
  # cabinet and part; a side of it where the backs of cabinets stand against is a wall right behind them, a side with no backs (the open side of a straight kitchen,
  # say) is a wall `open_distance` away. The walls stand on the floor, up to the room height (the top of the highest cabinet or loft, at least 2600 mm); the floor
  # is under the room and the walls, the roof over them. The doors and windows are openings cut through the walls, a door with its leaf in it and a window with its
  # glass.
  #
  # All of it is ONE group (Room) holding a group for the floor, one for the walls (one solid ring, the openings cut in it), one for the roof, one for the doors and
  # one for the windows, each on a tag of its own (Room Floor, Room Walls, Room Roof, Room Doors, Room Windows). Build Room draws it again, Remove Room takes it away.
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
    LEAF_THICKNESS = 40.0   # mm
    GLASS_THICKNESS = 10.0  # mm

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
        next if item[:island] # (the back of an island is not against a wall: the side is open, and gets the distance)

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
      { kind: o[:kind], wall: o[:wall], from: from, to: to, out: out, thickness: wall }
    end
    private_class_method :box_of

    # ---- SketchUp ----------------------------------------------------------------

    def self.perform(action, raw)
      case action
      when 'build_room' then build(raw)
      when 'remove_room' then remove
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
          origin: [t.origin.x.to_mm, t.origin.y.to_mm], front: [t.xaxis.x, t.xaxis.y], island: !item.get_attribute(AttributeManager::DICTIONARY, 'island_seating').nil? }
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
      Response.ok("Room drawn as one group: #{format('%g', (plan[:x1] - plan[:x0]).round)} x #{format('%g', (plan[:y1] - plan[:y0]).round)} mm inside, #{format('%g', plan[:height].round)} mm high" \
                  "#{", walls right behind the cabinets on #{sides} side#{'s' unless sides == 1}" if sides.positive?}" \
                  "#{", #{cuts.count { |c| c[:kind] == 'Door' }} door(s) and #{cuts.count { |c| c[:kind] == 'Window' }} window(s)" unless cuts.empty?}.")
    end

    # The room: one group with a group inside it for the floor, the walls, the roof, the doors and the windows, each on its own tag.
    def self.draw_room(model, plan, options, cuts)
      room = model.entities.add_group
      room.name = 'Room'
      room.set_attribute(DICTIONARY, KEY, 'Room')
      inside = room.entities
      boxes(plan, options).select { |b| b[:name] == 'Floor' }.each { |box| solid(model, inside, box) }
      if (ring = ring(plan, options))
        walls = part(model, inside, 'Walls')
        wall_ring(walls.entities, ring)
        cuts.each { |cut| cut_wall(walls.entities, cut) }
      end
      boxes(plan, options).select { |b| b[:name] == 'Roof' }.each { |box| solid(model, inside, box) }
      group_of = {}
      cuts.each do |cut|
        name = cut[:kind] == 'Door' ? 'Doors' : 'Windows'
        group = group_of[name] ||= part(model, inside, name)
        fill(group.entities, cut)
      end
      room
    end
    private_class_method :draw_room

    # A group for a part of the room, on its tag and with its colour.
    def self.part(model, entities, name)
      group = entities.add_group
      group.name = name
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

    # What goes in an opening: the leaf of a door, the glass of a window (thin boxes in the middle of the wall).
    def self.fill(entities, cut)
      thickness = cut[:kind] == 'Door' ? LEAF_THICKNESS : GLASS_THICKNESS
      from = cut[:from].dup
      to = cut[:to].dup
      axis = cut[:out][0].zero? ? 1 : 0 # across the wall: x for a west or east wall, y for a south or north one
      middle = (from[axis] + to[axis]) / 2.0
      from[axis] = middle - (thickness / 2.0)
      to[axis] = middle + (thickness / 2.0)
      slab(entities, from, to)
    end
    private_class_method :fill

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
      Response.ok('The room (floor, walls, roof, doors and windows) was removed.')
    end
  end
end
