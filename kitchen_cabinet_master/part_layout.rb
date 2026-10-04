# frozen_string_literal: true

module KitchenCabinetMaster
  # Works out the geometry of a filler or an end panel. Pure maths, no SketchUp
  # calls (see PartGenerator for the model side). Uses the same coordinate
  # convention as CabinetLayout: depth = X, width = Y, height = Z, floor = Z 0.
  module PartLayout
    Layout = Struct.new(:base_z, :top_z, :board, :toe_kick, keyword_init: true)

    # A FILLER is a single flat board beside a cabinet, on the cabinet's wall side:
    #
    #   plan view                       X (front) ▲
    #                                             │      door front
    #        cabinet        filler       ──────────┼───────┬──┬───────────
    #     ┌──────────┐    ┌──┐                     │       │██│  ◄ thickness
    #     │          │    │██│  ◄ front face flush  wall    └──┘
    #     └──────────┘    └──┘    with the door
    #
    # It stands at the cabinet's own base Z and its front face is level with the
    # door front. `params` carries what it was inserted against, copied in once by
    # PartManager (target_base_z, target_flush_x), so Update never has to look the
    # cabinet up again. The part's own origin is the cabinet's back edge, so the
    # board is set forward by `target_flush_x - thickness`; that also keeps a
    # following cabinet lined up when it is chained after the filler.
    def self.filler(params)
      thickness = params['thickness'].to_f
      base_z = params['target_base_z'].to_f
      height = params['height'].to_f
      board = CabinetLayout::Panel.new(
        role: 'board', name: 'Filler Panel',
        extent: [round2(thickness), round2(params['width'].to_f), round2(height)],
        offset: [round2(params['target_flush_x'].to_f - thickness), 0.0, round2(base_z)]
      )
      with_overrides(Layout.new(base_z: round2(base_z), top_z: round2(base_z + height), board: board, toe_kick: []), params)
    end

    # What the user changed in the Customize window (params['custom_overrides'], see Customizer): the board of a
    # filler, end panel or worktop piece (key "board"), or the pieces of a toe kick (their roles).
    def self.with_overrides(layout, params)
      overrides = params && params['custom_overrides']
      return layout unless overrides.is_a?(Hash) && !overrides.empty?

      changed = ([layout.board].compact + layout.toe_kick).map { |item| CabinetLayout.tweak_item(item, overrides[item.role]) }.any?
      layout.top_z = round2(layout.board.offset[2] + layout.board.extent[2]) if changed && layout.board
      layout
    end

    # The layout of a stored part (filler, end panel, toe kick, or a worktop piece), with its changes; nil when it
    # cannot be worked out from what was stored (a worktop made before pieces recorded their shape).
    def self.layout_for(params)
      case params['part_kind']
      when 'filler' then filler(params)
      when 'end_panel' then end_panel(params)
      when 'toe_kick' then toe_kick(params)
      when 'worktop', 'backsplash' then worktop_for(params)
      end
    end

    # A worktop slab or back splash piece again from what it recorded when it was built.
    def self.worktop_for(params)
      return nil unless params['board_extent'].is_a?(Array)

      slab = params['part_kind'] == 'worktop'
      points = params['board_points'].is_a?(Array) ? params['board_points'] : nil
      edge = params['board_round_edge'].to_s.empty? ? nil : params['board_round_edge'].to_i
      worktop(params['board_extent'], points, slab ? 'Worktop' : 'Back Splash', params['board_round'].to_f, edge, params)
    end

    # A TOE KICK is a run of equal pieces laid end to end along Y, standing on the
    # floor. It has no board of its own: the pieces ARE the part (see ToeKick).
    def self.toe_kick(params)
      with_overrides(Layout.new(base_z: 0.0, top_z: round2(params['toe_kick_height']), board: nil, toe_kick: ToeKick.pieces(params)), params)
    end

    # [depth, width, top] from the filler's own local floor origin: everything from
    # the cabinet's back edge to the filler's front face, so nothing else is put
    # in the space between.
    def self.filler_envelope(params)
      [params['target_flush_x'].to_f, params['width'].to_f, params['target_base_z'].to_f + params['height'].to_f]
    end

    # An END PANEL is a single thin board covering the exposed side of a cabinet or
    # filler, with its own size: `depth` (back to front), `thickness` (its width
    # along the row) and `height` (floor to top). Depth starts as the target's door
    # front, so it stands flush with the doors, and height as the target's top,
    # but both are the user's to change. The board sits at the part's own local
    # origin (the cabinet's back edge, on the floor); PartManager places the part's
    # root against the target's actual face.
    def self.end_panel(params)
      depth = params['depth'].to_f
      height = params['height'].to_f
      base_z = params['target_base_z'].to_f
      board = CabinetLayout::Panel.new(
        role: 'board', name: 'End Panel',
        extent: [round2(depth), round2(params['thickness'].to_f), round2(height)],
        offset: [0.0, 0.0, round2(base_z)]
      )
      with_overrides(Layout.new(base_z: round2(base_z), top_z: round2(base_z + height), board: board, toe_kick: []), params)
    end

    # A WORKTOP slab: one board of extent [depth, length, thickness] at its own origin
    # (PartManager / WorktopManager put the part's root on top of the carcass).
    # `round` rounds the front-top edge (mm, 0 = square); a corner's polygon is not rounded.
    def self.worktop(extent, points = nil, name = 'Worktop', round = 0.0, round_edge = nil, params = nil)
      board = CabinetLayout::Panel.new(role: 'board', name: name, extent: extent.map { |v| round2(v) }, offset: [0.0, 0.0, 0.0],
                                       points: points&.map { |x, y| [round2(x), round2(y)] }, round: round.to_f, round_edge: round_edge)
      with_overrides(Layout.new(base_z: 0.0, top_z: round2(extent[2]), board: board, toe_kick: []), params)
    end

    # [depth, thickness, top] from the end panel's own local floor origin.
    def self.end_panel_envelope(params)
      [params['depth'].to_f, params['thickness'].to_f, params['target_base_z'].to_f + params['height'].to_f]
    end

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end
