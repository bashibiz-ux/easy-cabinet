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
      'carcass_raise'         => { label: 'Carcass bottom raise', min: 0.0, max: 1000.0 },
      'oven_height'           => { label: 'Oven height', min: 300.0, max: 900.0 },
      'oven2_height'          => { label: 'Second oven height', min: 300.0, max: 900.0 },
      'micro_height'          => { label: 'Microwave height', min: 200.0, max: 600.0 },
      'door_gap'              => { label: 'Door gap', min: 0.0, max: 10.0 },
      'door_reveal'           => { label: 'Door reveal', min: 0.0, max: 10.0 },
      'door_distance'         => { label: 'Door distance', min: 0.0, max: 50.0 },
      'front_radius'          => { label: 'Front edge radius', min: 0.0, max: 9.0 },
      'door_opening_angle'    => { label: 'Opening angle', min: 1.0, max: 170.0, unit: 'degrees' },
      'placement_gap'         => { label: 'Gap between cabinets', min: 0.0, max: 100.0 },
      # A cabinet only needs the toe-kick HEIGHT (how far it stands off the floor);
      # the toe kick itself is a separate entity, see validate_toe_kick.
      'toe_kick_height'       => { label: 'Toe-kick height', min: 0.0, max: 400.0, required: true, toe_kick: true },
      'handle_length'         => { label: 'Handle length', min: 10.0, max: 2000.0 },
      'handle_side_offset'    => { label: 'Handle vertical side offset', min: 0.0, max: 1000.0 },
      'handle_vertical_offset' => { label: 'Handle horizontal side offset', min: 0.0, max: 2000.0 },
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

      # A corner-type catalog entry says what shape it is (see CabinetManager.prepare).
      style = raw['corner_style'].to_s
      out['corner_style'] = style if Defaults::CORNER_STYLES.include?(style)
      second_length = to_float(raw['leg2_length'])
      out['leg2_length'] = second_length if second_length && second_length > 0 && out['corner_style'] == 'l_shape'
      second_depth = to_float(raw['leg2_depth'])
      out['leg2_depth'] = second_depth if second_depth && second_depth > 0 && out['corner_style'] == 'l_shape'
      out['door_stacked'] = truthy?(raw['door_stacked'])
      set = raw['appliance_set'].to_s
      out['appliance_set'] = Defaults::APPLIANCE_SETS.include?(set) ? set : ''
      zone = to_float(raw['front_zone'])
      out['front_zone'] = zone if zone && zone >= 0
      bottom = to_float(raw['bottom_zone'])
      out['bottom_zone'] = bottom if bottom && bottom >= 0
      blind = to_float(raw['blind_width'])
      out['blind_width'] = blind if blind && blind >= 0
      out['custom_overrides'] = clean_overrides(raw['custom_overrides'])
      out['door_split'] = truthy?(raw['door_split'])
      split = to_float(raw['split_height'])
      out['split_height'] = split if split && split >= 0
      heights = raw['drawer_heights'].to_s.strip
      out['drawer_heights'] = heights if heights.match?(/\A(\d+(\.\d+)?)?(,(\d+(\.\d+)?)?)*\z/)
      out['sink'] = truthy?(raw['sink'])
      out['sink_bowls'] = to_float(raw['sink_bowls']) == 2.0 ? 2 : 1
      out['sink_tray'] = truthy?(raw['sink_tray'])
      turn = to_float(raw['sink_rotation']) # (an older cabinet's half turn is a mirror now)
      out['sink_mirror'] = truthy?(raw['sink_mirror']) || (turn && turn.to_i % 360 == 180) ? true : false
      out['hob'] = truthy?(raw['hob'])
      out['hood'] = truthy?(raw['hood'])
      rise = to_float(raw['worktop_rise'])
      out['worktop_rise'] = rise if rise && rise >= 0 && rise <= 200
      out['fridge'] = truthy?(raw['fridge'])
      out['fridge_lift'] = raw.key?('fridge_lift') ? truthy?(raw['fridge_lift']) : true
      out['freestanding'] = truthy?(raw['freestanding'])
      out['free_housing'] = truthy?(raw['free_housing'])
      out['pullout'] = truthy?(raw['pullout'])
      out['finger_pull'] = truthy?(raw['finger_pull'])
      out['finger_all'] = truthy?(raw['finger_all'])
      gap = to_float(raw['finger_gap'])
      if out['finger_pull'] && gap && !gap.between?(15.0, 100.0)
        errors << error('finger_gap', 'The finger gap (how much shorter the doors are) must be between 15 and 100 mm.')
      elsif gap && gap.between?(15.0, 100.0)
        out['finger_gap'] = gap
      end
      drawer_gap = to_float(raw['finger_gap_drawer'])
      if out['finger_pull'] && drawer_gap && !drawer_gap.between?(15.0, 100.0)
        errors << error('finger_gap_drawer', 'The finger gap of the drawer front (how much shorter it is) must be between 15 and 100 mm.')
      elsif drawer_gap && drawer_gap.between?(15.0, 100.0)
        out['finger_gap_drawer'] = drawer_gap
      end
      out['front_design'] = FrontDesign.clean(raw['front_design'])
      lift = to_float(raw['housing_lift'])
      out['housing_lift'] = lift if lift && lift >= 0
      mode = raw['lower_mode'].to_s
      out['lower_mode'] = mode if Defaults::LOWER_MODES.include?(mode)
      drawers = to_float(raw['lower_drawers'])
      out['lower_drawers'] = drawers.round.clamp(1, 6) if drawers
      small = to_float(raw['small_drawer'])
      if small && small >= 80.0 && small <= 600.0
        out['small_drawer'] = small
      elsif small && !raw['small_drawer'].to_s.strip.empty?
        errors << error('small_drawer', 'The small drawer must be between 80 and 600 mm high.')
      end
      fridge = to_float(raw['fridge_height'])
      out['fridge_height'] = fridge if fridge && fridge >= 0
      top_front = to_float(raw['top_front'])
      out['top_front'] = top_front if top_front && top_front >= 0
      pattern = raw['drawer_pattern'].to_s.strip
      out['drawer_pattern'] = pattern if pattern.match?(/\A\d+(\.\d+)?(,\d+(\.\d+)?)*\z/)
    end
    private_class_method :check_identity

    # The Customize window's changes, cleaned: part key => { 'extent' => [x, y, z] (nil = unchanged), 'move' => [dx, dy, dz] }.
    def self.clean_overrides(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), out|
        next unless key.to_s.match?(/\A[a-z0-9_]+\z/) && value.is_a?(Hash)

        sizes = Array(value['extent']).first(3).map { |v| (n = to_float(v)) && n.positive? && n <= 6000 ? n : nil }
        moves = Array(value['move']).first(3).map { |v| (n = to_float(v)) && n.abs <= 6000 ? n : 0.0 }
        sizes += [nil] * (3 - sizes.length)
        moves += [0.0] * (3 - moves.length)
        next if sizes.compact.empty? && moves.all?(&:zero?)

        out[key.to_s] = { 'extent' => sizes, 'move' => moves }
      end
    end

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

      out['carcass_raise'] = 0.0 unless wall # only a wall unit lifts its carcass
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

      style = raw['top_panel_style'].to_s.strip
      if Defaults::TOP_PANEL_STYLES.include?(style)
        out['top_panel_style'] = style
      else
        errors << error('top_panel_style', 'Select how the top panel is made.')
      end

      %w[show_opening_direction show_door_symbol show_wall_opening_direction hide_wall_handles hide_base_handles hide_tall_handles show_cabinet_names].each do |key|
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

      place = raw['handle_horizontal_place'].to_s.strip
      if place.empty?
        out['handle_horizontal_place'] = ''
      elsif Defaults.handle_horizontal_place_ids.include?(place)
        out['handle_horizontal_place'] = place
      else
        errors << error('handle_horizontal_place', 'Select where the horizontal handle goes.')
      end
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
      # (A corner unit takes the Base Unit door material, see CabinetGenerator.door_material.)
      %w[base wall tall].each do |category|
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

      if out['cabinet_category'] == 'wall' && usable.call('height', 'material_thickness', 'carcass_raise') && out['height']
        room = out['height'] - (2 * thickness) - MIN_INTERIOR
        if out['carcass_raise'].to_f > room
          errors << error('carcass_raise', "The carcass would be too short: the bottom can be raised at most #{fmt(room.round(1))} mm.")
        end
      end

      if usable.call('depth', 'back_thickness')
        minimum = Defaults.back_recess(out['back_thickness']) + out['back_thickness'] + Defaults::SHELF_FRONT_SETBACK + MIN_INTERIOR
        if out['depth'] && out['depth'] < minimum
          errors << error('depth', "Depth is too small for the back panel and shelf setback (minimum #{fmt(minimum)} mm).")
        end
      end

      check_shelves(out, errors, bad)
      check_fixtures(out, errors, bad)
      check_housing(out, errors, bad)
      check_corner(out, errors, bad)
      check_zone(out, door_count, drawer_count, errors, bad)

      check_doors(out, door_count, errors, bad)
      check_drawers(out, drawer_count, errors, bad)
      check_drawer_heights(out, drawer_count, errors, bad)
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

    # Two doors one above the other (a tall unit): `split_height` is the lower door's height, the upper one takes the rest.
    def self.check_split(out, errors, bad)
      return unless (bad & %w[height door_gap door_reveal]).empty? && out['height']

      lower = out['split_height'].to_f.positive? ? out['split_height'] : 1000.0
      upper = out['height'] - (2 * out['door_reveal']) - out['door_gap'] - lower
      return if lower >= MIN_DOOR_SIZE && upper >= MIN_DOOR_SIZE

      errors << error('split_height', "The two doors would be #{fmt(lower.round(1))} and #{fmt(upper.round(1))} mm high (each needs at least #{fmt(MIN_DOOR_SIZE)} mm).")
    end
    private_class_method :check_split

    # The height typed for each drawer ("200,,150": top down, a blank takes its share) must fit the unit.
    def self.check_drawer_heights(out, drawer_count, errors, bad)
      list = out['drawer_heights'].to_s.split(',', -1).first(drawer_count.to_i).map { |text| text.strip.to_f }
      return unless drawer_count.to_i.positive? && list.any?(&:positive?) && (bad & %w[height door_gap door_reveal]).empty? && out['height']
      return if out['front_zone'].to_f.positive? || out['bottom_zone'].to_f.positive? # only a unit of drawers alone

      count = drawer_count.to_i
      total = out['height'] - (2 * out['door_reveal']) - ((count - 1) * out['door_gap'])
      fixed = list.select(&:positive?)
      free = count - fixed.length
      too_small = fixed.find { |height| height < 50.0 }
      if too_small
        errors << error('drawer_heights', "A drawer front must be at least 50 mm high (#{fmt(too_small)} was typed).")
      elsif total - fixed.sum < free * MIN_DRAWER_HEIGHT
        errors << error('drawer_heights', "The drawers are too high for the unit: #{fmt(fixed.sum.round(1))} mm typed leaves #{fmt((total - fixed.sum).round(1))} mm for #{free} more (each needs #{fmt(MIN_DRAWER_HEIGHT)}).")
      end
    end
    private_class_method :check_drawer_heights

    # A housing for a freestanding fridge: the cabinet over the fridge must be a sensible height and leave room for it.
    def self.check_housing(out, errors, bad)
      return unless out['free_housing'] && (bad & %w[height]).empty? && out['height']

      lift = out['housing_lift'].to_f
      lift = CabinetLayout::HOUSING_LIFT unless lift.positive?
      if lift < 150.0
        errors << error('housing_lift', 'The lift-up cabinet must be at least 150 mm high.')
      elsif out['height'] - lift < 800.0
        errors << error('housing_lift', "That leaves only #{fmt((out['height'] - lift).round(1))} mm for the fridge (at least 800 mm).")
      end
    end
    private_class_method :check_housing

    # A sink must lie inside its cabinet.
    def self.check_fixtures(out, errors, bad)
      return unless out['sink'] && (bad & %w[width depth material_thickness back_thickness]).empty? && out['width'] && out['depth']

      dims = CabinetLayout.send(:dimensions, out.merge('door_count' => 0, 'drawer_count' => 0))
      plan = Fixtures.sink_plan(out, dims)
      return if plan.nil? || plan[:fits]

      errors << error('sink_bowls', 'That sink does not fit this cabinet. Use one bowl, no drainer or a wider cabinet.')
    end
    private_class_method :check_fixtures

    # A front zone (drawers over a door, or a door over an open niche) must leave sensible sizes.
    def self.check_zone(out, door_count, drawer_count, errors, bad)
      zone = out['front_zone'].to_f
      bottom = out['bottom_zone'].to_f
      return check_fridge(out, door_count, errors, bad) if out['fridge']
      return check_stacked(out, errors, bad) if out['door_stacked'] && door_count.to_i == 2
      lower = out['lower_mode'].to_s
      housing = bottom.positive? && (drawer_count.to_i.positive? || %w[door drawer_door].include?(lower))
      return unless (zone.positive? || bottom.positive?) && (door_count.to_i.positive? || housing) &&
                    (bad & %w[height door_gap door_reveal]).empty? && out['height']

      if housing
        check_appliances(out, bottom, errors, door_count.to_i.positive?)
        if lower == 'drawer_door'
          door_h = bottom - (2 * out['door_reveal']) - out['door_gap'] - out['small_drawer'].to_f
          errors << error('small_drawer', "The door under the small drawer would be only #{fmt(door_h.round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).") if door_h < MIN_DOOR_SIZE
        elsif drawer_count.to_i.positive?
          each = (bottom - (2 * out['door_reveal']) - ((drawer_count.to_i - 1) * out['door_gap'])) / drawer_count.to_i
          errors << error('height', "Each drawer front would be only #{fmt(each.round(1))} mm high (minimum #{fmt(MIN_DRAWER_HEIGHT)} mm).") if each < MIN_DRAWER_HEIGHT
        elsif bottom - (2 * out['door_reveal']) < MIN_DOOR_SIZE
          errors << error('height', "The lower door would be only #{fmt((bottom - (2 * out['door_reveal'])).round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
        end
        niche = out['height'] - bottom - zone - (2 * out['door_gap'])
        errors << error('height', "The niche between the drawers and the door would be only #{fmt(niche.round(1))} mm high.") if zone.positive? && niche < 100.0
      elsif drawer_count.to_i.positive?
        door_h = out['height'] - zone - out['door_gap'] - out['door_reveal']
        errors << error('height', "The door under the drawers would be only #{fmt(door_h.round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).") if door_h < MIN_DOOR_SIZE
        each = (zone - out['door_reveal'] - ((drawer_count.to_i - 1) * out['door_gap'])) / drawer_count.to_i
        errors << error('height', "Each drawer front would be only #{fmt(each.round(1))} mm high (minimum #{fmt(MIN_DRAWER_HEIGHT)} mm).") if each < MIN_DRAWER_HEIGHT
      elsif zone - out['door_reveal'] < MIN_DOOR_SIZE
        errors << error('height', "The door would be only #{fmt((zone - out['door_reveal']).round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
      end
    end
    private_class_method :check_zone

    # Two stacked doors (a built-in fridge-freezer): the top door's height is front_zone.
    def self.check_stacked(out, errors, bad)
      return unless (bad & %w[height door_gap door_reveal]).empty? && out['height']

      top = out['front_zone'].to_f
      return unless top.positive?

      bottom = out['height'] - top - out['door_gap'] - out['door_reveal']
      if top - out['door_reveal'] < MIN_DOOR_SIZE || bottom < MIN_DOOR_SIZE
        errors << error('height', "The two doors would be #{fmt((top - out['door_reveal']).round(1))} and #{fmt(bottom.round(1))} mm high (each needs at least #{fmt(MIN_DOOR_SIZE)} mm).")
      end
    end
    private_class_method :check_stacked

    # The appliances of an oven housing, stacked on shelves above the drawers, must leave room for a door
    # (or, with no door, for the top panel or the fixed panel over them).
    def self.check_appliances(out, bottom, errors, with_door = true)
      heights = { 'oven' => [out['oven_height']], 'double_oven' => [out['oven_height'], out['oven2_height']],
                  'oven_micro' => [out['oven_height'], out['micro_height']] }[out['appliance_set']]
      return unless heights && heights.all? && out['material_thickness']

      t = out['material_thickness']
      ends = (bottom - t) + heights.sum { |height| t + height + 4.0 } # where the appliances (and their air gap) end
      unless with_door # a built-in oven with no door: the appliances must fit under the top panel or the panel over them
        limit = out['height'] - (out['top_front'].to_f.positive? ? out['top_front'] : t)
        room = limit - ends
        what = out['top_front'].to_f.positive? ? 'the panel over them' : 'the top panel'
        errors << error('oven_height', "The appliances do not fit: they need #{fmt((-room).round(1))} mm more height under #{what}. Choose a smaller appliance set or a taller unit.") if room.negative?
        return
      end

      door = out['height'] - (ends + out['door_reveal']) - out['door_reveal']
      return if door >= MIN_DOOR_SIZE

      errors << error('oven_height', "The appliances do not fit: they leave only #{fmt(door.round(1))} mm for the door above them (needs #{fmt(MIN_DOOR_SIZE)}). Choose smaller appliances or a taller unit.")
    end
    private_class_method :check_appliances

    # A built-in fridge: `fridge_height` is the (bottom) fridge door's height and `front_zone` the top door's (two doors).
    # With the lift-up door on, it needs room above the doors; with it off, the top door carries on to the top.
    def self.check_fridge(out, door_count, errors, bad)
      return unless (bad & %w[height width door_gap door_reveal]).empty? && out['height'] && out['width']

      reveal = out['door_reveal']
      gap = out['door_gap']
      errors << error('width', "The doors would be only #{fmt((out['width'] - (2 * reveal)).round(1))} mm wide (minimum #{fmt(MIN_DOOR_SIZE)} mm).") if out['width'] - (2 * reveal) < MIN_DOOR_SIZE
      full = out['height']
      first = out['fridge_height'].to_f
      two = door_count.to_i >= 2
      if two
        bottom = first.positive? ? first : 675.0
        top = out['front_zone'].to_f.positive? ? out['front_zone'] : 1100.0
        f = (2 * reveal) + bottom + gap + top
        if top < MIN_DOOR_SIZE || bottom < MIN_DOOR_SIZE
          errors << error('fridge_height', "The two fridge doors would be #{fmt(top.round(1))} and #{fmt(bottom.round(1))} mm high (each needs at least #{fmt(MIN_DOOR_SIZE)} mm).")
          return
        end
      else
        bottom = first.positive? ? first : 1780.0
        f = bottom + (2 * reveal)
        if bottom < MIN_DOOR_SIZE
          errors << error('fridge_height', "The fridge door would be only #{fmt(bottom.round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
          return
        end
      end
      if f > full
        errors << error('fridge_height', "The fridge door#{'s' if two} (#{fmt(f.round(1))} mm with the gaps) cannot be taller than the unit (#{fmt(full)} mm).")
        return
      end
      return unless out['fridge_lift'] != false

      lift = full - f
      return if lift >= CabinetLayout::FRIDGE_MIN_LIFT

      errors << error('fridge_height', "The lift-up door above the fridge would be only #{fmt(lift.round(1))} mm high (minimum #{fmt(CabinetLayout::FRIDGE_MIN_LIFT)} mm). Make the fridge door#{'s' if two} shorter, or switch the lift-up door off.")
    end
    private_class_method :check_fridge

    # A cabinet type has doors OR drawers, never both, so this and check_doors
    # never both fire for the same cabinet in practice.
    def self.check_drawers(out, drawer_count, errors, bad)
      return unless drawer_count.to_i.positive?
      return unless (bad & %w[height door_gap door_reveal]).empty? && out['height'] && !out['front_zone'].to_f.positive? && !out['bottom_zone'].to_f.positive?

      count = drawer_count.to_i
      front_h = (out['height'] - (2 * out['door_reveal']) - ((count - 1) * out['door_gap'])) / count
      return unless front_h < MIN_DRAWER_HEIGHT

      errors << error('height', "Each drawer front would be only #{fmt(front_h.round(1))} mm high (minimum #{fmt(MIN_DRAWER_HEIGHT)} mm).")
    end
    private_class_method :check_drawers

    MIN_CORNER_SIZE = 500.0
    MIN_L_ARM = 150.0

    # A corner unit must be square (its one door runs diagonally corner to
    # corner) and big enough for that diagonal door to be a sensible size.
    # A corner unit's outer footprint is a square sized by Width; its Depth is
    # the return length of the shortened right-side and front-return panels
    # (the same field, same meaning, as any other cabinet's Depth -- so it can
    # be set to match a neighbouring run). Depth must leave room for those two
    # panels to meet the diagonal without overlapping, and for a sensible door.
    def self.check_corner(out, errors, bad)
      check_blind(out, errors, bad)
      return unless Defaults.corner?(out)
      return unless (bad & %w[width depth material_thickness]).empty? && out['width'] && out['depth']

      if out['width'] < MIN_CORNER_SIZE
        errors << error('width', "A corner unit must be at least #{fmt(MIN_CORNER_SIZE)} mm wide (minimum #{fmt(MIN_CORNER_SIZE)} mm).")
        return
      end

      if Defaults.corner_style(out) == 'l_shape'
        check_l_shape(out, errors)
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

    # An L-shaped corner: each leg's depth must leave room for the other leg's door (the same rules the
    # L-corner builder script uses: a leg's depth stays under the other leg's length less a panel).
    def self.check_l_shape(out, errors)
      t = out['material_thickness']
      la = out['width']
      da = out['depth']
      lb = out['leg2_length'].to_f.positive? ? out['leg2_length'] : la
      db = out['leg2_depth'].to_f.positive? ? out['leg2_depth'] : da
      if da >= lb - t
        errors << error('depth', "Leg 1 depth (#{fmt(da)} mm) must be less than leg 2 length (#{fmt(lb)} mm) minus a panel.")
      elsif lb - da < MIN_L_ARM
        errors << error('depth', "Leg 2 needs at least #{fmt(MIN_L_ARM)} mm of door beyond leg 1's depth.")
      end
      if db >= la - t
        errors << error('leg2_depth', "Leg 2 depth (#{fmt(db)} mm) must be less than leg 1 length (#{fmt(la)} mm) minus a panel.")
      elsif la - db < MIN_L_ARM
        errors << error('leg2_depth', "Leg 1 needs at least #{fmt(MIN_L_ARM)} mm of door beyond leg 2's depth.")
      end
    end
    private_class_method :check_l_shape

    # A blind corner: a door over the open part and a fixed panel over the blind part.
    def self.check_blind(out, errors, bad)
      return unless Defaults.corner_style(out) == 'blind' && (bad & %w[width]).empty? && out['width']

      blind = out['blind_width'].to_f
      room = out['width'] - (2 * out['door_reveal']) - out['door_gap']
      door = blind.positive? ? room - blind : (room - 50.0) / 2.0
      if door < MIN_DOOR_SIZE
        errors << error(blind.positive? ? 'blind_width' : 'width', "The blind corner's door would be only #{fmt(door.round(1))} mm wide (minimum #{fmt(MIN_DOOR_SIZE)} mm). Make the blind panel narrower or the unit wider.")
      elsif blind.positive? && blind < MIN_DOOR_SIZE
        errors << error('blind_width', "The blind panel must be at least #{fmt(MIN_DOOR_SIZE)} mm wide.")
      end
    end
    private_class_method :check_blind

    # A corner unit's single door is sized by check_corner (its width is a
    # diagonal, not the cabinet's own Width), so the usual width-based door-fit
    # check below does not apply to it; the height check still does.
    def self.check_doors(out, door_count, errors, bad)
      return unless door_count.to_i.positive?

      count = door_count.to_i
      return if out['fridge'] # see check_fridge
      return if out['door_stacked'] && count == 2 # two doors one above the other: see check_stacked

      if Defaults.corner_style(out).nil? && (bad & %w[width door_gap door_reveal]).empty? && out['width']
        door_width = (out['width'] - (2 * out['door_reveal']) - ((count - 1) * out['door_gap'])) / count
        if door_width < MIN_DOOR_SIZE
          errors << error('width', "Each door would be only #{fmt(door_width.round(1))} mm wide (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
        end
      end

      return check_split(out, errors, bad) if out['door_split']
      return unless (bad & %w[height door_reveal]).empty? && out['height'] && !out['front_zone'].to_f.positive? && !out['bottom_zone'].to_f.positive?

      door_height = out['height'] - (2 * out['door_reveal'])
      return unless door_height < MIN_DOOR_SIZE

      errors << error('height', "Doors would be only #{fmt(door_height.round(1))} mm high (minimum #{fmt(MIN_DOOR_SIZE)} mm).")
    end
    private_class_method :check_doors

    # ---- filler -----------------------------------------------------------

    # A filler is a single board beside a cabinet: no catalog, doors, shelves or
    # material of its own (it follows the cabinet's door material, see PartManager).
    # A filler can be far narrower than a cabinet, so it has its own width limits.
    FILLER_FIELDS = {
      'width'     => { label: 'Filler width', min: 5.0, max: 1000.0, required: true },
      'thickness' => { label: 'Filler thickness', min: 3.0, max: 60.0, required: true },
      'height'    => { label: 'Filler height', min: 50.0, max: 3000.0, required: true }
    }.freeze

    # Only its own size is validated here. Where it goes (which cabinet, which
    # side, how high off the floor) and its material come from the cabinet it is
    # inserted against, see PartManager.
    def self.validate_filler(raw)
      raw = stringify_keys(raw)
      errors = []
      out = { 'part_kind' => 'filler' }

      FILLER_FIELDS.each do |key, spec|
        value, problem = numeric_field(raw, key, spec)
        out[key] = value unless value.nil?
        errors << problem if problem
      end

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
      out['toe_kick_cover_row'] = truthy?(raw['toe_kick_cover_row']) # pieces of the chosen length over the whole row

      Result.new(out, errors)
    end

    # ---- worktop ------------------------------------------------------------

    WORKTOP_FIELDS = {
      'worktop_thickness' => { label: 'Worktop thickness', min: 10.0, max: 100.0, required: true },
      'worktop_front'     => { label: 'Front overhang', min: 0.0, max: 100.0, required: true },
      'worktop_end'       => { label: 'End overhang', min: 0.0, max: 200.0, required: true },
      'worktop_piece'     => { label: 'Piece length', min: 0.0, max: 10_000.0 },
      'worktop_round'     => { label: 'Front edge radius', min: 0.0, max: 100.0 },
      'backsplash_height' => { label: 'Back splash height', min: 0.0, max: 1000.0 }
    }.freeze

    def self.validate_worktop(raw)
      raw = stringify_keys(raw)
      errors = []
      out = { 'material' => Defaults::DEFAULT_MATERIAL }
      WORKTOP_FIELDS.each do |key, spec|
        value, problem = numeric_field(raw, key, spec)
        out[key] = value unless value.nil?
        errors << problem if problem
      end
      material = raw['material'].to_s.strip
      out['material'] = material unless material.empty?
      out['backsplash_material'] = raw['backsplash_material'].to_s.strip # blank: the material of the worktop

      # Where to cut: distances from the start of a run, all positive numbers.
      cuts = raw['worktop_cuts'].to_s.strip
      if cuts.empty?
        out['worktop_cuts'] = ''
      elsif (list = Worktop.parse_cuts(cuts))
        out['worktop_cuts'] = list.map { |v| format('%g', v) }.join(',')
      else
        errors << error('worktop_cuts', 'Cut at: give distances like 1500, 3000 (positive numbers, separated by commas).')
      end
      Result.new(out, errors)
    end

    # ---- end panel ----------------------------------------------------------

    END_PANEL_FIELDS = {
      'depth'     => { label: 'End panel depth', min: 10.0, max: 1500.0, required: true },
      'thickness' => { label: 'End panel thickness', min: 6.0, max: 60.0, required: true },
      'height'    => { label: 'End panel height', min: 50.0, max: 3500.0, required: true }
    }.freeze

    # An end panel is which side it sits on, its own depth, thickness and height,
    # and its material. (PartManager fills a blank depth and height in from what
    # it is attached to: the door front and the top.)
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

      # "Same as door material" (the default) follows the door of what it is
      # attached to; a named material is the user's own choice and stays.
      choice = raw['material'].to_s.strip
      out['material_choice'] = choice.empty? ? Defaults::SAME_AS_DOOR : choice

      # Its outer face: flat, or in the front design that was selected (kept with it, so a later Update does not lose it).
      out['face'] = raw['face'].to_s == 'design' ? 'design' : 'flat'
      out['front_design'] = FrontDesign.clean(raw['front_design'])
      # The radius of its rounded outer edges, as on the doors.
      radius, problem = numeric_field(raw, 'front_radius', { label: 'Front edge radius', min: 0.0, max: 9.0 })
      out['front_radius'] = radius.nil? ? Defaults.params['front_radius'] : radius
      errors << problem if problem

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

    def self.truthy_value?(value) = truthy?(value)

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
