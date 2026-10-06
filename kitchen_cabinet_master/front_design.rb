# frozen_string_literal: true

module KitchenCabinetMaster
  # The designs a door or drawer front can have. A front is a plain board; a design cuts shapes into its outer face (a
  # recessed panel in a frame, steps, grooves). Pure maths, no SketchUp objects: `cuts` says what is cut, PanelGenerator
  # cuts it. All numbers are millimetres, on the front face: y across the front (0 at its left), z up it (0 at its bottom).
  module FrontDesign
    DEFAULT = 'flat'
    GLASS_FRAME = 'glass_frame' # not one to choose: the front of a glass door (a frame round an opening right through it)
    GLASS_FRAME_WIDTH = 50.0
    GLASS_THICKNESS = 4.0
    DESIGNS = [
      { 'id' => 'flat', 'name' => 'Flat (slab)' },
      { 'id' => 'shaker', 'name' => 'Shaker (recessed panel)' },
      { 'id' => 'slim_shaker', 'name' => 'Slim shaker' },
      { 'id' => 'stepped', 'name' => 'Stepped panel' },
      { 'id' => 'fluted', 'name' => 'Fluted (vertical grooves)' },
      { 'id' => 'grooved', 'name' => 'Two panels (horizontal groove)' },
      { 'id' => 'three_panel', 'name' => 'Three panels (two grooves)' },
      { 'id' => 'beaded', 'name' => 'Beaded (fine vertical grooves)' },
      { 'id' => 'flutes_h', 'name' => 'Horizontal grooves' },
      { 'id' => 'line_frame', 'name' => 'Line frame (grooved outline)' },
      { 'id' => 'edge_pull', 'name' => 'Edge pull (finger groove along the top)' }
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
      when 'three_panel' then three_panel_cuts(width, height, thickness)
      when 'beaded' then beaded_cuts(width, height, thickness)
      when 'flutes_h' then flutes_h_cuts(width, height, thickness)
      when 'line_frame' then line_frame_cuts(width, height, thickness)
      when 'edge_pull' then edge_pull_cuts(width, height, thickness)
      when GLASS_FRAME then glass_frame_cuts(width, height, thickness)
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

      pitch = [22.0, (width - 56.0) / 50.0].max # never more than about 50 grooves
      count = ((width - 50.0 - 6.0) / pitch).floor + 1
      return [] if count < 3

      span = ((count - 1) * pitch) + 6.0
      start = (width - span) / 2.0
      depth = [3.0, thickness / 5.0].min
      (0...count).map { |i| [start + (i * pitch), start + (i * pitch) + 6.0, 25.0, height - 25.0, 0.0, depth] }
    end
    private_class_method :fluted_cuts

    # One groove across the whole width, in the middle of the height: two panels.
    def self.grooved_cuts(width, height, thickness)
      return [] if height < 300.0 || width < 100.0

      [[0.0, width, (height / 2.0) - 3.0, (height / 2.0) + 3.0, 0.0, [3.0, thickness / 5.0].min]]
    end
    private_class_method :grooved_cuts

    # Two grooves, a third of the height apart: three panels (a tall front).
    def self.three_panel_cuts(width, height, thickness)
      return [] if height < 600.0 || width < 100.0

      depth = [3.0, thickness / 5.0].min
      [1.0 / 3.0, 2.0 / 3.0].map { |k| [0.0, width, (height * k) - 2.0, (height * k) + 2.0, 0.0, depth] }
    end
    private_class_method :three_panel_cuts

    # Fine vertical grooves (a beadboard): 3 mm wide every 16 mm.
    def self.beaded_cuts(width, height, thickness)
      return [] if width < 90.0 || height < 100.0

      pitch = [16.0, (width - 43.0) / 60.0].max
      count = ((width - 40.0 - 3.0) / pitch).floor + 1
      return [] if count < 5

      span = ((count - 1) * pitch) + 3.0
      start = (width - span) / 2.0
      depth = [2.0, thickness / 6.0].min
      (0...count).map { |i| [start + (i * pitch), start + (i * pitch) + 3.0, 20.0, height - 20.0, 0.0, depth] }
    end
    private_class_method :beaded_cuts

    # Horizontal grooves 6 mm high every 22 mm, as a group in the middle of the height.
    def self.flutes_h_cuts(width, height, thickness)
      return [] if height < 90.0 || width < 100.0

      pitch = [22.0, (height - 56.0) / 50.0].max
      count = ((height - 50.0 - 6.0) / pitch).floor + 1
      return [] if count < 3

      span = ((count - 1) * pitch) + 6.0
      start = (height - span) / 2.0
      depth = [3.0, thickness / 5.0].min
      (0...count).map { |i| [25.0, width - 25.0, start + (i * pitch), start + (i * pitch) + 6.0, 0.0, depth] }
    end
    private_class_method :flutes_h_cuts

    # The grooves of a design that run all the way round a rectangle, as [y0, y1, z0, z1, groove width, from, to] (the outside of the
    # groove): the line frame. `cuts` has the same groove as four boards, for when it is cut square.
    def self.loops(design, width, height, thickness)
      return [] unless design.to_s == 'line_frame' && width >= 120.0 && height >= 120.0

      [[45.0, width - 45.0, 45.0, height - 45.0, 3.0, 0.0, [2.0, thickness / 6.0].min]]
    end
    # The frame of a glass door: an opening right through the board, GLASS_FRAME_WIDTH in from the edges (less on a small door).
    # The pane goes in that opening.
    def self.glass_opening(width, height)
      f = [GLASS_FRAME_WIDTH, ([width, height].min - 80.0) / 2.0].min
      f < 25.0 ? nil : [f, width - f, f, height - f]
    end

    def self.glass_frame_cuts(width, height, thickness)
      opening = glass_opening(width, height)
      opening ? [opening + [0.0, thickness]] : []
    end
    private_class_method :glass_frame_cuts

    # A groove 3 mm wide drawn as a rectangle 45 mm in from the edges.
    def self.line_frame_cuts(width, height, thickness)
      return [] if width < 120.0 || height < 120.0

      i = 45.0
      g = 3.0
      depth = [2.0, thickness / 6.0].min
      [[i, width - i, i, i + g, 0.0, depth], [i, width - i, height - i - g, height - i, 0.0, depth],
       [i, i + g, i + g, height - i - g, 0.0, depth], [width - i - g, width - i, i + g, height - i - g, 0.0, depth]]
    end
    private_class_method :line_frame_cuts

    # A rebate along the top edge, 22 mm high and 10 mm deep, to get a finger under (the front is taken hold of there).
    def self.edge_pull_cuts(width, height, thickness)
      return [] if height < 150.0 || width < 100.0

      [[0.0, width, height - 22.0, height, 0.0, [10.0, thickness * 0.55].min]]
    end
    private_class_method :edge_pull_cuts
  end
end
