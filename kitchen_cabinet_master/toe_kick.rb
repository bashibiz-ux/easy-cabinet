# frozen_string_literal: true

module KitchenCabinetMaster
  # The toe kick (plinth): a panel under the front of a base or tall cabinet,
  # standing on the floor and set back from the carcass front so there is room
  # for toes. Pure maths, no SketchUp calls (see CabinetGenerator for the model side).
  #
  #   side view                  Z
  #     carcass ┌──────────┐     ▲   carcass base Z = toe-kick height
  #             │          │     │
  #     plinth      ┌┐ ◄── Z 0 .. toe-kick height
  #   floor ────────┴┴───────►  X (front is to the right)
  #                 ▲ set back Defaults::TOE_KICK_RECESS from the carcass front
  #
  # Segmentation by PIECE LENGTH: the plinth spans the full cabinet width and is
  # cut into pieces of the chosen length, with whatever is left over as the last
  # piece (the way a plinth is cut from stock boards):
  #
  #   900 wide,  600 pieces  ->  600 + 300
  #   1000 wide, 600 pieces  ->  600 + 400
  #   1200 wide, 600 pieces  ->  600 + 600
  #   2400 wide, 900 pieces  ->  900 + 900 + 600
  #   500 wide,  600 pieces  ->  500            (shorter than one piece: a single piece)
  #
  # "Intelligent" part: if the leftover would be a sliver (under MIN_PIECE), the
  # last full piece and the leftover are shared equally instead, so no piece is
  # ever a useless offcut:
  #
  #   650 wide,  600 pieces  ->  325 + 325      (not 600 + 50)
  #
  # Wall units have no toe kick, and a toe-kick height of 0 means "no plinth".
  module ToeKick
    ROLE_PREFIX = 'toe_kick_'
    MIN_PIECE = 100.0 # mm; a shorter leftover is merged with the previous piece
    TOLERANCE = 0.01

    # Array of CabinetLayout::Panel (millimetres), in cabinet coordinates.
    def self.panels(params)
      return [] if params['cabinet_category'].to_s == 'wall'

      height = params['toe_kick_height'].to_f
      return [] unless height.positive?

      thick = params['toe_kick_thickness'].to_f
      front = round2(params['depth'].to_f - Defaults::TOE_KICK_RECESS - thick)

      start = 0.0
      segment_widths(params['width'].to_f, params['toe_kick_piece_length'].to_f).each_with_index.map do |piece, index|
        panel = CabinetLayout::Panel.new(
          role: "#{ROLE_PREFIX}#{index + 1}", name: "Toe Kick #{index + 1}",
          extent: [round2(thick), round2(piece), round2(height)],
          offset: [front, round2(start), 0.0]
        )
        start += piece
        panel
      end
    end

    # The widths of the pieces, left to right, that add up to `width`.
    def self.segment_widths(width, piece_length)
      return [width] unless piece_length.positive? && width > piece_length

      full = (width / piece_length).floor
      rest = width - (full * piece_length)
      return Array.new(full, piece_length) if rest < TOLERANCE
      return Array.new(full, piece_length) + [rest] if rest >= MIN_PIECE

      # The leftover would be a sliver: share it with the last full piece.
      Array.new(full - 1, piece_length) + Array.new(2, (piece_length + rest) / 2.0)
    end

    # The material a toe kick is painted with: its own choice, or the door's or
    # the carcass's colour.
    def self.material_name(params, door_material, carcass_material)
      chosen = params['toe_kick_material'].to_s
      case chosen
      when '', Defaults::SAME_AS_DOOR, Defaults::SAME_AS_CABINET then door_material
      when Defaults::SAME_AS_CARCASS then carcass_material
      else chosen
      end
    end

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end
