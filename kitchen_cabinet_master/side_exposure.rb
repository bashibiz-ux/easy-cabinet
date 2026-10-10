# frozen_string_literal: true

module KitchenCabinetMaster
  # Which part of the side of a cabinet shows: the side is a rectangle (from the back of the carcass to the door front, from the bottom to the top)
  # and whatever stands against it hides the part it touches. A taller cabinet beside a lower one shows its side above the lower one; a deeper
  # one shows a strip in front of the shallower one. Pure maths, in millimetres, in the frame of the cabinet whose side it is.
  module SideExposure
    MIN_SIZE = 50.0 # a strip smaller than this is not worth a panel (and a panel cannot be lower than this)

    # side: { depth:, base:, top: }; neighbours: [{ x0:, x1:, z0:, z1: }] of what touches that side.
    # => [[x0, z0, x1, z1]]: the rectangles that nothing covers (none, when the side is covered; the whole side, when nothing touches it).
    def self.uncovered(side, neighbours)
      depth = side[:depth].to_f
      base = side[:base].to_f
      top = side[:top].to_f
      return [[0.0, base, depth, top]] if neighbours.empty?

      x1 = neighbours.map { |n| [n[:x1].to_f, depth].min }.max
      z0 = neighbours.map { |n| [n[:z0].to_f, base].max }.min
      z1 = neighbours.map { |n| [n[:z1].to_f, top].min }.max
      found = []
      found << [0.0, z1, depth, top] if top - z1 >= MIN_SIZE # above the lower cabinet: the whole depth
      found << [0.0, base, depth, z0] if z0 - base >= MIN_SIZE # below one that hangs
      found << [x1, [z0, base].max, depth, [z1, top].min] if depth - x1 >= MIN_SIZE && z1 - z0 >= MIN_SIZE # the strip in front of a shallower one
      found
    end
  end
end