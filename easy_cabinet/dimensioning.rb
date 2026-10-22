# frozen_string_literal: true

module EasyCabinet
  # Dimensions drawn on the cabinets, for the plan and for the elevation: the width of every unit and the length of each run of them (along the front, below the
  # units); the depth of a run (along its left end, and its right end when that unit is deeper or shallower); and the heights: of a base run (the toe kick and the
  # whole height), of a wall run (how high its underside hangs and how tall the units are) and of each tall unit. `lines` is the maths (millimetres, no SketchUp
  # objects); DimensionManager draws them.
  module Dimensioning
    GAP = 150.0       # units this close are one run
    UNIT_OFFSET = 120.0 # how far from the units the width of one unit is drawn
    RUN_OFFSET = 320.0  # and the length of a whole run
    SIDE_OFFSET = 150.0

    # items: [{ x:, y:, z:, hx:, hy:, fx:, fy:, width:, depth:, base_z:, top:, tall:, wall:, island:, overhang: }] where x, y, z is the unit's origin (its back left corner on the
    #   floor), hx / hy the way its width runs, fx / fy the way its front looks, base_z the height of its underside and top the height of its top.
    # => [{ from: [x, y, z], to: [x, y, z], offset: [x, y, z] }]
    def self.lines(items)
      out = []
      items.each do |item|
        z = item[:base_z].to_f
        out << widths(item, z, UNIT_OFFSET)
        out << height(item) if item[:tall]
      end
      runs(items).each do |run|
        first = run.first
        last = run.last
        if run.length >= 2
          out << { from: front_point(first, 0.0, first[:base_z].to_f), to: front_point(last, last[:width].to_f, last[:base_z].to_f), offset: scaled(first, :f, RUN_OFFSET) }
          if first[:island] # an island is seen from every side: its length on the back too, and how deep it is (with the seating overhang)
            back = first[:overhang].to_f
            z = first[:base_z].to_f
            out << { from: point(first, -back, 0.0, z), to: point(last, -back, last[:width].to_f, z), offset: scaled(first, :f, -RUN_OFFSET) }
            out << { from: point(first, -back, 0.0, z), to: front_point(first, 0.0, z), offset: scaled(first, :h, -SIDE_OFFSET * 2) }
          end
        end
        next if first[:island]

        out << depth_line(first, -1.0) # (the plan: how deep the run is, on its left end)
        out << depth_line(last, 1.0) if (last[:depth].to_f - first[:depth].to_f).abs > 1.0 # (and on its right end when that unit has another depth)
        out.concat(heights(first)) unless first[:tall] # (the elevation: a tall unit has its own, above)
      end
      out
    end

    def self.widths(item, z, offset)
      { from: front_point(item, 0.0, z), to: front_point(item, item[:width].to_f, z), offset: scaled(item, :f, offset) }
    end
    private_class_method :widths

    # The depth of a unit from its back to its front, drawn on its left (side -1) or right (side 1) end, at the height of its underside.
    def self.depth_line(item, side)
      along = side.negative? ? 0.0 : item[:width].to_f
      z = item[:base_z].to_f
      { from: point(item, 0.0, along, z), to: front_point(item, along, z), offset: scaled(item, :h, side * SIDE_OFFSET) }
    end
    private_class_method :depth_line

    # The heights of a run, up the left end of its first unit: a wall unit hangs `base_z` above the floor and is `top - base_z` tall; a base unit stands on its toe kick
    # (`base_z` high) and is `top` high in all.
    def self.heights(item)
      floor = front_point(item, 0.0, 0.0)
      base = item[:base_z].to_f
      top = item[:top].to_f
      wall = item[:wall].nil? ? base > 600.0 : item[:wall]
      out = []
      out << { from: floor, to: [floor[0], floor[1], base], offset: scaled(item, :h, -SIDE_OFFSET) } if base > 1.0 # (the toe kick, or how high the wall units hang)
      out << { from: [floor[0], floor[1], base], to: [floor[0], floor[1], top], offset: scaled(item, :h, -SIDE_OFFSET) } if wall && top > base
      out << { from: floor, to: [floor[0], floor[1], top], offset: scaled(item, :h, -SIDE_OFFSET * 2) } unless wall # (a base unit: the whole height, outside the toe kick)
      out
    end
    private_class_method :heights

    def self.height(item)      point = front_point(item, 0.0, 0.0)
      { from: point, to: [point[0], point[1], item[:top].to_f], offset: scaled(item, :h, -SIDE_OFFSET, -1.0) }
    end
    private_class_method :height

    # The point `forward` mm from the back of a unit (its front is `depth`), `along` mm from its left side, at height z.
    def self.point(item, forward, along, z)
      [item[:x].to_f + (item[:fx].to_f * forward) + (item[:hx].to_f * along), item[:y].to_f + (item[:fy].to_f * forward) + (item[:hy].to_f * along), z]
    end
    private_class_method :point

    # The point on the front of a unit `along` mm from its left side, at height z.
    def self.front_point(item, along, z)
      [item[:x].to_f + (item[:fx].to_f * item[:depth].to_f) + (item[:hx].to_f * along),
       item[:y].to_f + (item[:fy].to_f * item[:depth].to_f) + (item[:hy].to_f * along), z]
    end
    private_class_method :front_point

    # A vector `length` long along the front (:f) or along the width (:h) of the unit.
    def self.scaled(item, axis, length, _sign = 1.0)
      axis == :f ? [item[:fx].to_f * length, item[:fy].to_f * length, 0.0] : [item[:hx].to_f * length, item[:hy].to_f * length, 0.0]
    end
    private_class_method :scaled

    # The units in a line, one after the other with next to no gap, at the same height of underside: a run. Sorted along the line.
    def self.runs(items)
      groups = items.group_by { |item| [Math.atan2(item[:hy].to_f, item[:hx].to_f).round(2), lateral(item).round, item[:wall].nil? ? item[:base_z].to_f.positive? : item[:wall]] }
      groups.values.flat_map do |group|
        runs = []
        current = []
        group.sort_by { |item| along(item) }.each do |item|
          if current.any? && along(item) - (along(current.last) + current.last[:width].to_f) > GAP
            runs << current
            current = []
          end
          current << item
        end
        runs << current if current.any?
        runs
      end
    end
    private_class_method :runs

    def self.along(item) = (item[:x].to_f * item[:hx].to_f) + (item[:y].to_f * item[:hy].to_f)
    def self.lateral(item) = ((item[:x].to_f * -item[:hy].to_f) + (item[:y].to_f * item[:hx].to_f)) / 5.0
    private_class_method :along, :lateral
  end
end