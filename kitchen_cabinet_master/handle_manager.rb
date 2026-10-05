# frozen_string_literal: true

module KitchenCabinetMaster
  # Handles are separate components that live INSIDE their door's container, so a
  # door's rotation carries the handle with it during Open / Close / Toggle.
  #
  # A handle definition is built at the origin like this (vertical orientation):
  #
  #   X = out of the door face (projection)   Y = across the door   Z = along the grip
  #   origin = the centre of the handle's back, where it touches the door
  #
  # A horizontal handle is the same definition turned 90 degrees about X, so
  # orientation never creates a new definition.
  module HandleManager
    TOLERANCE = 1e-6
    KNOB_SEGMENTS = 48

    # Fills in anything the panel left blank from the bundle's own defaults, so what
    # is stored on the cabinet is always the complete, effective set of values.
    def self.apply_defaults!(params, bundle)
      defaults = Defaults::HANDLE_DEFAULTS.merge(bundle['defaults'].is_a?(Hash) ? bundle['defaults'] : {})

      params['handle_length'] ||= default_length(bundle)
      params['handle_finish'] = bundle['finishes'].first['name'] if params['handle_finish'].to_s.empty?
      params['handle_orientation'] = defaults['orientation'] if params['handle_orientation'].to_s.empty?
      params['handle_position'] = defaults['position'] if params['handle_position'].to_s.empty?
      params['handle_horizontal_place'] = defaults['horizontal_place'] if params['handle_horizontal_place'].to_s.empty?
      params['handle_side_offset'] ||= defaults['side_offset'].to_f
      params['handle_vertical_offset'] ||= defaults['vertical_offset'].to_f
      params['handle_custom_x'] ||= defaults['custom_x'].to_f
      params['handle_custom_z'] ||= defaults['custom_z'].to_f
      params
    end

    # The complete settings for one bundle as a Hash (also stored as 'handle_settings').
    def self.settings(params, bundle)
      {
        'bundle' => bundle['id'],
        'profile' => bundle['profile'],
        'length' => params['handle_length'].to_f,
        'finish' => params['handle_finish'].to_s,
        'material' => params['handle_material'].to_s,
        'orientation' => params['handle_orientation'].to_s,
        'position' => params['handle_position'].to_s,
        'horizontal_place' => params['handle_horizontal_place'].to_s,
        'category' => params['cabinet_category'].to_s,
        'side_offset' => params['handle_side_offset'].to_f,
        'vertical_offset' => params['handle_vertical_offset'].to_f,
        'custom_x' => params['handle_custom_x'].to_f,
        'custom_z' => params['handle_custom_z'].to_f
      }
    end

    # Errors for the panel: unknown length / finish, or a handle that does not fit its door.
    def self.errors(params, layout, bundle)
      errors = []

      unless bundle['lengths'].any? { |length| (length.to_f - params['handle_length'].to_f).abs < TOLERANCE }
        errors << { 'field' => 'handle_length',
                    'message' => "\"#{bundle['name']}\" is not offered in #{format('%g', params['handle_length'])} mm (choose from #{bundle['lengths'].join(', ')})." }
      end
      unless bundle['finishes'].any? { |finish| finish['name'] == params['handle_finish'] }
        errors << { 'field' => 'handle_finish', 'message' => "\"#{bundle['name']}\" does not have the finish \"#{params['handle_finish']}\"." }
      end
      return errors unless errors.empty?

      layout.doors.each do |door|
        next if door.handle == false # this door has no handle

        problem = fit_problem(door, settings(params, bundle), bundle)
        return [problem] if problem
      end
      []
    end

    # ---- placement (pure maths, millimetres) -----------------------------------

    # Where the handle's centre goes on a door face, measured from the door's
    # low-Y (left) edge and its bottom edge, plus the handle's footprint.
    # Returns { 'u', 'v', 'half_u', 'half_v', 'horizontal' }.
    def self.placement(door, settings, bundle)
      door_w = door.extent[1]
      door_h = door.extent[2]
      length = settings['length']
      horizontal = settings['orientation'] == 'horizontal' && bundle['profile'] == 'bar'
      # A lift-up door and a drawer front always take a horizontal handle, whatever orientation is chosen.
      horizontal = true if %w[top center].include?(door.hinge) && bundle['profile'] == 'bar'

      # A knob is round (its length is the diameter); a bar is `length` long and `section` wide.
      half_along = length / 2.0
      half_across = bundle['profile'] == 'knob' ? half_along : section(bundle) / 2.0
      half_u, half_v = horizontal ? [half_along, half_across] : [half_across, half_along]

      side = settings['side_offset']
      vertical = settings['vertical_offset']
      position = resolved_position(settings['position'], settings['category'])
      free_edge_is_high = door.hinge == 'left' # the hinge is on the other side

      # A drawer's handle always centres horizontally (there is no hinge side to
      # offset from), regardless of the chosen position; marked by hinge 'center'.
      # A horizontal handle can be centred across the door instead of sitting at its
      # free edge: still at the top of the door, `vertical` (the offset) below the edge.
      # A lift-up door is taken hold of along its bottom edge: the handle is centred there.
      if door.hinge == 'top'
        return { 'u' => door_w / 2.0, 'v' => vertical + half_v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => horizontal }
      end
      position = 'top' if door.hinge == 'center' && position == 'hand' # a drawer is not at "hand height": its handle is at its top

      if horizontal && settings['horizontal_place'] == 'middle' && door.hinge != 'center'
        v = case position
            when 'bottom' then vertical + half_v
            when 'hand' then hand_height(door, door_h, half_v, vertical)
            else door_h - vertical - half_v
            end
        v = grip_height(door, door_h, half_v, vertical) || v
        return { 'u' => door_w / 2.0, 'v' => v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => true }
      end

      u = if door.hinge == 'center'
            door_w / 2.0
          else
            case position
            when 'custom' then settings['custom_x']
            when 'left' then side + half_u
            when 'right' then door_w - side - half_u
            when 'center' then door_w / 2.0
            else free_edge_is_high ? door_w - side - half_u : side + half_u
            end
          end

      v = case position
          when 'custom' then settings['custom_z']
          when 'top' then door_h - vertical - half_v
          when 'bottom' then vertical + half_v
          when 'hand' then hand_height(door, door_h, half_v, vertical)
          else door_h / 2.0
          end

      v = grip_height(door, door_h, half_v, vertical) || v
      if door.hinge == 'center' # a drawer front: a vertical handle is centred on it, and no handle runs off it
        v = door_h / 2.0 unless horizontal
        v = door_h >= 2 * half_v ? v.clamp(half_v, door_h - half_v) : door_h / 2.0
      end
      { 'u' => u, 'v' => v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => horizontal }
    end

    # Hand height on a tall unit's door, kept a handle-offset clear of the door's edges, so on a door that
    # lies wholly above or below it (the lower door of a fridge) the handle sits near its edge, not on the gap.
    def self.hand_height(door, door_h, half_v, margin)
      margin += 25.0 # clearly away from the gap between two doors
      low = half_v + margin
      high = [door_h - half_v - margin, low].max
      (Defaults::TALL_HANDLE_HEIGHT - door.offset[2].to_f).clamp(low, high)
    end

    # By unit type (and a blank, from older cabinets): a base or corner unit's handle
    # sits near the top of its door, a wall unit's near the bottom, and a tall unit's
    # at hand height ('hand', about 1050 mm above the floor). Anything else is as chosen.
    # A handle next to the gap between two doors: near the top edge ('top') or the bottom edge ('bottom') of the door.
    def self.grip_height(door, door_h, half_v, margin)
      case door.respond_to?(:grip) && door.grip
      when 'top' then door_h - margin - half_v
      when 'bottom' then margin + half_v
      end
    end

    def self.resolved_position(position, category)
      return position unless position.to_s.empty? || position == 'auto'

      case category.to_s
      when 'wall' then 'bottom'
      when 'tall' then 'hand'
      else 'top'
      end
    end

    # nil if the handle sits fully inside the door, otherwise an error Hash.
    def self.fit_problem(door, settings, bundle)
      spot = placement(door, settings, bundle)
      door_w = door.extent[1]
      door_h = door.extent[2]
      inside = (spot['u'] - spot['half_u']) >= -TOLERANCE && (spot['u'] + spot['half_u']) <= door_w + TOLERANCE &&
               (spot['v'] - spot['half_v']) >= -TOLERANCE && (spot['v'] + spot['half_v']) <= door_h + TOLERANCE
      return nil if inside

      field = settings['position'] == 'custom' ? 'handle_custom_x' : 'handle_length'
      { 'field' => field,
        'message' => "The handle does not fit on the door (#{format('%g', door_w)} x #{format('%g', door_h)} mm). " \
                     'Use a shorter handle, smaller offsets, or another position.' }
    end
    private_class_method :fit_problem

    # ---- SketchUp objects ------------------------------------------------------

    # Handle instance transformation in the DOOR container's coordinates
    # (origin = door back face, low-Y edge, bottom).
    def self.transformation(spot, door_thickness)
      position = Geom::Transformation.translation(Geom::Vector3d.new(door_thickness.mm, spot['u'].mm, spot['v'].mm))
      return position unless spot['horizontal']

      turn = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(1, 0, 0), Math::PI / 2)
      position * turn
    end

    # Finds or builds the shared handle definition for this geometry.
    def self.definition(model, bundle, length)
      profile = bundle['profile']
      section = section(bundle)
      projection = projection(bundle)
      name = format('Handle %<profile>s %<length>g x %<section>g x %<projection>g smooth',
                    profile: profile, length: length, section: section, projection: projection)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      if profile == 'knob'
        build_knob(definition.entities, length, projection)
      else
        build_bar(model, definition.entities, length, section, projection)
      end
      definition
    end

    # The material name and colour for a finish of the bundle.
    def self.finish_material(bundle, finish_name)
      finish = bundle['finishes'].find { |f| f['name'] == finish_name } || bundle['finishes'].first
      [finish['material'].to_s.empty? ? finish['name'] : finish['material'], finish['color']]
    end

    def self.section(bundle)
      (bundle['section'] || Defaults::HANDLE_SECTION).to_f
    end

    def self.projection(bundle)
      (bundle['projection'] || Defaults::HANDLE_PROJECTION).to_f
    end

    def self.default_length(bundle)
      lengths = bundle['lengths']
      lengths.include?(bundle['default_length']) ? bundle['default_length'].to_f : lengths.first.to_f
    end

    # A bar: a round grip with domed ends along Z, held off the door by two round posts on small roses (see bar_faces), drawn
    # with 48 sides and smooth edges.
    def self.build_bar(_model, entities, length, section, projection)
      bar_faces(length, section, projection).each { |points| entities.add_face(points.map { |x, y, z| [x.mm, y.mm, z.mm] }) }
      PanelGenerator.soften(entities)
    end
    private_class_method :build_bar

    # A knob: a turned round knob standing off the door (a lathe shape: a small rose on the door, a slim neck, a domed head
    # with a rounded rim), drawn with 48 sides and smooth edges. `diameter` is the head's width.
    def self.build_knob(entities, diameter, projection)
      knob_faces(diameter, projection).each { |points| entities.add_face(points.map { |x, y, z| [x.mm, y.mm, z.mm] }) }
      PanelGenerator.soften(entities)
    end
    private_class_method :build_knob

    # The outline of the knob as [radius, height above the door] from the middle of its base to the middle of its top.
    # Pure maths.
    def self.knob_profile(diameter, projection)
      head = diameter / 2.0
      rose = [diameter * 0.34, head].min
      neck = diameter * 0.17
      lift = [projection * 0.1, 2.5].min          # the rose
      neck_top = [projection * 0.42, lift + 4.0].max
      head_h = [projection - neck_top, 5.0].max
      rim_z = neck_top + (head_h * 0.38)          # where the rim is widest
      steps = 10
      points = [[0.0, 0.0], [rose, 0.0], [rose, lift * 0.55], [rose * 0.88, lift], [neck * 1.5, lift + 0.8], [neck, lift + 2.2], [neck, neck_top - 2.5]]
      (1..4).each { |k| points << [neck + ((neck * 0.55) * (1 - Math.cos((Math::PI / 2.0) * k / 4))), neck_top - (2.5 * (1 - (k / 4.0)))] } # a curve out of the neck
      (1..4).each do |k| # the underside of the head: a gentle slope out to the rim
        t = k / 4.0
        points << [(neck * 1.55) + ((head - (neck * 1.55)) * t), neck_top + (((rim_z - neck_top) * 0.9) * (t**1.6))]
      end
      (1..steps).each do |k| # the rounded rim and the dome, a quarter of an ellipse
        angle = (Math::PI / 2.0) * k / steps
        points << [head * Math.cos(angle), rim_z + ((projection - rim_z) * Math.sin(angle))]
      end
      points.map { |r, z| [(r * 1000).round / 1000.0, (z * 1000).round / 1000.0] }
    end

    # The faces of the knob (arrays of [x, y, z] in mm, each facing outwards): the outline turned about the X axis (out of the
    # door), `segments` sides round. Pure maths.
    def self.knob_faces(diameter, projection, segments = KNOB_SEGMENTS)
      lathe_faces(knob_profile(diameter, projection), segments, ->(axial, a, b) { [axial, a, b] })
    end

    # A shape turned on a lathe: the outline [[radius, along the axis], ...] (running up the right-hand side of the shape, from
    # one end of the axis to the other) turned `segments` sides round. `place` takes (along the axis, a, b) in the shape's own
    # frame (a and b across the axis) to a point [x, y, z] in mm. Returns the faces, each facing outwards. Pure maths.
    def self.lathe_faces(profile, segments, place)
      faces = []
      profile.each_cons(2) do |(r0, x0), (r1, x1)|
        dr = r1 - r0
        dx = x1 - x0
        length = Math.hypot(dr, dx)
        next if length < 1e-9 || (r0.zero? && r1.zero?)

        radial = dx / length # the outward normal in the (radius, along the axis) plane
        axial = -dr / length
        segments.times do |j|
          corners = [[r0, x0, j], [r0, x0, j + 1], [r1, x1, j + 1], [r1, x1, j]]
          points = corners.map do |r, x, i|
            angle = 2.0 * Math::PI * (i % segments) / segments
            place.call(x, r * Math.cos(angle), r * Math.sin(angle))
          end
          points = points.each_with_index.reject { |p, i| i.positive? && p == points[i - 1] }.map(&:first)
          points.pop if points.length > 1 && points.first == points.last
          next if points.length < 3

          middle = 2.0 * Math::PI * (j + 0.5) / segments
          rm = (r0 + r1) / 2.0
          xm = (x0 + x1) / 2.0
          from = place.call(xm, rm * Math.cos(middle), rm * Math.sin(middle))
          toward = place.call(xm + axial, (rm + radial) * Math.cos(middle), (rm + radial) * Math.sin(middle))
          outward = [toward[0] - from[0], toward[1] - from[1], toward[2] - from[2]]
          points.reverse! if dot(newell(points), outward).negative?
          faces << points
        end
      end
      faces
    end

    # A bar handle: a round grip with domed ends held off the door by two round posts, each on a small rose. Faces in mm in
    # the handle's frame (X out of the door, Y across, Z along the grip, the origin in the middle of the back). Pure maths.
    def self.bar_faces(length, section, projection, segments = KNOB_SEGMENTS)
      d = [section, projection].min
      radius = d / 2.0
      cap = [radius, length / 2.0].min
      centre_x = projection - radius # the grip's axis
      steps = 8
      half = length / 2.0
      grip = [[0.0, -half]]
      (1..steps).each { |k| a = (Math::PI / 2.0) * k / steps; grip << [radius * Math.sin(a), -half + cap - (cap * Math.cos(a))] }
      grip << [radius, half - cap] unless cap * 2.0 >= length # the straight part between the two domes
      (1..steps).each { |k| a = (Math::PI / 2.0) * k / steps; grip << [radius * Math.cos(a), half - cap + (cap * Math.sin(a))] }
      faces = lathe_faces(grip, segments, ->(axial, a, b) { [centre_x + a, b, axial] })
      post_length = centre_x
      if projection > d + 0.5 # a grip that stands off the door has posts
        rp = radius * 0.62
        rose = [radius * 0.98, rp * 1.1].max
        post = [[0.0, 0.0], [rose, 0.0], [rose, 0.7], [rose * 0.9, 1.4], [rp * 1.4, 2.0], [rp, 3.2], [rp, [post_length, 3.3].max], [0.0, [post_length, 3.3].max]]
        [-1.0, 1.0].each do |side|
          z = side * (half - cap)
          faces.concat(lathe_faces(post, segments, ->(axial, a, b) { [axial, a, z + b] }))
        end
      end
      faces
    end

    def self.newell(points)
      normal = [0.0, 0.0, 0.0]
      points.each_with_index do |p, i|
        q = points[(i + 1) % points.length]
        normal[0] += (p[1] - q[1]) * (p[2] + q[2])
        normal[1] += (p[2] - q[2]) * (p[0] + q[0])
        normal[2] += (p[0] - q[0]) * (p[1] + q[1])
      end
      normal
    end
    private_class_method :newell

    def self.dot(a, b)
      (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])
    end
    private_class_method :dot
  end
end
