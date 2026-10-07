# frozen_string_literal: true

module KitchenCabinetMaster
  # The designs a door or drawer front can have. A front is a plain board; a design cuts shapes into its outer face (a
  # recessed panel in a frame, steps, grooves). Pure maths, no SketchUp objects: `cuts` says what is cut, PanelGenerator
  # cuts it. All numbers are millimetres, on the front face: y across the front (0 at its left), z up it (0 at its bottom).
  module FrontDesign
    DEFAULT = 'flat'
    GLASS_FRAME = 'glass_frame' # not one to choose: the front of a glass door cabinet (a frame round an opening right through it)
    GLASS_FRAME_WIDTH = 50.0
    GLASS_THICKNESS = 4.0
    THIRD_ROW_HEIGHT = 700.0 # a door this high or higher has three rows of panes in a grid (two below that)
    FLUTED_GLASS = 'Glass - Fluted' # the glass material whose panes get real flutes
    # The glass designs: a frame rame mm wide round openings right through the door, ar mm bars between several panes, made of the door
    # material (rame_material nil) or of its own (an aluminium or a black frame). split says how the panes are laid out.
    GLASS_LOOKS = {
      GLASS_FRAME => { frame: GLASS_FRAME_WIDTH, bar: 0.0, split: nil, frame_material: nil },
      'glass_wide' => { frame: GLASS_FRAME_WIDTH, bar: 0.0, split: nil, frame_material: nil },
      'glass_wide_grid' => { frame: GLASS_FRAME_WIDTH, bar: 20.0, split: :grid, frame_material: nil },
      'glass_aluminium' => { frame: 15.0, bar: 0.0, split: nil, frame_material: 'Aluminium frame' },
      'glass_black' => { frame: 15.0, bar: 0.0, split: nil, frame_material: 'Black frame' },
      'glass_two' => { frame: 15.0, bar: 15.0, split: :long, frame_material: 'Aluminium frame' },
      'glass_grid' => { frame: 15.0, bar: 15.0, split: :grid, frame_material: 'Aluminium frame' }
    }.freeze
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

    # The glass doors (the Glass Door field of the Models section; the doors of a cabinet are a frame with panes in it).
    GLASS_DESIGNS = [
      { 'id' => 'glass_aluminium', 'name' => 'Full glass, aluminium frame' },
      { 'id' => 'glass_black', 'name' => 'Full glass, black frame' },
      { 'id' => 'glass_wide', 'name' => 'Wide door frame' },
      { 'id' => 'glass_wide_grid', 'name' => 'Wide door frame with grid of panes' },
      { 'id' => 'glass_two', 'name' => 'Two panes, aluminium' },
      { 'id' => 'glass_grid', 'name' => 'Grid of panes, aluminium' }
    ].freeze

    def self.ids
      DESIGNS.map { |design| design['id'] }
    end

    def self.valid?(id)
      ids.include?(id.to_s)
    end

    # Two doors one above the other (a lift-up 2 door unit, or its bi-fold) can have the glass on the upper one, the lower one, or both
    # (`glass_doors`: 'upper', 'lower', anything else is both). The bi-fold's first door is the upper one, the stacked doors' second.
    def self.glass_on_door?(role, params)
      return true unless (params['door_stacked'] == true || params['bifold'] == true) && params['door_count'].to_i == 2

      upper = params['bifold'] == true ? 'door_1' : 'door_2'
      case params['glass_doors'].to_s
      when 'upper' then role == upper
      when 'lower' then role != upper
      else true
      end
    end

    # The glass door to use for a stored value: one of the glass doors, or blank (no glass).
    def self.clean_glass(id)
      GLASS_DESIGNS.any? { |design| design['id'] == id.to_s } ? id.to_s : ''
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
      when *GLASS_LOOKS.keys then glass_openings(design, width, height).map { |opening| opening + [0.0, thickness] }
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
    def self.glass?(id)
      GLASS_LOOKS.key?(id.to_s)
    end

    # How the frame of a glass design looks, so that it can be made when the material is not in the model (or not in the list yet): colour,
    # roughness and metalness.
    FRAME_LOOKS = {
      'Aluminium frame' => { color: '#AEB3B8', props: { 'roughness' => 0.35, 'metalness' => 0.9 } },
      'Black frame' => { color: '#1E1F21', props: { 'roughness' => 0.45, 'metalness' => 0.6 } }
    }.freeze

    # The material of the frame of a glass design: its own (an aluminium or black frame), or nil for the door material.
    def self.frame_material(id)
      GLASS_LOOKS.dig(id.to_s, :frame_material)
    end

    # The openings right through a glass door `width` x `height`, as [[y0, y1, z0, z1], ...]: the frame is `frame` wide round them and
    # `bar` wide between them. [] when the door is too small for the design (it is then a plain board). The panes of glass go in them.
    def self.glass_openings(design, width, height)
      look = GLASS_LOOKS[design.to_s]
      return [] unless look

      frame = look[:frame]
      frame = [frame, ([width, height].min - 80.0) / 2.0].min if frame >= GLASS_FRAME_WIDTH # (a wide frame is narrower on a small door)
      return [] if frame < 12.0 || [width, height].min < 100.0

      cols, rows = glass_layout(look[:split], width, height, THIRD_ROW_HEIGHT)
      bar = look[:bar]
      pane_w = (width - (2 * frame) - ((cols - 1) * bar)) / cols
      pane_h = (height - (2 * frame) - ((rows - 1) * bar)) / rows
      return [] if pane_w < 40.0 || pane_h < 40.0

      (0...rows).flat_map do |row|
        (0...cols).map do |col|
          y0 = frame + (col * (pane_w + bar))
          z0 = frame + (row * (pane_h + bar))
          [y0, y0 + pane_w, z0, z0 + pane_h].map { |v| (v * 1000).round / 1000.0 }
        end
      end
    end

    # How many panes across and up a door has: none (one pane), two along the longer side, or a grid.
    def self.glass_layout(split, width, height, third_row = THIRD_ROW_HEIGHT)
      case split
      when :long then height >= width ? [1, height < 350.0 ? 1 : 2] : [width < 350.0 ? 1 : 2, 1]
      when :grid then [width >= 300.0 ? 2 : 1, height >= third_row ? 3 : (height >= 350.0 ? 2 : 1)]
      else [1, 1]
      end
    end
    private_class_method :glass_layout

    # The first (or only) opening of the glass door of a glass cabinet.
    def self.glass_opening(width, height)
      glass_openings(GLASS_FRAME, width, height).first
    end
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
