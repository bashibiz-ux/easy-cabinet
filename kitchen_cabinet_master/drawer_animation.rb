# frozen_string_literal: true

module KitchenCabinetMaster
  # How drawers move: a drawer front is only ever moved by a translation along
  # the cabinet's own depth axis (+X, towards the front) -- no rotation, no
  # hinge. `open?` / `set_open` are shared with doors (DoorAnimation): they just
  # read and write a plain boolean attribute, nothing door-specific.
  #
  #   drawer.transformation = Translation(0, 0, ..) * ClosedPlacement
  module DrawerAnimation
    # How far a drawer pulls out, capped relative to the cabinet's own depth so
    # a shallow wall cabinet's drawer does not slide out further than the
    # cabinet itself is deep. This module has no idea of a "drawer box" (only
    # the front is modelled), so this is a visual stand-in, not a runner spec.
    MAX_PULL_OUT = 500.0
    PULL_OUT_FRACTION = 0.8

    def self.pull_out(depth)
      [depth.to_f * PULL_OUT_FRACTION, MAX_PULL_OUT].min
    end

    # The drawer's transformation at a given opening fraction (0 = closed, 1 =
    # fully open). `cabinet_depth` decides how far "fully open" pulls out.
    def self.transformation(spec, cabinet_depth, fraction)
      closed = Geom::Transformation.new(spec.offset.map(&:mm))
      return closed if fraction.zero?

      slide(cabinet_depth, fraction) * closed
    end

    def self.slide(cabinet_depth, fraction)
      distance = pull_out(cabinet_depth) * fraction
      Geom::Transformation.translation(Geom::Vector3d.new(distance.mm, 0, 0))
    end
  end
end
