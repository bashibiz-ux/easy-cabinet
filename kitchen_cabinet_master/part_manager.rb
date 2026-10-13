# frozen_string_literal: true

module KitchenCabinetMaster
  # Entry point for the Filler, Side Panel and Toe Kick actions: insert_filler,
  # insert_end_panel, insert_toe_kick, update_part, delete_part. Mirrors
  # CabinetManager's shape (validate, wrap in one undoable operation, reply with
  # a Response) but for the much simpler parts: no catalog, no doors, no handles.
  module PartManager
    def self.perform(action, raw)
      case action
      when 'insert_filler' then insert_filler(raw)
      when 'insert_end_panel' then insert_end_panel(raw)
      when 'insert_panel' then insert_panel(raw)
      when 'insert_exposed_side_panels' then insert_exposed_side_panels(raw)
      when 'insert_toe_kick' then insert_toe_kick(raw)
      when 'apply_toe_kicks' then apply_toe_kicks(raw)
      when 'update_placed' then update_placed(raw)
      when 'update_part' then update_part(raw)
      when 'delete_part' then delete_part
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # ---- filler ---------------------------------------------------------------

    # A filler goes against a cabinet: the selected one (else the last one
    # inserted), on its wall side, with its front face flush with the door. The
    # side is the one with nothing against it (the right when both are free, so a
    # cabinet inserted next carries on after the filler). Its base height comes
    # from the cabinet, and it always takes the cabinet's door material (it has no
    # material of its own, and follows the cabinet when that changes, see
    # follow_door). What it needs from the cabinet is copied into its stored
    # parameters, so a later Update never has to look the cabinet up again.
    def self.insert_filler(raw)
      model = Sketchup.active_model
      target = SelectionManager.selected_cabinet(model) || PlacementManager.last_cabinet(model)
      unless target
        return Response.fail('Select the cabinet the filler goes beside. It is placed on its wall side, flush with the door.')
      end

      target_params = AttributeManager.read(target)
      # A filler is as tall as the unit it stands beside (a tall filler for a tall
      # unit, a base one for a base unit, a wall one for a wall unit) unless the
      # user typed a height of their own.
      raw = stringify(raw)
      raw['height'] = target_params['height'] if truthy?(raw['height_auto']) || raw['height'].to_s.strip.empty?
      params, failure = prepare_filler(raw, door_material_of(target_params))
      return failure if failure

      params.merge!(filler_target(target, target_params))
      transformation, side, problem = filler_placement(target, params)
      return Response.fail(problem) if problem

      params['side'] = side
      layout = PartLayout.filler(params)
      entities = target.parent.entities
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Filler') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['sequence'] = AttributeManager.next_sequence(model)
          params['part_name'] = NamingManager.unique_name(entities, NamingManager.filler_name(params))
          PartGenerator.build(model, entities, params, transformation, layout)
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted on the #{side} of #{target.name}.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_filler

    # A filler `width` wide beside a cabinet that is already built (the gap after a blind corner), at `offset` along the
    # cabinet's own Y axis (negative: before it). As tall as the cabinet, flush with its doors, in its door material.
    # Call inside an operation; selects nothing. Returns the filler, or nil when it could not be made.
    def self.add_filler_beside(model, entities, target, offset, width)
      target_params = AttributeManager.read(target)
      raw = { 'width' => width, 'thickness' => Defaults.filler_params['thickness'], 'height' => target_params['height'] }
      params, failure = prepare_filler(raw, door_material_of(target_params))
      return nil if failure

      params.merge!(filler_target(target, target_params))
      params['side'] = offset.negative? ? 'left' : 'right'
      transformation = target.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, offset.mm, 0))
      params['part_id'] = AttributeManager.next_part_id(model)
      params['sequence'] = AttributeManager.next_sequence(model)
      params['part_name'] = NamingManager.unique_name(entities, NamingManager.filler_name(params))
      PartGenerator.build(model, entities, params, transformation, PartLayout.filler(params))
    end

    # What a filler needs from the cabinet it goes against. `target_flush_x` is the
    # door front: the carcass depth plus the door clearance and door thickness (a
    # corner unit is a square with nothing standing proud of it).
    # A tall L corner unit: its two arms end in the room (the sides of a row that ends at the corner), each as deep as a tall unit; a base L corner
    # has no side panels of its own (its arms meet the units of both rows).
    def self.arm_corner?(params)
      CabinetLayout.corner?(params) && params['cabinet_category'].to_s == 'tall' && CabinetLayout.corner_style(params) == 'l_shape'
    end
    private_class_method :arm_corner?

    # The sides of a unit that can have a panel: its two ends, and the end of the second arm of a tall L corner ('front': the end that faces the
    # way the row came from).
    def self.panel_sides(params)
      arm_corner?(params) ? %w[left right front] : %w[left right]
    end
    private_class_method :panel_sides

    def self.filler_target(target, target_params)
      corner = CabinetLayout.corner?(target_params) && !arm_corner?(target_params)
      depth = (corner ? CabinetLayout.corner_extent(target_params) : target_params['depth']).to_f
      flush = corner ? depth : depth + CabinetLayout.door_distance(target_params) + target_params['material_thickness'].to_f
      {
        'target_id' => AttributeManager.cabinet_id(target),
        'target_width' => target_params['width'].to_f,
        'target_depth' => depth,
        'target_base_z' => target_params['base_z'].to_f,
        'target_category' => target_params['cabinet_category'],
        'target_flush_x' => flush
      }
    end
    private_class_method :filler_target

    # Directly against the cabinet's right or left face, in the cabinet's own
    # frame (so it follows its position and rotation). The first side with room
    # wins: right, then left.
    def self.filler_placement(target, params)
      entities = target.parent.entities
      size = PartLayout.filler_envelope(params)
      sides = {
        'right' => params['target_width'],
        'left' => -params['width']
      }
      sides.each do |side, offset|
        transformation = target.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, offset.mm, 0))
        return [transformation, side, nil] unless PlacementManager.collides?(entities, transformation, size)
      end
      [nil, nil, "Both sides of #{target.name} already have something against them, so there is no room for a filler."]
    end
    private_class_method :filler_placement

    # The door colour recorded on a cabinet or filler (never blank).
    def self.door_material_of(stored)
      material = stored['material'].to_s
      material.empty? ? CabinetGenerator.door_material(stored) : material
    end
    private_class_method :door_material_of

    # ---- side panel --------------------------------------------------------------

    # The target (whatever cabinet or filler is currently selected) is read once,
    # here, at Insert time. Its own size is copied into the side panel's stored
    # parameters, so later Updates never need to re-find the target (see
    # PartLayout.end_panel and PartGenerator.attributes_for).
    def self.insert_end_panel(raw)
      model = Sketchup.active_model
      target = SelectionManager.selected_occupant(model)
      return Response.fail('Select a cabinet or filler first, then choose which side gets the side panel.') unless target

      target_params = AttributeManager.read(target)
      filler = AttributeManager.part_kind(target) == 'filler'
      door = door_material_of(target_params)
      carcass = filler ? door : CabinetGenerator.carcass_material(target_params, door)
      raw = to_floor(raw, target, target_params)

      # Depth and height are the panel's own to set. Left blank they start as the
      # target's: depth flush with its door front, height up to its top.
      params, failure = prepare_end_panel(end_panel_defaults(raw, target, target_params), door, carcass)
      return failure if failure

      # Recorded so the side panel can follow the door colour if that changes (follow_door).
      params['target_door_material'] = door
      params['target_carcass_material'] = carcass
      params['target_id'] = target.get_attribute(AttributeManager::DICTIONARY, 'cabinet_id') ||
                            target.get_attribute(AttributeManager::DICTIONARY, 'part_id')
      params['target_width'] = target_params['width'].to_f
      x_start = stringify(raw)['x_start'].to_f # a panel that starts this far from the back of the carcass ...
      params['target_base_z'] = panel_base(raw, target, target_params) # ... and this high (the floor too, when it is asked for)

      layout = PartLayout.end_panel(params)
      transformation, collision = placed_transformation(target, params, x_start)
      return Response.fail(collision) if collision

      root = SelectionManager.suspend do
        with_operation(model, 'Insert Side Panel') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(target.parent.entities, NamingManager.end_panel_name(params))
          PartGenerator.build(model, target.parent.entities, params, transformation, layout)
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted on the #{params['side']}.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_end_panel

    # A side panel on every exposed side of the selected cabinets (of every cabinet and filler in the model when none is selected): each side
    # is tried, and one that has something against it (a neighbour, a wall unit's cabinet, a panel already there) is not exposed and is
    # left alone. One Undo step.
    def self.insert_exposed_side_panels(raw)
      model = Sketchup.active_model
      chosen = model.selection.select { |entity| AttributeManager.cabinet?(entity) || AttributeManager.part_kind(entity) == 'filler' }
      targets = chosen.empty? ? model.entities.select { |entity| AttributeManager.cabinet?(entity) || AttributeManager.part_kind(entity) == 'filler' } : chosen
      return Response.fail('There is nothing to put side panels on: insert a cabinet first.') if targets.empty?

      made = 0
      covered = 0
      problems = []
      model.start_operation('Side Panels on Exposed Sides', true)
      @batch = true
      begin
        remove_corner_panels(model) # (a panel on a corner unit is a stray one: the notch of the L is not a side)
        tallest_first(targets).each do |target|
          panel_sides(AttributeManager.read(target)).each do |side|
            did, skipped, trouble = place_exposed_panels(model, target, side, raw)
            made += did
            covered += skipped
            problems.concat(trouble)
          end
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @batch = false
      end
      model.selection.clear
      targets.each { |target| model.selection.add(target) if target.valid? }
      message = "#{made} side panel#{'s' unless made == 1} placed on #{made == 1 ? 'an exposed side' : 'exposed sides'}"
      message += " (#{covered} side#{'s' unless covered == 1} already had something against #{covered == 1 ? 'it' : 'them'})" if covered.positive?
      message += ". #{problems.uniq.first(2).join(' ')}" unless problems.empty?
      Response.ok("#{message}.".sub('..', '.'), { 'count' => made })
    end
    private_class_method :insert_exposed_side_panels

    # Takes away any side panel that stands on a corner unit (older versions put them in the notch of the L).
    def self.remove_corner_panels(model)
      corners = model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.cabinet?(item) && CabinetLayout.corner?(AttributeManager.read(item)) && !arm_corner?(AttributeManager.read(item)) }
      ids = corners.map { |item| AttributeManager.cabinet_id(item) }.compact
      return if ids.empty?

      model.entities.grep(Sketchup::ComponentInstance).each do |part|
        next unless AttributeManager.part_kind(part) == 'end_panel'

        PartGenerator.remove(model, part) if ids.include?(AttributeManager.read(part)['target_id'])
      end
    end
    private_class_method :remove_corner_panels

    # The side panel one side of one cabinet needs: ONE panel, the whole depth of the carcass (never two pieces), or none when the side is wholly
    # covered by what stands against it. Its height:
    #   - an inner side (a unit beside it): only the side of the unit itself, from the bottom of its carcass to its top, not down through the toe kick;
    #   - an outer side (nothing beside it): from the floor to the top of the unit. A wall unit's panel is always only on the unit (see panel_span).
    # A unit that stands against a side that is only partly covered (a lower or a shallower one) is moved along, and every unit after it in the row,
    # by the thickness of the panel, to make room for it (not in the Auto Kitchen, which made the room itself).
    # The panel's own values (thickness, material, face, ...) are `raw`. => [panels made, sides left alone because covered, problems]
    def self.place_exposed_panels(model, target, side, raw)
      target_params = AttributeManager.read(target)
      return [0, 1, []] if side == 'front' && !arm_corner?(target_params)
      return [0, 1, []] if CabinetLayout.corner?(target_params) && !arm_corner?(target_params) # (a corner unit is L shaped: its sides meet the units of both rows, and the notch of the L is not a side)
      return [0, 1, []] if side == 'left' && arm_corner?(target_params) # (the wall side of a tall L corner: its carcass stands against the wall)
      return place_corner_front_panel(model, target, target_params, raw) if side == 'front'

      return [0, 1, []] if target_params['free_housing'] == true # (a housing for a freestanding fridge has its own two side panels, full height: another one on each would double them)

      thickness = stringify(raw)['thickness'].to_f
      rectangles, touching, near = side_rectangles(target, target_params, side, thickness + 3.0)
      return [0, 1, []] if rectangles.empty?

      # The end of a row at a wall: touching it, nothing shows; a little way from it, a filler fills the gap instead of a side panel.
      if raw['auto'] == true && touching.empty? && !arm_corner?(target_params) && (gap = wall_gap(model, target, side))
        return [0, 1, []] if gap < 1.0

        return fill_to_wall(model, target, target_params, side, gap)
      end

      shift_chain(target, side, touching, thickness) if touching.any? && thickness.positive? && raw['shift'] != false

      filler = AttributeManager.part_kind(target) == 'filler'
      hangs = (filler ? target_params['target_category'] : target_params['cabinet_category']).to_s == 'wall'
      carcass = start_z_of(target, target_params)
      inner = raw.key?('inner') ? raw['inner'] == true : (touching.any? || near) # (the Auto Kitchen says which sides are inner: it knows the rows)
      inner = true unless !raw.key?('to_floor') || truthy?(raw['to_floor']) # (the Side Panel card: only on the cabinet, the toe kick runs under it)
      from, top = SideExposure.panel_span(inner: inner, hangs: hangs, carcass: carcass, top: top_of(target_params))
      model.selection.clear
      model.selection.add(target)
      values = stringify(raw).merge('side' => side, 'depth' => door_front_of(target, target_params), 'height' => top - from, 'x_start' => 0.0, 'raise' => from)
      values.delete('depth_auto')
      values.delete('height_auto')
      answer = insert_end_panel(values)
      if answer['ok']
        mark_auto(model) if raw['auto'] == true # (this panel was placed by the tick in the Presets)
        [1, 0, []]
      elsif answer['message'].to_s.include?('already has something against it')
        [0, 1, []]
      else
        [0, 0, [answer['message']]]
      end
    end

    # The end of the second arm of a tall L corner (the face of the square that looks the way the row came from): a panel across it, turned a
    # quarter, when nothing stands against that end. Marked 'corner_arm' so that Update leaves it where it is.
    def self.place_corner_front_panel(model, target, target_params, raw)
      values = stringify(raw)
      thickness = values['thickness'].to_f
      return [0, 1, []] unless thickness.positive?

      width = target_params['width'].to_f
      arm = door_front_of(target, target_params)
      inverse = target.transformation.inverse
      base = start_z_of(target, target_params)
      covered = target.parent.entities.grep(Sketchup::ComponentInstance).any? do |other|
        next false if other.equal?(target) || !AttributeManager.occupant?(other)

        box = occupant_box(inverse, other)
        box[:x0] <= width + 3.0 && box[:x0] >= width - 1.0 && box[:x1] > width + 1.0 && box[:y0] < arm - 1.0 && box[:y1] > 1.0 && box[:z1] > base + 1.0
      end
      return [0, 1, []] if covered

      from, top = SideExposure.panel_span(inner: false, hangs: false, carcass: base, top: top_of(target_params))
      door = door_material_of(target_params)
      carcass = CabinetGenerator.carcass_material(target_params, door)
      params, failure = prepare_end_panel(values.merge('side' => 'right', 'depth' => arm, 'height' => top - from), door, carcass)
      return [0, 0, [failure['message']]] if failure

      params['side'] = 'front'
      params['corner_arm'] = 'front'
      params['target_door_material'] = door
      params['target_carcass_material'] = carcass
      params['target_id'] = AttributeManager.cabinet_id(target)
      params['target_width'] = width
      params['target_base_z'] = from
      layout = PartLayout.end_panel(params)
      turn = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), Math::PI / 2)
      transformation = target.transformation * Geom::Transformation.translation(Geom::Vector3d.new((width + thickness).mm, 0, 0)) * turn
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Side Panel') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(target.parent.entities, NamingManager.end_panel_name(params))
          PartGenerator.build(model, target.parent.entities, params, transformation, layout)
        end
      end
      root.set_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO, true) if values['auto'] == true
      [1, 0, []]
    end
    private_class_method :place_corner_front_panel

    private_class_method :place_exposed_panels

    # The widest gap between a cabinet and a wall that a filler fills (mm); a wall further away leaves the end of the row open, with a side panel.
    WALL_FILL_MAX = 200.0

    # How far (mm) the wall beyond the `side` of `target` is from that side, or nil when there is no wall within WALL_FILL_MAX: a tall vertical face
    # across the row, as high as the cabinet and along at least half its depth.
    def self.wall_gap(model, target, side)
      walls = SnapManager.send(:collect_walls, model, nil)
      return nil if walls.empty?

      transform = target.transformation
      params = AttributeManager.read(target)
      turn = side == 'left' ? -1.0 : 1.0
      along = transform.yaxis
      across = transform.xaxis
      dx = along.x * turn
      dy = along.y * turn
      fx = across.x
      fy = across.y
      origin = transform.origin
      edge = side == 'left' ? origin : origin + Geom::Vector3d.new(along.x * params['width'].to_f.mm, along.y * params['width'].to_f.mm, 0)
      back = (origin.x * fx) + (origin.y * fy)
      front = back + door_front_of(target, params).mm
      low = origin.z.to_f
      high = low + top_of(params).mm
      best = nil
      walls.each do |wall|
        nx, ny = wall[:normal]
        next unless ((nx * dx) + (ny * dy)).abs > 0.985
        next unless [high, wall[:z][1]].min - [low, wall[:z][0]].max > 0

        reach = wall[:points].map { |x, y| (x * fx) + (y * fy) }
        next unless [front, reach.max].min - [back, reach.min].max >= (front - back) * 0.5

        x, y = wall[:points].first
        gap = (((x * dx) + (y * dy)) - ((edge.x * dx) + (edge.y * dy))).to_mm
        next if gap < -1.0 || gap > WALL_FILL_MAX

        best = gap if best.nil? || gap.abs < best.abs
      end
      best && [best, 0.0].max
    end
    private_class_method :wall_gap

    # A filler `gap` mm wide in the space between the side of `target` and the wall, in the Presets tick's way (marked, so it follows the cabinets).
    def self.fill_to_wall(model, target, target_params, side, gap)
      offset = side == 'left' ? -gap : target_params['width'].to_f
      filler = add_filler_beside(model, target.parent.entities, target, offset, gap)
      return [0, 0, ["No filler could be made against the wall beside #{target.name}."]] unless filler

      filler.set_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO, true)
      [1, 0, []]
    end
    private_class_method :fill_to_wall

    # Moves `first` (the units against one side of `target`) and every unit that follows them along the row, `distance` mm away from the target. The
    # parts that are against them (fillers, side panels) go along; the worktop is built again where it is.
    def self.shift_chain(target, side, first, distance)
      entities = target.parent.entities
      inverse = target.transformation.inverse
      sign = side == 'left' ? -1.0 : 1.0
      boxes = entities.grep(Sketchup::ComponentInstance).select { |other| !other.equal?(target) && AttributeManager.occupant?(other) }.to_h { |other| [other, occupant_box(inverse, other)] }
      moving = first.dup
      loop do
        found = boxes.keys.reject { |other| moving.any? { |member| member.equal?(other) } }.select do |other|
          box = boxes[other]
          moving.any? do |member|
            reference = boxes[member]
            next false unless reference

            gap = sign.positive? ? box[:y0] - reference[:y1] : reference[:y0] - box[:y1]
            gap.abs <= 3.0 && box[:x1] > reference[:x0] + 1.0 && box[:x0] < reference[:x1] - 1.0
          end
        end
        break if found.empty?

        moving.concat(found)
      end
      step = target.transformation.yaxis
      step.length = distance.mm
      step = Geom::Vector3d.new(step.x * sign, step.y * sign, step.z * sign)
      entities.transform_entities(Geom::Transformation.translation(step), moving)
      WorktopManager.refresh(Sketchup.active_model) if WorktopManager.respond_to?(:refresh)
    end
    private_class_method :shift_chain

    # The box a unit takes, in the frame of `inverse`'s object: { x0:, x1:, y0:, y1:, z0:, z1: } in millimetres (a hanging unit from where it starts).
    def self.occupant_box(inverse, other)
      stored = AttributeManager.read(other) || {}
      size = %w[envelope_depth envelope_width envelope_top].map { |key| other.get_attribute(AttributeManager::DICTIONARY, key).to_f }
      points = [0, size[0]].product([0, size[1]], [0, size[2]]).map { |x, y, z| inverse * (other.transformation * Geom::Point3d.new(x.mm, y.mm, z.mm)) }
      floor = stored['cabinet_category'].to_s == 'wall' || stored['target_category'].to_s == 'wall' ? (stored['base_z'] || stored['target_base_z']).to_f : stored['target_base_z'].to_f
      { x0: points.map { |p| p.x.to_mm }.min, x1: points.map { |p| p.x.to_mm }.max, y0: points.map { |p| p.y.to_mm }.min, y1: points.map { |p| p.y.to_mm }.max,
        z0: points.map { |p| p.z.to_mm }.min + floor, z1: points.map { |p| p.z.to_mm }.max }
    end
    private_class_method :occupant_box

    # What the side panels of the Presets tick are: marked, so that they can be taken away and placed again (a panel you inserted yourself is not).
    def self.mark_auto(model)
      panel = model.selection.to_a.first
      panel.set_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO, true) if panel
    end
    private_class_method :mark_auto

    def self.auto_panels(model) # (the side panels and the fillers at a wall that the tick made)
      model.entities.grep(Sketchup::ComponentInstance).select { |part| %w[end_panel filler].include?(AttributeManager.part_kind(part)) && part.get_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO) == true }
    end
    private_class_method :auto_panels

    def self.remove_auto_panels(model)
      auto_panels(model).each { |part| PartGenerator.remove(model, part) if part.valid? }
    end
    private_class_method :remove_auto_panels

    # The Side Panel card's "to the floor" option: on the end of a row (nothing against that side) the panel starts at the floor; without it, or on a side
    # that has a unit against it, it stands only on the cabinet (from the bottom of its carcass).
    def self.to_floor(raw, target, target_params)
      values = stringify(raw)
      return values unless truthy?(values['to_floor']) && !wall_item?(target) && values['raise'].to_s.strip.empty?

      _rectangles, touching, _near = side_rectangles(target, target_params, values['side'].to_s, values['thickness'].to_f + 3.0)
      return values unless touching.empty?

      values.merge('raise' => 0.0, 'height' => top_of(target_params), 'height_auto' => false)
    end
    private_class_method :to_floor

    # A side panel on every side that shows, of every cabinet and filler (inside an operation of its own, see LiveParts).
    def self.place_auto_panels(model, values)
      targets = model.entities.select { |entity| AttributeManager.cabinet?(entity) || AttributeManager.part_kind(entity) == 'filler' }
      return 0 if targets.empty?

      made = 0
      problems = []
      @batch = true
      begin
        panel_values = stringify(values).merge('auto' => true)
        tallest_first(targets).each do |target|
          id = AttributeManager.cabinet_id(target) || AttributeManager.part_id(target)
          panel_sides(AttributeManager.read(target)).each do |side|
            next if LiveParts.dismissed?("side:#{id}:#{side}") # (taken away with Delete)

            begin
              answer = place_exposed_panels(model, target, side, panel_values)
              made += answer[0]
              problems.concat(answer[2])
            rescue StandardError => e
              problems << "#{target.name} (#{side}): #{e.message} at #{Array(e.backtrace).first.to_s[/\w+\.rb:\d+/]}"
            end
          end
        end
      ensure
        @batch = false
      end
      model.selection.clear
      DialogManager.push('notice', { 'message' => "A side panel could not be placed: #{problems.uniq.first(2).join('; ')}" }) if !problems.empty? && defined?(DialogManager)
      made
    end
    private_class_method :place_auto_panels

    # The toe kicks of the Presets tick: marked, so that they can be taken away and placed again (a toe kick you inserted yourself is not).
    def self.auto_toe_kicks(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |part| AttributeManager.part_kind(part) == 'toe_kick' && part.get_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO_TOE) == true }
    end
    private_class_method :auto_toe_kicks

    def self.remove_auto_toe_kicks(model)
      auto_toe_kicks(model).each { |part| PartGenerator.remove(model, part) if part.valid? }
    end
    private_class_method :remove_auto_toe_kicks

    # A toe kick under each row: the one that carries on from the first unit (turning at the corners, see ToeKick.turns_from), and one under the first
    # unit of an island, each made by the Insert Toe Kick code against its unit (inside an operation of its own, see LiveParts).
    def self.place_auto_toe_kicks(model, values)
      units = model.entities.grep(Sketchup::ComponentInstance).select { |item| (AttributeManager.cabinet?(item) || AttributeManager.part_kind(item) == 'filler') && !wall_item?(item) }
      return 0 if units.empty?

      sequence = ->(item) { item.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i }
      island = units.select { |item| !item.get_attribute(AttributeManager::DICTIONARY, 'island_seating').nil? }.min_by(&sequence)
      anchors = [units.min_by(&sequence), island].compact.uniq
      made = 0
      @batch = true
      begin
        anchors.each do |anchor|
          next if LiveParts.dismissed?("toe:#{AttributeManager.cabinet_id(anchor) || AttributeManager.part_id(anchor)}") # (taken away with Delete)

          model.selection.clear
          model.selection.add(anchor)
          answer = insert_toe_kick(stringify(values).merge('toe_kick_cover_row' => true))
          next unless answer['ok']

          made += 1
          model.selection.to_a.first&.set_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO_TOE, true)
        end
      ensure
        @batch = false
      end
      model.selection.clear
      made
    end
    private_class_method :place_auto_toe_kicks

    # The highest units first, so that the panel of a tall unit is the one that stands in the room between it and a lower unit.
    def self.tallest_first(targets)
      targets.sort_by { |target| -top_of(AttributeManager.read(target)).to_f }
    end
    private_class_method :tallest_first

    # The rectangles of one side of a cabinet that show (see SideExposure): the cabinets, fillers and side panels that touch the side hide the
    # part they cover. [[x0, z0, x1, z1]] in millimetres, in the cabinet's own frame (x from the back of the carcass).
    def self.side_rectangles(target, target_params, side, reach = 3.0)
      depth = door_front_of(target, target_params)
      base = start_z_of(target, target_params)
      top = top_of(target_params)
      width = target_params['width'].to_f
      inverse = target.transformation.inverse
      tolerance = 3.0
      neighbours = []
      near = false # a unit within reach of the side (touching it, or a panel's thickness away), whatever its height
      target.parent.entities.grep(Sketchup::ComponentInstance).each do |other|
        next if other.equal?(target) || !AttributeManager.occupant?(other)

        stored = AttributeManager.read(other) || {}
        size = %w[envelope_depth envelope_width envelope_top].map { |key| other.get_attribute(AttributeManager::DICTIONARY, key).to_f }
        points = [0, size[0]].product([0, size[1]], [0, size[2]]).map { |x, y, z| inverse * (other.transformation * Geom::Point3d.new(x.mm, y.mm, z.mm)) }
        xs = points.map { |p| p.x.to_mm }
        ys = points.map { |p| p.y.to_mm }
        zs = points.map { |p| p.z.to_mm }
        touches = side == 'left' ? (ys.max >= -tolerance && ys.max <= 1.0 && ys.min < -1.0) : (ys.min <= width + tolerance && ys.min >= width - 1.0 && ys.max > width + 1.0)
        close = side == 'left' ? (ys.max >= -reach && ys.max <= 1.0 && ys.min < -1.0) : (ys.min <= width + reach && ys.min >= width - 1.0 && ys.max > width + 1.0)
        near ||= close && xs.max > 1.0 && xs.min < depth - 1.0
        next unless touches

        floor = stored['cabinet_category'].to_s == 'wall' || stored['target_category'].to_s == 'wall' ? (stored['base_z'] || stored['target_base_z']).to_f : stored['target_base_z'].to_f
        low = zs.min + floor
        high = zs.max
        next unless xs.max > 1.0 && xs.min < depth - 1.0 && high > base + 1.0 && low < top - 1.0

        neighbours << { x0: xs.min, x1: xs.max, z0: low, z1: high, ref: other }
      end
      [SideExposure.uncovered({ depth: depth, base: base, top: top }, neighbours), neighbours.map { |n| n[:ref] }, near]
    end
    private_class_method :side_rectangles

    def self.end_panel_defaults(raw, target, target_params)
      raw = stringify(raw)
      raw['depth'] = door_front_of(target, target_params) if truthy?(raw['depth_auto']) || raw['depth'].to_s.strip.empty?
      raw['height'] = top_of(target_params) - start_z_of(target, target_params) if truthy?(raw['height_auto']) || raw['height'].to_s.strip.empty?
      raw
    end

    # How high the panel starts: the `raise` it was asked for (0 is the floor), else the bottom of the carcass of the unit it is on.
    def self.panel_base(raw, target, target_params)
      asked = stringify(raw)['raise']
      asked.nil? || asked.to_s.strip.empty? ? start_z_of(target, target_params) : asked.to_f
    end
    private_class_method :panel_base

    # Where a side panel starts: at the bottom of the carcass of the unit it is on (above its toe kick, or where a wall unit hangs), so that it is
    # exactly as high as that unit and does not run down to the floor.
    def self.start_z_of(target, target_params)
      filler = AttributeManager.part_kind(target) == 'filler'
      (filler ? target_params['target_base_z'] : target_params['base_z']).to_f
    end
    private_class_method :start_z_of

    def self.truthy?(value)
      [true, 'true', 1, '1'].include?(value)
    end
    private_class_method :truthy?
    private_class_method :end_panel_defaults

    # X of the target's door front: what an side panel's depth starts as, so the
    # panel stands flush with the doors. A filler's front is where it was flush to.
    def self.door_front_of(target, target_params)
      return target_params['target_flush_x'].to_f if AttributeManager.part_kind(target) == 'filler'

      filler_target(target, target_params)['target_flush_x']
    end
    private_class_method :door_front_of

    # Floor to the top of the target: what an side panel's height starts as.
    def self.top_of(target_params)
      (target_params['envelope_top'] || CabinetLayout.envelope(target_params)[2]).to_f
    end
    private_class_method :top_of

    # Directly against the target's left or right face, in the target's own
    # coordinate frame (so it follows the target's position and rotation).
    # Refuses (rather than sliding, like a row insert would) if that side is
    # already occupied: an side panel belongs on a genuinely exposed face.
    def self.placed_transformation(target, params, x_start = 0.0)
      offset = params['side'] == 'left' ? -params['thickness'] : params['target_width']
      transformation = target.transformation * Geom::Transformation.translation(Geom::Vector3d.new(x_start.mm, offset.mm, 0))

      # The space the panel takes: from where it starts up to its top (a panel beside a wall unit or above a lower cabinet does not start on the floor).
      lifted = transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, 0, params['target_base_z'].to_f.mm))
      size = [params['depth'].to_f, params['thickness'].to_f, params['height'].to_f]
      if occupied?(target.parent.entities, lifted, size)
        return [nil, "The #{params['side']} side of #{target.name} already has something against it."]
      end

      [transformation, nil]
    end
    private_class_method :placed_transformation

    # Does the box (positioned by `transformation`, size in millimetres) share space with a cabinet, filler or side panel? Like
    # PlacementManager.collides?, but a unit that hangs (a wall unit, a panel that starts above the floor) only takes the space from where it starts.
    def self.occupied?(entities, transformation, size)
      box = PlacementManager.box_for(transformation, size.map(&:mm))
      entities.grep(Sketchup::ComponentInstance).any? do |other|
        next false unless AttributeManager.occupant?(other)

        stored = AttributeManager.read(other) || {}
        extent = %w[envelope_depth envelope_width envelope_top].map { |key| other.get_attribute(AttributeManager::DICTIONARY, key).to_f.mm }
        found = PlacementManager.box_for(other.transformation, extent)
        from = stored['cabinet_category'].to_s == 'wall' ? stored['base_z'].to_f : stored['target_base_z'].to_f
        found[:min][2] += from.mm if from.positive?
        PlacementManager.overlap?(box, found)
      end
    end
    private_class_method :occupied?

    # ---- toe kick ---------------------------------------------------------------

    # A toe kick is its own entity, a run of equal pieces laid end to end. What it
    # goes against is decided by the selection, once, at Insert time:
    #
    #   a cabinet or filler  -> it starts at that item's left end, under its front,
    #                           set back `recess` from the carcass front
    #   another toe kick     -> it carries straight on from where that one ends
    #   nothing              -> at the origin, under a carcass as deep as the
    #                           panel's Depth field
    #
    # The depth and door / carcass colours it needs are copied into its stored
    # parameters, so a later Update never has to look the target up again.
    def self.insert_toe_kick(raw)
      model = Sketchup.active_model
      anchor = toe_kick_anchor(model)
      params, failure = prepare_toe_kick(raw, anchor)
      return failure if failure

      layout = PartLayout.toe_kick(params)
      entities, transformation = toe_kick_placement(model, anchor, params['toe_kick_lead'].to_f)
      if toe_kick_overlaps?(entities, transformation, params)
        return Response.fail('There is already a toe kick there. Select a different cabinet, or delete or change the existing toe kick first.')
      end

      root = SelectionManager.suspend do
        with_operation(model, 'Insert Toe Kick') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(entities, NamingManager.toe_kick_name(params))
          built = PartGenerator.build(model, entities, params, transformation, layout)
          # A new toe kick follows the Toe Kick tick in the Visibility section.
          built.visible = false if raw.is_a?(Hash) && [false, 'false', 0, '0'].include?(raw['visible'])
          built
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted: #{layout.toe_kick.length} piece#{'s' unless layout.toe_kick.length == 1}, " \
                  "#{format('%g', ToeKick.total_length(params))} mm long.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_toe_kick

    # The selected toe kick (to carry on from it), else the selected cabinet or filler, else nil.
    def self.toe_kick_anchor(model)
      part = SelectionManager.selected_part(model)
      return part if part && AttributeManager.part_kind(part) == 'toe_kick'

      SelectionManager.selected_occupant(model) || PlacementManager.first_occupant(model) { |item| !wall_item?(item) }
    end
    private_class_method :toe_kick_anchor

    # A wall unit (or a filler beside one) hangs above the floor: it has no toe kick.
    def self.wall_item?(item)
      dictionary = AttributeManager::DICTIONARY
      (item.get_attribute(dictionary, 'cabinet_category') || item.get_attribute(dictionary, 'target_category')) == 'wall'
    end
    private_class_method :wall_item?

    def self.toe_kick_placement(model, anchor, lead = 0.0)
      return [model.active_entities, Geom::Transformation.new] unless anchor

      transformation = anchor.transformation
      transformation *= Geom::Transformation.translation(Geom::Vector3d.new(0, -lead.mm, 0)) if lead.positive? && AttributeManager.part_kind(anchor) != 'toe_kick'
      if AttributeManager.part_kind(anchor) == 'toe_kick'
        length = anchor.get_attribute(AttributeManager::DICTIONARY, 'width').to_f
        transformation *= Geom::Transformation.translation(Geom::Vector3d.new(0, length.mm, 0))
      end
      [anchor.parent.entities, transformation]
    end
    private_class_method :toe_kick_placement

    # Would a toe kick built from params at 	ransformation stand on top of another
    # toe kick in entities? Compares the plan-view outlines of the pieces (and their
    # floor level); touching ends do not count. exclude is the toe kick being updated.
    def self.toe_kick_overlaps?(entities, transformation, params, exclude: nil)
      mine = toe_kick_boxes(transformation, params)
      entities.grep(Sketchup::ComponentInstance).any? do |other|
        next false unless AttributeManager.part_kind(other) == 'toe_kick' && !other.equal?(exclude)

        theirs = toe_kick_boxes(other.transformation, AttributeManager.read(other) || {})
        mine.any? { |a| theirs.any? { |b| boxes_overlap?(a, b) } }
      end
    end
    private_class_method :toe_kick_overlaps?

    # [min_x, min_y, min_z, max_x, max_y, max_z] of each piece, in the parent's frame (mm).
    def self.toe_kick_boxes(transformation, params)
      floor = transformation.origin.z.to_mm
      top = floor + params['toe_kick_height'].to_f
      ToeKick.footprints(params).map do |corners|
        points = corners.map { |x, y| transformation * Geom::Point3d.new(x.mm, y.mm, 0) }
        xs = points.map { |p| p.x.to_mm }
        ys = points.map { |p| p.y.to_mm }
        [xs.min, ys.min, floor, xs.max, ys.max, top]
      end
    end
    private_class_method :toe_kick_boxes

    def self.boxes_overlap?(first, second)
      (0..2).all? { |axis| first[axis] < second[axis + 3] - 1.0 && first[axis + 3] > second[axis] + 1.0 }
    end
    private_class_method :boxes_overlap?

    # Validates the panel values, adds what the selection supplies (see
    # insert_toe_kick) and checks the plinth actually fits under the carcass.
    def self.prepare_toe_kick(raw, anchor)
      result = ValidationManager.validate_toe_kick(raw)
      params = result.params
      errors = result.errors.dup
      params.merge!(toe_kick_target(raw, anchor)) if errors.empty?

      errors.concat(toe_kick_fit_errors(Sketchup.active_model, params)) if errors.empty?
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      record_toe_kick_path(Sketchup.active_model, params, anchor)
      params['width'] = ToeKick.total_length(params)
      [params, nil]
    end
    private_class_method :prepare_toe_kick

    # Works out the material (see ToeKick.material_name), then checks that the
    # plinth fits under the carcass and that the material exists.
    def self.toe_kick_fit_errors(model, params)
      errors = []
      if ToeKick.front_offset(params).negative?
        together = params['toe_kick_recess'] + params['toe_kick_thickness']
        errors << { 'field' => 'toe_kick_recess',
                    'message' => "The recess and thickness together (#{format('%g', together)} mm) are more than " \
                                 "the carcass depth (#{format('%g', params['target_depth'])} mm)." }
      end

      params['material'] = ToeKick.material_name(params, params['target_door_material'], params['target_carcass_material'])
      unless MaterialManager.available?(model, params['material'])
        errors << { 'field' => 'toe_kick_material', 'message' => "The material \"#{params['material']}\" was not found in the model." }
      end
      errors
    end
    private_class_method :toe_kick_fit_errors

    # A toe kick that starts at a cabinet or filler follows the row from there: where
    # the row turns a corner (the cabinets after it are turned), so does the toe
    # kick. `toe_kick_from` remembers which item it started at, so an Update (a new
    # recess, say) can work the path out again.
    def self.record_toe_kick_path(model, params, anchor)
      params['toe_kick_turns'] = ''
      params['toe_kick_total'] = 0.0
      return unless anchor && AttributeManager.part_kind(anchor) != 'toe_kick'

      params['toe_kick_from'] = AttributeManager.cabinet_id(anchor) || AttributeManager.part_id(anchor)
      row = toe_kick_row(anchor)
      params['toe_kick_turns'] = ToeKick.turns_from(*row, params['toe_kick_recess'].to_f)
      # The toe kick covers the whole row from there: pieces of the chosen length, one after another.
      if params['toe_kick_cover_row'] == true
        total = ToeKick.run_length(*row)
        lead, trail = params['toe_kick_turns'].to_s.length > 2 ? [0.0, 0.0] : toe_kick_reach(anchor, total) # (a straight row: it runs on to the side panels at its ends)
        params['toe_kick_lead'] = lead
        params['toe_kick_total'] = ToeKick.run_length(*row) + lead + trail
      end
    end
    private_class_method :record_toe_kick_path

    # The anchor and the cabinets / fillers inserted after it, as plain numbers in
    # the anchor's own frame (see ToeKick.turns_from).
    def self.toe_kick_row(anchor)
      to_frame = anchor.transformation.inverse
      dictionary = AttributeManager::DICTIONARY
      order = ->(item) { item.get_attribute(dictionary, 'sequence').to_i }
      following = anchor.parent.entities.grep(Sketchup::ComponentInstance).select do |item|
        !item.equal?(anchor) && order.call(item) > order.call(anchor) &&
          (AttributeManager.cabinet?(item) || AttributeManager.part_kind(item) == 'filler') && !wall_item?(item)
      end.sort_by(&order)

      describe = lambda do |item|
        relative = to_frame * item.transformation
        heading = relative.yaxis
        stored = AttributeManager.read(item) || {}
        corner = CabinetLayout.corner?(stored)
        width = stored['width'].to_f
        { x: relative.origin.x.to_mm, y: relative.origin.y.to_mm,
          angle: Math.atan2(-heading.x, heading.y) * 180.0 / Math::PI,
          width: width, corner: corner,
          depth: if AttributeManager.part_kind(item) == 'filler' then stored['target_depth'].to_f
                 else corner ? CabinetLayout.corner_extent(stored) : stored['depth'].to_f end }
      end

      [describe.call(anchor).merge(x: 0.0, y: 0.0, angle: 0.0), following.map { |item| describe.call(item) }]
    end
    private_class_method :toe_kick_row

    # How far a toe kick from `anchor` over a straight row `length` mm long reaches to touch the side panels at the ends of the row (see ToeKick.panel_reach).
    def self.toe_kick_reach(anchor, length)
      to_frame = anchor.transformation.inverse
      panels = anchor.parent.entities.grep(Sketchup::ComponentInstance).filter_map do |part|
        next unless AttributeManager.part_kind(part) == 'end_panel'

        stored = AttributeManager.read(part) || {}
        relative = to_frame * part.transformation
        next unless relative.origin.x.to_mm.abs < 5.0 && relative.yaxis.y > 0.98 # (against the same line of units, the same way round)

        { y: relative.origin.y.to_mm, thickness: stored['thickness'].to_f, base: stored['target_base_z'].to_f, category: stored['target_category'].to_s }
      end
      ToeKick.panel_reach(panels, length)
    end
    private_class_method :toe_kick_reach

    def self.find_toe_kick_anchor(model, id)
      return nil if id.to_s.empty?

      model.active_entities.grep(Sketchup::ComponentInstance).find do |item|
        AttributeManager.cabinet_id(item) == id || AttributeManager.part_id(item) == id
      end
    end
    private_class_method :find_toe_kick_anchor

    # target_depth, target_door_material, target_carcass_material for `anchor`.
    def self.toe_kick_target(raw, anchor)
      stored = anchor ? AttributeManager.read(anchor) : nil
      return fallback_target(raw) unless stored

      # `target_id` is the cabinet the toe kick goes with, so it can follow that
      # cabinet's door colour (see follow_door).
      if AttributeManager.part_kind(anchor) == 'toe_kick'
        stored.slice('target_id', 'target_depth', 'target_door_material', 'target_carcass_material')
      elsif AttributeManager.part_kind(anchor) == 'filler'
        # The carcass depth of the cabinet the filler goes beside (recorded when it was inserted).
        material = door_material_of(stored)
        { 'target_id' => stored['target_id'], 'target_depth' => stored['target_depth'].to_f,
          'target_door_material' => material, 'target_carcass_material' => material }
      else
        # The door material the cabinet was actually built with; if it never
        # recorded one (an older cabinet), work it out so this is never blank.
        door = stored['material'].to_s
        door = CabinetGenerator.door_material(stored) if door.empty?
        # A corner unit is a square: its carcass reaches Width, not its Depth field.
        depth = CabinetLayout.corner?(stored) ? CabinetLayout.corner_extent(stored) : stored['depth']
        { 'target_id' => AttributeManager.cabinet_id(anchor), 'target_depth' => depth.to_f,
          'target_door_material' => door, 'target_carcass_material' => CabinetGenerator.carcass_material(stored, door) }
      end
    end
    private_class_method :toe_kick_target

    def self.fallback_target(raw)
      depth = ValidationManager.to_float(stringify(raw)['depth'])
      material = Defaults::PARAMS['base_material']
      { 'target_depth' => depth&.positive? ? depth : Defaults::DEFAULT_TOE_KICK_DEPTH,
        'target_door_material' => material, 'target_carcass_material' => material }
    end
    private_class_method :fallback_target

    def self.stringify(hash)
      hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
    end
    private_class_method :stringify

    def self.update_toe_kick(model, root, raw)
      params, layout, failure = build_toe_kick_update(model, root, raw)
      return failure if failure

      SelectionManager.suspend { with_operation(model, 'Update Toe Kick') { PartGenerator.update(model, root, params, layout) } }
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_toe_kick

    # Checks `raw` for one existing toe kick and works out what it becomes. Returns
    # [params, layout, nil], or [nil, nil, failure Response]. Changes nothing.
    def self.build_toe_kick_update(model, root, raw, check_overlap: true)
      result = ValidationManager.validate_toe_kick(raw)
      params = result.params
      errors = result.errors.dup

      stored = AttributeManager.read(root)
      %w[target_id target_depth target_door_material target_carcass_material toe_kick_from custom_overrides].each { |key| params[key] = stored[key] }
      errors.concat(toe_kick_fit_errors(model, params)) if errors.empty?
      return [nil, nil, Response.fail(summary(errors), errors)] unless errors.empty?

      record_toe_kick_path(model, params, find_toe_kick_anchor(model, stored['toe_kick_from']))
      params['toe_kick_total'] = stored['toe_kick_total'].to_f if params['toe_kick_cover_row'] == true && params['toe_kick_total'].to_f.zero? # carried on from another toe kick
      if check_overlap && toe_kick_overlaps?(root.parent.entities, root.transformation, params, exclude: root)
        return [nil, nil, Response.fail('That would put this toe kick on top of another toe kick.')]
      end
      params['width'] = ToeKick.total_length(params)
      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.toe_kick_name(params))
      [params, PartLayout.toe_kick(params), nil]
    end
    private_class_method :build_toe_kick_update

    TOE_KICK_KEYS = %w[toe_kick_height toe_kick_thickness toe_kick_piece_length toe_kick_pieces toe_kick_recess toe_kick_material
                       toe_kick_cover_row].freeze

    # The Toe Kick fields act on EVERY toe kick in the model, live, as one Undo step,
    # when none is selected (a selected toe kick is edited on its own, see
    # update_part). Only the fields that were changed are sent; each toe kick keeps
    # the rest of its own values. One that cannot take a change (it would run into
    # the next toe kick, say) is left as it was, and the reply says so.
    def self.apply_toe_kicks(raw)
      raw = stringify(raw)
      answer = apply_to_toe_kicks(raw)

      # A higher toe kick lifts every cabinet that stands on it (and what is attached).
      height = raw['toe_kick_height'].to_s.strip
      return answer if height.empty? || !answer['ok']

      model = Sketchup.active_model
      return answer if model.selection.any? { |item| AttributeManager.part_kind(item) == 'toe_kick' } && !model.selection.any? { |item| AttributeManager.cabinet?(item) } # (only those toe kicks)

      lifted = CabinetManager.send(:apply_all, 'toe_kick_height' => height)
      return answer unless lifted['ok']

      note = lifted['message'].to_s
      note.empty? || note.start_with?('Every cabinet', 'No cabinets') ? answer : Response.ok("#{answer['message']} #{note}")
    end
    private_class_method :apply_toe_kicks

    def self.apply_to_toe_kicks(raw)
      overrides = {}
      TOE_KICK_KEYS.each do |key|
        value = raw[key].to_s.strip
        overrides[key] = value unless value.empty?
      end

      model = Sketchup.active_model
      kicks = model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.part_kind(item) == 'toe_kick' }
      # With the Toe kick switch on, the toe kicks it placed are drawn again with the new values after this (see LiveParts), so only the others are
      # changed here: a toe kick that could not take the change must not stop the cabinets from being lifted.
      kicks = kicks.reject { |item| item.get_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO_TOE) == true } if defined?(LiveParts) && LiveParts.toe_kicks?
      if kicks.empty?
        return Response.ok('Toe kick height applied to the cabinets and their toe kicks.') if overrides.key?('toe_kick_height') && (defined?(LiveParts) && LiveParts.toe_kicks?)

        return Response.ok('No toe kicks in the model yet. A new toe kick will use these values.')
      end

      picked = kicks.select { |item| model.selection.include?(item) } # (toe kicks selected, one or several: the values are for them alone)
      kicks = picked unless picked.empty?

      plans = []
      problems = []
      kicks.each do |kick|
        stored = AttributeManager.read(kick)
        merged = stored.slice(*TOE_KICK_KEYS).merge(overrides)
        params, layout, failure = build_toe_kick_update(model, kick, merged, check_overlap: false)
        failure ? problems << [kick, failure['message']] : plans << [kick, params, layout]
      end

      # The new runs must not stand on one another either (the old ones are being replaced).
      accepted = []
      plans.each do |kick, params, layout|
        boxes = toe_kick_boxes(kick.transformation, params)
        clash = accepted.find { |_k, other| boxes.any? { |a| other.any? { |c| boxes_overlap?(a, c) } } }
        if clash
          problems << [kick, "that would put it on top of #{clash[0].name}"]
        else
          accepted << [kick, boxes, params, layout]
        end
      end
      accepted = accepted.map { |kick, _boxes, params, layout| [kick, params, layout] }
      return Response.fail("#{problems.first[0].name}: #{problems.first[1]}") if accepted.empty? && problems.any?

      changed = accepted.reject { |kick, params, _layout| toe_kick_unchanged?(kick, params) }
      if changed.empty?
        return Response.ok('Every toe kick already has these values.') if problems.empty?

        return Response.fail("#{problems.first[0].name}: #{problems.first[1]}")
      end

      SelectionManager.suspend do
        with_operation(model, 'Apply Toe Kick Settings') do
          changed.each { |kick, params, layout| PartGenerator.update(model, kick, params, layout) }
        end
      end
      SelectionManager.push_selection(model)

      done = "#{changed.length} toe kick#{'s' unless changed.length == 1} updated."
      return Response.ok(done) if problems.empty?

      Response.ok("#{done} #{problems.length} left as #{problems.length == 1 ? 'it was' : 'they were'} (#{problems.first(2).map { |k, why| "#{k.name}: #{why}" }.join('; ')}).")
    end
    private_class_method :apply_to_toe_kicks

    def self.toe_kick_unchanged?(kick, params)
      stored = AttributeManager.read(kick)
      TOE_KICK_KEYS.all? do |key|
        was = stored[key]
        was = false if key == 'toe_kick_cover_row' && was.nil? # older toe kicks never covered the row
        was.to_s == params[key].to_s || (was.is_a?(Numeric) && was.to_f == params[key].to_f)
      end &&
        stored['toe_kick_turns'].to_s == params['toe_kick_turns'].to_s
    end
    private_class_method :toe_kick_unchanged?

    # The toe kick was raised from `from` to `to` mm. Everything that stands on it
    # goes up with the cabinets: fillers rise to the new toe-kick height and side panels
    # grow to the cabinets' new top. Everything on the WALL goes up by the same
    # amount, so wall units, the fillers and side panels beside them keep their place
    # above the base units. Inside an operation.
    def self.lift_attached(model, from, to)
      delta = to.to_f - from.to_f
      return if delta.abs < 1e-9

      up = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta.mm))
      model.entities.grep(Sketchup::ComponentInstance).each do |item|
        stored = AttributeManager.read(item)
        next unless stored

        base = stored['target_base_z'].to_f
        if AttributeManager.cabinet?(item)
          item.transformation = up * item.transformation if stored['cabinet_category'] == 'wall'
          next
        end

        case AttributeManager.part_kind(item)
        when 'filler'
          if stored['target_category'] == 'wall'
            item.transformation = up * item.transformation
            next
          end
          next if stored['target_category'].nil? && base.zero?

          params = stored.merge('target_base_z' => to.to_f)
          PartGenerator.update(model, item, params, PartLayout.filler(params))
        when 'end_panel'
          if base.positive? # beside a wall unit: it hangs, so it moves
            item.transformation = up * item.transformation
            next
          end

          params = stored.merge('height' => stored['height'].to_f + delta)
          PartGenerator.update(model, item, params, PartLayout.end_panel(params))
        end
      end
    end

    # The Filler and Side Panel fields with no filler / side panel selected: every one placed by hand takes the field that was edited (the others
    # keep their own values). Those placed by the Presets switches are drawn again by LiveParts and fitted to the wall, so they are left alone.
    def self.update_placed(raw)
      raw = stringify(raw)
      kind = raw['kind'].to_s
      return Response.fail('Unknown kind of part.') unless %w[filler end_panel].include?(kind)

      fields = stringify(raw['fields']).reject { |_, value| value.to_s.strip.empty? }
      model = Sketchup.active_model
      parts = model.entities.grep(Sketchup::ComponentInstance).select do |item|
        AttributeManager.part_kind(item) == kind && item.get_attribute(AttributeManager::DICTIONARY, LiveParts::AUTO) != true
      end
      label = kind == 'filler' ? 'filler' : 'side panel'
      return Response.ok("No #{label} placed by hand yet. A new one will use these values.") if parts.empty?

      keys = kind == 'filler' ? %w[width thickness height] : %w[side depth thickness height face front_design front_radius]
      done = 0
      problems = []
      @batch = true
      begin
        model.start_operation("Update #{label.capitalize}s", true)
        parts.each do |item|
          stored = AttributeManager.read(item)
          one = stored.slice(*keys)
          one['material'] = stored['material_choice'] if kind == 'end_panel'
          one.merge!(fields)
          answer = kind == 'filler' ? update_filler(model, item, one) : update_end_panel(model, item, one)
          answer['ok'] ? done += 1 : problems << answer['message']
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @batch = false
      end
      message = "#{done} #{label}#{'s' unless done == 1} updated."
      message += " #{problems.uniq.first(2).join(' ')}" unless problems.empty?
      done.zero? && !problems.empty? ? Response.fail(message) : Response.ok(message)
    end
    private_class_method :update_placed

    # ---- panel ---------------------------------------------------------------------

    PANEL_START_Z = 3000.0 # mm: where a new panel is put on the Z axis

    # A plain panel (Category = Panel): vertical or horizontal, its own size. It goes after the last unit of the row (or the one selected); it is no
    # part of the row, so nothing is built against it, and it can be moved or sized afterwards.
    def self.insert_panel(raw)
      model = Sketchup.active_model
      params, failure = prepare_panel(raw)
      return failure if failure

      layout = PartLayout.panel(params)
    entities, transformation = PlacementManager.send(:target_row, model, { 'placement_gap' => 0.0 }, PartLayout.panel_envelope(params))
    transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, PANEL_START_Z.mm - transformation.origin.z)) * transformation # (it starts 3000 mm up: it is moved from there)
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Panel') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(entities, NamingManager.panel_name(params))
          PartGenerator.build(model, entities, params, transformation, layout)
        end
      end
      SelectionManager.select(root)
      Response.ok("#{root.name} inserted.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_panel

    def self.update_panel(model, root, raw)
      stored = AttributeManager.read(root)
      params, failure = prepare_panel(raw)
      return failure if failure

      params['custom_overrides'] = stored['custom_overrides']
      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.panel_name(params))
      layout = PartLayout.panel(params)
      SelectionManager.suspend do
        with_operation(model, 'Update Panel') { PartGenerator.update(model, root, params, layout) }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_panel

    # "Same as door material" is the door material the panel sent along (the Base Unit's), else the default.
    def self.prepare_panel(raw)
      raw = stringify(raw)
      result = ValidationManager.validate_panel(raw)
      return [nil, Response.fail(summary(result.errors), result.errors)] unless result.errors.empty?

      params = result.params
      door = raw['door_material'].to_s.strip
      params['material'] = params['material_choice'] == Defaults::SAME_AS_DOOR ? (door.empty? ? Defaults::DEFAULT_MATERIAL : door) : params['material_choice']
      errors = material_errors(Sketchup.active_model, params, %w[material])
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [params, nil]
    end
    private_class_method :prepare_panel

    # ---- update / delete (all kinds) -------------------------------------------

    def self.update_part(raw)
      model = Sketchup.active_model
      root = SelectionManager.selected_part(model)
      return Response.fail('Select a filler, side panel or toe kick to update.') unless root

      case AttributeManager.part_kind(root)
      when 'filler' then update_filler(model, root, raw)
      when 'end_panel' then update_end_panel(model, root, raw)
      when 'panel' then update_panel(model, root, raw)
      when 'toe_kick' then update_toe_kick(model, root, raw)
      when 'worktop', 'backsplash' then WorktopManager.apply(raw, only_if_exists: false)
      when 'wall_bottom' then Response.ok('Change the wall bottom panel with Apply in the Worktop section.')
      else Response.fail('That selection is not a filler, an side panel, a toe kick or a worktop.')
      end
    end
    private_class_method :update_part

    # Its size can change; where it sits (the cabinet, the side, the base height,
    # the door front) stays as inserted, copied back from what was stored then.
    # Its material is the cabinet's door colour, kept up to date by follow_door.
    def self.update_filler(model, root, raw)
      stored = AttributeManager.read(root)
      params, failure = prepare_filler(raw, door_material_of(stored))
      return failure if failure

      %w[target_id target_width target_depth target_base_z target_category target_flush_x side custom_overrides].each { |key| params[key] = stored[key] }
      params['part_id'] = AttributeManager.part_id(root)
      layout = PartLayout.filler(params)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.filler_name(params))

      # A filler on the left keeps its right edge against the cabinet when its width changes.
      transformation = nil
      shift = stored['width'].to_f - params['width']
      if stored['side'] == 'left' && shift.abs > 1e-9
        transformation = root.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, shift.mm, 0))
      end

      old_size = %w[envelope_depth envelope_width envelope_top].map { |key| stored[key].to_f }
      if PlacementManager.crowds?(root.parent.entities, root, transformation || root.transformation, PartLayout.filler_envelope(params), old_size)
        return Response.fail('That size would make the filler overlap the item next to it.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Update Filler') { PartGenerator.update(model, root, params, layout, transformation) }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_filler

    # Makes a filler `width` mm wide and puts it at `transformation` (RowResizer:
    # the filler is the neighbour that gives way when a cabinet is made wider).
    # Call inside an operation.
    def self.resize_filler(model, root, width, transformation)
      stored = AttributeManager.read(root)
      params = stored.merge('width' => width)
      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.filler_name(params))
      PartGenerator.update(model, root, params, PartLayout.filler(params), transformation)
    end
    def self.update_end_panel(model, root, raw)
      stored = AttributeManager.read(root)
      door = stored['target_door_material'].to_s
      door = Defaults::DEFAULT_MATERIAL if door.empty?
      carcass = stored['target_carcass_material'].to_s
      carcass = door if carcass.empty?
      params, failure = prepare_end_panel(raw, door, carcass)
      return failure if failure

      %w[target_id target_width target_base_z target_door_material target_carcass_material custom_overrides].each { |key| params[key] = stored[key] }
      arm_end = stored['corner_arm'].to_s == 'front' # (across the end of the second arm of a tall L corner)
      params['side'] = stored['side'] if arm_end
      params['corner_arm'] = stored['corner_arm'] if arm_end

      layout = PartLayout.end_panel(params)
      offset = params['side'] == 'left' ? -params['thickness'] : params['target_width']
      local_move = Geom::Transformation.translation(Geom::Vector3d.new(0, offset.mm, 0))
      # The panel keeps the position it was placed at; only its own offset along
      # the target's face (which side, how thick) can move it.
      base = target_placement(root)
      transformation = arm_end ? root.transformation : base * local_move
      size = PartLayout.end_panel_envelope(params)

      if !arm_end && PlacementManager.collides?(root.parent.entities, transformation, size, exclude: root)
        return Response.fail("The #{params['side']} side already has something against it.")
      end

      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.end_panel_name(params))

      SelectionManager.suspend do
        with_operation(model, 'Update Side Panel') { PartGenerator.update(model, root, params, layout, transformation) }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_end_panel

    # The target's own placement, recovered from the side panel's CURRENT
    # transformation and its CURRENT (pre-update) side/thickness, so a change of
    # side or thickness can be re-applied on top of the same base placement.
    def self.target_placement(root)
      stored = AttributeManager.read(root)
      offset = stored['side'] == 'left' ? -stored['thickness'].to_f : stored['target_width'].to_f
      root.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, -offset.mm, 0))
    end
    private_class_method :target_placement

    def self.delete_part
      model = Sketchup.active_model
      root = SelectionManager.selected_part(model)
      return Response.fail('Select a filler, side panel or toe kick to delete.') unless root

      name = root.name
      SelectionManager.suspend { with_operation(model, 'Delete Part') { PartGenerator.remove(model, root) } }
      SelectionManager.push_selection(model)
      Response.ok("#{name} deleted. Use Edit > Undo to bring it back.")
    end
    private_class_method :delete_part

    # ---- shared -----------------------------------------------------------------

    # `material` is the cabinet's door material: a filler has no material of its own.
    def self.prepare_filler(raw, material)
      result = ValidationManager.validate_filler(raw)
      return [nil, Response.fail(summary(result.errors), result.errors)] unless result.errors.empty?

      result.params['material'] = material
      errors = material_errors(Sketchup.active_model, result.params, %w[material])
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [result.params, nil]
    end
    private_class_method :prepare_filler

    # An side panel's material is "same as door material" (following what it is
    # attached to) unless a material was picked by hand; `door` and `carcass` are
    # what it would follow.
    def self.prepare_end_panel(raw, door, carcass)
      result = ValidationManager.validate_end_panel(raw)
      return [nil, Response.fail(summary(result.errors), result.errors)] unless result.errors.empty?

      params = result.params
      params['material'] = ToeKick.material_name({ 'toe_kick_material' => params['material_choice'] }, door, carcass)
      errors = material_errors(Sketchup.active_model, params, %w[material])
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [params, nil]
    end
    private_class_method :prepare_end_panel

    # ---- following the door material ----------------------------------------------

    # Called after a cabinet is updated. Everything that goes with it and has no
    # colour of its own follows the cabinet's door material:
    #
    #   filler                    always
    #   side panel, toe kick       unless a material was picked for it by hand
    #                             ("same as door / carcass material" follows)
    #
    # Only the colour changes; nothing is rebuilt. Call inside an operation.
    def self.follow_door(model, cabinet)
      cabinet_id = AttributeManager.cabinet_id(cabinet)
      return unless cabinet_id

      params = AttributeManager.read(cabinet)
      door = door_material_of(params)
      carcass = CabinetGenerator.carcass_material(params, door)
      parts = cabinet.parent.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.part?(instance) }

      # Things attached to a filler beside this cabinet belong with it too.
      fillers = parts.select do |part|
        AttributeManager.part_kind(part) == 'filler' && part.get_attribute(AttributeManager::DICTIONARY, 'target_id') == cabinet_id
      end
      owners = [cabinet_id] + fillers.map { |filler| AttributeManager.part_id(filler) }

      parts.each do |part|
        stored = AttributeManager.read(part)
        next unless fillers.include?(part) || owners.include?(stored['target_id'])

        name = followed_material(part, stored, door, carcass)
        recolour(model, part, stored, name, door, carcass) if name
        follow_radius(model, part, stored, params['front_radius']) # a side panel's edges are as round as the doors'
      end
    end

    # A side panel's rounded outer edges follow the cabinet's Front edge radius: when that changes the panel is rebuilt with the new one.
    def self.follow_radius(model, part, stored, radius)
      return unless stored['part_kind'] == 'end_panel' && !radius.nil? && stored.key?('front_radius')
      return if (stored['front_radius'].to_f - radius.to_f).abs < 0.001

      merged = stored.merge('front_radius' => radius.to_f)
      PartGenerator.update(model, part, merged, PartLayout.end_panel(merged))
    end
    private_class_method :follow_radius

    # The colour a part should now have, or nil if it keeps its own.
    def self.followed_material(part, stored, door, carcass)
      case AttributeManager.part_kind(part)
      when 'filler' then door
      when 'end_panel' then follows?(stored['material_choice']) ? ToeKick.material_name({ 'toe_kick_material' => stored['material_choice'] }, door, carcass) : nil
      when 'toe_kick' then follows?(stored['toe_kick_material']) ? ToeKick.material_name(stored, door, carcass) : nil
      end
    end
    private_class_method :followed_material

    def self.follows?(choice)
      choice.to_s.empty? || MaterialManager.follows_another_part?(choice.to_s)
    end
    private_class_method :follows?

    def self.recolour(model, part, stored, name, door, carcass)
      return if stored['material'].to_s == name && stored['target_door_material'].to_s == door

      AttributeManager.write(part, 'material' => name, 'target_door_material' => door, 'target_carcass_material' => carcass)
      part.definition.entities.grep(Sketchup::ComponentInstance).each { |piece| MaterialManager.apply(piece, name, model) }
    end
    private_class_method :recolour

    def self.material_errors(model, params, fields)
      fields.each_with_object([]) do |field, errors|
        name = params[field].to_s
        next if MaterialManager.available?(model, name)

        errors << { 'field' => field, 'message' => "The material \"#{name}\" was not found in the model." }
      end
    end
    private_class_method :material_errors

    def self.summary(errors)
      return errors.first['message'] if errors.length == 1

      "#{errors.length} values need attention."
    end
    private_class_method :summary

    def self.with_operation(model, name)
      return yield if (defined?(KitchenManager) && KitchenManager.building?) || @batch # (inside Design Kitchen or a batch of panels: its own one Undo step)

      model.start_operation(name, true)
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      end
    end
    private_class_method :with_operation
  end
end
