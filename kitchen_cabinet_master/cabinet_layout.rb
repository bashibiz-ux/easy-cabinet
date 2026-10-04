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
    Panel  = Struct.new(:role, :name, :extent, :offset, :points, :rotation, :round, :round_edge, :front, keyword_init: true)
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
    Door   = Struct.new(:role, :name, :extent, :offset, :hinge, :pivot, :rotation, :swing, :handle, :grip, keyword_init: true)
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
      panels.concat(zone_panels(params, dims, zone))
      fridge = fridge_layout(params, dims)
      panels.concat(fridge_panels(dims, fridge)) if fridge
      panels << top_front_panel(params, dims) if params['top_front'].to_f.positive?
      doors = door_panels(params, dims, base_z)
      drawers = drawer_panels(params, dims, base_z)
      Layout.new(base_z: base_z, top_z: round2(base_z + dims.height), panels: panels, doors: doors,
                 drawers: drawers, toe_kick: [], drawer_boxes: drawer_boxes(params, dims, drawers),
                 appliances: appliance_boxes(params, dims, front_zone(params, dims)))
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
      base_z = category == 'wall' || params['freestanding'] == true ? 0.0 : params['toe_kick_height'].to_f
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
      return fridge_doors(params, dims, base_z) if params['fridge'] == true
      return oven_doors(params, dims, base_z) if lower_door?(params)
      return stacked_doors(params, dims, base_z) if params['door_stacked'] == true && count == 2

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
      doors
    end
    private_class_method :door_panels

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
      t = dims.thick # the boards are as thick as the carcass panels (Panel Thickness in the Presets)
      slide = Defaults::DRAWER_SLIDE_GAP
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      base = params['cabinet_category'].to_s == 'wall' ? 0.0 : params['toe_kick_height'].to_f
      lift = Defaults::DRAWER_BOTTOM_LIFT # the bottom board (with the front and back boards on it) is raised this far
      length = dims.depth + door_distance(params) - Defaults::DRAWER_BACK_GAP # from the back of the front to 46 mm off the wall
      width = dims.inner_w - (2 * slide)
      drawers.each do |drawer|
        front_z = drawer.offset[2] - base # the front's bottom, above the carcass bottom
        bottom = [front_z + 20.0, dims.thick + 20.0].max
        top = [front_z + drawer.extent[2] - 50.0, dims.height - dims.thick - 50.0 - gap].min
        height = top - bottom
        next if length < 100.0 || width < 100.0 || height < 40.0 || height - t - lift < 10.0

        y0 = (dims.thick - reveal) + slide
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
        out.concat(item[:kind] == :oven ? oven_parts(key, dims, item) : microwave_parts(key, dims, item))
      end
      fridge = fridge_layout(params, dims)
      out.concat(fridge_parts(dims, fridge)) if fridge
      out
    end
    private_class_method :appliance_boxes

    # One box of an appliance: [x, y, z] its corner, [dx, dy, dz] its size.
    def self.part(key, suffix, label, corner, size)
      panel("#{key}_#{suffix}", label, size, corner)
    end
    private_class_method :part

    # A plate as wide as the unit less 8 mm (a 900 mm unit takes a 900 mm oven), centred.
    def self.appliance_plate_width(dims)
      [dims.width - 8.0, 900.0].min
    end
    private_class_method :appliance_plate_width

    def self.oven_parts(key, dims, item)
      front = dims.depth # the carcass front
      h = item[:height]
      z0 = item[:z]
      w = appliance_plate_width(dims)
      y0 = (dims.width - w) / 2.0
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 550.0].min
      margin = 12.0
      strip = [56.0, h * 0.12].min
      strip_z = z0 + h - margin - strip
      handle_z = strip_z - 30.0
      glass_top = handle_z - 8.0 - 14.0
      glass_bottom = z0 + 36.0
      handle_w = [w - 160.0, 100.0].max
      handle_y = y0 + ((w - handle_w) / 2.0)
      x = front + 6.0 # the face of the steel front

      parts = [
        part(key, 'body', 'Oven Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        part(key, 'frame', 'Oven Front', [front, y0, z0], [6.0, w, h]),
        part(key, 'panel', 'Oven Control Strip', [x, y0 + margin, strip_z], [1.5, w - (2 * margin), strip]),
        part(key, 'display', 'Oven Display', [x + 1.5, y0 + (w / 2.0) - 35.0, strip_z + (strip / 2.0) - 11.0], [1.0, 70.0, 22.0]),
        part(key, 'knob_1', 'Oven Knob 1', [x + 1.5, y0 + margin + 22.0, strip_z + (strip / 2.0) - 13.0], [10.0, 26.0, 26.0]),
        part(key, 'knob_2', 'Oven Knob 2', [x + 1.5, y0 + w - margin - 22.0 - 26.0, strip_z + (strip / 2.0) - 13.0], [10.0, 26.0, 26.0]),
        part(key, 'handle', 'Oven Handle', [x + 22.0, handle_y, handle_z - 8.0], [12.0, handle_w, 16.0]),
        part(key, 'post_1', 'Oven Handle Post 1', [x, handle_y, handle_z - 8.0], [22.0, 16.0, 16.0]),
        part(key, 'post_2', 'Oven Handle Post 2', [x, handle_y + handle_w - 16.0, handle_z - 8.0], [22.0, 16.0, 16.0])
      ]
      if glass_top - glass_bottom >= 50.0
        parts << part(key, 'glass', 'Oven Window', [x, y0 + 40.0, glass_bottom], [2.0, w - 80.0, glass_top - glass_bottom])
      end
      parts
    end
    private_class_method :oven_parts

    def self.microwave_parts(key, dims, item)
      front = dims.depth
      h = item[:height]
      z0 = item[:z]
      w = appliance_plate_width(dims)
      y0 = (dims.width - w) / 2.0
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 350.0].min
      margin = 14.0
      ctrl_w = (w * 0.22).round
      ctrl_y = y0 + w - margin - ctrl_w
      glass_w = ctrl_y - 30.0 - (y0 + margin)
      handle_h = h * 0.55
      x = front + 6.0

      parts = [
        part(key, 'body', 'Microwave Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        part(key, 'frame', 'Microwave Front', [front, y0, z0], [6.0, w, h]),
        part(key, 'panel', 'Microwave Control Panel', [x, ctrl_y, z0 + margin], [1.5, ctrl_w, h - (2 * margin)]),
        part(key, 'display', 'Microwave Display', [x + 1.5, ctrl_y + 10.0, z0 + h - margin - 14.0 - 24.0], [1.0, ctrl_w - 20.0, 24.0]),
        part(key, 'handle', 'Microwave Handle', [x + 22.0, ctrl_y - 26.0, z0 + ((h - handle_h) / 2.0)], [12.0, 14.0, handle_h]),
        part(key, 'post_1', 'Microwave Handle Post 1', [x, ctrl_y - 26.0, z0 + ((h - handle_h) / 2.0)], [22.0, 14.0, 14.0]),
        part(key, 'post_2', 'Microwave Handle Post 2', [x, ctrl_y - 26.0, z0 + ((h + handle_h) / 2.0) - 14.0], [22.0, 14.0, 14.0])
      ]
      3.times do |index|
        parts << part(key, "knob_#{index + 1}", "Microwave Button #{index + 1}",
                      [x + 1.5, ctrl_y + 15.0, z0 + margin + 20.0 + (index * 34.0)], [8.0, ctrl_w - 30.0, 18.0])
      end
      parts << part(key, 'glass', 'Microwave Window', [x, y0 + margin, z0 + margin], [2.0, glass_w, h - (2 * margin)]) if glass_w >= 60.0
      parts
    end
    private_class_method :microwave_parts

    # ---- a built-in fridge (or fridge-freezer) -------------------------------------------
    #
    # Fridge units draw a fridge behind their doors. `fridge_height` is the height of the fridge doors
    # from the carcass bottom; whatever is above it is a shelf and a lift-up door, which hinges on its top
    # edge. With no room for one (the fridge height is the unit height) the door runs the full height.
    # The fridge door covers the front of the shelf under the lift-up door, a door reveal short of its
    # top edge. Two doors (a fridge-freezer) are stacked, `front_zone` being the top one's height.
    FRIDGE_MIN_LIFT = 100.0 # the least height a lift-up door above the fridge can have

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
    # Width x depth x height as entered. A white body on a dark plinth, a steel door each for the freezer (below)
    # and the fridge (above), and a vertical handle on each next to the gap between them.
    def self.freestanding_layout(params, dims)
      w = dims.width
      d = dims.depth
      h = dims.height
      plinth = 25.0
      body_h = h - plinth
      freezer = (body_h * 0.3).round
      door_t = 22.0
      key = 'appliance_fridge_1_free'
      split = plinth + freezer
      right_hinge = params['door_opening_direction'].to_s == 'right'
      y = right_hinge ? 25.0 : w - 25.0 - 22.0 # the handles are at the free edge
      parts = [
        part(key, 'panel', 'Fridge Plinth', [30.0, 20.0, 0.0], [d - 60.0, w - 40.0, plinth]),
        part(key, 'body', 'Fridge Body', [0.0, 0.0, plinth], [d - door_t, w, body_h]),
        part(key, 'plate_1', 'Fridge Freezer Door', [d - door_t, 0.0, plinth], [door_t, w, freezer - 2.0]),
        part(key, 'plate_2', 'Fridge Door', [d - door_t, 0.0, split + 2.0], [door_t, w, h - split - 2.0]),
        part(key, 'handle_1', 'Fridge Freezer Handle', [d, y, split - 40.0 - 300.0], [30.0, 22.0, 300.0]),
        part(key, 'handle_2', 'Fridge Handle', [d, y, split + 40.0], [30.0, 22.0, 450.0])
      ]
      Layout.new(base_z: 0.0, top_z: round2(h), panels: [], doors: [], drawers: [], toe_kick: [], drawer_boxes: {}, appliances: parts)
    end
    private_class_method :freestanding_layout
    # nil for a unit that is not a fridge; otherwise
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

    # The fridge: a white body on the bottom panel and, on its front, one steel plate per door.
    def self.fridge_parts(dims, fridge)
      bottom, top = fridge[:body]
      return [] unless top - bottom >= 200.0

      front = dims.depth
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 560.0].min
      w = appliance_plate_width(dims)
      y0 = (dims.width - w) / 2.0
      key = 'appliance_fridge_1'
      parts = [part(key, 'body', 'Fridge Body', [front - body_d, (dims.width - body_w) / 2.0, bottom], [body_d, body_w, top - bottom])]
      if fridge[:split]
        parts << part(key, 'plate_1', 'Fridge Lower Front', [front, y0, bottom], [2.0, w, fridge[:split] - 2.0 - bottom])
        parts << part(key, 'plate_2', 'Fridge Upper Front', [front, y0, fridge[:split] + 2.0], [2.0, w, top - fridge[:split] - 2.0])
      else
        parts << part(key, 'plate_1', 'Fridge Front', [front, y0, bottom], [2.0, w, top - bottom])
      end
      parts
    end
    private_class_method :fridge_parts

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
