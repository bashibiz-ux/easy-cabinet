# frozen_string_literal: true

module KitchenCabinetMaster
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

    # The section of a horizontal profile seen from the end: [[x, y], ...], x out of the front (0 is the face of the doors, `back` the back of the doors, negative),
    # y up from the top edge of the front it sits on, from the drawings. The back plate stands `depth` behind the doors, with two small clips on its back.
    # B Plus: a plate under the worktop with a short flange at its top, curving at its foot into a tray that ends in a hook on the top of the door.
    # C Plus: a plate with an arm and a hook at each end that rest on the two fronts, and a clip in the middle.
    def self.horizontal_outline(system, back)
      spec = SYSTEMS.fetch(system)
      h = spec[:size]
      d = spec[:depth]
      xb = back - d # (the back of the plate)
      clips = lambda do |y0, y1| # a small hook on the back: from y1 down to y0
        [[xb, y1], [xb - 6.0, y1], [xb - 6.0, y1 - PLATE], [xb, y1 - PLATE], [xb, y0 + PLATE], [xb - 6.0, y0 + PLATE], [xb - 6.0, y0], [xb, y0]]
      end
      points =
        if system == 'b'
          [[xb, 0.0], [xb + d, 0.0], [xb + d, 5.0], [xb + d - PLATE, 5.0], [xb + d - PLATE, PLATE], [xb + 8.0, PLATE], [xb + 5.0, 2.6], [xb + 3.2, 4.4], [xb + PLATE, 8.0],
           [xb + PLATE, h - PLATE], [xb + 10.0, h - PLATE], [xb + 10.0, h], [xb, h]]
        else
          [[xb, 0.0], [xb + d, 0.0], [xb + d, 8.0], [xb + d - PLATE, 8.0], [xb + d - PLATE, PLATE], [xb + PLATE, PLATE], [xb + PLATE, h - PLATE], [xb + d - PLATE, h - PLATE],
           [xb + d - PLATE, h - 8.0], [xb + d, h - 8.0], [xb + d, h], [xb, h]]
        end
      middle = system == 'b' ? [[xb, 46.5], [xb - 6.0, 46.5], [xb - 6.0, 44.5], [xb, 44.5], [xb, 30.0], [xb - 6.0, 30.0], [xb - 6.0, 28.0], [xb, 28.0]] : clips.call(38.5, 40.5)
      points + middle
    end

    # The section of a vertical profile seen from above: [[x, y], ...], x out of the doors, y across them, centred on the gap between two doors (30 and 35 mm
    # wide). A back plate `depth` behind the doors, as wide as the profile is, and two walls along the edges of the doors that line the gap up to the face of
    # the doors.
    def self.vertical_outline(system, back)
      spec = SYSTEMS.fetch(system)
      w = spec[:size] / 2.0
      g = spec[:gap] / 2.0
      xb = back - spec[:depth]
      t = PLATE
      [[xb, -w], [xb + t, -w], [xb + t, -g], [0.0, -g], [0.0, -g + t], [xb + t, -g + t], [xb + t, g - t], [0.0, g - t], [0.0, g], [xb + t, g], [xb + t, w], [xb, w]]
    end

    # How much narrower than it was a door is made for an end profile: the gap of the system, less the reveal it had there.
    def self.end_reduce(system, reveal)
      [SYSTEMS.fetch(system)[:gap] - reveal, 10.0].max
    end

    # An end profile (a door at the end of a run, the cabinet beside it), seen from above, y from the edge of the door out over the gap to the cabinet (mirrored
    # for one on the left of its door): the plate, a small wing behind the door, and one wall along the edge of the door.
    def self.end_outline(system, back, mirror = false)
      spec = SYSTEMS.fetch(system)
      t = PLATE
      xb = back - spec[:depth]
      points = [[xb, -8.0], [xb + t, -8.0], [xb + t, 0.0], [0.0, 0.0], [0.0, t], [xb + t, t], [xb + t, spec[:gap]], [xb, spec[:gap]]]
      mirror ? points.map { |x, y| [x, -y] }.reverse : points
    end

    # The section for a spot (see apply!).
    def self.outline_for(spot)
      system = spot['system']
      case spot['kind']
      when 'pair' then vertical_outline(system, spot['back'])
      when 'end_right' then end_outline(system, spot['back'])
      when 'end_left' then end_outline(system, spot['back'], true)
      else SYSTEMS[system][:horizontal] ? horizontal_outline(system, spot['back']) : vertical_outline(system, spot['back']) # (a profile with no place given: its own direction)
      end
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
          cut = limit - (carcass_top - gap) # (the front stops the gap under the worktop)
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
