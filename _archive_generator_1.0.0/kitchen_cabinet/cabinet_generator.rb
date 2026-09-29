module KitchenCabinet
  module CabinetGenerator
    DICT = 'KitchenCabinet'.freeze
    MM = ->(v) { v.to_f.mm }

    DEFAULTS = {
      'type' => 'single', 'width' => 450.0, 'depth' => 580.0, 'height' => 780.0,
      'panel_thickness' => 18.0, 'back_thickness' => 6.0,
      'shutter_thickness' => 18.0, 'door_gap' => 1.5, 'shutter_distance' => 2.0,
      'toe_kick_height' => 100.0, 'toe_kick_thickness' => 18.0, 'toe_kick_length' => 900.0,
      'shelf_thickness' => 18.0, 'shelf_depth_reduction' => 20.0,
      'shelf_position' => 390.0, 'shelf_count' => 1, 'opening_angle' => 90.0,
      'placement_gap' => 0.0, 'toe_kick_enabled' => true,
      'carcass_material' => '', 'door_material' => '', 'toe_kick_mode' => 'door',
      'toe_kick_material' => '', 'show_carcass' => true, 'show_doors' => true,
      'show_toe_kick' => true, 'show_shelves' => true, 'show_back' => true,
      'show_opening_line' => true
    }.freeze

    def self.defaults(type = 'single')
      d = DEFAULTS.dup
      d['type'] = type
      d['width'] = 900.0 if type == 'double'
      d
    end

    def self.normalize(raw)
      d = defaults(raw['type'].to_s == 'double' ? 'double' : 'single')
      raw.each { |k,v| d[k.to_s] = v unless v.nil? }
      numeric = %w[width depth height panel_thickness back_thickness shutter_thickness door_gap shutter_distance toe_kick_height toe_kick_thickness toe_kick_length shelf_thickness shelf_depth_reduction shelf_position shelf_count opening_angle placement_gap]
      numeric.each { |k| d[k] = d[k].to_f }
      d['shelf_count'] = [[d['shelf_count'].round, 0].max, 20].min
      d['opening_angle'] = [[d['opening_angle'], 0.0].max, 180.0].min
      d['toe_kick_enabled'] = !!d['toe_kick_enabled']
      d
    end

    def self.validate!(p)
      errors = []
      %w[width depth height panel_thickness back_thickness shutter_thickness].each do |k|
        errors << "#{k} must be greater than 0" if p[k].to_f <= 0
      end
      errors << 'Toe kick height cannot be negative or exceed cabinet height.' if p['toe_kick_height'] < 0 || p['toe_kick_height'] >= p['height']
      errors << 'Door gap must be non-negative.' if p['door_gap'] < 0
      errors << 'Shelf count must be between 0 and 20.' unless (0..20).include?(p['shelf_count'])
      errors << 'Cabinet height is too small for the selected toe kick and panels.' if p['height'] <= p['toe_kick_height'] + p['panel_thickness'] * 2
      errors << 'Cabinet width is too small for the selected door gaps.' if p['width'] <= p['door_gap'] * 2 + p['panel_thickness'] * 2
      raise ArgumentError, errors.join('\n') unless errors.empty?
      true
    end

    def self.box(entities, name, width_x, width_y, height_z, x, y, z, material = nil, visible = true, cache = {})
      key = [name, width_x.round(4), width_y.round(4), height_z.round(4)].join('|')
      definition = cache[key]
      unless definition && !definition.deleted?
        definition = Sketchup.active_model.definitions.add("KC_#{name}_#{width_x.round(2)}x#{width_y.round(2)}x#{height_z.round(2)}")
        pts = [
          Geom::Point3d.new(0,0,0), Geom::Point3d.new(width_x,0,0),
          Geom::Point3d.new(width_x,width_y,0), Geom::Point3d.new(0,width_y,0),
          Geom::Point3d.new(0,0,height_z), Geom::Point3d.new(width_x,0,height_z),
          Geom::Point3d.new(width_x,width_y,height_z), Geom::Point3d.new(0,width_y,height_z)
        ]
        faces = [
          [0,1,2,3],[4,7,6,5],[0,4,5,1],[1,5,6,2],[2,6,7,3],[4,0,3,7]
        ]
        faces.each do |idx|
          face = definition.entities.add_face(idx.map { |i| pts[i] })
          face.reverse! if face.normal.z < -0.5 && idx == [4,7,6,5]
        end
        cache[key] = definition
      end
      inst = entities.add_instance(definition, Geom::Transformation.translation([x,y,z]))
      inst.material = material if material && material != ''
      inst.visible = visible
      inst
    end

    def self.material(model, name, fallback = nil)
      return fallback if name.nil? || name.to_s.empty?
      model.materials[name.to_s] || begin
        m = model.materials.add(name.to_s)
        m.color = fallback || 'White'
        m
      end
    end

    def self.apply_materials(model, p)
      carcass = material(model, p['carcass_material'], 'White')
      door = material(model, p['door_material'], 'White')
      toe = if p['toe_kick_mode'] == 'door'
               door
             else
               material(model, p['toe_kick_material'], 'Gray')
             end
      [carcass, door, toe]
    end

    def self.clear_definition(definition)
      definition.entities.to_a.each { |e| e.erase! unless e.deleted? }
    end

    def self.build(root_definition, p, cabinet_id)
      model = Sketchup.active_model
      validate!(p)
      clear_definition(root_definition)
      cache = {}
      carcass_mat, door_mat, toe_mat = apply_materials(model, p)
      t = MM.call(p['panel_thickness']); bt = MM.call(p['back_thickness'])
      w = MM.call(p['width']); d = MM.call(p['depth']); h = MM.call(p['height']); tk = MM.call(p['toe_kick_height'])
      sh = MM.call(p['shutter_thickness']); gap = MM.call(p['door_gap']); reveal = MM.call(p['shutter_distance'])
      shelf_t = MM.call(p['shelf_thickness']); shelf_reduction = MM.call(p['shelf_depth_reduction'])
      back_recess = MM.call(18); side_overlap = MM.call(9)
      carcass_h = h - tk
      
      # Coordinate system: X=depth, Y=width, Z=height.
      # Side panels run full cabinet depth to the wall/rear.
      box(root_definition.entities, 'SIDE', t, d, carcass_h, 0, 0, tk, carcass_mat, p['show_carcass'], cache)
      box(root_definition.entities, 'SIDE', t, d, carcass_h, 0, w - t, tk, carcass_mat, p['show_carcass'], cache)
      box(root_definition.entities, 'BOTTOM', d, w - 2*t, t, 0, t, tk, carcass_mat, p['show_carcass'], cache)
      box(root_definition.entities, 'TOP', d, w - 2*t, t, 0, t, h - t, carcass_mat, p['show_carcass'], cache)

      # Back panel: 18 mm recessed from rear; 9 mm overlap at each side.
      back_x = d - back_recess - bt
      back_y = -side_overlap
      back_w = w + side_overlap * 2
      box(root_definition.entities, 'BACK', bt, back_w, carcass_h, back_x, back_y, tk, carcass_mat, p['show_back'], cache)

      # Shelves: 20 mm shallower than cabinet depth at front.
      shelf_count = p['shelf_count'].to_i
      shelf_depth = [d - shelf_reduction, t].max
      opening_h = carcass_h - 2*t
      shelf_count.times do |i|
        z = tk + t + MM.call(p['shelf_position']) + i * (opening_h / [shelf_count,1].max)
        z = [[z, tk+t].max, h-t-shelf_t].min
        box(root_definition.entities, 'SHELF', shelf_depth, w-2*t, shelf_t, 0, t, z, carcass_mat, p['show_shelves'], cache)
      end

      # Doors sit at the front (X=-reveal), with 1.5 mm nominal gap and shutter distance.
      front_x = -reveal - sh
      door_h = carcass_h - 2*t - gap * 2
      opening_w = w - 2*t
      if p['type'] == 'double'
        door_w = (opening_w - gap) / 2.0
        add_door(root_definition, p, cabinet_id, 'DOOR_01', door_w, door_h, front_x, t + gap/2.0, tk+t+gap, door_mat, :left)
        add_door(root_definition, p, cabinet_id, 'DOOR_02', door_w, door_h, front_x, t + gap/2.0 + door_w + gap, tk+t+gap, door_mat, :right)
      else
        door_w = opening_w - gap * 2
        add_door(root_definition, p, cabinet_id, 'DOOR_01', door_w, door_h, front_x, t + gap, tk+t+gap, door_mat, :left)
      end

      add_opening_lines(root_definition, p, w, d, h, tk, t, sh, gap) if p['show_opening_line']

      if p['toe_kick_enabled']
        piece = MM.call([p['toe_kick_length'].to_f, 1].max)
        # Toe kick follows the cabinet width and is segmented by requested piece length.
        remaining = w
        y = 0.0
        idx = 1
        while remaining > 0.001
          len = [remaining, piece].min
          box(root_definition.entities, "TOEKICK_#{idx}", MM.call(p['toe_kick_thickness']), len, tk, 0, y, 0, toe_mat, p['show_toe_kick'], cache)
          y += len
          remaining -= len
          idx += 1
        end
      end

      root_definition.set_attribute(DICT, 'cabinet_id', cabinet_id)
      root_definition.set_attribute(DICT, 'params_json', JSON.generate(p))
      root_definition.set_attribute(DICT, 'version', '1.0')
      root_definition.set_attribute(DICT, 'is_parametric', true)
      root_definition
    end


    def self.add_opening_lines(root_definition, p, w, d, h, tk, t, sh, gap)
      model = Sketchup.active_model
      g = root_definition.entities.add_group
      g.name = 'KC_DOOR_OPENING_DIRECTION'
      g.set_attribute(DICT, 'part_type', 'opening_line')
      line_z = tk + (h - tk) * 0.55
      front = -MM.call(p['shutter_distance']) - MM.call(p['shutter_thickness']) - MM.call(4)
      radius = if p['type'] == 'double'
                 ((w - 2*t - MM.call(p['door_gap'])) / 2.0)
               else
                 (w - 2*t - MM.call(p['door_gap']) * 2)
               end
      angle = [[p['opening_angle'].to_f, 10.0].max, 180.0].min * Math::PI / 180.0
      hinge_ys = if p['type'] == 'double'
                   [t + MM.call(p['door_gap'])/2.0, w - t - MM.call(p['door_gap'])/2.0]
                 else
                   [t + MM.call(p['door_gap'])]
                 end
      hinge_ys.each_with_index do |hy, di|
        sign = (p['type'] == 'double' && di == 1) ? -1.0 : 1.0
        points = 18.times.map do |i|
          a = angle * i / 17.0
          # Closed direction points along +/-Y from hinge; swing arc moves toward +X/-X.
          yy = hy + sign * radius * Math.cos(a)
          xx = front + radius * Math.sin(a)
          Geom::Point3d.new(xx, yy, line_z)
        end
        # Physically segmented edges create a robust dashed indicator across SketchUp versions.
        (0...points.length-1).step(2) do |i|
          g.entities.add_line(points[i], points[[i+1, points.length-1].min])
        end
      end
      g
    end

    def self.add_door(root_definition, p, id, name, width, height, x, y, z, material, hinge)
      # Door component is its own definition; geometry is local to the hinge point.
      model = Sketchup.active_model
      t = MM.call(p['shutter_thickness'])
      defn = model.definitions.add("KC_#{name}_#{id}_#{width.round(2)}x#{height.round(2)}")
      pts = [Geom::Point3d.new(0,0,0), Geom::Point3d.new(0,width,0), Geom::Point3d.new(0,width,height), Geom::Point3d.new(0,0,height), Geom::Point3d.new(t,0,0), Geom::Point3d.new(t,width,0), Geom::Point3d.new(t,width,height), Geom::Point3d.new(t,0,height)]
      [[0,1,2,3],[4,7,6,5],[0,4,5,1],[1,5,6,2],[2,6,7,3],[4,0,3,7]].each { |idx| defn.entities.add_face(idx.map { |i| pts[i] }) }
      # Local Y is door width; local X is thickness; local Z is height.
      if hinge == :left
        tr = Geom::Transformation.translation([x, y, z])
      else
        # Right door is modeled from its right edge for a mirrored opening pivot.
        tr = Geom::Transformation.translation([x, y + width, z]) * Geom::Transformation.rotation(Geom::Point3d.new(0,0,0), Geom::Vector3d.new(0,0,1), Math::PI)
      end
      inst = root_definition.entities.add_instance(defn, tr)
      inst.material = material
      inst.set_attribute(DICT, 'cabinet_id', id)
      inst.set_attribute(DICT, 'part_type', 'door')
      inst.set_attribute(DICT, 'hinge', hinge.to_s)
      inst.set_attribute(DICT, 'base_transform', tr.to_a)
      inst.set_attribute(DICT, 'open', false)
      inst.set_attribute(DICT, 'opening_angle', p['opening_angle'].to_f)
      inst
    end
  end
end
