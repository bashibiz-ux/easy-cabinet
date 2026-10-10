# frozen_string_literal: true

module KitchenCabinetMaster
  # Dimensions drawn on the cabinets: the width of every unit and the length of each run of them (along the front, below the units), and the
  # height of the tall units (up their front edge). `lines` is the maths (millimetres, no SketchUp objects); DimensionManager draws them.
  module Dimensioning
    GAP = 150.0       # units this close are one run
    UNIT_OFFSET = 120.0 # how far from the units the width of one unit is drawn
    RUN_OFFSET = 320.0  # and the length of a whole run
    SIDE_OFFSET = 150.0

    # items: [{ x:, y:, z:, hx:, hy:, fx:, fy:, width:, depth:, base_z:, top:, tall:, island:, overhang: }] where x, y, z is the unit's origin (its back left corner on the
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
        next if run.length < 2

        first = run.first
        last = run.last
        out << { from: front_point(first, 0.0, first[:base_z].to_f), to: front_point(last, last[:width].to_f, last[:base_z].to_f), offset: scaled(first, :f, RUN_OFFSET) }
        next unless first[:island] # an island is seen from every side: its length on the back too, and how deep it is (with the seating overhang)

        back = first[:overhang].to_f
        z = first[:base_z].to_f
        out << { from: point(first, -back, 0.0, z), to: point(last, -back, last[:width].to_f, z), offset: scaled(first, :f, -RUN_OFFSET) }
        out << { from: point(first, -back, 0.0, z), to: front_point(first, 0.0, z), offset: scaled(first, :h, -SIDE_OFFSET * 2) }
      end
      out
    end

    def self.widths(item, z, offset)
      { from: front_point(item, 0.0, z), to: front_point(item, item[:width].to_f, z), offset: scaled(item, :f, offset) }
    end
    private_class_method :widths

    def self.height(item)
      point = front_point(item, 0.0, 0.0)
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
      groups = items.group_by { |item| [Math.atan2(item[:hy].to_f, item[:hx].to_f).round(2), lateral(item).round, item[:base_z].to_f.positive?] }
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