# frozen_string_literal: true

module KitchenCabinetMaster
  # Which part of the side of a cabinet shows: the side is a rectangle (from the back of the carcass to the door front, from the bottom to the top)
  # and whatever stands against it hides the part it touches. A tall cabinet beside a lower one shows its side above the lower one; a deeper one
  # shows a strip in front of a shallower one; wall cabinets over base cabinets leave the side between them showing. Pure maths, in millimetres,
  # in the frame of the cabinet whose side it is.
  module SideExposure
    MIN_SIZE = 50.0 # a piece smaller than this is not worth a panel (and a panel cannot be lower than this)

    # side: { depth:, base:, top: }; neighbours: [{ x0:, x1:, z0:, z1: }] of what touches that side.
    # => [[x0, z0, x1, z1]]: rectangles that together are the part of the side nothing covers (none when it is covered; the whole side when
    # nothing touches it). The side is cut into columns at the edges of the neighbours; each column's uncovered stretches are rectangles, and
    # neighbouring columns with the same stretch are joined.
    def self.uncovered(side, neighbours)
      depth = side[:depth].to_f
      base = side[:base].to_f
      top = side[:top].to_f
      edges = ([0.0, depth] + neighbours.flat_map { |n| [n[:x0].to_f, n[:x1].to_f] }).map { |x| x.clamp(0.0, depth) }.uniq.sort
      columns = edges.each_cons(2).filter_map do |from, to|
        next if to - from < 0.5

        middle = (from + to) / 2.0
        covering = neighbours.select { |n| n[:x0].to_f <= middle && n[:x1].to_f >= middle }
        [from, to, gaps(base, top, covering)]
      end
      joined = []
      columns.each do |from, to, stretches|
        last = joined.last
        if last && last[2] == stretches && (last[1] - from).abs < 0.5 then last[1] = to else joined << [from, to, stretches] end
      end
      joined.flat_map { |from, to, stretches| stretches.map { |z0, z1| [from, z0, to, z1] } }
            .select { |x0, z0, x1, z1| x1 - x0 >= MIN_SIZE && z1 - z0 >= MIN_SIZE }
    end

    # How high a side panel goes, as one piece: [from, to] in mm. The left side: from the floor (from where it hangs, for a wall unit) to the top of
    # the unit. The right side: when a unit stands against it, only the side of the unit itself (from the bottom of its carcass); otherwise, as the
    # left, from the floor to the top.
    def self.panel_span(side:, touched:, hangs:, carcass:, top:)
      from = side == 'right' && touched ? carcass : (hangs ? carcass : 0.0)
      [from, top]
    end

    # The stretches of base..top that none of `covering` (each with z0, z1) hides.
    def self.gaps(base, top, covering)
      stretches = []
      cursor = base
      covering.map { |n| [[n[:z0].to_f, base].max, [n[:z1].to_f, top].min] }.select { |a, b| b > a }.sort.each do |a, b|
        stretches << [cursor, a] if a > cursor
        cursor = [cursor, b].max
      end
      stretches << [cursor, top] if cursor < top
      stretches
    end
    private_class_method :gaps
  end
end