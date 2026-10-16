# frozen_string_literal: true

module KitchenCabinetMaster
  # "Room": a floor, walls and a roof drawn round the kitchen that is in the model. The room is the box that holds every cabinet and part; a side of it
  # where the backs of cabinets stand against is a wall right behind them, a side with no backs (the open side of a straight kitchen, say) is a wall
  # `open_distance` away. The walls stand on the floor, up to the room height (the top of the highest cabinet or loft, at least 2600 mm), the floor is
  # under the room and the walls, the roof over them. Everything is made as groups on the tag Room, marked so that Build Room draws it again and
  # Remove Room takes it away.
  #
  # The geometry that decides the room is plain arithmetic (RoomShell.plan, in mm) so that it can be tested without SketchUp.
  module RoomShell
    DICTIONARY = 'KitchenCabinetMaster'
    KEY = 'room_part'
    TAG = 'Room'
    TOL = 6.0            # mm: a back this close to the side of the box stands against it
    MIN_HEIGHT = 2600.0  # mm
    DEFAULTS = { 'wall_thickness' => 150.0, 'floor_thickness' => 100.0, 'roof_thickness' => 150.0, 'room_height' => 0.0, 'open_distance' => 1200.0 }.freeze
    COLOURS = { 'Floor' => [168, 160, 148], 'Walls' => [236, 233, 226], 'Roof' => [244, 244, 242] }.freeze

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
      open = opts['open_distance'].to_f
      grow = ->(side, sign) { box[side] + (backs[side] ? 0.0 : sign * open) }
      height = opts['room_height'].to_f.positive? ? opts['room_height'].to_f : [MIN_HEIGHT, items.map { |i| i[:top] }.max].max
      { x0: grow.call(:min_x, -1), x1: grow.call(:max_x, 1), y0: grow.call(:min_y, -1), y1: grow.call(:max_y, 1), height: height, backs: backs }
    end

    # The boxes of the room: [{ name:, from: [x, y, z], to: [x, y, z] }] in mm. The walls stand on the floor round the inside of the room, the floor is
    # under the room and the walls, the roof over them.
    def self.boxes(plan, options = {})
      opts = DEFAULTS.merge(options.compact)
      wall = opts['wall_thickness'].to_f
      floor = opts['floor_thickness'].to_f
      roof = opts['roof_thickness'].to_f
      x0 = plan[:x0] - wall
      x1 = plan[:x1] + wall
      y0 = plan[:y0] - wall
      y1 = plan[:y1] + wall
      h = plan[:height]
      list = []
      list << { name: 'Floor', from: [x0, y0, -floor], to: [x1, y1, 0.0] } if opts['floor'] != false && floor.positive?
      if opts['walls'] != false && wall.positive?
        list << { name: 'Walls', from: [x0, y0, 0.0], to: [plan[:x0], y1, h] }          # west
        list << { name: 'Walls', from: [plan[:x1], y0, 0.0], to: [x1, y1, h] }          # east
        list << { name: 'Walls', from: [plan[:x0], y0, 0.0], to: [plan[:x1], plan[:y0], h] } # south
        list << { name: 'Walls', from: [plan[:x0], plan[:y1], 0.0], to: [plan[:x1], y1, h] } # north
      end
      list << { name: 'Roof', from: [x0, y0, h], to: [x1, y1, h + roof] } if opts['roof'] != false && roof.positive?
      list
    end

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
          origin: [t.origin.x.to_mm, t.origin.y.to_mm], front: [t.xaxis.x, t.xaxis.y] }
      end
    end

    def self.parts_in(model)
      model.entities.grep(Sketchup::Group).select { |group| group.get_attribute(DICTIONARY, KEY) }
    end

    def self.build(raw)
      raw = stringify(raw)
      limits = { 'wall_thickness' => ['The wall thickness', 20.0, 1000.0], 'floor_thickness' => ['The floor thickness', 20.0, 1000.0],
                 'roof_thickness' => ['The roof thickness', 20.0, 1000.0], 'room_height' => ['The room height', 1500.0, 10_000.0],
                 'open_distance' => ['The distance to an open side', 0.0, 10_000.0] }
      options = {}
      limits.each do |key, (label, min, max)|
        value, problem = number(raw, key, label, min, max)
        return Response.fail(problem, [{ 'field' => key, 'message' => problem }]) if problem

        options[key] = value
      end
      %w[floor walls roof].each { |key| options[key] = ValidationManager.truthy_value?(raw[key]) if raw.key?(key) }
      return Response.fail('Choose at least one of the floor, the walls and the roof.') if %w[floor walls roof].none? { |key| options[key] != false }

      model = Sketchup.active_model
      plan = plan(items_of(model), options)
      return Response.fail('There is no kitchen in the model yet: the room is drawn round the cabinets.') unless plan

      boxes = boxes(plan, options)
      model.start_operation('Build Room', true)
      begin
        parts_in(model).each(&:erase!)
        tag = model.layers[TAG] || model.layers.add(TAG)
        boxes.each { |box| draw(model, tag, box) }
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      sides = plan[:backs].select { |_, back| back }.keys.length
      Response.ok("Room drawn: #{format('%g', (plan[:x1] - plan[:x0]).round)} x #{format('%g', (plan[:y1] - plan[:y0]).round)} mm inside, #{format('%g', plan[:height].round)} mm high" \
                  "#{", walls right behind the cabinets on #{sides} side#{'s' unless sides == 1}" if sides.positive?}.")
    end

    def self.draw(model, tag, box)
      group = model.entities.add_group
      group.name = box[:name]
      group.layer = tag
      group.set_attribute(DICTIONARY, KEY, box[:name])
      from = box[:from]
      to = box[:to]
      points = [[from[0], from[1]], [to[0], from[1]], [to[0], to[1]], [from[0], to[1]]].map { |x, y| Geom::Point3d.new(x.mm, y.mm, from[2].mm) }
      face = group.entities.add_face(points)
      face.reverse! if face.normal.z.negative?
      face.pushpull((to[2] - from[2]).mm)
      colour = COLOURS.fetch(box[:name], [230, 230, 230])
      material = model.materials["Room #{box[:name]}"] || model.materials.add("Room #{box[:name]}")
      material.color = Sketchup::Color.new(*colour)
      group.material = material
      group
    end
    private_class_method :draw

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
      Response.ok('The floor, walls and roof were removed.')
    end
  end
end
