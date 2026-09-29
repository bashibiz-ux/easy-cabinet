# frozen_string_literal: true

module KitchenCabinetMaster
  # Turns the raw values sent by the HTML panel (mostly strings) into a clean,
  # typed parameter Hash, or a list of field-level errors.
  module ValidationManager
    Result = Struct.new(:params, :errors) do
      def valid?
        errors.empty?
      end
    end

    # min/max are inclusive. `toe_kick: true` fields are ignored for wall units.
    NUMERIC_FIELDS = {
      'width'                 => { label: 'Width', min: 100.0, max: 3000.0, required: true },
      'depth'                 => { label: 'Depth', min: 100.0, max: 1200.0, required: true },
      'height'                => { label: 'Height', min: 100.0, max: 3000.0, required: true },
      'material_thickness'    => { label: 'Panel thickness', min: 6.0, max: 50.0 },
      'back_thickness'        => { label: 'Back panel thickness', min: 3.0, max: 25.0 },
      'door_gap'              => { label: 'Door gap', min: 0.0, max: 10.0 },
      'door_reveal'           => { label: 'Door reveal', min: 0.0, max: 10.0 },
      'door_opening_angle'    => { label: 'Opening angle', min: 1.0, max: 170.0, unit: 'degrees' },
      'placement_gap'         => { label: 'Gap between cabinets', min: 0.0, max: 100.0 },
      # A cabinet only needs the toe-kick HEIGHT (how far it stands off the floor);
      # the toe kick itself is a separate entity, see validate_toe_kick.
      'toe_kick_height'       => { label: 'Toe-kick height', min: 0.0, max: 400.0, required: true, toe_kick: true },
      'handle_length'         => { label: 'Handle length', min: 10.0, max: 2000.0 },
      'handle_side_offset'    => { label: 'Handle side offset', min: 0.0, max: 1000.0 },
      'handle_vertical_offset' => { label: 'Handle top/bottom offset', min: 0.0, max: 2000.0 },
      'handle_custom_x'       => { label: 'Handle position from left edge', min: 0.0, max: 3000.0 },
      'handle_custom_z'       => { label: 'Handle position from bottom edge', min: 0.0, max: 3000.0 }
    }.freeze

    MIN_INTERIOR = 20.0 # mm of clear space required inside the carcass
    MIN_DOOR_SIZE = 50.0
    MIN_SHELF_GAP = 30.0 # mm of clear space between shelves / panels

    # raw        - Hash from the HTML panel
    # door_count - Integer from the catalog entry (nil = skip door checks)
    def self.validate(raw, door_count: nil, drawer_count: nil)
      raw = stringify_keys(raw)
      errors = []
      out = Defaults.params

      check_identity(raw, out, errors)
      check_numbers(raw, out, errors)
      check_choices(raw, out, errors)
      check_materials(raw, out, errors)
      check_visibility(raw, out)
      cross_check(out, door_count, drawer_count, errors)

      Result.new(out, errors)
    end

    # ---- individual checks ---------------------------------------------------

    def self.check_identity(raw, out, errors)
      out['catalog_id'] = raw['catalog_id'].to_s.strip
      errors << error('catalog_id', 'Select a catalog.') if out['catalog_id'].empty?

      category = raw['cabinet_category'].to_s
      if Defaults.category_ids.include?(category)
        out['cabinet_category'] = category
      else
        errors << error('cabinet_category', 'Select a cabinet category.')
      end

      out['cabinet_type'] = raw['cabinet_type'].to_s.strip
      errors << error('cabinet_type', 'Select a cabinet.') if out['cabinet_type'].empty?

      out['handle_id'] = raw['handle_id'].to_s.strip
    end
    private_class_method :check_identity

    def self.check_numbers(raw, out, errors)
      wall = out['cabinet_category'] == 'wall'

      NUMERIC_FIELDS.each do |key, spec|
        if spec[:toe_kick] && wall
          out['toe_kick_height'] = 0.0 if key == 'toe_kick_height'
          next
        end

        text = raw[key].to_s.strip
        if text.empty?
          errors << error(key, "#{spec[:label]} is required.") if spec[:required]
          next
        end

        value = to_float(text)
        unit = spec[:unit] || 'mm'
        if value.nil?
          errors << error(key, "#{spec[:label]} must be a number.")
        elsif value < spec[:min] || value > spec[:max]
          errors << error(key, "#{spec[:label]} must be between #{fmt(spec[:min])} and #{fmt(spec[:max])} #{unit}.")
        else
          out[key] = value
        end
      end

      check_shelf_count(raw, out, errors)
    end
    private_class_method :check_numbers

    def self.check_shelf_count(raw, out, errors)
      text = raw['shelf_count'].to_s.strip
      return if text.empty?

      value = to_float(text)
      if value.nil? || value != value.round || value < 0 || value > 20
        errors << error('shelf_count', 'Shelves must be a whole number from 0 to 20.')
      else
        out['shelf_count'] = value.to_i
      end
    end
    private_class_method :check_shelf_count

    def self.check_choices(raw, out, errors)
      direction = raw['door_opening_direction'].to_s
      if Defaults.direction_ids.include?(direction)
        out['door_opening_direction'] = direction
      else
        errors << error('door_opening_direction', 'Select a door opening direction.')
      end

      %w[show_opening_direction show_door_symbol].each do |key|
        out[key] = truthy?(raw[key]) if raw.key?(key)
      end

      check_handle_choices(raw, out, errors)
    end

    # Blank means "use the bundle default"; anything else must be a known value.
    def self.check_handle_choices(raw, out, errors)
      { 'handle_orientation' => [Defaults.handle_orientation_ids, 'Select a handle orientation.'],
        'handle_position' => [Defaults.handle_position_ids, 'Select a handle position.'] }.each do |key, (allowed, message)|
        value = raw[key].to_s.strip
        if value.empty?
          out[key] = ''
        elsif allowed.include?(value)
          out[key] = value
        else
          errors << error(key, message)
        end
      end
      out['handle_finish'] = raw['handle_finish'].to_s.strip
    end
    private_class_method :check_handle_choices
    private_class_method :check_choices

    def self.check_materials(raw, out, errors)
      out['cabinet_material'] = raw['cabinet_material'].to_s.strip
      out['carcass_material'] = raw['carcass_material'].to_s.strip
      out['handle_material'] = raw['handle_material'].to_s.strip

      # A unit type nobody has chosen a door material for just gets the plain
      # white default (Defaults::PARAMS already holds it), so the first cabinet
      # can be inserted without picking anything.
      Defaults.category_ids.each do |category|
        key = "#{category}_material"
        value = raw[key].to_s.strip
        out[key] = value unless value.empty?
      end

      toe_material = raw['toe_kick_material'].to_s.strip
      out['toe_kick_material'] = toe_material unless toe_material.empty?
    end
    private_class_method :check_materials

    def self.check_visibility(raw, out)
      given = raw['visibility_settings']
      return unless given.is_a?(Hash)

      given = stringify_keys(given)
      out['visibility_settings'].each_key do |key|
        out['visibility_settings'][key] = truthy?(given[key]) if given.key?(key)
      end
    end
    private_class_method :check_visibility

    # Checks that depend on more than one field. Skipped for fields already in error.
    def self.cross_check(out, door_count, drawer_count, errors)
      bad = errors.map { |e| e['field'] }
      thickness = out['material_thickness']
      usable = ->(*fields) { (bad & fields).empty? }

      if usable.call('width', 'material_thickness')
        minimum = (2 * thickness) + MIN_INTERIOR
        if out['width'] && out['width'] < minimum
          errors << error('width', "Width is too small for #{fmt(thickness)} mm panels (minimum #{fmt(minimum)} mm).")
        end
      end

      if usable.call('height', 'material_thickness')
        minimum = (2 * thickness) + MIN_INTERIOR
        if out['height'] && out['height'] < minimum
          errors << error('height', "Height is too small for #{fmt(thickness)} mm panels (minimum #{fmt(minimum)} mm).")
        end
      end

      if usable.call('depth', 'back_thickness')
        minimum = Defaults::BACK_RECESS + out['back_thickness'] + Defaults::SHELF_FRONT_SETBACK + MIN_INTERIOR
        if out['depth'] && out['depth'] < minimum
          errors << error('depth', "Depth is too small for the back panel and shelf setback (minimum #{fmt(minimum)} mm).")
        end
      end

      check_shelves(out, errors, bad)
      check_corner(out, errors, bad)

      check_doors(out, door_count, errors, bad)
      check_drawers(out, drawer_count, errors, bad)
    end
    private_class_method :cross_check

    def self.check_shelves(out, errors, bad)
      count = out['shelf_count'].to_i
      return unless count.positive? && (bad & %w[height material_thickness shelf_count]).empty? && out['height']

      thickness = out['material_thickness']
      gap = (out['height'] - (2 * thickness) - (count * thickness)) / (count + 1)
      return unless gap < MIN_SHELF_GAP

      errors << error('shelf_count', "Too many shelves for this height: #{count} would leave only #{fmt(gap.round(1))} mm between panels (minimum #{fmt(MIN_SHELF_GAP)} mm).")
    end
    private_class_method :check_shelves

    MIN_DRAWER_HEIGHT = 80.0

    # A cabinet type has doors OR drawers, never both, so this and check_doors
    # never both fire for the same cabinet in practice.
    def self.check_drawers(out, drawer_count, errors, bad)
      return unless drawer_count.to_i.positive?
      return unless (bad & %w[height door_gap door_reveal]).empty? && out['height']

      count = drawer_count.to_i
      front_h = (out['height'] - (2 * out['door_reveal']) - ((count - 1) * out['door_gap'])) / count
      return unless front_h < MIN_DRAWER_HEIGHT

      errors << error('height', "Each drawer front would be only #{fmt(front_h.round(1))} mm high (minimum #{fmt(MIN_DRAWER_HEIGHT)} mm).")
    end
    private_class_method :check_drawers

    MIN_CORNER_SIZE = 500.0

    # A corner unit must be square (its one door runs diagonally corner to
    # corner) and big enough for that diagonal door to be a sensible size.
    # A corner unit's outer footprint is a square sized by Width; its Depth is
    # the return length of the shortened right-side and front-return panels
    # (the same field, same meaning, as any other cabinet's Depth -- so it can
    # be set to match a neighbouring run). Depth must leave room for those two
    # panels to meet the diagonal without overlapping, and for a sensible door.
    def self.check_corner(out, errors, bad)
      return unless out['cabinet_category'] == 'corner'
      return unless (bad & %w[width depth material_thickness]).empty? && out['width'] && out['depth']

      if out['width'] < MIN_CORNER_SIZE
        errors << error('width', "A corner unit must be at least #{fmt(MIN_CORNER_SIZE)} mm wide (minimum #{fmt(MIN_CORNER_SIZE)} mm).")
        return
      end

      inner_edge = out['width'] - out['material_thickness']
      if out['depth'] >= inner_edge
        errors << error('depth', "Depth is too large for a #{fmt(out['width'])} mm wide corner unit (must be under #{fmt(inner_edge)} mm).")
        return
      end

      diagonal = (inner_edge - out['depth']) * Math.sqrt(2)
      if diagonal < MIN_DOOR_SIZE
        errors << error('depth', "The corner door would be only #{fmt(diagonal.round(1))} mm on the diagonal (minimum #{fmt(MIN_DOOR_SIZE)} mm) -- reduce Depth.")
      end
    end
    private_class_method :check_corner

    # A corner unit's single door is sized by check_corner (its width is a
    # diagonal, not the cabinet's own Width), so the usual width-based door-fit
    # check below does not apply to it; the height check still does.
    def self.check_doors(out, door_count, errors, bad)
      return unless door_count.to_i.positive?

      count = door_count.to_i
      if out['cabinet_category'] != 'corner' && (bad & %w[width door_gap door_reveal]).empty? && out['width']
        door_width = (out['width'] - (2 * out['door_reveal']) - ((count - 1) * out['door_gap'])) / count
        if door_width < MIN_DOOR_SIZE
          errors << error('width', "Each door would be only #{fmt(door_width.round(1))} mm wide (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
        end
      end

      return unless (bad & %w[height door_reveal]).empty? && out['height']

      door_height = out['height'] - (2 * out['door_reveal'])
      return unless door_height < MIN_DOOR_SIZE

      errors << error('height', "Doors would be only #{fmt(door_height.round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
    end
    private_class_method :check_doors

    # ---- filler -----------------------------------------------------------

    FILLER_FIELDS = %w[width depth height toe_kick_height].freeze

    # A filler is a single board, not a cabinet: no catalog, doors, shelves, or
    # per-category material. It reuses the cabinet's width/depth/height field
    # rules; its toe-kick height is only how far it is raised off the floor.
    def self.validate_filler(raw)
      raw = stringify_keys(raw)
      errors = []
      out = { 'part_kind' => 'filler' }

      category = raw['cabinet_category'].to_s
      if Defaults.category_ids.include?(category)
        out['cabinet_category'] = category
      else
        errors << error('cabinet_category', 'Select where this filler sits (Base, Wall or Tall).')
      end

      wall = category == 'wall'

      FILLER_FIELDS.each do |key|
        spec = NUMERIC_FIELDS[key]
        next if spec[:toe_kick] && wall

        value, problem = numeric_field(raw, key, spec)
        out[key] = value unless value.nil?
        errors << problem if problem
      end
      out['toe_kick_height'] = 0.0 if wall

      out['material'] = raw['material'].to_s.strip
      out['material'] = Defaults::DEFAULT_MATERIAL if out['material'].empty?

      Result.new(out, errors)
    end

    # ---- toe kick -----------------------------------------------------------

    TOE_KICK_FIELDS = {
      'toe_kick_height'       => { label: 'Toe-kick height', min: 1.0, max: 400.0, required: true },
      'toe_kick_thickness'    => { label: 'Toe-kick thickness', min: 3.0, max: 50.0, required: true },
      'toe_kick_piece_length' => { label: 'Piece length', min: 50.0, max: 3000.0, required: true },
      'toe_kick_recess'       => { label: 'Recess from the carcass', min: 0.0, max: 500.0, required: true }
    }.freeze
    MAX_TOE_KICK_PIECES = 200

    # A toe kick is a run of `toe_kick_pieces` pieces of `toe_kick_piece_length`,
    # laid end to end. What it sits under (target depth, materials) is added by
    # PartManager once it knows what is selected.
    def self.validate_toe_kick(raw)
      raw = stringify_keys(raw)
      errors = []
      out = { 'part_kind' => 'toe_kick', 'toe_kick_material' => Defaults::SAME_AS_DOOR }

      TOE_KICK_FIELDS.each do |key, spec|
        value, problem = numeric_field(raw, key, spec)
        out[key] = value unless value.nil?
        errors << problem if problem
      end

      count = to_float(raw['toe_kick_pieces'])
      if count.nil? || count != count.round || count < 1 || count > MAX_TOE_KICK_PIECES
        errors << error('toe_kick_pieces', "Number of pieces must be a whole number from 1 to #{MAX_TOE_KICK_PIECES}.")
      else
        out['toe_kick_pieces'] = count.to_i
      end

      material = raw['toe_kick_material'].to_s.strip
      out['toe_kick_material'] = material unless material.empty?

      Result.new(out, errors)
    end

    # ---- end panel ----------------------------------------------------------

    END_PANEL_FIELDS = {
      'thickness' => { label: 'End panel thickness', min: 6.0, max: 60.0, required: true }
    }.freeze

    # An end panel just needs which side it sits on, how thick it is, and its
    # material; its width, height and depth all come from whatever it is
    # attached to (see PartLayout.end_panel).
    def self.validate_end_panel(raw)
      raw = stringify_keys(raw)
      errors = []
      out = { 'part_kind' => 'end_panel' }

      side = raw['side'].to_s
      if Defaults::END_PANEL_SIDES.include?(side)
        out['side'] = side
      else
        errors << error('side', 'Select left or right.')
      end

      END_PANEL_FIELDS.each do |key, spec|
        value, problem = numeric_field(raw, key, spec)
        out[key] = value unless value.nil?
        errors << problem if problem
      end

      out['material'] = raw['material'].to_s.strip
      out['material'] = Defaults::DEFAULT_MATERIAL if out['material'].empty?

      Result.new(out, errors)
    end

    # A single field's value, or the error that rejects it (nil, nil is not
    # possible: an optional field left blank returns [nil, nil]).
    def self.numeric_field(raw, key, spec)
      text = raw[key].to_s.strip
      return [nil, spec[:required] ? error(key, "#{spec[:label]} is required.") : nil] if text.empty?

      value = to_float(text)
      unit = spec[:unit] || 'mm'
      return [nil, error(key, "#{spec[:label]} must be a number.")] if value.nil?
      return [nil, error(key, "#{spec[:label]} must be between #{fmt(spec[:min])} and #{fmt(spec[:max])} #{unit}.")] if value < spec[:min] || value > spec[:max]

      [value, nil]
    end
    private_class_method :numeric_field

    # ---- helpers -------------------------------------------------------------

    def self.to_float(value)
      return value.to_f if value.is_a?(Numeric) && value.finite?

      number = Float(value.to_s.strip.tr(',', '.'))
      number.finite? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end

    def self.truthy?(value)
      [true, 'true', '1', 1, 'on', 'yes'].include?(value)
    end
    private_class_method :truthy?

    def self.stringify_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
    end
    private_class_method :stringify_keys

    def self.error(field, message)
      { 'field' => field, 'message' => message }
    end
    private_class_method :error

    def self.fmt(number)
      format('%g', number)
    end
    private_class_method :fmt
  end
end
