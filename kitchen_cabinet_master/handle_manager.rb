# frozen_string_literal: true

require_relative 'gola_profile'

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
    TALL_PULL_OUT_MIN = 1200.0 # a drawer front at least this high is a tall pull-out
    GRIP_PROFILES = %w[bar dbar model].freeze # handles with a grip along the door, up it or across it as chosen
    EDGE_PROFILES = %w[edge_pull cup].freeze # handles that sit on the top (or bottom) edge of a front, always along it
    EDGE_THICKNESS = 2.5                     # the sheet of an edge pull or a cup
    EDGE_LIP = 22.0                          # how far an edge pull's lip hangs down
    DBAR_THICKNESS = 7.0                     # the legs and the grip of a D handle or a T bar
    DBAR_WIDTH = 14.0                        # how wide they are across the door
    ARC_STEPS = 6                            # the straight pieces a bend is drawn with

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

    # The handle settings of the drawers when they have a bundle of their own: its own length, position and offsets, and the finish of the doors'
    # handle if the bundle has it. Returns a copy of params.
    def self.drawer_params(params, bundle)
      copy = params.merge('handle_id' => bundle['id'], 'handle_length' => nil, 'handle_orientation' => '', 'handle_position' => '', 'handle_horizontal_place' => '',
                          'handle_side_offset' => nil, 'handle_vertical_offset' => nil, 'handle_custom_x' => nil, 'handle_custom_z' => nil)
      copy['handle_finish'] = bundle['finishes'].any? { |f| f['name'] == params['handle_finish'] } ? params['handle_finish'] : ''
      apply_defaults!(copy, bundle)
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
        'custom_z' => params['handle_custom_z'].to_f,
        'pullout' => params['pullout'] == true # a pull-out unit: its handle is always vertical
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
    # rame is how wide the frame of a glass door is: the handle then sits on the frame, not over the glass.
    def self.placement(door, settings, bundle, frame = nil)
      return gola_placement(door, bundle) if bundle['profile'] == 'gola'
      return edge_placement(door, settings, bundle) if EDGE_PROFILES.include?(bundle['profile'])

      on_frame(plain_placement(door, settings, bundle), door, frame)
    end

    # Moves a handle that would be over the glass of a glass door onto the frame, along the nearer edge. Pure maths.
    def self.on_frame(spot, door, frame)
      return spot unless frame.to_f.positive?

      half = frame / 2.0
      if spot['horizontal']
        spot.merge('v' => spot['v'] < door.extent[2] / 2.0 ? half : door.extent[2] - half)
      else
        spot.merge('u' => spot['u'] < door.extent[1] / 2.0 ? half : door.extent[1] - half)
      end
    end

    def self.plain_placement(door, settings, bundle)

      door_w = door.extent[1]
      door_h = door.extent[2]
      length = settings['length']
      horizontal = settings['orientation'] == 'horizontal' && GRIP_PROFILES.include?(bundle['profile'])
      # A lift-up door and a drawer front always take a horizontal handle, whatever orientation is chosen.
      horizontal = true if %w[top fold center].include?(door.hinge) && GRIP_PROFILES.include?(bundle['profile'])
      pull_out = settings['pullout'] == true && door.hinge == 'center'
      horizontal = false if pull_out # ... except on a pull-out unit, whose handle is always vertical

      # A knob is round (its length is the diameter); a bar is `length` long and `section` wide.
      half_along, half_across = footprint(bundle, length)
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
      if %w[top fold].include?(door.hinge)
        return { 'u' => door_w / 2.0, 'v' => vertical + half_v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => horizontal }
      end
      # A drawer is not at "hand height": its handle is at its top. Only a full-height pull-out (a tall unit's) is taken hold of at hand height,
      # like the doors of the other tall units.
      position = 'top' if door.hinge == 'center' && position == 'hand' && door_h < TALL_PULL_OUT_MIN

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
        v = hand_height(door, door_h, half_v, vertical) if pull_out && door_h >= TALL_PULL_OUT_MIN # a tall pull-out: at hand height like the other tall units
        v = door_h >= 2 * half_v ? v.clamp(half_v, door_h - half_v) : door_h / 2.0
      end
      { 'u' => u, 'v' => v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => horizontal }
    end

    # An edge pull or a cup sits on the top edge of a door or drawer front (the bottom edge of a wall unit's door, and of a lift-up
    # door), centred across it and always along it. lip says it hangs from the bottom edge. Pure maths.
    def self.edge_placement(door, settings, bundle)
      door_h = door.extent[2]
      half_u = settings['length'] / 2.0
      half_v = [section(bundle) / 2.0, door_h / 2.0].min
      at_bottom = %w[top fold].include?(door.hinge) || resolved_position(settings['position'], settings['category']) == 'bottom'
      # (an edge pull is flush with the edge, a cup a little under it: the package says how far, not the offsets of the panel that a bar uses)
      offset = ((bundle['defaults'] || {})['vertical_offset'] || 0).to_f
      v = at_bottom ? offset + half_v : door_h - offset - half_v
      { 'u' => door.extent[1] / 2.0, 'v' => v.clamp(half_v, [door_h - half_v, half_v].max), 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => true, 'flip' => at_bottom }
    end
    private_class_method :edge_placement

    # A Gola profile is where the layout put it (see GolaProfile.apply!): its length, and where on the front it starts, are in `door.gola`. A front that has
    # none (a model of your own, say) gets a profile along its top. Pure maths.
    def self.gola_placement(door, bundle)
      spot = door.respond_to?(:gola) && door.gola
      spot ||= if GolaProfile::SYSTEMS.dig(bundle['system'].to_s, :horizontal) == false # (a vertical one: up the middle of the front)
                 { 'system' => bundle['system'].to_s, 'kind' => 'pair', 'back' => -21.0, 'horizontal' => false, 'length' => door.extent[2], 'u' => door.extent[1] / 2.0, 'v' => door.extent[2] / 2.0 }
               else
                 { 'system' => bundle['system'].to_s, 'kind' => 'top', 'back' => -21.0, 'horizontal' => true, 'length' => door.extent[1], 'u' => door.extent[1] / 2.0, 'v' => door.extent[2] }
               end
      spot.merge('half_u' => spot['length'] / 2.0, 'half_v' => 0.0, 'flip' => false, 'gola' => true)
    end
    private_class_method :gola_placement

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
      return nil if bundle['profile'] == 'gola' # (the profile is cut to the front)

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
    def self.definition(model, bundle, length, flip = false, spot = nil)
      name = format('Handle %<id>s %<length>g x %<section>g x %<projection>g v2', id: bundle['id'], length: length, section: section(bundle), projection: projection(bundle))
      name += " #{GolaProfile.key(spot)}" if bundle['profile'] == 'gola' && spot
      name += ' up' if flip && EDGE_PROFILES.include?(bundle['profile'])

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      if bundle['profile'] == 'model' # a handle you drew: its model file, set in the handle's frame (a plain bar if the file is gone)
        return definition if place_model(model, definition, bundle)
      end
      handle_faces(bundle, length, flip, spot).each { |points| definition.entities.add_face(points.map { |x, y, z| [x.mm, y.mm, z.mm] }) }
      PanelGenerator.soften(definition.entities)
      definition
    end

    # Where a handle you drew goes in the handle's frame (see the top of this file): its back (the high-Y side, as seen from the front) on the
    # door, its front standing out towards low Y, its grip along X (or along Z when that is the longer one, `along`), centred. Returns
    # [the axes of the model's X, Y, Z in the frame, and where its origin is, from its bounds in model units]. Pure maths.
    def self.model_axes(along, min, max)
      xc = (min[0] + max[0]) / 2.0
      zc = (min[2] + max[2]) / 2.0
      if along.to_s == 'z'
        [[0, 1, 0], [-1, 0, 0], [0, 0, 1], [max[1], -xc, -zc]]
      else
        [[0, 0, 1], [-1, 0, 0], [0, -1, 0], [max[1], zc, -xc]]
      end
    end

    # Fills the definition of a handle you drew with its model file. False if the file is missing.
    def self.place_model(model, definition, bundle)
      path = CatalogManager.handle_path(bundle)
      return false unless path && File.file?(path)

      source = model.definitions.load(path)
      bounds = source.bounds
      x, y, z, origin = model_axes(bundle['along'], bounds.min.to_a, bounds.max.to_a)
      axes = [x, y, z].map { |v| Geom::Vector3d.new(*v) }
      definition.entities.add_instance(source, Geom::Transformation.axes(Geom::Point3d.new(*origin), *axes))
      true
    end
    private_class_method :place_model

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of a handle, in its own frame: X out of the door, Y across it,
    # Z along the grip, the origin in the middle of the back. `flip` hangs an edge pull or a cup from the bottom edge. Pure maths.
    def self.handle_faces(bundle, length, flip = false, spot = nil)
      section = section(bundle)
      projection = projection(bundle)
      case bundle['profile']
      when 'gola'
        outline = GolaProfile.outline_for(spot || { 'system' => bundle['system'].to_s, 'kind' => 'top', 'back' => -21.0 })
        loft_faces([[-length / 2.0, outline], [length / 2.0, outline]])
      when 'knob' then knob_faces(length, projection, KNOB_SEGMENTS, bundle['style'].to_s)
      when 'dbar' then dbar_faces(length, projection, bundle)
      when 'edge_pull'
        outline = edge_pull_outline(projection, section, flip, bundle['lip'] || EDGE_LIP, bundle['thickness'] || EDGE_THICKNESS)
        loft_faces([[-length / 2.0, outline], [length / 2.0, outline]])
      when 'cup' then cup_faces(length, projection, flip, bundle['thickness'] || EDGE_THICKNESS)
      else bar_faces(length, section, projection)
      end
    end

    # Does this finish leave the handle as it was drawn ("As drawn" of a handle you drew)?
    def self.keeps_look?(bundle, finish_name)
      finish = bundle['finishes'].find { |f| f['name'] == finish_name } || bundle['finishes'].first
      finish['keep'] == true
    end

    # The material name and colour for a finish of the bundle.
    def self.finish_material(bundle, finish_name)
      finish = bundle['finishes'].find { |f| f['name'] == finish_name } || bundle['finishes'].first
      props = finish.slice('roughness', 'metalness').select { |_key, value| value.is_a?(Numeric) } # the look of the metal (PBR)
      [finish['material'].to_s.empty? ? finish['name'] : finish['material'], finish['color'], props.empty? ? nil : props]
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

    # The handle settings a model of your own keeps: what the Handle section said when it was inserted (changed later by the same section).
    MODEL_KEYS = %w[handle_id handle_length handle_finish handle_material handle_orientation handle_position handle_horizontal_place
                    handle_side_offset handle_vertical_offset handle_custom_x handle_custom_z door_opening_direction].freeze
    MODEL_NUMBERS = %w[handle_length handle_side_offset handle_vertical_offset handle_custom_x handle_custom_z].freeze

    # A door as big as the front of a model of your own (width across it, height up it), for placing a handle on it by the same rules as on a
    # cabinet's door. The hinge is on the side the Door Opening Direction says, so a vertical handle sits on the other one.
    def self.model_door(width, height, direction)
      CabinetLayout::Door.new(role: 'door_1', name: 'Door', extent: [0.0, width, height], offset: [0.0, 0.0, 0.0],
                              hinge: direction.to_s == 'right' ? 'right' : 'left', pivot: [0.0, 0.0, 0.0], rotation: 0.0)
    end

    # The settings of a handle on a model of your own, made complete and valid for its package: what is blank, or not offered by the package,
    # takes the package's own. Returns [params, bundle], the bundle nil when there is no handle package.
    def self.model_params(settings, category)
      params = Defaults.params.merge('cabinet_category' => category.to_s, 'pullout' => false)
      MODEL_KEYS.each do |key|
        value = settings[key]
        params[key] = MODEL_NUMBERS.include?(key) ? ValidationManager.to_float(value) : value.to_s
      end
      bundle = CatalogManager.handle_bundle(params['handle_id'])
      return [params, nil] unless bundle

      apply_defaults!(params, bundle)
      params['handle_length'] = default_length(bundle) unless bundle['lengths'].any? { |length| (length.to_f - params['handle_length'].to_f).abs < TOLERANCE }
      params['handle_finish'] = bundle['finishes'].first['name'] unless bundle['finishes'].any? { |finish| finish['name'] == params['handle_finish'] }
      [params, bundle]
    end

    # How far a handle reaches along the grip, and across it, half each: a D handle is `length` between its legs (the way they are sold), so it is
    # a leg thick longer than that.
    def self.footprint(bundle, length)
      case bundle['profile']
      when 'knob' then [length / 2.0, length / 2.0]
      when 'dbar' then [(length + (bundle['thickness'] || DBAR_THICKNESS).to_f) / 2.0, (bundle['width'] || DBAR_WIDTH).to_f / 2.0]
      else [length / 2.0, section(bundle) / 2.0]
      end
    end

    # Points on an arc of the circle (cx, cy, r) from one angle to another, in degrees. Pure maths.
    def self.arc(cx, cy, r, from, to, steps = ARC_STEPS)
      (0..steps).map do |k|
        a = (from + ((to - from) * k / steps.to_f)) * Math::PI / 180.0
        [cx + (r * Math.cos(a)), cy + (r * Math.sin(a))]
      end
    end

    # Rounds off the numbers and drops a point that is the same as the one before it (and the last, if it is the first).
    def self.tidy(points)
      kept = points.map { |x, y| [(x * 1000).round / 1000.0, (y * 1000).round / 1000.0] }.each_with_object([]) { |p, list| list << p unless list.last == p }
      kept.pop if kept.length > 1 && kept.first == kept.last
      kept
    end

    # The outline [[x, y], ...] of an edge pull seen from the end: x out of the door, y up it, centred on the plate that sits on the door's
    # face (section high). The top edge of the door is at y = section / 2; a sheet t thick runs out over it and turns down into a lip
    # (projection out, lip down), with the bends rounded as bent sheet is. flip hangs it from the bottom edge instead. Pure maths.
    def self.edge_pull_outline(projection, section, flip = false, lip = EDGE_LIP, t = EDGE_THICKNESS)
      top = section / 2.0
      lip = [lip, section - 2.0].min
      ro = [t * 1.4, projection / 3.0].min # the outside of the bend at the front, the inside of it one sheet less
      ri = [ro - t, 0.4].max
      points = [[0.0, top], [projection - ro, top]]
      points += arc(projection - ro, top - ro, ro, 90.0, 0.0)
      points += [[projection, top - lip], [projection - t, top - lip]]
      points += arc(projection - t - ri, top - t - ri, ri, 0.0, 90.0, 4)
      points += arc(t + ri, top - t - ri, ri, 90.0, 180.0, 4)
      points += [[t, -top], [0.0, -top]]
      points = tidy(points)
      flip ? points.map { |x, y| [x, -y] } : points
    end

    # The faces of a cup (a shell handle): a quarter-round sheet, its outside a quarter circle of radius projection from the foot on the door face
    # up to the lip, open upwards, t thick, `length` long, its ends closing in like the end of a shell (a quarter of an ellipse in plan). Pure maths.
    def self.cup_faces(length, projection, flip = false, t = EDGE_THICKNESS)
      outline = cup_outline(projection, flip, 12, t)
      middle = flip ? -projection / 2.0 : projection / 2.0 # (the middle of the quarter circle: the ends are quarters of a sphere about it)
      end_len = [projection, length / 2.0].min
      steps = 8
      half = length / 2.0
      ends = (0..steps).map do |k|
        s = k.to_f / steps
        scale = Math.sqrt([1.0 - (s**2), 0.0].max) # a quarter of an ellipse in plan
        [half - end_len + (end_len * s), [scale, 0.12].max]
      end
      shaped = ends.map { |z, s| [z, scale_about(outline, 0.0, middle, s)] }
      loft_faces(shaped.reverse.map { |z, o| [-z, o] } + shaped)
    end

    # The outline of a cup: the quarter-round sheet seen from the end, centred on its own height. Pure maths.
    def self.cup_outline(projection, flip = false, steps = 12, t = EDGE_THICKNESS)
      r = projection
      centre = r / 2.0
      outer = arc(0.0, centre, r, -90.0, 0.0, steps)
      inner = arc(0.0, centre, r - t, 0.0, -90.0, steps) # (back from the lip to the foot)
      points = tidy(outer + inner)
      flip ? points.map { |x, y| [x, -y] } : points
    end

    def self.scale_about(points, cx, cy, s)
      points.map { |x, y| [cx + ((x - cx) * s), cy + ((y - cy) * s)] }
    end
    private_class_method :scale_about

    # The faces of a D handle or a T bar: a flat bow standing off the door on two legs, `length` between the legs, as wide as its width, with
    # the outer bends rounded by `corner` (a T bar has square corners). Frame as in handle_faces. Pure maths.
    def self.dbar_faces(length, projection, bundle)
      t = (bundle['thickness'] || DBAR_THICKNESS).to_f
      width = (bundle['width'] || DBAR_WIDTH).to_f
      outline = dbar_outline(length, projection, t, (bundle['corner'] || 0).to_f)
      loft_faces([[-width / 2.0, outline], [width / 2.0, outline]]).map { |points| points.map { |x, u, e| [x, e, u] }.reverse } # (x out, u along the grip, e across it)
    end

    # The outline [[x, u], ...] of a bow seen from above: two legs t thick at u = +-length / 2, joined by a grip at the outside (x = projection),
    # the outer corners rounded with `corner`. Pure maths.
    def self.dbar_outline(length, projection, t, corner)
      half_o = (length / 2.0) + (t / 2.0)
      half_i = (length / 2.0) - (t / 2.0)
      ro = [corner, projection - t, half_o].min
      ro = 0.0 if ro < 0.3
      ri = ro.positive? ? [ro - t, 0.0].max : 0.0
      points = [[0.0, -half_o], [projection - ro, -half_o]]
      points += arc(projection - ro, -half_o + ro, ro, -90.0, 0.0) if ro.positive?
      points += [[projection, -half_o + ro], [projection, half_o - ro]]
      points += arc(projection - ro, half_o - ro, ro, 0.0, 90.0) if ro.positive?
      points += [[projection - ro, half_o], [0.0, half_o], [0.0, half_i], [projection - t - ri, half_i]]
      points += arc(projection - t - ri, half_i - ri, ri, 90.0, 0.0) if ri.positive?
      points += [[projection - t, half_i - ri], [projection - t, -half_i + ri]]
      points += arc(projection - t - ri, -half_i + ri, ri, 0.0, -90.0) if ri.positive?
      points += [[projection - t - ri, -half_i], [0.0, -half_i]]
      tidy(points)
    end

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of a shape made of outlines [[x, y], ...] placed at heights z, all with the same
    # number of points: a strip between each pair of neighbouring ones along every edge, and an end cap at each end. [[z, outline], ...] in the
    # order of z. Pure maths.
    def self.loft_faces(sections)
      first = sections.first[1]
      area = first.each_with_index.sum { |(x, y), i| nx, ny = first[(i + 1) % first.length]; (x * ny) - (nx * y) }
      sections = sections.map { |z, outline| [z, area.negative? ? outline.reverse : outline] } # (the outlines go round counter-clockwise)
      count = sections.first[1].length
      faces = [sections.last[1].map { |x, y| [x, y, sections.last[0]] }, sections.first[1].reverse.map { |x, y| [x, y, sections.first[0]] }]
      sections.each_cons(2) do |(z0, a), (z1, b)|
        count.times do |i|
          j = (i + 1) % count
          faces << [[a[i][0], a[i][1], z0], [a[j][0], a[j][1], z0], [b[j][0], b[j][1], z1], [b[i][0], b[i][1], z1]]
        end
      end
      faces.filter_map { |face| collapse(face) }
    end

    # A strip whose two ends have closed to a point (the end of a shell) is a triangle; one with two points that are the same loses one.
    def self.collapse(corners)
      points = corners.each_with_index.reject { |p, i| i.positive? && same_point?(p, corners[i - 1]) }.map(&:first)
      points.pop if points.length > 1 && same_point?(points.first, points.last)
      points.length >= 3 ? points : nil
    end
    private_class_method :collapse

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of an outline pushed out half mm either way along Z: two end caps and a strip
    # along every edge. Pure maths.
    def self.extrude_faces(outline, half)
      loft_faces([[-half, outline], [half, outline]])
    end



    # The outline of the knob as [radius, height above the door] from the middle of its base to the middle of its top.
    # Pure maths.
    def self.knob_profile(diameter, projection, style = '')
      return cylinder_knob_profile(diameter, projection) if style == 'cylinder'
      return ball_knob_profile(diameter, projection) if style == 'ball'

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
    def self.knob_faces(diameter, projection, segments = KNOB_SEGMENTS, style = '')
      lathe_faces(knob_profile(diameter, projection, style), segments, ->(axial, a, b) { [axial, a, b] })
    end

    # A straight cylinder knob with a softly rounded top edge, flat on the door. [[radius, height], ...] Pure maths.
    def self.cylinder_knob_profile(diameter, projection)
      head = diameter / 2.0
      round = [2.5, projection / 3.0, head / 2.0].min
      points = [[0.0, 0.0], [head, 0.0], [head, projection - round]]
      points += arc(head - round, projection - round, round, 0.0, 90.0, 6).drop(1)
      points << [0.0, projection]
      points.map { |r, z| [(r * 1000).round / 1000.0, (z * 1000).round / 1000.0] }
    end

    # A ball on a slim neck with a small rose on the door. [[radius, height], ...] Pure maths.
    def self.ball_knob_profile(diameter, projection)
      r = diameter / 2.0
      neck = diameter * 0.12
      centre = [projection - r, r * 0.6].max # the ball's middle
      rose = [diameter * 0.3, r].min
      join = centre - Math.sqrt((r * r) - (neck * neck)) # where the neck meets the ball
      points = [[0.0, 0.0], [rose, 0.0], [rose, 1.0], [neck * 1.6, 2.2], [neck, 3.4], [neck, [join, 3.6].max]]
      start = -Math.acos(neck / r) * 180.0 / Math::PI
      points += arc(0.0, centre, r, start, 90.0, 16).map { |x, y| [x, y] }
      points.map { |rad, z| [(rad * 1000).round / 1000.0, (z * 1000).round / 1000.0] }
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
          # (SketchUp refuses a face with two points closer than 0.001 inch: the corners that collapse on the axis are merged.)
          points = points.each_with_index.reject { |p, i| i.positive? && same_point?(p, points[i - 1]) }.map(&:first)
          points.pop if points.length > 1 && same_point?(points.first, points.last)
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
      grip = grip.map { |r, z| [(r * 1000).round / 1000.0, (z * 1000).round / 1000.0] } # (sin and cos of a right angle are not exactly 0)
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

    def self.same_point?(a, b)
      a.zip(b).all? { |u, v| (u - v).abs < 0.005 }
    end
    private_class_method :same_point?

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
