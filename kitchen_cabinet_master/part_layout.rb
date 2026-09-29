# frozen_string_literal: true

module KitchenCabinetMaster
  # Works out the geometry of a filler or an end panel. Pure maths, no SketchUp
  # calls (see PartGenerator for the model side). Uses the same coordinate
  # convention as CabinetLayout: depth = X, width = Y, height = Z, floor = Z 0.
  module PartLayout
    Layout = Struct.new(:base_z, :top_z, :board, :toe_kick, keyword_init: true)

    # A FILLER is a single flat board spanning the full configured size, raised off
    # the floor by the toe-kick height like a cabinet. It has no toe kick of its
    # own: the toe kick is a separate entity (see toe_kick below).
    def self.filler(params)
      base_z = filler_base_z(params)
      height = params['height'].to_f
      board = CabinetLayout::Panel.new(
        role: 'board', name: 'Filler Panel',
        extent: [round2(params['depth'].to_f), round2(params['width'].to_f), round2(height)],
        offset: [0.0, 0.0, round2(base_z)]
      )
      Layout.new(base_z: round2(base_z), top_z: round2(base_z + height), board: board, toe_kick: [])
    end

    # A TOE KICK is a run of equal pieces laid end to end along Y, standing on the
    # floor. It has no board of its own: the pieces ARE the part (see ToeKick).
    def self.toe_kick(params)
      Layout.new(base_z: 0.0, top_z: round2(params['toe_kick_height']), board: nil, toe_kick: ToeKick.pieces(params))
    end

    def self.filler_base_z(params)
      params['cabinet_category'].to_s == 'wall' ? 0.0 : params['toe_kick_height'].to_f
    end

    # [depth, width, top] from the filler's own local floor origin.
    def self.filler_envelope(params)
      [params['depth'].to_f, params['width'].to_f, filler_base_z(params) + params['height'].to_f]
    end

    # An END PANEL is a single thin board covering the exposed side of another
    # cabinet or filler: the same depth and total height (floor to top) as its
    # target, `thickness` wide. `params` carries the target's envelope, copied in
    # once by PartManager when the end panel is inserted (see PartManager,
    # PartGenerator.attributes_for), so no SketchUp lookup of the target is ever
    # needed again, including on every later Update. The board sits at the part's
    # own local origin; PartManager places the part's root against the target's
    # actual face.
    def self.end_panel(params)
      depth = params['target_depth'].to_f
      top = params['target_top'].to_f
      thickness = params['thickness'].to_f
      board = CabinetLayout::Panel.new(
        role: 'board', name: 'End Panel',
        extent: [round2(depth), round2(thickness), round2(top)],
        offset: [0.0, 0.0, 0.0]
      )
      Layout.new(base_z: 0.0, top_z: round2(top), board: board, toe_kick: [])
    end

    # [depth, thickness, top] from the end panel's own local floor origin.
    def self.end_panel_envelope(params)
      [params['target_depth'].to_f, params['thickness'].to_f, params['target_top'].to_f]
    end

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end
