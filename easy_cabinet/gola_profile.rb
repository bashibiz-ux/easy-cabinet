# frozen_string_literal: true

module EasyCabinet
  # The Gola handle model: instead of handles, aluminium profiles (the Häfele Gola systems) are fixed in the gaps between the fronts, and the fronts are cut
  # back to make room for them. Pure maths, no SketchUp objects; all numbers are millimetres. The sections are drawn from Häfele's drawings.
  #
  #   B Plus  horizontal, under the worktop of a base unit, behind the top doors or drawers: 35 mm of it is the gap to put the fingers in, between the worktop and
  #           the front, the other 21.5 of its 56.5 is behind the front; it is 27 mm deep from its back plate to the back of the doors (the top front rail of the
  #           carcass stands back for it)
  #   C Plus  horizontal, between a drawer or door and the one above it, behind both: 35 mm of its 73 is the gap, 19 are behind each front; 26 mm deep
  #   D, E    vertical, between two doors side by side (30 and 35 mm apart); the doors are screwed to it. An end profile takes the place of the second door
  #           at the end of a run. D is 66.5 wide and 12 deep behind the doors, E 72 wide and 20 deep.
  module GolaProfile
    DEFAULT_GAP = 35.0 # mm: the gap to put the fingers in, to start with: between the worktop and the top front (B Plus), between two fronts (C Plus). The profile
    #                  goes behind the fronts and covers the rest of its height behind them (21.5 under the worktop, 19 behind each of two fronts).
    REVISION = 7       # what the profiles do (changes when a version makes them do more): a cabinet built under an older one is built again by the next setting for all cabinets
    PLATE = 2.0        # the thickness of the sheet the sections are drawn with
    NEIGHBOUR = 60.0   # fronts this close are neighbours
    MIN_FRONT = 60.0   # a front is never cut back to less than this
    SYSTEMS = {
      'b' => { name: 'Gola System B Plus', horizontal: true, size: 56.5, depth: 27.0 },
      'c' => { name: 'Gola System C Plus', horizontal: true, size: 73.0, depth: 26.0 },
      'd' => { name: 'Gola System D', horizontal: false, size: 66.5, depth: 12.0, gap: 30.0 },
      'e' => { name: 'Gola System E', horizontal: false, size: 72.0, depth: 20.0, gap: 35.0 }
    }.freeze

    def self.clean(system)
      SYSTEMS.key?(system.to_s) ? system.to_s : ''
    end

    # ---- the sections, traced from the Häfele drawings -------------------------------------------------------------------------------------------------------
    #
    # Each is worked out in the measures of the drawing, as points [u, y]: u is how far behind the back of the doors (0 is the plane the back faces of the doors are
    # in; u grows towards the back of the cabinet); y is up from the foot of a horizontal profile, or across from the middle of the gap between two doors for a vertical
    # one. They are then put in the frame of the handle (x = back - u, `back` being the back of the door, negative). A section can have holes: the hollow chambers of
    # the aluminium. Its sheet is 1 to 1.6 mm.

    # Points [u, y] on the arc of the circle (u0, y0, radius) from one angle to another, in degrees.
    def self.arc(u0, y0, radius, from, to, steps = 6)
      (0..steps).map do |k|
        angle = (from + ((to - from) * k / steps.to_f)) * Math::PI / 180.0
        [u0 + (radius * Math.cos(angle)), y0 + (radius * Math.sin(angle))]
      end
    end

    # B Plus, 56.5 high and 27 deep to the back of its clips: a plate 20 mm behind the doors with a flange at its top that runs back towards the cabinet and ends in a small
    # lip; two clips on the back of the plate that face one another; at its foot the plate curves forward into an arm that ends in a foot (a stub down and a tab back) at the
    # back of the door. => [outline, holes]
    def self.b_section
      points = [[0.0, 0.0], [4.0, 0.0], [4.0, 1.4], [1.6, 1.4], [1.6, 3.3], [14.2, 3.3]]
      points += arc(14.2, 10.6, 7.3, -90.0, 0.0)[1..]
      points += [[21.5, 10.9], [27.0, 10.9], [27.0, 16.4], [25.8, 16.4], [25.8, 12.4], [21.5, 12.4], [21.5, 25.6], [25.8, 25.6], [25.8, 21.7], [27.0, 21.7], [27.0, 26.8],
                 [21.5, 26.8], [21.5, 55.0], [26.4, 55.0], [26.4, 53.2], [28.0, 53.2], [28.0, 56.5], [19.9, 56.5], [19.9, 10.6]]
      points += arc(14.2, 10.6, 5.7, 0.0, -90.0)[1..]
      points << [0.0, 4.9]
      [points, []]
    end

    # C Plus, 73 high and 26 deep: a plate 20 mm behind the doors that curves at both ends into an arm reaching the back of the front, each ending in a foot (a stub and a
    # tab) round the edge of the front; in the middle of the back a hollow clip (a box). => [outline, holes]
    def self.c_section
      points = [[0.0, 0.0], [4.3, 0.0], [4.3, 1.2], [1.4, 1.2], [1.4, 3.5], [15.3, 3.5]]
      points += arc(15.3, 9.3, 5.8, -90.0, 0.0)[1..]
      points += [[21.1, 28.6], [26.2, 28.6], [26.2, 44.3], [21.1, 44.3], [21.1, 63.7]]
      points += arc(15.3, 63.7, 5.8, 0.0, 90.0)[1..]
      points += [[1.4, 69.5], [1.4, 71.8], [4.3, 71.8], [4.3, 73.0], [0.0, 73.0], [0.0, 68.2], [15.3, 68.2]]
      points += arc(15.3, 63.7, 4.5, 90.0, 0.0)[1..]
      points << [19.8, 9.3]
      points += arc(15.3, 9.3, 4.5, 0.0, -90.0)[1..]
      points << [0.0, 4.8]
      [points, [[[21.1, 30.0], [24.8, 30.0], [24.8, 42.9], [21.1, 42.9]]]]
    end

    # The numbers of the vertical profiles, from the drawings: wall (the sheet), width (over the outer walls of the feet), total (the height with the tube), tube (the width
    # of the tube: the gap between the panels it is screwed to), foot (how wide a foot is), foot_in .. turn_y, turn_u, radius (the slanted wall goes from the inner end of
    # the foot up to where it turns, with that radius, into the plate), end_width (an end profile, from the cabinet to the outer wall).
    VERTICAL = {
      'e' => { wall: 1.0, width: 72.0, total: 41.0, tube: 35.0, foot: 4.5, foot_in: 31.5, turn_y: 27.5, turn_u: 15.0, radius: 4.0, end_width: 53.0 },
      'd' => { wall: 0.9, width: 66.5, total: 37.0, tube: 30.0, foot: 6.8, foot_in: 25.6, turn_y: 24.3, turn_u: 7.0, radius: 4.0, end_width: 48.5 }
    }.freeze

    # The right half of a vertical section, from the middle of the underside of the plate to the top of the tube: the underside, the slanted wall (it is hollow with the outer
    # wall, which stands on the foot: a cell open at its top, to the panel), the top of the plate and the outside of the tube. `outer` is where the outer wall is, `foot_in` and
    # `turn_y` where the slanted wall is, `half` the tube's outside.
    def self.vertical_half(v, outer, foot_in, turn_y, half)
      t = v[:wall]
      r = v[:radius]
      under = v[:turn_u] + r
      top = under + t
      pull = turn_y - r
      points = [[under, 0.0], [under, pull]]
      points += arc(v[:turn_u], pull, r, 0.0, 90.0)[1..]
      points += [[0.0, foot_in], [0.0, outer], [top, outer], [top, outer - t], [1.0, outer - t], [1.0, foot_in + t], [v[:turn_u], turn_y + t]]
      points += arc(v[:turn_u], pull, r + t, 90.0, 0.0)[1..]
      points += [[top, half], [v[:total], half], [v[:total], half - t], [v[:total] - 1.5, half - t]]
      points
    end
    private_class_method :vertical_half

    # D or E between two doors, centred on the gap: [outline, holes] in [u, y]. The tube is hollow.
    def self.vertical_section(system)
      v = VERTICAL.fetch(system)
      t = v[:wall]
      half = v[:tube] / 2.0
      right = vertical_half(v, v[:width] / 2.0, v[:foot_in], v[:turn_y], half)
      left = right.map { |u, y| [u, -y] }.reverse
      outline = right + left[1..-2]
      under = v[:turn_u] + v[:radius]
      [outline, [[[under + t, -(half - t)], [v[:total] - 2.5, -(half - t)], [v[:total] - 2.5, half - t], [under + t, half - t]]]]
    end

    # An end profile (between the cabinet and a door), as drawn: y from the face of the cabinet (0) to the outer wall of the foot, which is behind the door. A long wall along the
    # cabinet, the plate with a fillet to it, the tube, and the foot and slanted wall of a profile between doors. [outline, holes] in [u, y].
    def self.end_section(system)
      v = VERTICAL.fetch(system)
      t = v[:wall]
      r = v[:radius]
      outer = v[:end_width]
      foot_in = outer - v[:foot]
      turn_y = foot_in - (v[:foot_in] - v[:turn_y])
      half = v[:tube]
      under = v[:turn_u] + r
      top = under + t
      fillet = 3.0
      points = [[0.0, 0.0], [0.0, t], [under - fillet, t]]
      points += arc(under - fillet, t + fillet, fillet, -90.0, 0.0)[1..]
      points << [under, turn_y - r]
      points += vertical_half(v, outer, foot_in, turn_y, half)[2..]
      points += [[v[:total] - 1.5, t], [v[:total], t], [v[:total], 0.0]]
      [points, [[[top, t], [v[:total] - 2.5, t], [v[:total] - 2.5, half - t], [top, half - t]]]]
    end

    # The section and holes of a spot (see apply!) in the frame of the handle: [[x, y], ...] and [[[x, y], ...], ...], x out of the front (0) and `back` the back of the door.
    def self.section_for(spot)
      system = spot['system']
      back = spot['back'].to_f
      gap = SYSTEMS.fetch(system)[:gap]
      outline, holes =
        case spot['kind']
        when 'pair' then vertical_section(system)
        when 'end_right', 'end_left'
          shape, cavity = end_section(system)
          # from the face of the cabinet to from the edge of the door out over the gap to the cabinet (a left one is the other way round)
          flip = spot['kind'] == 'end_right' ? ->(y) { gap - y } : ->(y) { y - gap }
          [shape.map { |u, y| [u, flip.call(y)] }, cavity.map { |loop| loop.map { |u, y| [u, flip.call(y)] } }]
        else SYSTEMS[system][:horizontal] ? (system == 'b' ? b_section : c_section) : vertical_section(system)
        end
      place = ->(points) { points.map { |u, y| [back - u, y] } }
      [place.call(outline), holes.map { |loop| place.call(loop) }]
    end

    # The outline of the section of a spot (see section_for).
    def self.outline_for(spot)
      section_for(spot).first
    end

    # The holes of the section of a spot.
    def self.holes_for(spot)
      section_for(spot).last
    end

    # How much narrower than it was a door is made for an end profile: the gap of the system, less the reveal it had there.
    def self.end_reduce(system, reveal)
      [SYSTEMS.fetch(system)[:gap] - reveal, 10.0].max
    end

    # What a profile is called, so that one definition is shared by all that are alike.
    def self.key(spot)
      format('%<system>s %<kind>s %<back>g', system: spot['system'], kind: spot['kind'], back: spot['back'].to_f.round(1))
    end

    # Cuts the fronts back and says where the profile of each goes. `doors` and `drawers` are CabinetLayout::Door; each gets `gola`, a Hash for the handle placement
    # (or nil: it has no profile and so no handle):
    #   'system', 'kind' (top, between, pair, end_left, end_right), 'back' (the back of the door, from its face), 'u' and 'v' (where the
    #   outline's origin is, from the low-Y edge and the bottom of the front), 'length', 'horizontal'
    # params   gola_system (the doors' profile) and gola_system_drawer (the drawers'): b c d e, or blank
    # limit    the height of the top of the fronts of a unit (above the floor)
    # base     the unit is a base unit
    def self.apply!(params, doors, drawers, limit:, base:)
      systems = { doors: clean(params['gola_system']), drawers: clean(params['gola_system_drawer']) }
      return if systems.values.all?(&:empty?)

      reveal = params['door_reveal'].to_f
      gap = DEFAULT_GAP - params['gola_grow'].to_f # (the gap to put the fingers in: the fronts grow upward into it)
      carcass_top = limit + reveal
      everything = doors + drawers
      fronts = doors.map { |item| [item, systems[:doors]] } + drawers.map { |item| [item, systems[:drawers]] }
      fronts.reject! { |item, system| system.empty? || %w[top fold].include?(item.hinge) }
      all = fronts.map(&:first)
      # Which profile each front has along its top edge: the top front of a base unit has B Plus under the worktop (with C Plus, and for a drawer with D or E, too:
      # they are for between fronts), a front with another over it has C Plus when that is its system; B Plus is on base units only.
      along = {}
      fronts.each do |item, system|
        topmost = everything.none? { |other| other != item && other.offset[2] >= top_of(item) - 0.6 && overlap_across(item, other) > 0.0 }
        vertical_door = !SYSTEMS[system][:horizontal] && doors.include?(item)
        if topmost
          along[item] = 'b' if base && !vertical_door
        elsif system == 'c'
          along[item] = 'c'
        end
      end
      sides = along.keys.to_h { |item| [item, neighbours(item, all)] } # (worked out before any front is cut back)
      uppers = along.select { |_, system| system == 'c' }.to_h { |item, _| [item, upper_of(item, all)] }

      along.each do |item, system|
        spec = SYSTEMS[system]
        if system == 'b'
          profile_bottom = carcass_top - spec[:size] # (the profile hangs under the worktop, behind the front, and stays there)
          cut = top_of(item) - (carcass_top - gap) # (the front stops the gap under the worktop: the doors of a corner unit are as high as their own)
        else
          above = uppers[item]
          next unless above

          profile_bottom = above.offset[2] - DEFAULT_GAP - ((spec[:size] - DEFAULT_GAP) / 2.0) # (behind the two fronts, as much behind each: it stays there)
          cut = top_of(item) - (above.offset[2] - gap) # (the front under stops the gap under the front over it)
        end
        next if cut.negative? || item.extent[2] - cut < MIN_FRONT

        left, right = sides[item]
        left = left ? left / 2.0 : reveal # (the ends reach the outside of the carcass: the profiles of two units side by side meet)
        right = right ? right / 2.0 : reveal
        item.extent = [item.extent[0], item.extent[1], round2(item.extent[2] - cut)]
        item.gola = { 'system' => system, 'kind' => system == 'b' ? 'top' : 'between', 'back' => round2(-item.extent[0]), 'horizontal' => true,
                      'length' => round2(item.extent[1] + left + right), 'u' => round2((item.extent[1] + right - left) / 2.0), 'v' => round2(profile_bottom - item.offset[2]), 'z' => round2(profile_bottom) }
      end

      verticals = fronts.select { |item, system| !SYSTEMS[system][:horizontal] && doors.include?(item) }.sort_by { |item, _| [item.offset[1], item.offset[2]] }
      verticals.each do |item, system|
        partner = verticals.map(&:first).select { |other| other != item && beside?(item, other) }.min_by { |other| other.offset[1] }
        if partner
          pair!(item, partner, system)
        elsif verticals.none? { |other, _| other != item && beside?(other, item) }
          finish!(item, system, reveal) # (no neighbour on either side)
        end
      end
      nil
    end

    def self.top_of(item) = round2(item.offset[2] + item.extent[2])

    # The fronts have been made taller or shorter (or moved) after the profiles were worked out: each profile stays where it was (`z`, the height of its bottom or
    # of the middle of a vertical one, above the floor) and its place on its front is worked out again.
    def self.settle!(fronts)
      fronts.each do |item|
        spot = item.gola
        next unless spot

        spot['v'] = round2(spot['z'] - item.offset[2]) if spot['z']
      end
    end

    # How far two fronts overlap across the unit (0 when they do not stand over one another).
    def self.overlap_across(a, b)
      [[a.offset[1] + a.extent[1], b.offset[1] + b.extent[1]].min - [a.offset[1], b.offset[1]].max, 0.0].max
    end

    # `other` stands to the right of `item`, close to it and at the same height (it covers half of the lower one at least).
    def self.beside?(item, other)
      gap = other.offset[1] - (item.offset[1] + item.extent[1])
      gap >= -0.01 && gap <= NEIGHBOUR && overlap(item, other) >= 0.5
    end

    # The gaps to the fronts at the same top on each side: [left, right], nil where there is none.
    def self.neighbours(item, all)
      row = all.select { |other| other != item && (top_of(other) - top_of(item)).abs < 0.6 }
      left = row.select { |other| beside?(other, item) }.max_by { |other| other.offset[1] }
      right = row.select { |other| beside?(item, other) }.min_by { |other| other.offset[1] }
      [left && (item.offset[1] - (left.offset[1] + left.extent[1])), right && (right.offset[1] - (item.offset[1] + item.extent[1]))]
    end

    def self.round2(value) = (value * 100).round / 100.0

    # The front directly above one, if there is one: it stands over it, close above, across the same part of the width.
    def self.upper_of(item, all)
      all.select do |other|
        other != item && !%w[top fold].include?(other.hinge) && other.offset[2] - top_of(item) >= -0.6 && other.offset[2] - top_of(item) <= NEIGHBOUR &&
          [other.offset[1] + other.extent[1], item.offset[1] + item.extent[1]].min - [other.offset[1], item.offset[1]].max > 0.5 * [other.extent[1], item.extent[1]].min
      end.min_by { |other| other.offset[2] }
    end

    # Makes the profile of a front reach `left` and `right` beyond its edges (what a profile does at the end of a run: the reveal, or half the gap to the front beside it).
    def self.set_ends!(item, left, right)
      spot = item.gola
      return unless spot && spot['horizontal']

      spot['length'] = round2(item.extent[1] + left + right)
      spot['u'] = round2((item.extent[1] + right - left) / 2.0)
    end

    # The notches the horizontal profiles need in the front edge of the side panels, where they run through them: [[depth, from, to], ...] (mm, from the bottom of
    # the carcass), bottom to top. `distance` is how far the doors stand off the carcass.
    def self.notches(doors, drawers, distance:, base_z:, height:)
      list = (doors + drawers).filter_map do |item|
        spot = item.gola
        next unless spot && spot['horizontal']

        spec = SYSTEMS[spot['system']]
        from = (spot['z'] || top_of(item)) - base_z
        depth = round2(spec[:depth] - distance)
        next unless depth.positive?

        [depth, round2(from), round2([from + spec[:size], height].min)]
      end
      list.uniq.sort_by { |_, from, _| from }
    end

    # How much of the shorter of two fronts the other one covers, up and down (0..1).
    def self.overlap(a, b)
      low = [a.offset[2], b.offset[2]].max
      high = [top_of(a), top_of(b)].min
      [high - low, 0.0].max / [a.extent[2], b.extent[2]].min
    end

    # Two doors side by side: the gap between them is the one the profile leaves, each door gives up half of what that needs.
    def self.pair!(left, right, system)
      spec = SYSTEMS[system]
      gap = right.offset[1] - (left.offset[1] + left.extent[1])
      delta = (spec[:gap] - gap) / 2.0
      left.extent = [left.extent[0], round2(left.extent[1] - delta), left.extent[2]]
      left.pivot = [left.pivot[0], round2(left.pivot[1] - delta), left.pivot[2]] if left.pivot && left.hinge == 'right'
      right.offset = [right.offset[0], round2(right.offset[1] + delta), right.offset[2]]
      right.extent = [right.extent[0], round2(right.extent[1] - delta), right.extent[2]]
      right.pivot = [right.pivot[0], round2(right.pivot[1] + delta), right.pivot[2]] if right.pivot && right.hinge == 'left'
      height = [left.extent[2], right.extent[2]].min
      left.gola = { 'system' => system, 'kind' => 'pair', 'back' => round2(-left.extent[0]), 'horizontal' => false, 'length' => round2(height),
                    'u' => round2(left.extent[1] + (spec[:gap] / 2.0)), 'v' => round2(left.extent[2] / 2.0), 'z' => round2(left.offset[2] + (height / 2.0)) }
    end

    # A door with no neighbour: an end profile where the door is not hinged (between it and the cabinet).
    def self.finish!(door, system, reveal)
      reduce = end_reduce(system, reveal)
      return unless %w[left right].include?(door.hinge)
      return if door.extent[1] - reduce < MIN_FRONT

      free_right = door.hinge == 'left'
      door.extent = [door.extent[0], round2(door.extent[1] - reduce), door.extent[2]]
      door.offset = [door.offset[0], round2(door.offset[1] + reduce), door.offset[2]] unless free_right
      door.gola = { 'system' => system, 'kind' => free_right ? 'end_right' : 'end_left', 'back' => round2(-door.extent[0]), 'horizontal' => false,
                    'length' => round2(door.extent[2]), 'u' => free_right ? door.extent[1] : 0.0, 'v' => round2(door.extent[2] / 2.0), 'z' => round2(door.offset[2] + (door.extent[2] / 2.0)) }
    end
  end
end
