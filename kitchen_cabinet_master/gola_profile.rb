# frozen_string_literal: true

module KitchenCabinetMaster
  # The Gola handle model: instead of handles, aluminium profiles (the Häfele Gola systems) are fixed in the gaps between the fronts, and the fronts are cut
  # back to make room for them. Pure maths, no SketchUp objects; all numbers are millimetres.
  #
  #   B Plus  horizontal, between the worktop and the top doors or drawers of a base unit   (56.5 high, 27 deep)
  #   C Plus  horizontal, between a drawer or door and the one above it                      (73 high, 26 deep)
  #   D, E    vertical, between two doors side by side (and an end profile between the cabinet and a door that has no neighbour)
  #           D is 66.5 wide and 12 deep, E 72 wide and 20 deep
  #
  # The sizes are Häfele's. Their pages give no drawing: the section of each profile is a plain model of one (a back plate, and the lips or walls that make the
  # grip), and how much of it shows (see `lip` and `gap`) and the width of an end profile are assumptions.
  module GolaProfile
    PLATE = 2.0        # the thickness of the sheet the section is drawn with
    END_WIDTH = 22.0   # an end profile (cabinet to door): how wide it is across the front ...
    END_REDUCE = 20.0  # ... and how much narrower the door is for it
    NEIGHBOUR = 60.0   # fronts this close are neighbours
    MIN_FRONT = 60.0   # a front is never cut back to less than this
    SYSTEMS = {
      'b' => { name: 'Gola System B Plus', horizontal: true, size: 56.5, depth: 27.0, lip: 30.0 },
      'c' => { name: 'Gola System C Plus', horizontal: true, size: 73.0, depth: 26.0, lip: 25.0 },
      'd' => { name: 'Gola System D', horizontal: false, size: 66.5, depth: 12.0, gap: 26.5 },
      'e' => { name: 'Gola System E', horizontal: false, size: 72.0, depth: 20.0, gap: 32.0 }
    }.freeze

    def self.clean(system)
      SYSTEMS.key?(system.to_s) ? system.to_s : ''
    end

    # The section of a horizontal profile seen from the end: [[x, y], ...], x out of the front (0 is the face of the doors, `back` the front of the carcass,
    # negative), y up from the top edge of the front it sits on. B Plus: a back plate, a top plate under the worktop and a lip that hangs in front with a hook
    # at its foot. C Plus: a back plate with a lip rising in front of the lower front and one hanging in front of the upper one, a channel between them.
    def self.horizontal_outline(system, back)
      spec = SYSTEMS.fetch(system)
      h = spec[:size]
      t = PLATE
      lip = spec[:lip]
      if system == 'b'
        [[back, 0.0], [back + t, 0.0], [back + t, h - t], [-t, h - t], [-t, h - lip], [-10.0, h - lip], [-10.0, h - lip - t], [0.0, h - lip - t], [0.0, h], [back, h]]
      else
        [[back, 0.0], [0.0, 0.0], [0.0, lip], [-t, lip], [-t, t], [back + t, t], [back + t, h - t], [-t, h - t], [-t, h - lip], [0.0, h - lip], [0.0, h], [back, h]]
      end
    end

    # The section of a vertical profile seen from above: [[x, y], ...], x out of the doors, y across them, centred on the gap between two doors. A back plate
    # behind the edges of both doors and two walls that line the gap, as deep as the profile is.
    def self.vertical_outline(system, back)
      spec = SYSTEMS.fetch(system)
      w = spec[:size] / 2.0
      g = spec[:gap] / 2.0
      t = PLATE
      front = [back + spec[:depth], -t].min
      [[back, -w], [back + t, -w], [back + t, -g - t], [front, -g - t], [front, -g], [back + t, -g], [back + t, g], [front, g], [front, g + t], [back + t, g + t], [back + t, w], [back, w]]
    end

    # An end profile (between the cabinet and a door), seen from above, y from 0 outwards (mirrored for one on the left of its door): a plate behind the
    # door and a wall at the outer end.
    def self.end_outline(system, back, mirror = false)
      spec = SYSTEMS.fetch(system)
      t = PLATE
      front = [back + spec[:depth], -t].min
      points = [[back, 0.0], [back + t, 0.0], [back + t, END_WIDTH - t], [front, END_WIDTH - t], [front, END_WIDTH], [back, END_WIDTH]]
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
    #   'system', 'kind' (top, between, pair, end_left, end_right), 'back' (the front of the carcass, from the face of the door), 'u' and 'v' (where the
    #   outline's origin is, from the low-Y edge and the bottom of the front), 'length', 'horizontal'
    # params   gola_system (the doors' profile) and gola_system_drawer (the drawers'): b c d e, or blank
    # limit    the height of the top of the fronts of a unit (above the floor); distance  how far the doors stand off the carcass; base  the unit is a base unit
    def self.apply!(params, doors, drawers, limit:, distance:, base:)
      systems = { doors: clean(params['gola_system']), drawers: clean(params['gola_system_drawer']) }
      return if systems.values.all?(&:empty?)

      reveal = params['door_reveal'].to_f
      fronts = doors.map { |item| [item, systems[:doors]] } + drawers.map { |item| [item, systems[:drawers]] }
      fronts.reject! { |item, system| system.empty? || %w[top fold].include?(item.hinge) }
      all = fronts.map(&:first)
      horizontal = fronts.select { |_, system| SYSTEMS[system][:horizontal] }
      sides = horizontal.to_h { |item, _| [item, neighbours(item, all)] } # (worked out before any front is cut back)
      uppers = horizontal.select { |_, system| system == 'c' }.to_h { |item, _| [item, upper_of(item, all)] }

      horizontal.each do |item, system|
        spec = SYSTEMS[system]
        if system == 'b'
          next unless base && (top_of(item) - limit).abs < 0.6

          cut = spec[:size] - reveal
        else
          above = uppers[item]
          next unless above

          cut = spec[:size] - (above.offset[2] - top_of(item))
        end
        next if cut.negative? || item.extent[2] - cut < MIN_FRONT

        left, right = sides[item]
        left = left ? left / 2.0 : reveal
        right = right ? right / 2.0 : reveal
        item.extent = [item.extent[0], item.extent[1], round2(item.extent[2] - cut)]
        item.gola = { 'system' => system, 'kind' => system == 'b' ? 'top' : 'between', 'back' => round2(-(item.extent[0] + distance)), 'horizontal' => true,
                      'length' => round2(item.extent[1] + left + right), 'u' => round2((item.extent[1] + right - left) / 2.0), 'v' => item.extent[2] }
      end

      verticals = fronts.select { |item, system| !SYSTEMS[system][:horizontal] && doors.include?(item) }.sort_by { |item, _| [item.offset[1], item.offset[2]] }
      verticals.each do |item, system|
        partner = verticals.map(&:first).select { |other| other != item && beside?(item, other) }.min_by { |other| other.offset[1] }
        if partner
          pair!(item, partner, system, distance)
        elsif verticals.none? { |other, _| other != item && beside?(other, item) }
          finish!(item, system, distance) # (no neighbour on either side)
        end
      end
      nil
    end

    def self.top_of(item) = round2(item.offset[2] + item.extent[2])

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

    # How much of the shorter of two fronts the other one covers, up and down (0..1).
    def self.overlap(a, b)
      low = [a.offset[2], b.offset[2]].max
      high = [top_of(a), top_of(b)].min
      [high - low, 0.0].max / [a.extent[2], b.extent[2]].min
    end

    # Two doors side by side: the gap between them is the one the profile leaves, each door gives up half of what that needs.
    def self.pair!(left, right, system, distance)
      spec = SYSTEMS[system]
      gap = right.offset[1] - (left.offset[1] + left.extent[1])
      delta = (spec[:gap] - gap) / 2.0
      left.extent = [left.extent[0], round2(left.extent[1] - delta), left.extent[2]]
      left.pivot = [left.pivot[0], round2(left.pivot[1] - delta), left.pivot[2]] if left.pivot && left.hinge == 'right'
      right.offset = [right.offset[0], round2(right.offset[1] + delta), right.offset[2]]
      right.extent = [right.extent[0], round2(right.extent[1] - delta), right.extent[2]]
      right.pivot = [right.pivot[0], round2(right.pivot[1] + delta), right.pivot[2]] if right.pivot && right.hinge == 'left'
      height = [left.extent[2], right.extent[2]].min
      left.gola = { 'system' => system, 'kind' => 'pair', 'back' => round2(-(left.extent[0] + distance)), 'horizontal' => false, 'length' => round2(height),
                    'u' => round2(left.extent[1] + (spec[:gap] / 2.0)), 'v' => round2((left.extent[2] / 2.0)) }
    end

    # A door with no neighbour: an end profile where the door is not hinged (between it and the cabinet).
    def self.finish!(door, system, distance)
      return unless %w[left right].include?(door.hinge)
      return if door.extent[1] - END_REDUCE < MIN_FRONT

      free_right = door.hinge == 'left'
      door.extent = [door.extent[0], round2(door.extent[1] - END_REDUCE), door.extent[2]]
      door.offset = [door.offset[0], round2(door.offset[1] + END_REDUCE), door.offset[2]] unless free_right
      door.gola = { 'system' => system, 'kind' => free_right ? 'end_right' : 'end_left', 'back' => round2(-(door.extent[0] + distance)), 'horizontal' => false,
                    'length' => round2(door.extent[2]), 'u' => free_right ? door.extent[1] : 0.0, 'v' => round2(door.extent[2] / 2.0) }
    end
  end
end
