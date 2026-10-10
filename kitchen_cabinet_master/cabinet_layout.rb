# frozen_string_literal: true

module KitchenCabinetMaster
  # Works out every carcass panel: its role, size and position. All numbers are
  # millimetres and use NO SketchUp API, so the rules live in one readable place.
  #
  # Coordinate system (fixed for every cabinet):
  #   Width  = Y axis   (0 at the left end, growing to the right when you face the cabinet)
  #   Depth  = X axis   (0 at the rear / wall side, growing towards the front)
  #   Height = Z axis   (0 at the bottom of the carcass)
  # The reference point (origin) is the rear-left-bottom corner of the carcass.
  #
  # Plan view, looking down (X up the page is the front):
  #
  #   front  ┌──────────────────────────┐  X = depth
  #          │ shelves stop 20 mm short │
  #          │         ...              │
  #          └─[back]───────────────────┘  X = recess .. recess + back thickness
  #   rear   X = 0 (wall side)
  module CabinetLayout
    # extent = [x, y, z] box size. `points` is nil for an ordinary box panel; when
    # set (a corner unit's bottom panel or shelves), the panel is instead the
    # outline `points` (a flat polygon in the X-Y plane, millimetres, going
    # around in order) pushed up by extent[2] (its thickness), and `offset` is
    # then just [0, 0, z] since the outline's own coordinates are already absolute.
    # `front` marks a panel that is part of the FRONT (a blind corner's fixed panel, the panel over a
    # built-in oven): it takes the door material, not the carcass one.
    Panel  = Struct.new(:role, :name, :extent, :offset, :points, :rotation, :round, :round_edge, :front, :holes, :shape, :path, keyword_init: true)
    # A door is a panel plus a hinge. `pivot` is the vertical hinge axis in cabinet
    # coordinates (on the door's FRONT face edge, so the door never swings back
    # into the carcass, even at wide opening angles).
    # `rotation` (degrees about Z, applied at `offset` before the door's own
    # swing) is 0 for every ordinary axis-aligned door or drawer; a corner
    # unit's diagonal door is the one case that sets it (see corner_door).
    # `hinge` is 'left' / 'right' (a vertical hinge), 'top' (a lift-up door: its hinge is the top edge,
    # `pivot` = [x of the front face, -, z of the top edge]) or 'center' (a drawer front).
    # `swing` is a smaller opening angle a door needs to be at least (an L corner's doors must open wide
    # enough to see inside); nil = just the Opening Angle of the panel.
    # `handle` false = this door gets no handle (an L corner has one handle, on its narrower door); `grip` 'top' or
    # 'bottom' puts the handle next to that edge (the two doors of a fridge have theirs next to the gap between them).
    Door   = Struct.new(:role, :name, :extent, :offset, :hinge, :pivot, :rotation, :swing, :handle, :grip, :parent, :bifold, keyword_init: true)
    Layout = Struct.new(:base_z, :top_z, :panels, :doors, :drawers, :toe_kick, :drawer_boxes, :appliances, keyword_init: true)
    # `return_depth` is only meaningful for a corner unit: how far its shortened
    # right-side panel and front-return panel extend (see corner geometry
    # methods below); for every other category it is unused.
    Dims   = Struct.new(:width, :depth, :height, :thick, :back, :inner_w, :interior_start, :interior_d,
                        :shelf_setback, :return_depth, :recess, :groove, keyword_init: true)

    # How far a corner unit reaches along X: Width for a diagonal corner; an L takes the length of its second leg.
    def self.corner_extent(params)
      second = params['leg2_length'].to_f
      Defaults.corner_style(params) == 'l_shape' && second.positive? ? second : params['width'].to_f
    end

    # The shape of a corner-type cabinet: diagonal, l_shape or blind; nil for an ordinary one.
    # (A cabinet saved as category "corner" before shapes existed is a diagonal corner.)
    def self.corner_style(params) = Defaults.corner_style(params)

    # A unit with a square footprint (Width x Width) that turns the row a quarter turn.
    def self.corner?(params) = Defaults.corner?(params)

    # A straight cabinet whose front is part door, part fixed blind panel.
    def self.blind?(params)
      corner_style(params) == 'blind'
    end

    # params - validated parameter Hash (millimetres)
    def self.compute(params)
      dims = dimensions(params)
      return freestanding_layout(params, dims) if params['freestanding'] == true
      return housing_layout(params, dims) if params['free_housing'] == true
      return dishwasher_layout(params, dims) if params['dishwasher'] == true
      category = params['cabinet_category'].to_s
      style = corner_style(params)

      # A wall unit can have its carcass bottom lifted (room for a panel under it): the
      # carcass is shorter and starts higher, while the doors keep the full height.
      full_height = dims.height
      lift = category == 'wall' ? [params['carcass_raise'].to_f, 0.0].max : 0.0
      dims.height = full_height - lift

      panels =
        if style == 'l_shape'
          l_panels(params, dims)
        elsif style == 'diagonal'
          [
            panel('left_side', 'Left Side Panel', [dims.width - dims.thick, dims.thick, dims.height], [0, 0, 0]),
            panel('right_side', 'Right Side Panel', [dims.return_depth, dims.thick, dims.height],
                  [0, dims.width - dims.thick, 0]),
            panel('front_return', 'Front Return Panel', [dims.thick, dims.return_depth, dims.height],
                  [dims.width - dims.thick, 0, 0]),
            back_panel(dims),
            corner_bottom_panel(dims)
          ]
        else
          [
            panel('left_side',  'Left Side Panel',  [dims.depth, dims.thick, dims.height], [0, 0, 0]),
            panel('right_side', 'Right Side Panel', [dims.depth, dims.thick, dims.height], [0, dims.width - dims.thick, 0]),
            back_panel(dims),
            panel('bottom',     'Bottom Panel',     [dims.interior_d, dims.inner_w, dims.thick],
                  [dims.interior_start, dims.thick, 0])
          ]
        end
      panels.concat(
        case style
        when 'diagonal' then corner_top_panels(dims)
        when 'l_shape' then l_top_panels(params, dims)
        else top_panels(category, dims, params['top_panel_style'], open: open_unit?(params))
        end
      )
      panels.concat(
        if style == 'diagonal'
          corner_shelf_panels(params['shelf_count'].to_i, dims)
        elsif style == 'l_shape'
          l_shelf_panels(params['shelf_count'].to_i, params, dims)
        else
          shelf_panels(params['shelf_count'].to_i, dims)
        end
      )

      # Toe-kick rule: the whole carcass sits on top of the toe kick.
      # Cabinet Base Z = Toe Kick Height, Cabinet Top Z = Toe Kick Height + Cabinet Height.
      # The toe kick itself is a separate entity (see ToeKick / PartLayout.toe_kick),
      # so the cabinet's layout has none.
      base_z = round2(category == 'wall' ? 0.0 : params['toe_kick_height'].to_f)
      panels.each { |item| item.offset = [item.offset[0], item.offset[1], round2(item.offset[2] + lift)] } if lift.positive?
      dims.height = full_height
      panels << blind_panel(params, dims) if blind?(params) # the fixed front stays full height
      zone = front_zone(params, dims)
      panels << stacked_divider(params, dims) if params['door_stacked'] == true && params['door_count'].to_i == 2 && corner_style(params).nil?
      panels.concat(zone_panels(params, dims, zone))
      fridge = fridge_layout(params, dims)
      panels.concat(fridge_panels(dims, fridge)) if fridge
      panels << top_front_panel(params, dims) if params['top_front'].to_f.positive?
      doors = door_panels(params, dims, base_z)
      drawers = drawer_panels(params, dims, base_z)
      # A drawer front the user resized or moved: its inner box follows it, so it is changed before the box is made.
      panels.concat(finger_pull_panels(params, dims, doors, drawers, base_z, panels)) # (the top fronts are shorter: the finger gap)
      custom = params['custom_overrides']
      drawers.each { |drawer| tweak_item(drawer, custom[drawer.role]) } if custom.is_a?(Hash) && !custom.empty?
      apply_overrides(Layout.new(base_z: base_z, top_z: round2(base_z + dims.height), panels: panels, doors: doors,
                                 drawers: drawers, toe_kick: [], drawer_boxes: drawer_boxes(params, dims, drawers),
                                 appliances: appliance_boxes(params, dims, front_zone(params, dims))), params, drawers: false)
    end

    # A space for a built-in dishwasher: no carcass (the neighbours' sides are its sides), two rails across the top that carry the worktop, and
    # the front of the dishwasher in the door material and design, as tall as the doors of the units beside it, with a handle (unless it is turned off).
    def self.dishwasher_layout(params, dims)
      base_z = round2(params['toe_kick_height'].to_f)
      reveal = params['door_reveal'].to_f
      rail = [Defaults::RAIL_DEPTH, dims.depth / 2.0].min
      z = dims.height - dims.thick
      panels = [
        panel('top_rear_rail', 'Top Rear Rail', [rail, dims.width, dims.thick], [0, 0, z]),
        panel('top_front_rail', 'Top Front Rail', [rail, dims.width, dims.thick], [dims.depth - rail, 0, z])
      ]
      width = dims.width - (2 * reveal)
      height = dims.height - (2 * reveal)
      x = params['depth'].to_f + door_distance(params) # (where the doors beside it stand: an open unit's own depth already reaches their fronts)
      if params['dishwasher_handle'] == false # no handle: just the front panel
        front = panel('dishwasher_front', 'Dishwasher Front Panel', [dims.thick, width, height], [x, reveal, reveal])
        front.front = true # the colour of the doors
        front.shape = "front_#{FrontDesign.clean(params['front_design'])}"
        front.round = params['front_radius'].to_f
        panels << front
        return Layout.new(base_z: base_z, top_z: round2(base_z + dims.height), panels: panels, doors: [], drawers: [], toe_kick: [], drawer_boxes: [], appliances: [])
      end

      # With a handle the front is a front like a drawer's (door material and design, the handle of the Handle section on it, centred).
      front = Door.new(role: 'drawer_1', name: 'Dishwasher Front', extent: [dims.thick, width, height].map { |v| round2(v) },
                       offset: [x, reveal, base_z + reveal].map { |v| round2(v) }, hinge: 'center', pivot: [dims.depth, reveal, base_z].map { |v| round2(v) }, rotation: 0.0)
      Layout.new(base_z: base_z, top_z: round2(base_z + dims.height), panels: panels, doors: [], drawers: [front], toe_kick: [], drawer_boxes: [], appliances: [])
    end
    private_class_method :dishwasher_layout

    # Two doors one above the other have a shelf between them, flush with the front of the carcass, in the gap between the doors (its middle on the
    # middle of the gap), as the middle of a two-layer lift-up unit is.
    def self.stacked_divider(params, dims)
      top = params['front_zone'].to_f
      top = dims.height * 0.35 unless top.positive? && top < dims.height - 200.0
      gap = params['door_gap'].to_f
      middle = dims.height - top - (gap / 2.0) # (the gap runs from height - top - gap to height - top, as stacked_doors lays the doors out)
      z = (middle - (dims.thick / 2.0)).clamp(dims.thick, dims.height - (2 * dims.thick))
      panel('divider', 'Middle Shelf', [dims.interior_d, dims.inner_w, dims.thick], [dims.interior_start, dims.thick, z])
    end
    private_class_method :stacked_divider

    # The model without handles: the top fronts of a base unit are shorter by `finger_gap` (35 mm to start with; a drawer front by
    # `finger_gap_drawer`), and the gap that leaves over them is how the fingers take hold. It is closed by a panel in the door
    # material, flush with the front of the carcass sides and from the outside of one to the outside of the other, up to their top. It
    # reaches `FINGER_OVERLAP` down in front of the top of the fronts, which stay where they are; the top front rail steps back by its
    # thickness. When the fronts are made shorter or taller the panel follows. With `finger_all` every front of the unit (each drawer, a
    # door under a drawer) has its own gap, closed by a panel of its own up to where the front used to end. Not for the corner shapes, a
    # unit with a panel over its oven, or wall and tall units. The fronts are changed here; the panels are returned.
    def self.finger_pull_panels(params, dims, doors, drawers, base_z, panels)
      return [] unless params['finger_pull'] == true && params['cabinet_category'].to_s == 'base' && corner_style(params).nil? && !params['top_front'].to_f.positive?

      reveal = params['door_reveal'].to_f
      door_gap = params['finger_gap'].to_f.positive? ? params['finger_gap'].to_f : Defaults::FINGER_GAP
      drawer_gap = params['finger_gap_drawer'].to_f.positive? ? params['finger_gap_drawer'].to_f : door_gap # (a drawer front has its own reduction)
      limit = base_z + dims.height - reveal
      gaps = {}
      doors.each { |item| gaps[item.object_id] = door_gap }
      drawers.each { |item| gaps[item.object_id] = drawer_gap }
      fronts = (doors + drawers).select do |item|
        reaches_top = (item.offset[2] + item.extent[2] - limit).abs < 0.6
        (reaches_top || params['finger_all'] == true) && item.extent[2] - gaps[item.object_id] >= 60.0
      end
      return [] if fronts.empty?

      # Fronts that end at the same height (a pair of doors) share one gap and one panel, the highest first.
      levels = fronts.group_by { |item| round2(item.offset[2] + item.extent[2]) }.sort_by { |top, _| -top }
      result = levels.each_with_index.map do |(top, group), index|
        gap = group.map { |item| gaps[item.object_id] }.max # (the panel reaches down behind the lowest of them)
        group.each { |item| item.extent = [item.extent[0], item.extent[1], round2(item.extent[2] - gaps[item.object_id])] }
        highest = (top - limit).abs < 0.6
        # The top front rail (or the front of a full top panel) steps back one board thickness, behind the panel.
        if highest
          rail = panels.find { |item| item.role == 'top_front_rail' }
          rail.offset = [round2(rail.offset[0] - dims.thick), rail.offset[1], rail.offset[2]] if rail
          full = panels.find { |item| item.role == 'top' }
          full.extent = [round2(full.extent[0] - dims.thick), full.extent[1], full.extent[2]] if full && !full.points
        end
        ended = top - base_z                                   # where the front ended, above the carcass bottom
        bottom = ended - gap - Defaults::FINGER_OVERLAP
        # (the panel's front is flush with the front of the side panels and it runs from the outside of one side panel to the other,
        # up to their top, or for a lower front up to where it ended)
        panel = panel(index.zero? && highest ? 'finger_panel' : "finger_panel_#{index + 1}", 'Finger Gap Panel', [dims.thick, dims.width, (highest ? dims.height : ended) - bottom],
                      [dims.depth - dims.thick, 0, bottom])
        panel.front = true # the colour of the doors
        panel
      end
      # The side panels are cut away where a finger gap panel stands (it runs from outside to outside, in front of them): a notch at the
      # front edge, one board thickness deep, over the height of the panel.
      notches = result.map { |item| [round2(dims.thick), item.offset[2], round2(item.offset[2] + item.extent[2])] }.sort_by { |notch| notch[1] }
      panels.each do |item|
        next unless %w[left_side right_side].include?(item.role)

        item.shape = 'notch'
        item.path = notches
      end
      result
    end
    private_class_method :finger_pull_panels

    # What the user changed in the Customize window (see Customizer): per part key, a size for the axes that were
    # changed and a move from where it belongs. Applied last, so everything built on the layout sees it.
    # `drawers: false` leaves the drawer fronts alone (compute has already changed them, so that the drawer boxes,
    # built from them, follow).
    def self.apply_overrides(layout, params, drawers: true)
      overrides = params['custom_overrides']
      return layout unless overrides.is_a?(Hash) && !overrides.empty?

      tweak = ->(item) { tweak_item(item, overrides[item.role]) }
      (layout.panels + layout.doors + (drawers ? layout.drawers : []) + layout.appliances.to_a).each(&tweak)
      (layout.drawer_boxes || {}).each_value { |boards| boards.each(&tweak) }
      layout
    end
    private_class_method :apply_overrides

    # Changes one board (a Panel or a Door): `change` = { 'extent' => [x, y, z] (nil = unchanged), 'move' => [dx, dy, dz] }.
    # Also used for fillers, side panels, toe kicks and worktops (PartLayout). Returns true when something changed.
    def self.tweak_item(item, change)
      return false unless change.is_a?(Hash)

      size = Array(change['extent'])
      move = Array(change['move']).map(&:to_f)
      move += [0.0] * (3 - move.length)
      if item.respond_to?(:points) && item.points && !item.points.empty? # a shaped board: only its thickness and its place change
        thickness = size[2].to_f.positive? ? size[2].to_f : item.extent[2]
        item.points = item.points.map { |x, y| [round2(x + move[0]), round2(y + move[1])] }
        item.extent = [item.extent[0], item.extent[1], round2(thickness)]
        item.offset = [item.offset[0], item.offset[1], round2(item.offset[2] + move[2])]
      else
        item.extent = (0..2).map { |axis| round2(size[axis].to_f.positive? ? size[axis].to_f : item.extent[axis]) }
        item.offset = (0..2).map { |axis| round2(item.offset[axis] + move[axis]) }
      end
      item.pivot = (0..2).map { |axis| round2(item.pivot[axis] + move[axis]) } if item.respond_to?(:pivot) && item.pivot
      true
    end

    # The fixed panels of a front zone. Each one is flush with the carcass front, and the door (or the
    # drawer fronts) next to it covers its edge, stopping a door reveal short of the panel's far edge.
    #   oven housing   a shelf under every appliance (the drawers cover the first one) and, with a door, a
    #                  rail under that door (the door covers it)
    #   drawers + door a rail between the two
    #   door over a niche (a fridge housing) a rail under the door, where it closes
    def self.zone_panels(params, dims, zone)
      return [] unless zone

      reveal = params['door_reveal'].to_f
      shelf = [dims.interior_d, dims.inner_w, dims.thick] # to the carcass front: flush
      if zone[:bottom]
        out = Array(zone[:shelves] || [zone[:bottom] - dims.thick]).each_with_index.map do |z, index|
          panel("oven_shelf_#{index + 1}", 'Oven Shelf', shelf, [dims.interior_start, dims.thick, z])
        end
        rail_z = zone[:rail] || (dims.height - zone[:door] - reveal if zone[:door])
        out << panel('niche_rail', 'Niche Rail', shelf, [dims.interior_start, dims.thick, rail_z]) if rail_z
        if params['lower_mode'] == 'drawer_door' # a rail between the small drawer and the door under it
          door_h = zone[:bottom] - (2 * reveal) - params['door_gap'].to_f - params['small_drawer'].to_f
          out << panel('lower_rail', 'Lower Rail', shelf, [dims.interior_start, dims.thick,
                                                          reveal + door_h + (params['door_gap'].to_f / 2.0) - (dims.thick / 2.0)])
        end
        out
      elsif zone[:drawers]
        mid = dims.height - zone[:drawers] - (params['door_gap'].to_f / 2.0) - (dims.thick / 2.0)
        [panel('drawer_rail', 'Drawer Rail', shelf, [dims.interior_start, dims.thick, mid])]
      elsif zone[:door]
        [panel('door_rail', 'Door Rail', shelf, [dims.interior_start, dims.thick, dims.height - zone[:door] - reveal])]
      else
        []
      end
    end
    private_class_method :zone_panels

    # A fixed front panel across the top of a unit (the one over a built-in oven), in the door material.
    # `top_front` is its height from the carcass top down.
    def self.top_front_panel(params, dims)
      reveal = params['door_reveal'].to_f
      height = params['top_front'].to_f
      front = panel('top_front', 'Top Front Panel', [dims.thick, dims.width - (2 * reveal), height - reveal],
                    [dims.depth + door_distance(params), reveal, dims.height - height])
      front.front = true
      front
    end
    private_class_method :top_front_panel

    # How far the doors stand in front of the carcass (Door Distance in the Presets).
    # Cabinets stored before it existed use the old fixed 2 mm.
    def self.door_distance(params)
      value = params['door_distance']
      value.nil? || value.to_s.strip.empty? ? Defaults::DOOR_CLEARANCE : value.to_f
    end

    # The space a cabinet takes up, closed: [depth, width, top Z] in millimetres,
    # measured from its rear-left-bottom corner. Depth includes the doors (or, on an
    # open unit, the flush front), so it is the same either way. Used to keep new
    # cabinets from landing on top of existing ones.
    def self.envelope(params)
      thick = params['material_thickness'].to_f
      category = params['cabinet_category'].to_s
      base_z = category == 'wall' || params['freestanding'] == true || params['free_housing'] == true ? 0.0 : params['toe_kick_height'].to_f
      # A corner unit's outer footprint is a square sized by Width in both
      # directions; its own Depth instead controls the internal return panels.
      square = corner?(params)
      nominal_depth = square ? corner_extent(params) : params['depth'].to_f
      # A corner unit's doors sit on a diagonal inside that square, so nothing of
      # it stands proud of Width; the door clearance only applies to flat fronts.
      depth = square ? nominal_depth : nominal_depth + door_distance(params) + thick
      [depth, params['width'].to_f, base_z + params['height'].to_f]
    end

    # The back panel. A back set in from the rear edge (thinner than 18 mm) sits in a
    # groove in each side panel, so it is wider than the space between them by
    # groove on both sides. A flush 18 mm back just fits between the sides.
    def self.back_panel(dims)
      panel('back', 'Back Panel', [dims.back, dims.inner_w + (2 * dims.groove), dims.height],
            [dims.recess, dims.thick - dims.groove, 0])
    end
    private_class_method :back_panel

    # 9 mm into each side (never more than half its thickness), or none for a flush back.
    def self.groove_for(back, thick)
      return 0.0 if Defaults.back_recess(back).zero?

      [Defaults::BACK_GROOVE, thick / 2.0].min
    end
    private_class_method :groove_for

    def self.dimensions(params)
      width = params['width'].to_f
      depth = params['depth'].to_f
      thick = params['material_thickness'].to_f
      back = params['back_thickness'].to_f
      recess = Defaults.back_recess(back)
      start = recess + back

      # An OPEN unit (no doors) has nothing standing in front of it, so its panels
      # reach forward to the front face of the neighbours' doors (door clearance
      # plus door thickness) and its shelves are flush too. With doors, the carcass
      # ends at the nominal depth and the shelves stop short of the doors.
      corner = corner?(params)
      return_depth = depth # the value the user actually typed in "Depth"

      # A corner unit's carcass footprint is a square (Width x Width): its two
      # side panels sit against two walls, so its OWN "depth" direction is
      # governed by Width too. The typed Depth becomes `return_depth` instead,
      # controlling how far the (shortened) right-side and front-return panels
      # reach -- see corner panel/door geometry below.
      depth = corner_extent(params) if corner

      open_unit = open_unit?(params) # a unit with drawers has a front too, so it is not open
      depth += door_distance(params) + thick if open_unit && !corner

      Dims.new(width: width, depth: depth, height: params['height'].to_f, thick: thick, back: back,
               inner_w: width - (2 * thick), interior_start: start, interior_d: depth - start,
               shelf_setback: open_unit ? 0.0 : Defaults::SHELF_FRONT_SETBACK, return_depth: return_depth,
               recess: recess, groove: groove_for(back, thick))
    end
    private_class_method :dimensions

    # A unit with neither doors nor drawers.
    def self.open_unit?(params)
      params['door_count'].to_i.zero? && params['drawer_count'].to_i.zero?
    end

    # The top of the carcass. A BASE unit's is two separate 10 cm panels (a front and a
    # rear rail), the default, or one full panel (the Top Panel setting); an open base
    # unit, with nothing in front to hide its top, starts with one full panel. A wall or
    # tall unit's is always one full panel, whatever the setting.
    def self.top_panels(category, dims, style = '', open: false)
      z = dims.height - dims.thick
      rails = category == 'base' && (style.to_s.empty? ? !open : style.to_s == 'rails')

      if rails
        rail = [Defaults::RAIL_DEPTH, dims.interior_d / 2.0].min
        [
          panel('top_rear_rail',  'Top Rear Rail',  [rail, dims.inner_w, dims.thick], [dims.interior_start, dims.thick, z]),
          panel('top_front_rail', 'Top Front Rail', [rail, dims.inner_w, dims.thick], [dims.depth - rail, dims.thick, z])
        ]
      else
        [panel('top', 'Top Panel', [dims.interior_d, dims.inner_w, dims.thick], [dims.interior_start, dims.thick, z])]
      end
    end
    private_class_method :top_panels

    # Same pentagon as the bottom panel (see corner_bottom_panel), just at the top.
    def self.corner_top_panels(dims)
      z = dims.height - dims.thick
      [Panel.new(role: 'top', name: 'Top Panel', points: corner_footprint(dims, 0.0, 0.0),
                 extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(z)])]
    end
    private_class_method :corner_top_panels

    # The interior outline for a corner unit's bottom panel, shelf or top: a
    # square (inside the left and back panels, and inside the right and
    # front-return panels) with its front-right corner cut along the diagonal
    # -- the same diagonal the door runs along, inset by `setback` (from the
    # door, perpendicular to the cut) and `side_margin` (from the left panel).
    # Five points, going around: back-left, back-right (inside the right
    # panel), where the right panel ends and the cut begins, where the cut
    # meets the front-return panel, and back along that panel to the front-left.
    def self.corner_footprint(dims, setback, side_margin)
      inner_edge = dims.width - dims.thick # the inside face of the right / front-return panels
      y_min = dims.thick + side_margin
      # The diagonal line (through (return_depth, inner_edge) and (inner_edge,
      # return_depth)) satisfies x + y = return_depth + inner_edge; inset it
      # `setback` perpendicular (toward the interior) by shrinking that sum.
      cut = dims.return_depth - (setback * Math.sqrt(2))

      [
        [dims.interior_start, y_min],
        [dims.interior_start, inner_edge],
        [cut, inner_edge],
        [inner_edge, cut],
        [inner_edge, y_min]
      ].map { |x, y| [round2(x), round2(y)] }
    end
    private_class_method :corner_footprint

    # The bottom panel reaches all the way to the nominal front/diagonal edge
    # (no setback), the same as a normal cabinet's bottom panel reaches the
    # front -- it sits below the door, so it does not need to clear it.
    def self.corner_bottom_panel(dims)
      Panel.new(role: 'bottom', name: 'Bottom Panel', points: corner_footprint(dims, 0.0, 0.0),
                extent: [nil, nil, round2(dims.thick)], offset: [0, 0, 0])
    end
    private_class_method :corner_bottom_panel

    def self.corner_shelf_panels(count, dims)
      return [] unless count.positive?

      clear = dims.height - (2 * dims.thick)
      gap = (clear - (count * dims.thick)) / (count + 1)
      points = corner_footprint(dims, dims.shelf_setback, Defaults::SHELF_SIDE_CLEARANCE)

      (1..count).map do |index|
        z = dims.thick + (gap * index) + (dims.thick * (index - 1))
        Panel.new(role: "shelf_#{index}", name: "Shelf #{index}", points: points,
                  extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(z)])
      end
    end
    private_class_method :corner_shelf_panels

    # Shelves are spread evenly between the top of the bottom panel and the
    # underside of the top panel / rails.
    def self.shelf_panels(count, dims)
      return [] unless count.positive?

      clear = dims.height - (2 * dims.thick)
      gap = (clear - (count * dims.thick)) / (count + 1)
      side = Defaults::SHELF_SIDE_CLEARANCE
      extent = [dims.interior_d - dims.shelf_setback, dims.inner_w - (2 * side), dims.thick]

      (1..count).map do |index|
        z = dims.thick + (gap * index) + (dims.thick * (index - 1))
        panel("shelf_#{index}", "Shelf #{index}", extent, [dims.interior_start, dims.thick + side, z])
      end
    end
    private_class_method :shelf_panels

    # Overlay doors that sit in front of the carcass, side by side across the width.
    # One door: the hinge side follows the opening direction. Two or more doors:
    # the left half hinges on the left, the right half on the right, so pairs
    # open in opposite directions.
    #
    # "Left" and "right" are as seen when facing the cabinet front (left = low Y).
    def self.door_panels(params, dims, base_z)
      count = params['door_count'].to_i
      return [] unless count.positive?
      style = corner_style(params)
      return corner_door(params, dims, base_z) if style == 'diagonal'
      return l_doors(params, dims, base_z) if style == 'l_shape'
      return blind_doors(params, dims, base_z) if style == 'blind'
      return bifold_doors(params, dims, base_z) if params['bifold'] == true && count == 2
      return fridge_doors(params, dims, base_z) if params['fridge'] == true
      return oven_doors(params, dims, base_z) if lower_door?(params)
      return split_doors(params, dims, base_z) if params['door_split'] == true
      if params['door_stacked'] == true && count == 2
        doors = stacked_doors(params, dims, base_z)
        doors.each { |door| lift_up!(door) } if params['lift_door'] == true # two layers of lift-up doors: each lifts on its own top edge, apart from the other
        return doors
      end

      gap = params['door_gap'].to_f
      reveal = params['door_reveal'].to_f
      door_w = (dims.width - (2 * reveal) - ((count - 1) * gap)) / count
      door_h, door_z = door_span(params, dims)

      doors = (0...count).map do |index|
        hinge_left = count == 1 ? params['door_opening_direction'].to_s != 'right' : index < count / 2.0
        y = reveal + (index * (door_w + gap))
        Door.new(
          role: "door_#{index + 1}", name: "Door #{index + 1}",
          extent: [dims.thick, door_w, door_h].map { |v| round2(v) },
          offset: [dims.depth + door_distance(params), y, base_z + door_z].map { |v| round2(v) },
          hinge: hinge_left ? 'left' : 'right',
          pivot: [dims.depth + door_distance(params) + dims.thick, hinge_left ? y : y + door_w, base_z].map { |v| round2(v) },
          rotation: 0.0
        )
      end
      lift_up!(doors.last) if lift_up_over_appliances?(params, dims)
      doors.each { |door| lift_up!(door) } if params['lift_door'] == true # a lift-up unit: the flap is hinged on its top edge
      doors
    end
    private_class_method :door_panels

    # A hydraulic bi-fold lift-up: two doors across the whole width, one above the other. The upper one is hinged on its top edge like a lift-up
    # door and carries no handle; the lower one ('fold' hinge: on the bottom edge of the upper one, `parent`) folds up against it as it lifts,
    # and has the handle (on its bottom edge). Each is half of the door height (less the door gap between them).
    def self.bifold_doors(params, dims, base_z)
      gap = params['door_gap'].to_f
      reveal = params['door_reveal'].to_f
      door_w = round2(dims.width - (2 * reveal))
      door_h, door_z = door_span(params, dims)
      each = (door_h - gap) / 2.0
      front = dims.depth + door_distance(params)
      upper_z = door_z + each + gap
      upper = Door.new(role: 'door_1', name: 'Upper Door', extent: [dims.thick, door_w, each].map { |v| round2(v) },
                       offset: [front, reveal, base_z + upper_z].map { |v| round2(v) }, hinge: 'top',
                       pivot: [front + dims.thick, reveal, base_z + upper_z + each].map { |v| round2(v) }, rotation: 0.0, handle: false, bifold: true)
      lower = Door.new(role: 'door_2', name: 'Lower Door', extent: [dims.thick, door_w, each].map { |v| round2(v) },
                       offset: [front, reveal, base_z + door_z].map { |v| round2(v) }, hinge: 'fold',
                       pivot: [front + dims.thick, reveal, base_z + upper_z].map { |v| round2(v) }, rotation: 0.0, parent: upper, bifold: true)
      [upper, lower]
    end
    private_class_method :bifold_doors
    # With two ovens, or an oven and a microwave, the door over the appliances is a lift-up door.
    def self.lift_up_over_appliances?(params, dims)
      zone = front_zone(params, dims)
      !!(zone && zone[:bottom] && zone[:door] && %w[double_oven oven_micro].include?(params['appliance_set'].to_s))
    end
    private_class_method :lift_up_over_appliances?

    # Turns a door into a lift-up door: hinged on its top edge (the pivot is the front face, at the top).
    def self.lift_up!(door)
      door.hinge = 'top'
      door.pivot = [door.pivot[0], door.offset[1], door.offset[2] + door.extent[2]].map { |v| round2(v) }
      door
    end
    private_class_method :lift_up!

    # A CORNER unit's one door runs diagonally between the shortened right-side
    # panel and the front-return panel (see the panel list in `compute` and
    # `corner_footprint`), across the open corner between them.
    #
    #   plan view (X = depth, Y = width, both walls on the low side):
    #
    #     Y=width  ┌──────────A                A = where the right panel ends
    #              │           \.              B = where the front-return panel ends
    #              │            \.             the door runs A -> B, cutting
    #              │             B              the corner off at 45 degrees
    #     Y=0      └──────────────  X=depth
    #     X=0 (back wall)                    (right wall is the Y=width edge)
    #
    # The cut is always at 45 degrees because both panels are inset from the
    # outer square by the same amount (one panel thickness). The hinge (Door
    # Opening Direction) picks which end -- near the right panel (A, "left") or
    # near the front-return panel (B, "right") -- the door pivots from.
    def self.corner_door(params, dims, base_z)
      inner_edge = dims.width - dims.thick
      reveal = params['door_reveal'].to_f
      clear = door_distance(params)
      thick = dims.thick
      outward = [Math.sqrt(0.5), Math.sqrt(0.5)] # away from the back-left wall corner, at 45 degrees

      a = [dims.return_depth, inner_edge]
      b = [inner_edge, dims.return_depth]
      length = Math.hypot(b[0] - a[0], b[1] - a[1])
      # The door's local +Y (its length) turned by +45 degrees points from B
      # towards A, so the door's origin corner sits at B and it runs B -> A.
      offset_xy = [b[0] + (outward[0] * clear), b[1] + (outward[1] * clear)]

      # "Left" is as seen facing the door from outside, which puts the left edge
      # at B (the low end of the door's local Y), the same as any other door:
      # left hinge = low local Y, and the free edge is the high end.
      hinge_left = params['door_opening_direction'].to_s != 'right'
      pivot_far = hinge_left ? b : a
      pivot_xy = [pivot_far[0] + (outward[0] * (clear + thick)), pivot_far[1] + (outward[1] * (clear + thick))]

      [Door.new(
        role: 'door_1', name: 'Door 1',
        extent: [thick, length, dims.height - (2 * reveal)].map { |v| round2(v) },
        offset: [offset_xy[0], offset_xy[1], base_z + reveal].map { |v| round2(v) },
        hinge: hinge_left ? 'left' : 'right',
        pivot: [pivot_xy[0], pivot_xy[1], base_z].map { |v| round2(v) },
        rotation: 45.0
      )]
    end
    private_class_method :corner_door

    # ---- L-shaped corner unit ---------------------------------------------------------
    #
    # Built the way the L-corner builder script does it: two legs, each with its own length and
    # depth, meeting in an L. Plan view, X = depth up the page (front), Y across, walls on the low X
    # and low Y sides:
    #
    #        Y=0                         Y=width (leg 1 length)
    #   X=lb  ┌────────────────────────┐   leg 2 runs along the Y=0 wall: length lb, depth db
    #         │   leg 2 (door B)       │
    #   X=da  ├──────┬─────────────────┘   leg 1 runs along the X=0 wall: length la = Width, depth da = Depth
    #         │ leg 1│
    #   X=0   └──────┘
    #
    # The legs have no inner panels: the two doors are the front, meeting at the inside corner of
    # the L (door A on the front of leg 1, door B on the front of leg 2). The bottom, top and
    # shelves are one L-shaped board. Each leg has its own thin back panel (they meet flush at the
    # wall corner), and an 18 mm side panel closes the end of each leg.
    def self.l_legs(params, dims)
      la = dims.width
      da = dims.return_depth
      lb = params['leg2_length'].to_f.positive? ? params['leg2_length'].to_f : la
      db = params['leg2_depth'].to_f.positive? ? params['leg2_depth'].to_f : da
      { la: la, da: da, lb: lb, db: db }
    end
    private_class_method :l_legs

    def self.l_panels(params, dims)
      t = dims.thick
      l = l_legs(params, dims)
      start = dims.interior_start
      [
        panel('right_side', 'Right Side Panel', [l[:da], t, dims.height], [0, l[:la] - t, 0]),
        panel('front_return', 'Front Side Panel', [t, l[:db], dims.height], [l[:lb] - t, 0, 0]),
        # The left back (along the Y=0 wall, leg 2) is always a full 18 mm panel, flush with the wall,
        # whatever the back panel thickness; leg 1's thin back (along the X=0 wall) starts beside it.
        panel('back_2', 'Left Back Panel', [l[:lb] - t, t, dims.height], [0, 0, 0]),
        # The thin back runs dims.groove (9 mm) into the groove of the panel at each end: the left back panel and the
        # right side panel.
        panel('back', 'Back Panel Leg 1', [dims.back, l[:la] - (2 * t) + (2 * dims.groove), dims.height], [dims.recess, t - dims.groove, 0]),
        Panel.new(role: 'bottom', name: 'Bottom Panel', points: l_footprint(params, dims, 0.0, 0.0),
                  extent: [nil, nil, round2(t)], offset: [0, 0, 0])
      ]
    end
    private_class_method :l_panels

    # The inside outline of the L, inset by `setback` from the doors and `side_margin` from the legs' ends.
    def self.l_footprint(params, dims, setback, side_margin)
      t = dims.thick
      l = l_legs(params, dims)
      s = dims.interior_start
      [
        [s, t],
        [l[:lb] - t - side_margin, t],
        [l[:lb] - t - side_margin, l[:db] - setback],
        [l[:da] - setback, l[:db] - setback],
        [l[:da] - setback, l[:la] - t - side_margin],
        [s, l[:la] - t - side_margin]
      ].map { |x, y| [round2(x), round2(y)] }
    end
    private_class_method :l_footprint

    def self.l_top_panels(params, dims)
      [Panel.new(role: 'top', name: 'Top Panel', points: l_footprint(params, dims, 0.0, 0.0),
                 extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(dims.height - dims.thick)])]
    end
    private_class_method :l_top_panels

    def self.l_shelf_panels(count, params, dims)
      return [] unless count.positive?

      clear = dims.height - (2 * dims.thick)
      gap = (clear - (count * dims.thick)) / (count + 1)
      points = l_footprint(params, dims, dims.shelf_setback, Defaults::SHELF_SIDE_CLEARANCE)
      (1..count).map do |index|
        z = dims.thick + (gap * index) + (dims.thick * (index - 1))
        Panel.new(role: "shelf_#{index}", name: "Shelf #{index}", points: points,
                  extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(z)])
      end
    end
    private_class_method :l_shelf_panels

    # One door on the front of each leg, meeting at the inside corner of the L. By default both hinge
    # at the outer ends, so they open away from the corner ("right" swaps them). Door B starts one
    # door thickness (and a little more) beyond the notch so the two never touch.
    def self.l_doors(params, dims, base_z)
      t = dims.thick
      l = l_legs(params, dims)
      # Sized like the L-corner builder script's shutters: a door gap (1.5 mm) all round and a 2 mm stand-off.
      gap = params['door_gap'].to_f
      clear = door_distance(params)
      height = dims.height - (2 * gap)
      outer = params['door_opening_direction'].to_s != 'right'

      # Leg 1's door (shutter 1 of the script) is Leg 1 Length - Leg 2 Depth - 2 gaps - a panel - 4 mm wide: it
      # steps back from the corner by a panel and 4 mm so door 2's thickness clears it. Leg 2's door (shutter 2)
      # is Leg 2 Length - Leg 1 Depth - 2 gaps.
      y_from = l[:db] + gap + t + 4.0
      y_to = l[:la] - gap
      x_from = l[:da] + gap
      x_to = l[:lb] - gap

      doors = [
        Door.new(role: 'door_1', name: 'Door 1', extent: [t, y_to - y_from, height].map { |v| round2(v) },
                 offset: [l[:da] + clear, y_from, base_z + gap].map { |v| round2(v) },
                 hinge: outer ? 'right' : 'left',
                 pivot: [l[:da] + clear + t, outer ? y_to : y_from, base_z].map { |v| round2(v) }, rotation: 0.0,
                 swing: L_DOOR_SWING),
        # Faces +Y: its frame is turned a quarter turn, so its length runs from x_to back to x_from.
        Door.new(role: 'door_2', name: 'Door 2', extent: [t, x_to - x_from, height].map { |v| round2(v) },
                 offset: [x_to, l[:db] + clear, base_z + gap].map { |v| round2(v) },
                 hinge: outer ? 'left' : 'right',
                 pivot: [outer ? x_to : x_from, l[:db] + clear + t, base_z].map { |v| round2(v) }, rotation: 90.0,
                 swing: L_DOOR_SWING)
      ]
      # One handle, on the narrower door.
      wider = doors.max_by { |door| door.extent[1] }
      wider.handle = false unless doors.first.extent[1] == doors.last.extent[1]
      doors.last.handle = false if doors.first.extent[1] == doors.last.extent[1]
      doors
    end
    L_DOOR_SWING = 120.0 # an L corner's doors open at least this wide, so the inside can be seen
    private_class_method :l_doors
    # ---- blind corner unit --------------------------------------------------------------
    #
    # A straight cabinet whose front is one door over the open part and a fixed panel over the blind
    # part, which sits behind the neighbouring run. The blind panel is always 50 mm wider than the
    # door. Door Opening Direction "left" puts the door on the left and the blind part on the right;
    # "right" swaps them. The door hinges on the blind side, so it opens away from the open end.
    BLIND_EXTRA = 50.0 # how much wider the blind panel is than the door

    # The blind panel is `blind_width` wide (630 mm to start; adjustable) and the door takes the rest of the width.
    # A corner unit saved before that has no blind_width: its panel is 50 mm wider than its door.
    def self.blind_door_width(params, width)
      blind = params['blind_width'].to_f
      room = width - (2 * params['door_reveal'].to_f) - params['door_gap'].to_f
      blind.positive? ? room - blind : (room - BLIND_EXTRA) / 2.0
    end

    def self.blind_split(params, dims)
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      door = blind_door_width(params, dims.width)
      blind = params['blind_width'].to_f.positive? ? params['blind_width'].to_f : door + BLIND_EXTRA
      if params['door_opening_direction'].to_s != 'right' # blind on the right
        { door: [reveal, reveal + door], blind: [reveal + door + gap, dims.width - reveal] }
      else
        { door: [reveal + blind + gap, dims.width - reveal], blind: [reveal, reveal + blind] }
      end
    end
    private_class_method :blind_split

    def self.blind_panel(params, dims)
      from, to = blind_split(params, dims)[:blind]
      reveal = params['door_reveal'].to_f
      blind = panel('blind_front', 'Blind Panel', [dims.thick, to - from, dims.height - (2 * reveal)],
                    [dims.depth + door_distance(params), from, reveal])
      blind.front = true # the blind panel is the same colour as the door
      blind
    end
    private_class_method :blind_panel

    def self.blind_doors(params, dims, base_z)
      from, to = blind_split(params, dims)[:door]
      reveal = params['door_reveal'].to_f
      hinge_left = params['door_opening_direction'].to_s == 'right' # blind on the left: the hinge is on the left, next to it
      door_w = to - from
      [Door.new(
        role: 'door_1', name: 'Door 1', extent: [dims.thick, door_w, dims.height - (2 * reveal)].map { |v| round2(v) },
        offset: [dims.depth + door_distance(params), from, base_z + reveal].map { |v| round2(v) },
        hinge: hinge_left ? 'left' : 'right',
        pivot: [dims.depth + door_distance(params) + dims.thick, hinge_left ? from : to, base_z].map { |v| round2(v) },
        rotation: 0.0
      )]
    end
    private_class_method :blind_doors
    # The inner box of every drawer, built the way the drawer script does it: two sides, a bottom, a back
    # and an inner front, all as thick as the carcass panels (Panel Thickness). It is 13 mm clear of the
    # carcass on each side and its back is 46 mm from the wall behind it. The bottom of the lowest drawer
    # rests 20 mm above the bottom panel, the others 20 mm above their front; every box stops 50 mm below
    # the top of its front (and 50 mm under the top rails). Boards are in the drawer's own frame (the
    # origin is the back face of its front at the left edge; X points out of the cabinet, so the box lies
    # at negative X). { drawer role => [Panel, ...] }. A drawer too small for a box gets none.
    def self.drawer_boxes(params, dims, drawers)
      boxes = {}
      return boxes if params['pullout'] == true # a pull-out unit is just its front: nothing inside it
      t = dims.thick # the boards are as thick as the carcass panels (Panel Thickness in the Presets)
      slide = Defaults::DRAWER_SLIDE_GAP
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      base = params['cabinet_category'].to_s == 'wall' ? 0.0 : params['toe_kick_height'].to_f
      lift = Defaults::DRAWER_BOTTOM_LIFT # the bottom board (with the front and back boards on it) is raised this far
      length = dims.depth + door_distance(params) - Defaults::DRAWER_BACK_GAP # from the back of the front to 46 mm off the wall
      drawers.each do |drawer|
        # across the width of its own front, which is the cabinet's less the reveals unless the front was resized
        y0 = (dims.thick - reveal) + slide
        width = drawer.extent[1] - (2 * y0)
        front_z = drawer.offset[2] - base # the front's bottom, above the carcass bottom
        bottom = [front_z + 20.0, dims.thick + 20.0].max
        top = [front_z + drawer.extent[2] - 50.0, dims.height - dims.thick - 50.0 - gap].min
        height = top - bottom
        next if length < 100.0 || width < 100.0 || height < 40.0 || height - t - lift < 10.0

        z0 = bottom - front_z
        name = lambda do |role, label, extent, offset|
          panel("#{drawer.role}_box_#{role}", "Drawer Box #{label}", extent, offset)
        end
        boxes[drawer.role] = [
          name.call('left', 'Side', [length, t, height], [-length, y0, z0]),
          name.call('right', 'Side', [length, t, height], [-length, y0 + width - t, z0]),
          name.call('bottom', 'Bottom', [length, width - (2 * t), t], [-length, y0 + t, z0 + lift]),
          name.call('back', 'Back', [t, width - (2 * t), height - t - lift], [-length, y0 + t, z0 + t + lift]),
          name.call('front', 'Front', [t, width - (2 * t), height - t - lift], [-t, y0 + t, z0 + t + lift])
        ]
      end
      boxes
    end
    private_class_method :drawer_boxes

    # Two doors one above the other, both full width, hinged on the same side (a built-in fridge-freezer):
    # `front_zone` is the height of the top door.
    def self.stacked_doors(params, dims, base_z)
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      clear = door_distance(params)
      top = params['front_zone'].to_f
      top = dims.height * 0.35 unless top.positive? && top < dims.height - 200.0
      width = dims.width - (2 * reveal)
      hinge_left = params['door_opening_direction'].to_s != 'right'
      spans = [[reveal, dims.height - top - gap - reveal], [dims.height - top, top - reveal]] # bottom door, top door
      spans.each_with_index.map do |(z, height), index|
        Door.new(
          role: "door_#{index + 1}", name: "Door #{index + 1}", extent: [dims.thick, width, height].map { |v| round2(v) },
          offset: [dims.depth + clear, reveal, base_z + z].map { |v| round2(v) },
          hinge: hinge_left ? 'left' : 'right',
          pivot: [dims.depth + clear + dims.thick, hinge_left ? reveal : reveal + width, base_z].map { |v| round2(v) },
          rotation: 0.0
        )
      end
    end
    private_class_method :stacked_doors

    # The height and bottom (above the carcass bottom) of the doors: the full height, or, with a
    # front zone, only what is left under the drawers, or only the zone at the top over an open niche.
    def self.door_span(params, dims)
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      zone = front_zone(params, dims)
      return [dims.height - (2 * reveal), reveal] unless zone

      if zone[:bottom]
        return [zone[:door] - reveal, dims.height - zone[:door]] if zone[:door]

        low = zone[:bottom] + gap # the door covers everything above the drawers
        return [dims.height - reveal - low, low]
      end

      if zone[:drawers]
        top = dims.height - zone[:drawers] - gap
        [top - reveal, reveal]
      else
        [zone[:door] - reveal, dims.height - zone[:door]]
      end
    end
    private_class_method :door_span

    # The appliances of an oven housing, stacked above its drawers: a shelf under each appliance, the
    # appliance on it, and (with a door) a rail over the last one. `bottom` is the line the drawers' zone
    # ends at: the TOP of the first shelf, so the drawer fronts cover that shelf's edge, a door reveal
    # short of its top. The set and the heights come from the panel (appliance_set, oven_height,
    # oven2_height for a second oven, micro_height). Returns the same kind of hash as front_zone, with
    # the extra :stack (each { kind:, z:, height: }), :shelves (their bottom edges), :rail (the lower
    # edge of the rail under the door; the door covers it, a door reveal short of its bottom edge) and
    # :top (where the appliances end, with their air gap).
    def self.appliance_stack(params, dims, bottom)
      set = params['appliance_set'].to_s
      return nil unless Defaults::APPLIANCE_SETS.include?(set)

      oven = params['oven_height'].to_f.positive? ? params['oven_height'].to_f : Defaults::OVEN_HEIGHT
      oven2 = params['oven2_height'].to_f.positive? ? params['oven2_height'].to_f : oven
      micro = params['micro_height'].to_f.positive? ? params['micro_height'].to_f : Defaults::MICRO_HEIGHT
      kinds = { 'oven' => [[:oven, oven]], 'double_oven' => [[:oven, oven], [:oven, oven2]], 'oven_micro' => [[:oven, oven], [:micro, micro]] }[set]

      z = bottom - dims.thick
      shelves = []
      stack = []
      kinds.each do |kind, height|
        shelves << z
        z += dims.thick
        stack << { kind: kind, z: z, height: height }
        z += height + APPLIANCE_GAP
      end
      return { bottom: bottom, door: nil, stack: stack, shelves: shelves, rail: nil, top: z } unless params['door_count'].to_i.positive?

      reveal = params['door_reveal'].to_f
      { bottom: bottom, door: dims.height - (z + reveal), stack: stack, shelves: shelves, rail: z, top: z }
    end
    private_class_method :appliance_stack
    APPLIANCE_GAP = 4.0 # air above each appliance

    # The appliances themselves, built from plain boxes in the carcass's frame (an oven: body, steel
    # front, control strip with a display and knobs, glass window, handle; a microwave: the same with the
    # window beside a control panel; a fridge: a white body behind steel fronts). Which material a part
    # gets follows the end of its role (see CabinetGenerator.appliance_finish).
    def self.appliance_boxes(params, dims, zone)
      out = []
      counts = Hash.new(0)
      (zone && zone[:stack] || []).each do |item|
        counts[item[:kind]] += 1
        key = "appliance_#{item[:kind]}_#{counts[item[:kind]]}"
        out.concat(item[:kind] == :oven ? AppliancePieces.oven(key, dims, item) : AppliancePieces.microwave(key, dims, item))
      end
      # (A built-in fridge housing is just the housing: doors, shelf and lift-up door. No fridge is drawn inside it.)
      out.concat(Fixtures.parts(params, dims)) # the sink, the hob, the hood
      out
    end
    private_class_method :appliance_boxes

    # One box of an appliance: [x, y, z] its corner, [dx, dy, dz] its size.
    def self.part(key, suffix, label, corner, size)
      panel("#{key}_#{suffix}", label, size, corner)
    end
    private_class_method :part

    # The oven, microwave, built-in fridge and freestanding fridge are drawn by AppliancePieces (appliance_parts.rb).

    # ---- a built-in fridge (or fridge-freezer) -------------------------------------------
    #
    # Fridge units draw a fridge behind their doors. `fridge_height` is the height of the fridge doors
    # from the carcass bottom; whatever is above it is a shelf and a lift-up door, which hinges on its top
    # edge. With no room for one (the fridge height is the unit height) the door runs the full height.
    # The fridge door covers the front of the shelf under the lift-up door, a door reveal short of its
    # top edge. Two doors (a fridge-freezer) are stacked, `front_zone` being the top one's height.
    FRIDGE_MIN_LIFT = 100.0 # the least height a lift-up door above the fridge can have

    # ---- a tall unit's doors in two halves ------------------------------------------------------------
    # `split_height` is the height of the lower doors, the upper ones take the rest; each column of the unit (one door,
    # or two side by side) is split at the same line, and the handles sit next to the gap between them. The lower
    # doors are numbered first, then the upper ones.
    def self.split_doors(params, dims, base_z)
      count = params['door_count'].to_i
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      clear = door_distance(params)
      door_w = (dims.width - (2 * reveal) - ((count - 1) * gap)) / count
      lower = params['split_height'].to_f.positive? ? params['split_height'].to_f : 1000.0
      upper = dims.height - (2 * reveal) - gap - lower

      [[reveal, lower, 'bottom'], [reveal + lower + gap, upper, 'top']].each_with_index.flat_map do |(z, height, edge), row|
        (0...count).map do |index|
          hinge_left = count == 1 ? params['door_opening_direction'].to_s != 'right' : index < count / 2.0
          y = reveal + (index * (door_w + gap))
          number = (row * count) + index + 1
          Door.new(
            role: "door_#{number}", name: "Door #{number}", extent: [dims.thick, door_w, height].map { |v| round2(v) },
            offset: [dims.depth + clear, y, base_z + z].map { |v| round2(v) },
            hinge: hinge_left ? 'left' : 'right',
            pivot: [dims.depth + clear + dims.thick, hinge_left ? y : y + door_w, base_z].map { |v| round2(v) },
            rotation: 0.0, grip: edge == 'bottom' ? 'top' : 'bottom'
          )
        end
      end
    end
    private_class_method :split_doors

    # ---- the lower part of an oven housing: drawers, a door, or a small drawer over a door ------------
    LOWER_DOOR_MODES = %w[door drawer_door].freeze

    def self.lower_door?(params)
      LOWER_DOOR_MODES.include?(params['lower_mode'].to_s)
    end
    private_class_method :lower_door?

    # The doors of an oven housing whose lower part has a door: the lower door (alone, or under a small drawer) and the
    # door over the appliances. All hinge the same way.
    def self.oven_doors(params, dims, base_z)
      zone = front_zone(params, dims)
      return [] unless zone && zone[:bottom]

      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      clear = door_distance(params)
      width = dims.width - (2 * reveal)
      hinge_left = params['door_opening_direction'].to_s != 'right'
      lower = zone[:bottom] - (2 * reveal) # what the lower part shares
      lower -= gap + params['small_drawer'].to_f if params['lower_mode'] == 'drawer_door'
      spans = [[reveal, lower]]
      if zone[:door]
        height, z = door_span(params, dims)
        spans << [z, height]
      end
      doors = spans.each_with_index.map do |(z, height), index|
        Door.new(
          role: "door_#{index + 1}", name: "Door #{index + 1}", extent: [dims.thick, width, height].map { |v| round2(v) },
          offset: [dims.depth + clear, reveal, base_z + z].map { |v| round2(v) },
          hinge: hinge_left ? 'left' : 'right',
          pivot: [dims.depth + clear + dims.thick, hinge_left ? reveal : reveal + width, base_z].map { |v| round2(v) },
          rotation: 0.0
        )
      end
      lift_up!(doors.last) if zone[:door] && lift_up_over_appliances?(params, dims)
      doors
    end
    private_class_method :oven_doors

    # The one small drawer at the top of the lower part, over its door.
    def self.small_drawer(params, dims, base_z)
      zone = front_zone(params, dims)
      return [] unless zone && zone[:bottom]

      reveal = params['door_reveal'].to_f
      height = params['small_drawer'].to_f
      [Door.new(
        role: 'drawer_1', name: 'Drawer 1', extent: [dims.thick, dims.width - (2 * reveal), height].map { |v| round2(v) },
        offset: [dims.depth + door_distance(params), reveal, base_z + zone[:bottom] - reveal - height].map { |v| round2(v) },
        hinge: 'center', pivot: [dims.depth, reveal, base_z].map { |v| round2(v) }, rotation: 0.0
      )]
    end
    private_class_method :small_drawer

    # ---- a freestanding fridge: no carcass, just the fridge itself ----------------------------------------
    # Width x depth x height as entered (see AppliancePieces.free_fridge for how it looks by width).
    def self.freestanding_layout(params, dims)
      hinge_left = params['door_opening_direction'].to_s != 'right'
      parts = AppliancePieces.free_fridge('appliance_fridge_1_free', 0.0, 0.0, 0.0, dims.width, dims.depth, dims.height, hinge_left)
      apply_overrides(Layout.new(base_z: 0.0, top_z: round2(dims.height), panels: [], doors: [], drawers: [], toe_kick: [], drawer_boxes: {}, appliances: parts), params)
    end
    private_class_method :freestanding_layout

    # ---- a housing for a freestanding fridge ----------------------------------------------------------------
    # Two side panels (the door material) as deep as the cabinet and as high as it is, a fridge standing between them
    # with its doors flush with the panels, and over it a cabinet of its own with the extension's standard carcass
    # (sides, top, bottom, back) and a standard lift-up door (reveal, gap and overlay as on any door). `housing_lift`
    # is the height of that cabinet, 360 mm to start (the height of our short wall units). Width is the whole unit,
    # panels included.
    HOUSING_LIFT = 360.0
    def self.housing_layout(params, dims)
      t = dims.thick
      d = dims.depth
      w = dims.width
      h = dims.height
      reveal = params['door_reveal'].to_f
      clear = door_distance(params)
      lift = params['housing_lift'].to_f
      lift = HOUSING_LIFT unless lift.positive?
      lift = [lift, h - 800.0].min
      cab_z = h - lift
      cab_w = dims.inner_w          # the cabinet fills the space between the panels
      cab_d = d - t - clear         # so that its door is flush with the front of the panels
      inner = cab_w - (2 * t)
      start = dims.interior_start
      sides = [panel('left_side', 'Left Side Panel', [d, t, h], [0, 0, 0]),
               panel('right_side', 'Right Side Panel', [d, t, h], [0, w - t, 0])]
      sides.each { |side| side.front = true } # the side panels are the colour of the doors
      panels = sides + [
        panel('lift_left', 'Lift Cabinet Left Side', [cab_d, t, lift], [0, t, cab_z]),
        panel('lift_right', 'Lift Cabinet Right Side', [cab_d, t, lift], [0, w - (2 * t), cab_z]),
        panel('back', 'Back Panel', [dims.back, inner + (2 * dims.groove), lift], [dims.recess, (2 * t) - dims.groove, cab_z]),
        panel('lift_bottom', 'Lift Cabinet Bottom', [cab_d - start, inner, t], [start, 2 * t, cab_z]),
        panel('top', 'Top Panel', [cab_d - start, inner, t], [start, 2 * t, h - t])
      ]
      door_h = lift - (2 * reveal)
      y = t + reveal
      z = cab_z + reveal
      front = cab_d + clear # the back face of the door
      door = Door.new(
        role: 'door_1', name: 'Lift-up Door', extent: [t, cab_w - (2 * reveal), door_h].map { |v| round2(v) },
        offset: [front, y, z].map { |v| round2(v) }, hinge: 'top', pivot: [front + t, y, z + door_h].map { |v| round2(v) }, rotation: 0.0
      )
      niche = cab_z - 15.0
      fridge_w = dims.inner_w - 10.0
      fridge_d = d - 25.0 # flush with the front of the panels, 25 mm off the wall
      parts = niche >= 700.0 && fridge_w >= 400.0 ? AppliancePieces.free_fridge('appliance_fridge_1_housed', d - fridge_d, t + 5.0, 0.0, fridge_w, fridge_d, niche, params['door_opening_direction'].to_s != 'right') : []
      apply_overrides(Layout.new(base_z: 0.0, top_z: round2(h), panels: panels, doors: [door], drawers: [], toe_kick: [], drawer_boxes: {}, appliances: parts), params)
    end
    private_class_method :housing_layout    # nil for a unit that is not a fridge; otherwise
    # { spans: [[z, height], ...] bottom door first, lift: [z, height] or nil, shelf_z: shelf lower edge or nil,
    #   split: z between two doors or nil, body: [bottom, top] of the fridge itself, top_end: where the top fridge door ends }
    #
    # `fridge_height` is the height of the (bottom) fridge door and `front_zone` the top door's, both as entered. The
    # doors together reach F; above F is the lift-up door (`fridge_lift`, on by default) or, with it switched off,
    # the top door simply carries on to the top. Either way a shelf stands over the fridge at F.
    def self.fridge_layout(params, dims)
      return nil unless params['fridge'] == true && params['door_count'].to_i.positive?

      t = dims.thick
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      full = dims.height
      two = params['door_count'].to_i >= 2
      first = params['fridge_height'].to_f
      if two
        bottom = first.positive? ? first : 675.0
        top = params['front_zone'].to_f
        top = 1100.0 unless top.positive?
        f = reveal + bottom + gap + top + reveal
      else
        bottom = first.positive? ? first : 1780.0
        f = bottom + (2 * reveal)
      end
      f = [f, full].min
      lifted = params['fridge_lift'] != false && full - f >= FRIDGE_MIN_LIFT
      shelved = full - f >= (2 * t) # room for a shelf over the fridge

      end_z = (lifted ? f : full) - reveal # where the top fridge door ends
      if two
        low = reveal + bottom + gap
        spans = [[reveal, bottom], [low, end_z - low]]
        split = reveal + bottom + (gap / 2.0)
      else
        spans = [[reveal, end_z - reveal]]
        split = nil
      end

      shelf_z = shelved ? f - t : nil
      lift = lifted ? [f - reveal + gap, full - reveal - (f - reveal + gap)] : nil
      { spans: spans, lift: lift, shelf_z: shelf_z, split: split, top_end: end_z, f: f,
        body: [t, (shelf_z || (full - t)) - APPLIANCE_GAP] }
    end
    private_class_method :fridge_layout

    # The shelf under the lift-up door, flush with the carcass front.
    def self.fridge_panels(dims, fridge)
      return [] unless fridge[:shelf_z]

      [panel('fridge_shelf', 'Fridge Shelf', [dims.interior_d, dims.inner_w, dims.thick], [dims.interior_start, dims.thick, fridge[:shelf_z]])]
    end
    private_class_method :fridge_panels

    # The fridge door(s), one above the other and all hinged on the same side, and the lift-up door over
    # them (the last door; it hinges on its top edge and has no vertical hinge).
    def self.fridge_doors(params, dims, base_z)
      fridge = fridge_layout(params, dims)
      reveal = params['door_reveal'].to_f
      clear = door_distance(params)
      width = dims.width - (2 * reveal)
      hinge_left = params['door_opening_direction'].to_s != 'right'
      x = dims.depth + clear

      doors = fridge[:spans].each_with_index.map do |(z, height), index|
        # two doors: both handles next to the gap between them
        grip = fridge[:spans].length > 1 ? (index.zero? ? 'top' : 'bottom') : nil
        Door.new(
          role: "door_#{index + 1}", name: "Door #{index + 1}", extent: [dims.thick, width, height].map { |v| round2(v) },
          offset: [x, reveal, base_z + z].map { |v| round2(v) },
          hinge: hinge_left ? 'left' : 'right',
          pivot: [x + dims.thick, hinge_left ? reveal : reveal + width, base_z].map { |v| round2(v) },
          rotation: 0.0, grip: grip
        )
      end
      if fridge[:lift]
        z, height = fridge[:lift]
        index = doors.length + 1
        doors << Door.new(
          role: "door_#{index}", name: 'Lift-up Door', extent: [dims.thick, width, height].map { |v| round2(v) },
          offset: [x, reveal, base_z + z].map { |v| round2(v) },
          hinge: 'top', pivot: [x + dims.thick, reveal, base_z + z + height].map { |v| round2(v) }, rotation: 0.0
        )
      end
      doors
    end
    private_class_method :fridge_doors


    # nil without a zone; { drawers: zone_height } over a door, { door: zone_height } for a door on top
    # of an open niche (a fridge housing).
    def self.front_zone(params, dims)
      zone = params['front_zone'].to_f
      bottom = params['bottom_zone'].to_f
      return nil if params['door_stacked'] == true # two stacked doors use front_zone for the top door's height
      return nil if params['fridge'] == true # a fridge unit: front_zone is its top door's height (see fridge_layout)

      # An oven housing: drawers at the bottom, the door at the top, an open niche between. (A base unit
      # with a built-in oven has no door: the oven stands over its drawer and the top panel closes it.)
      if bottom.positive? && bottom < dims.height && (params['drawer_count'].to_i.positive? || lower_door?(params))
        stack = appliance_stack(params, dims, bottom)
        return stack if stack
        return nil unless params['door_count'].to_i.positive?
        return { bottom: bottom, door: (zone.positive? && zone + bottom < dims.height ? zone : nil) }
      end
      return nil unless params['door_count'].to_i.positive?
      return nil unless zone.positive? && zone < dims.height

      params['drawer_count'].to_i.positive? ? { drawers: zone } : { door: zone }
    end
    private_class_method :front_zone

    # Overlay drawer fronts, stacked from bottom to top in one column across the
    # full width, using the same reveal/gap and overlay plane as doors. Each is a
    # Door-shaped struct (role "drawer_N") so it can share the door/handle
    # container code in CabinetGenerator; `hinge` is set to 'center' as a marker
    # meaning "a drawer handle always centres horizontally" (see HandleManager),
    # and `pivot` is unused since a drawer slides rather than swings.
    def self.drawer_panels(params, dims, base_z)
      count = params['drawer_count'].to_i
      return [] unless count.positive?
      return small_drawer(params, dims, base_z) if params['lower_mode'] == 'drawer_door'

      gap = params['door_gap'].to_f
      reveal = params['door_reveal'].to_f
      front_w = dims.width - (2 * reveal)
      zone = front_zone(params, dims)
      # Over a door the drawers share the zone at the top; otherwise they share the whole height.
      from = zone && zone[:drawers] ? dims.height - zone[:drawers] : reveal
      # What the fronts share: an oven housing's drawers stop a door reveal short of the top of the first
      # shelf (`bottom` is that line), drawers over a door share their zone, otherwise the whole height.
      share =
        if zone && zone[:bottom] then zone[:bottom] - (2 * reveal)
        elsif zone then zone[:drawers] - reveal
        else dims.height - (2 * reveal)
        end
      heights = drawer_heights(params, count, share - ((count - 1) * gap))

      z = from
      heights.each_with_index.map do |front_h, index|
        drawer = Door.new(
          role: "drawer_#{index + 1}", name: "Drawer #{index + 1}",
          extent: [dims.thick, front_w, front_h].map { |v| round2(v) },
          offset: [dims.depth + door_distance(params), reveal, base_z + z].map { |v| round2(v) },
          hinge: 'center', pivot: [dims.depth, reveal, base_z].map { |v| round2(v) }, rotation: 0.0
        )
        z += front_h + gap
        drawer
      end
    end
    private_class_method :drawer_panels

    # The heights of the drawer fronts, lowest first, sharing `total`. Equal, unless the unit has a
    # drawer_pattern like "1,1,2" (listed from the top down: two small drawers over a big one).
    def self.drawer_heights(params, count, total)
      weights = params['drawer_pattern'].to_s.split(',').map(&:to_f)
      weights = [1.0] * count unless weights.length == count && weights.all?(&:positive?)
      # Heights typed for single drawers (top down; a blank has none): those drawers are as typed, the rest share what is left.
      typed = params['drawer_heights'].to_s.split(',', -1).first(count).map { |text| text.strip.to_f }
      typed += [0.0] * (count - typed.length)
      if typed.any?(&:positive?)
        free_weight = (0...count).sum { |i| typed[i].positive? ? 0.0 : weights[i] }
        rest = [total - typed.sum, 0.0].max
        return (0...count).map { |i| typed[i].positive? ? typed[i] : rest * weights[i] / free_weight }.reverse # the first drawer is the lowest
      end

      weights = weights.reverse # the first drawer is the lowest
      sum = weights.sum
      weights.map { |weight| total * weight / sum }
    end
    private_class_method :drawer_heights

    def self.panel(role, name, extent, offset)
      Panel.new(role: role, name: name, extent: extent.map { |v| round2(v) }, offset: offset.map { |v| round2(v) }, points: nil)
    end
    private_class_method :panel

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end

# The sink, hob and hood parts (loaded here too so the layout works wherever it is loaded alone, as in the tests).
require_relative 'front_design'
require_relative 'appliance_parts'
require_relative 'fixtures'
