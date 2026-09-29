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
    KNOB_SEGMENTS = 24

    # Fills in anything the panel left blank from the bundle's own defaults, so what
    # is stored on the cabinet is always the complete, effective set of values.
    def self.apply_defaults!(params, bundle)
      defaults = Defaults::HANDLE_DEFAULTS.merge(bundle['defaults'].is_a?(Hash) ? bundle['defaults'] : {})

      params['handle_length'] ||= default_length(bundle)
      params['handle_finish'] = bundle['finishes'].first['name'] if params['handle_finish'].to_s.empty?
      params['handle_orientation'] = defaults['orientation'] if params['handle_orientation'].to_s.empty?
      params['handle_position'] = defaults['position'] if params['handle_position'].to_s.empty?
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

      # A knob is round (its length is the diameter); a bar is `length` long and `section` wide.
      half_along = length / 2.0
      half_across = bundle['profile'] == 'knob' ? half_along : section(bundle) / 2.0
      half_u, half_v = horizontal ? [half_along, half_across] : [half_across, half_along]

      side = settings['side_offset']
      vertical = settings['vertical_offset']
      position = settings['position']
      free_edge_is_high = door.hinge == 'left' # the hinge is on the other side

      # A drawer's handle always centres horizontally (there is no hinge side to
      # offset from), regardless of the chosen position; marked by hinge 'center'.
      u = if door.hinge == 'center'
            (door_w / 2.0) - half_u
          else
            case position
            when 'custom' then settings['custom_x']
            when 'left' then side + half_u
            when 'right' then door_w - side - half_u
            when 'center' then (door_w / 2.0) - half_u
            else free_edge_is_high ? door_w - side - half_u : side + half_u
            end
          end

      v = case position
          when 'custom' then settings['custom_z']
          when 'top' then door_h - vertical - half_v
          when 'bottom' then vertical + half_v
          else door_h / 2.0
          end

      { 'u' => u, 'v' => v, 'half_u' => half_u, 'half_v' => half_v, 'horizontal' => horizontal }
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
      name = format('Handle %<profile>s %<length>g x %<section>g x %<projection>g',
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

    # A bar: a grip along Z held off the door by two posts. Built from shared box
    # definitions, so no boolean geometry is needed.
    def self.build_bar(model, entities, length, section, projection)
      grip = [section, projection].min
      post = projection - grip

      parts = [['Grip', [grip, section, length], [projection - grip, -section / 2.0, -length / 2.0]]]
      if post.positive?
        parts << ['Post 1', [post, section, section], [0, -section / 2.0, -length / 2.0]]
        parts << ['Post 2', [post, section, section], [0, -section / 2.0, (length / 2.0) - section]]
      end

      parts.each do |name, extent, offset|
        instance = entities.add_instance(PanelGenerator.definition(model, extent), Geom::Transformation.new(offset.map(&:mm)))
        instance.name = name
      end
    end
    private_class_method :build_bar

    # A knob: a cylinder standing off the door. `length` is its diameter.
    def self.build_knob(entities, diameter, projection)
      circle = entities.add_circle(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(1, 0, 0), (diameter / 2.0).mm, KNOB_SEGMENTS)
      face = entities.add_face(circle)
      face.reverse! if face.normal.x < 0
      face.pushpull(projection.mm)
    end
    private_class_method :build_knob
  end
end
