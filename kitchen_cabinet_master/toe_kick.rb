# frozen_string_literal: true

module KitchenCabinetMaster
  # The toe kick (plinth) is its OWN entity: it is not part of any cabinet. A
  # cabinet only stands on the floor at the toe-kick height (its Base Z); the
  # plinth itself is inserted separately, as a run of equal pieces laid one after
  # another. Pure maths, no SketchUp calls (see PartLayout / PartGenerator).
  #
  #   side view                  Z
  #     carcass ┌──────────┐     ▲   carcass base Z = toe-kick height
  #             │          │     │
  #     plinth      ┌┐ ◄── Z 0 .. toe-kick height
  #   floor ────────┴┴───────►  X (front is to the right)
  #                 ▲ set back `recess` from the carcass front
  #
  #   plan view (Y runs along the pieces)
  #     piece 1      piece 2      piece 3
  #   ┌──────────┬──────────┬──────────┐   each piece is `piece_length` long,
  #   └──────────┴──────────┴──────────┘   `pieces` of them, end to end
  module ToeKick
    ROLE_PREFIX = 'toe_kick_'

    # Array of CabinetLayout::Panel (millimetres), in the toe kick's own frame:
    # origin at the left end of the first piece, on the floor.
    #
    #   piece_length  length of each piece (Y)
    #   pieces        how many pieces, placed one after another
    #   thickness     front-to-back size of a piece (X)
    #   height        floor to top (Z)
    #   recess        how far the plinth's front face is set back from the carcass front
    #   target_depth  the carcass depth it sits under; the front face is at
    #                 target_depth - recess, so the piece starts `thickness` behind that
    def self.pieces(params)
      height = params['toe_kick_height'].to_f
      return [] unless height.positive?

      length = params['toe_kick_piece_length'].to_f
      count = params['toe_kick_pieces'].to_i
      return [] unless length.positive? && count.positive?

      thick = params['toe_kick_thickness'].to_f
      front = front_offset(params)

      (0...count).map do |index|
        CabinetLayout::Panel.new(
          role: "#{ROLE_PREFIX}#{index + 1}", name: "Toe Kick #{index + 1}",
          extent: [round2(thick), round2(length), round2(height)],
          offset: [round2(front), round2(index * length), 0.0]
        )
      end
    end

    # X of the back face of a piece: the carcass front, less the recess, less the piece's own thickness.
    def self.front_offset(params)
      params['target_depth'].to_f - params['toe_kick_recess'].to_f - params['toe_kick_thickness'].to_f
    end

    # Total length of the whole run.
    def self.total_length(params)
      params['toe_kick_piece_length'].to_f * params['toe_kick_pieces'].to_i
    end

    # The material a toe kick is painted with: its own choice, or the colour of the
    # door / carcass of whatever it was inserted against. By default it follows the
    # door; when there is no door colour to follow (nothing selected, or a cabinet
    # that never recorded one) it falls back to the plain white default, so the
    # result is never an empty name.
    def self.material_name(params, door_material, carcass_material)
      chosen = params['toe_kick_material'].to_s
      name = case chosen
             when '', Defaults::SAME_AS_DOOR, Defaults::SAME_AS_CABINET then door_material
             when Defaults::SAME_AS_CARCASS then carcass_material
             else chosen
             end
      name.to_s.empty? ? Defaults::DEFAULT_MATERIAL : name.to_s
    end

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end
