# frozen_string_literal: true

module KitchenCabinetMaster
  # The designs a door or drawer front can have. A front is a plain board; a design cuts shapes into its outer face (a
  # recessed panel in a frame, steps, grooves). Pure maths, no SketchUp objects: `cuts` says what is cut, PanelGenerator
  # cuts it. All numbers are millimetres, on the front face: y across the front (0 at its left), z up it (0 at its bottom).
  module FrontDesign
    DEFAULT = 'flat'
    DESIGNS = [
      { 'id' => 'flat', 'name' => 'Flat (slab)' },
      { 'id' => 'shaker', 'name' => 'Shaker (recessed panel)' },
      { 'id' => 'slim_shaker', 'name' => 'Slim shaker' },
      { 'id' => 'stepped', 'name' => 'Stepped panel' },
      { 'id' => 'fluted', 'name' => 'Fluted (vertical grooves)' },
      { 'id' => 'grooved', 'name' => 'Two panels (horizontal groove)' }
    ].freeze

    def self.ids
      DESIGNS.map { |design| design['id'] }
    end

    def self.valid?(id)
      ids.include?(id.to_s)
    end

    # The design to use for a stored value: an unknown or blank one is the flat front.
    def self.clean(id)
      valid?(id) ? id.to_s : DEFAULT
    end

    # The cuts of a front `width` x `height` x `thickness` as [[y0, y1, z0, z1, from, to], ...]: a rectangle of the face cut from
    # `from` mm to `to` mm deep (into the board). Empty for a flat front, or when the front is too small for the design (it is
    # then flat: a narrow pull-out keeps a plain face).
    def self.cuts(design, width, height, thickness)
      case design.to_s
      when 'shaker' then frame_cut(width, height, thickness, 70.0)
      when 'slim_shaker' then frame_cut(width, height, thickness, 45.0)
      when 'stepped' then stepped_cuts(width, height, thickness)
      when 'fluted' then fluted_cuts(width, height, thickness)
      when 'grooved' then grooved_cuts(width, height, thickness)
      else []
      end
    end

    # A recessed panel inside a frame `frame` wide (narrower on a small front, never under 25 mm).
    def self.frame_cut(width, height, thickness, frame)
      f = [frame, ([width, height].min - 60.0) / 2.0].min
      return [] if f < 25.0

      [[f, width - f, f, height - f, 0.0, [6.0, thickness / 3.0].min]]
    end
    private_class_method :frame_cut

    # Two steps down into the board: a wide shallow recess, and a narrower, deeper one inside it.
    def self.stepped_cuts(width, height, thickness)
      f = [60.0, ([width, height].min - 90.0) / 2.0].min
      return [] if f < 25.0

      step = [4.0, thickness / 5.0].min
      inner = f + 25.0
      cuts = [[f, width - f, f, height - f, 0.0, step]]
      cuts << [inner, width - inner, inner, height - inner, step, step * 2.0] if width - (2 * inner) >= 30.0 && height - (2 * inner) >= 30.0
      cuts
    end
    private_class_method :stepped_cuts

    # Vertical grooves 6 mm wide every 22 mm, from 25 mm under the top to 25 mm over the bottom, as a group in the middle.
    def self.fluted_cuts(width, height, thickness)
      return [] if width < 90.0 || height < 120.0

      count = ((width - 50.0 - 6.0) / 22.0).floor + 1
      return [] if count < 3

      span = ((count - 1) * 22.0) + 6.0
      start = (width - span) / 2.0
      depth = [3.0, thickness / 5.0].min
      (0...count).map { |i| [start + (i * 22.0), start + (i * 22.0) + 6.0, 25.0, height - 25.0, 0.0, depth] }
    end
    private_class_method :fluted_cuts

    # One groove across the whole width, in the middle of the height: two panels.
    def self.grooved_cuts(width, height, thickness)
      return [] if height < 300.0 || width < 100.0

      [[0.0, width, (height / 2.0) - 3.0, (height / 2.0) + 3.0, 0.0, [3.0, thickness / 5.0].min]]
    end
    private_class_method :grooved_cuts
  end
end
