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
    Panel  = Struct.new(:role, :name, :extent, :offset, :points, :rotation, :round, :round_edge, keyword_init: true)
    # A door is a panel plus a hinge. `pivot` is the vertical hinge axis in cabinet
    # coordinates (on the door's FRONT face edge, so the door never swings back
    # into the carcass, even at wide opening angles).
    # `rotation` (degrees about Z, applied at `offset` before the door's own
    # swing) is 0 for every ordinary axis-aligned door or drawer; a corner
    # unit's diagonal door is the one case that sets it (see corner_door).
    Door   = Struct.new(:role, :name, :extent, :offset, :hinge, :pivot, :rotation, keyword_init: true)
    Layout = Struct.new(:base_z, :top_z, :panels, :doors, :drawers, :toe_kick, keyword_init: true)
    # `return_depth` is only meaningful for a corner unit: how far its shortened
    # right-side panel and front-return panel extend (see corner geometry
    # methods below); for every other category it is unused.
    Dims   = Struct.new(:width, :depth, :height, :thick, :back, :inner_w, :interior_start, :interior_d,
                        :shelf_setback, :return_depth, :recess, :groove, keyword_init: true)

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
      category = params['cabinet_category'].to_s
      style = corner_style(params)

      # A wall unit can have its carcass bottom lifted (room for a panel under it): the
      # carcass is shorter and starts higher, while the doors keep the full height.
      full_height = dims.height
      lift = category == 'wall' ? [params['carcass_raise'].to_f, 0.0].max : 0.0
      dims.height = full_height - lift

      panels =
        if style == 'l_shape'
          l_panels(dims)
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
        when 'l_shape' then l_top_panels(dims)
        else top_panels(category, dims, params['top_panel_style'], open: open_unit?(params))
        end
      )
      panels.concat(
        if style == 'diagonal'
          corner_shelf_panels(params['shelf_count'].to_i, dims)
        elsif style == 'l_shape'
          l_shelf_panels(params['shelf_count'].to_i, dims)
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
      if zone && zone[:bottom] # an oven housing: a shelf for the oven over the drawers, a rail under the door
        shelf = [dims.interior_d - dims.shelf_setback, dims.inner_w, dims.thick]
        panels << panel('oven_shelf', 'Oven Shelf', shelf, [dims.interior_start, dims.thick, zone[:bottom]])
        panels << panel('niche_rail', 'Niche Rail', shelf, [dims.interior_start, dims.thick, dims.height - zone[:door] - dims.thick]) if zone[:door]
      elsif zone && zone[:drawers] # a rail between the drawers and the door below
        mid = dims.height - zone[:drawers] - (params['door_gap'].to_f / 2.0) - (dims.thick / 2.0)
        panels << panel('drawer_rail', 'Drawer Rail', [dims.interior_d, dims.inner_w, dims.thick], [dims.interior_start, dims.thick, mid])
      end
      doors = door_panels(params, dims, base_z)
      drawers = drawer_panels(params, dims, base_z)
      Layout.new(base_z: base_z, top_z: round2(base_z + dims.height), panels: panels, doors: doors,
                 drawers: drawers, toe_kick: [])
    end

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
      base_z = category == 'wall' ? 0.0 : params['toe_kick_height'].to_f
      # A corner unit's outer footprint is a square sized by Width in both
      # directions; its own Depth instead controls the internal return panels.
      square = corner?(params)
      nominal_depth = square ? params['width'].to_f : params['depth'].to_f
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
      depth = width if corner

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

      gap = params['door_gap'].to_f
      reveal = params['door_reveal'].to_f
      door_w = (dims.width - (2 * reveal) - ((count - 1) * gap)) / count
      door_h, door_z = door_span(params, dims)

      (0...count).map do |index|
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
    end
    private_class_method :door_panels

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
    #   plan view (X = depth up the page is the front, walls on the low X and low Y sides):
    #
    #            Y=0                       Y=width
    #   X=depth  ┌──────────────────────────┐ ...  arm 2 runs along the Y=0 wall
    #            │  open room corner        │
    #   X=D      ├─────┐                    │      arm 1 runs along the X=0 wall
    #            │ door│ (arm 1 front)      │
    #   X=0      └─────┴────────────────────┘
    #
    # Two arms of depth `return_depth` (the Depth field) meet in an L; the front of each arm has
    # a door, so the inside of the L is reached from the room through two doors at right angles.
    # The footprint is a Width x Width square, like the diagonal corner unit, and the row turns a
    # quarter turn there in the same way.
    def self.l_panels(dims)
      t = dims.thick
      d = dims.return_depth
      w = dims.width
      [
        panel('left_side', 'Left Side Panel', [w - t, t, dims.height], [0, 0, 0]),
        panel('right_side', 'Right Side Panel', [d, t, dims.height], [0, w - t, 0]),
        panel('front_return', 'Front Return Panel', [t, d, dims.height], [w - t, 0, 0]),
        panel('inner_front_1', 'Inner Front Panel', [t, w - d, dims.height], [d - t, d - t, 0]),
        panel('inner_front_2', 'Inner Front Panel', [w - d - t, t, dims.height], [d, d - t, 0]),
        back_panel(dims),
        Panel.new(role: 'bottom', name: 'Bottom Panel', points: l_footprint(dims, 0.0, 0.0),
                  extent: [nil, nil, round2(t)], offset: [0, 0, 0])
      ]
    end
    private_class_method :l_panels

    # The inside outline of the L, inset by `setback` from the doors and `side_margin` from the sides.
    def self.l_footprint(dims, setback, side_margin)
      t = dims.thick
      d = dims.return_depth
      w = dims.width
      [
        [dims.interior_start, t + side_margin],
        [dims.interior_start, w - t - side_margin],
        [d - t - setback, w - t - side_margin],
        [d - t - setback, d - t - setback],
        [w - t - side_margin, d - t - setback],
        [w - t - side_margin, t + side_margin]
      ].map { |x, y| [round2(x), round2(y)] }
    end
    private_class_method :l_footprint

    def self.l_top_panels(dims)
      [Panel.new(role: 'top', name: 'Top Panel', points: l_footprint(dims, 0.0, 0.0),
                 extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(dims.height - dims.thick)])]
    end
    private_class_method :l_top_panels

    def self.l_shelf_panels(count, dims)
      return [] unless count.positive?

      clear = dims.height - (2 * dims.thick)
      gap = (clear - (count * dims.thick)) / (count + 1)
      points = l_footprint(dims, dims.shelf_setback, Defaults::SHELF_SIDE_CLEARANCE)
      (1..count).map do |index|
        z = dims.thick + (gap * index) + (dims.thick * (index - 1))
        Panel.new(role: "shelf_#{index}", name: "Shelf #{index}", points: points,
                  extent: [nil, nil, round2(dims.thick)], offset: [0, 0, round2(z)])
      end
    end
    private_class_method :l_shelf_panels

    # One door on the front of each arm, meeting at the inside corner of the L. By default both
    # hinge at the outer ends, so they open away from the corner ("right" swaps them).
    def self.l_doors(params, dims, base_z)
      t = dims.thick
      d = dims.return_depth
      w = dims.width
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      clear = door_distance(params)
      height = dims.height - (2 * reveal)
      outer = params['door_opening_direction'].to_s != 'right'

      y_from = d + clear + t + gap # clear of the other door
      y_to = w - reveal
      x_from = d + reveal
      x_to = w - reveal

      [
        Door.new(role: 'door_1', name: 'Door 1', extent: [t, y_to - y_from, height].map { |v| round2(v) },
                 offset: [d + clear, y_from, base_z + reveal].map { |v| round2(v) },
                 hinge: outer ? 'right' : 'left',
                 pivot: [d + clear + t, outer ? y_to : y_from, base_z].map { |v| round2(v) }, rotation: 0.0),
        # Faces +Y: its frame is turned a quarter turn, so its length runs from x_to back to x_from.
        Door.new(role: 'door_2', name: 'Door 2', extent: [t, x_to - x_from, height].map { |v| round2(v) },
                 offset: [x_to, d + clear, base_z + reveal].map { |v| round2(v) },
                 hinge: outer ? 'left' : 'right',
                 pivot: [outer ? x_to : x_from, d + clear + t, base_z].map { |v| round2(v) }, rotation: 90.0)
      ]
    end
    private_class_method :l_doors

    # ---- blind corner unit --------------------------------------------------------------
    #
    # A straight cabinet whose front is one door over the open part and a fixed panel over the
    # `blind_width` part, which sits behind the neighbouring run. Door Opening Direction "left"
    # puts the door on the left and the blind part on the right; "right" swaps them.
    def self.blind_split(params, dims)
      reveal = params['door_reveal'].to_f
      gap = params['door_gap'].to_f
      blind = params['blind_width'].to_f.clamp(MIN_BLIND, [dims.width - MIN_BLIND, MIN_BLIND].max)
      open = dims.width - blind
      if params['door_opening_direction'].to_s != 'right' # blind on the right
        { door: [reveal, open - (gap / 2.0)], blind: [open + (gap / 2.0), dims.width - reveal] }
      else
        { door: [blind + (gap / 2.0), dims.width - reveal], blind: [reveal, blind - (gap / 2.0)] }
      end
    end
    private_class_method :blind_split
    MIN_BLIND = 50.0

    def self.blind_panel(params, dims)
      from, to = blind_split(params, dims)[:blind]
      reveal = params['door_reveal'].to_f
      panel('blind_front', 'Blind Panel', [dims.thick, to - from, dims.height - (2 * reveal)],
            [dims.depth + door_distance(params), from, reveal])
    end
    private_class_method :blind_panel

    def self.blind_doors(params, dims, base_z)
      from, to = blind_split(params, dims)[:door]
      reveal = params['door_reveal'].to_f
      hinge_left = params['door_opening_direction'].to_s != 'right'
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

    # nil without a zone; { drawers: zone_height } over a door, { door: zone_height } for a door on top
    # of an open niche (a fridge housing).
    def self.front_zone(params, dims)
      zone = params['front_zone'].to_f
      bottom = params['bottom_zone'].to_f
      return nil unless params['door_count'].to_i.positive?

      # An oven housing: drawers at the bottom, the door at the top, an open niche between.
      if bottom.positive? && bottom < dims.height && params['drawer_count'].to_i.positive?
        return { bottom: bottom, door: (zone.positive? && zone + bottom < dims.height ? zone : nil) }
      end
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

      gap = params['door_gap'].to_f
      reveal = params['door_reveal'].to_f
      front_w = dims.width - (2 * reveal)
      zone = front_zone(params, dims)
      # Over a door the drawers share the zone at the top; otherwise they share the whole height.
      from = zone && zone[:drawers] ? dims.height - zone[:drawers] : reveal
      front_h =
        if zone && zone[:bottom] then (zone[:bottom] - reveal - (gap / 2.0) - ((count - 1) * gap)) / count
        elsif zone then (zone[:drawers] - reveal - ((count - 1) * gap)) / count
        else (dims.height - (2 * reveal) - ((count - 1) * gap)) / count
        end

      (0...count).map do |index|
        z = from + (index * (front_h + gap))
        Door.new(
          role: "drawer_#{index + 1}", name: "Drawer #{index + 1}",
          extent: [dims.thick, front_w, front_h].map { |v| round2(v) },
          offset: [dims.depth + door_distance(params), reveal, base_z + z].map { |v| round2(v) },
          hinge: 'center', pivot: [dims.depth, reveal, base_z].map { |v| round2(v) }, rotation: 0.0
        )
      end
    end
    private_class_method :drawer_panels

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
