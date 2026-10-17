# frozen_string_literal: true

require 'json'

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
      total = params['toe_kick_total'].to_f
      return [] unless length.positive? && (count.positive? || total.positive?)

      thick = params['toe_kick_thickness'].to_f
      front = front_offset(params)
      turns = turns_of(params)
      # Over a whole row: pieces of length laid one after another to cover 	otal, the last one shorter.
      lengths = total.positive? ? piece_lengths(total, length) : Array.new(count, length)
      return straight_pieces(lengths, thick, height, front) + returns(params, thick, height, front) if turns.empty?

      path_pieces(lengths, thick, height, front + thick, turns, total.positive? ? total : nil) # the path runs along the FRONT face
    end

    # 	otal mm cut into pieces of length; the last piece takes what is left.
    def self.piece_lengths(total, length)
      count = (total / length).ceil
      count = 1 if count < 1
      lengths = Array.new(count, length)
      lengths[-1] = total - (length * (count - 1))
      lengths
    end

    # How far a toe kick that runs `length` mm from the start of its row reaches at each end to touch the INNER face of a side panel that stands on the
    # floor near the end: [lead, trail] in mm. It stops at that face and never goes into the panel (a panel touching the end of the row needs no
    # extension; one a little way off is reached). panels: [{ y:, thickness:, base: }] in the frame of the row's first unit (y along the row, 0 at the
    # start of the first unit; y is where the panel's own thickness starts); only a panel that reaches the floor (base about 0) counts.
    REACH_LIMIT = 60.0 # a panel further than this from the end of the row is not the end panel of this row

    def self.panel_reach(panels, length)
      lead = 0.0
      trail = 0.0
      panels.each do |panel|
        high = panel[:base].to_f > 1.0
        next if high && panel[:category].to_s == 'wall' # (the side panel of a wall unit hangs: no toe kick under it)

        # A panel that is only on the cabinet leaves the floor under it free: the toe kick goes under it, to its outer face.
        before = -(panel[:y].to_f + (high ? 0.0 : panel[:thickness].to_f)) # the room between the inner face of a panel at the start and the start of the row
        after = panel[:y].to_f + (high ? panel[:thickness].to_f : 0.0) - length # and between the end of the row and the inner face of a panel at the end
        lead = [lead, before].max if before > 0.5 && before <= REACH_LIMIT
        trail = [trail, after].max if after > 0.5 && after <= REACH_LIMIT
      end
      [lead, trail]
    end

    # Which ends of a straight row have a side panel that stands only on the cabinet (it leaves the floor under it free, where the plinth goes under it): [start, end]. A
    # return of the toe kick closes the side there, under the panel. Same input as panel_reach.
    def self.panel_returns(panels, length)
      start = false
      finish = false
      panels.each do |panel|
        next unless panel[:base].to_f > 1.0 && panel[:category].to_s != 'wall'

        before = -panel[:y].to_f
        after = panel[:y].to_f + panel[:thickness].to_f - length
        start = true if before > 0.5 && before <= REACH_LIMIT
        finish = true if after > 0.5 && after <= REACH_LIMIT
      end
      [start, finish]
    end

    # The pieces that turn the plinth round the end of a straight row under a side panel that stands only on the cabinet: from the front piece back to the carcass,
    # one thickness wide, flush with the outer face of the panel (the row of pieces reaches that face, see panel_reach). `toe_kick_return_start` and
    # `toe_kick_return_end` say which ends have one.
    def self.returns(params, thick, height, front)
      return [] unless front.positive?

      total = total_length(params)
      list = []
      if truthy?(params['toe_kick_return_start'])
        list << CabinetLayout::Panel.new(role: "#{ROLE_PREFIX}return_start", name: 'Toe Kick Return 1', extent: [round2(front), round2(thick), round2(height)], offset: [0.0, 0.0, 0.0])
      end
      if truthy?(params['toe_kick_return_end'])
        list << CabinetLayout::Panel.new(role: "#{ROLE_PREFIX}return_end", name: "Toe Kick Return #{list.length + 1}", extent: [round2(front), round2(thick), round2(height)], offset: [0.0, round2(total - thick), 0.0])
      end
      list
    end
    private_class_method :returns

    def self.truthy?(value) = [true, 'true', 1, '1'].include?(value)
    private_class_method :truthy?

    # How long the row of cabinets and fillers from nchor runs (see turns_from), in mm:
    # their widths added up, for as long as they join on.
    def self.run_length(anchor, items)
      angle = 0.0
      total = anchor[:width].to_f
      previous_end = [anchor[:x].to_f, anchor[:y].to_f + anchor[:width].to_f]
      items.each do |item|
        break unless distance(previous_end, [item[:x], item[:y]]) <= item[:width].to_f + 150.0

        change = normalise(item[:angle].to_f - angle)
        if change.abs > 1.0
          break unless (change + 90.0).abs < 1.0

          angle = item[:angle].to_f
        else
          total += distance(previous_end, [item[:x], item[:y]]) # the room left between two units (for a side panel) is plinth too
        end
        total += item[:width].to_f
        forward = unit(item[:angle].to_f, :y)
        previous_end = [item[:x] + forward[0] * item[:width].to_f, item[:y] + forward[1] * item[:width].to_f]
      end
      round2(total)
    end

    # The turns of the row of cabinets this toe kick follows: [[distance, degrees], ...].
    # `distance` is how far the front face runs before it meets the next leg's front
    # face; `degrees` is the turn there (-90 = the row turns clockwise, as a corner
    # cabinet does). Stored as JSON text or an Array; none means a straight run.
    def self.turns_of(params)
      raw = params['toe_kick_turns']
      raw = JSON.parse(raw) if raw.is_a?(String) && !raw.empty?
      return [] unless raw.is_a?(Array)

      raw.map { |distance, degrees| [distance.to_f, degrees.to_f] }
    rescue JSON::ParserError
      []
    end

    # Works out the turns of the row that follows `anchor`, for `toe_kick_turns`.
    #
    # `anchor` and every entry of `items` (the cabinets and fillers inserted after
    # it, in order) are Hashes, all measured in the ANCHOR's own plan frame, in mm:
    #   x, y      the item's origin      angle   its heading in degrees (0 = the anchor's)
    #   width     along its own Y        depth   how deep its front is (a corner: its width)
    #   corner    true for a corner unit
    # Returns [[distance, degrees], ...] (see turns_of). The run stops following the
    # row at the first item that is not a clockwise quarter turn from the last, or
    # that does not join on where the one before ended.
    def self.turns_from(anchor, items, recess)
      angle = 0.0
      depth = anchor[:depth].to_f
      line_point = [depth - recess, 0.0] # a point on the current leg's front line
      line_start = line_point
      previous_end = [anchor[:x].to_f, anchor[:y].to_f + anchor[:width].to_f]
      turns = []

      items.each_with_index do |item, index|
        joined = distance(previous_end, [item[:x], item[:y]]) <= item[:width].to_f + 150.0
        break unless joined

        change = normalise(item[:angle].to_f - angle)
        if change.abs > 1.0
          break unless (change + 90.0).abs < 1.0

          leg_depth = leg_depth_for(items, index, depth)
          heading = unit(angle, :y)
          normal = unit(item[:angle], :x)
          point = [item[:x] + normal[0] * (leg_depth - recess), item[:y] + normal[1] * (leg_depth - recess)]
          run = ((point[0] - line_point[0]) * heading[0]) + ((point[1] - line_point[1]) * heading[1])
          corner = [line_point[0] + heading[0] * run, line_point[1] + heading[1] * run]
          run_from_start = ((corner[0] - line_start[0]) * heading[0]) + ((corner[1] - line_start[1]) * heading[1])
          break if run_from_start < 1.0

          turns << [round2(run_from_start), change]
          angle = item[:angle].to_f
          depth = leg_depth
          line_point = corner
          line_start = corner
        end
        forward = unit(item[:angle].to_f, :y)
        previous_end = [item[:x] + forward[0] * item[:width].to_f, item[:y] + forward[1] * item[:width].to_f]
      end
      turns
    end

    # The depth a leg's front sits at: that of the first cabinet or filler on it that
    # is not a corner unit (a corner is a square, its front is not the run's).
    def self.leg_depth_for(items, index, fallback)
      heading = items[index][:angle].to_f
      items[index..].each do |item|
        break unless (normalise(item[:angle].to_f - heading)).abs <= 1.0
        return item[:depth].to_f unless item[:corner]
      end
      fallback
    end
    private_class_method :leg_depth_for

    def self.normalise(degrees)
      value = (degrees + 180.0) % 360.0 - 180.0
      value == -180.0 ? 180.0 : value
    end
    private_class_method :normalise

    def self.distance(first, second)
      Math.sqrt(((first[0] - second[0])**2) + ((first[1] - second[1])**2))
    end
    private_class_method :distance

    # The plan-view outline of every piece, as four [x, y] corners in mm in the toe
    # kick's own frame (turned legs included). Used to keep two toe kicks from
    # being put on top of one another.
    def self.footprints(params)
      pieces(params).map do |piece|
        radians = piece.rotation.to_f * Math::PI / 180.0
        cos = Math.cos(radians)
        sin = Math.sin(radians)
        [[0.0, 0.0], [piece.extent[0], 0.0], [piece.extent[0], piece.extent[1]], [0.0, piece.extent[1]]].map do |x, y|
          [(x * cos) - (y * sin) + piece.offset[0], (x * sin) + (y * cos) + piece.offset[1]]
        end
      end
    end
    def self.straight_pieces(lengths, thick, height, front)
      along = 0.0
      lengths.each_with_index.map do |length, index|
        piece = CabinetLayout::Panel.new(
          role: "#{ROLE_PREFIX}#{index + 1}", name: "Toe Kick #{index + 1}",
          extent: [round2(thick), round2(length), round2(height)],
          offset: [round2(front), round2(along), 0.0]
        )
        along += length
        piece
      end
    end
    private_class_method :straight_pieces

    # Pieces laid one after another along the front of a row that turns corners.
    # Each leg runs along its own wall; the piece that reaches a corner is cut short
    # to end there, and the next leg starts under it, so the corner closes without
    # overlap (a butt joint). All maths is in the toe kick's own plan frame: X is
    # depth (front is +X), Y runs along the first leg, and a turn of `degrees`
    # rotates the direction of travel about Z (clockwise is negative).
    def self.path_pieces(lengths, thick, height, front, turns, total = nil)
      legs = legs_for(front, thick, turns)
      length = lengths.first
      count = lengths.length
      remaining = total
      leg = 0
      used = 0.0
      pieces = []

      # Without a total: exactly count pieces. With one: as many as it takes to cover it.
      while total ? remaining > 0.5 : pieces.length < count
        current = legs[leg]
        room = current[:length] ? current[:length] - used : length
        piece = [length, room].min
        piece = [piece, remaining].min if total
        if piece < 1.0 && leg < legs.length - 1
          leg += 1
          used = 0.0
          next
        end

        direction = unit(current[:angle], :y)
        normal = unit(current[:angle], :x)
        along = [current[:start][0] + direction[0] * used, current[:start][1] + direction[1] * used]
        pieces << CabinetLayout::Panel.new(
          role: "#{ROLE_PREFIX}#{pieces.length + 1}", name: "Toe Kick #{pieces.length + 1}",
          extent: [round2(thick), round2(piece), round2(height)],
          offset: [round2(along[0] - normal[0] * thick), round2(along[1] - normal[1] * thick), 0.0],
          rotation: current[:angle]
        )
        used += piece
        remaining -= piece if total
        if current[:length] && used >= current[:length] - 0.01 && leg < legs.length - 1
          leg += 1
          used = 0.0
        end
      end
      pieces
    end
    private_class_method :path_pieces

    # One entry per straight leg: where its front line starts, its heading in
    # degrees, and how long it runs (nil = the last leg, which just carries on).
    # A leg after a corner starts one thickness behind the corner point so its body
    # tucks in behind the last piece of the leg before.
    def self.legs_for(front, thick, turns)
      start = [front, 0.0]
      angle = 0.0
      legs = []
      turns.each_with_index do |(distance, degrees), index|
        run = index.zero? ? distance : distance + thick
        legs << { start: start, angle: angle, length: run }
        heading = unit(angle, :y)
        corner = [start[0] + heading[0] * run, start[1] + heading[1] * run]
        angle += degrees
        next_heading = unit(angle, :y)
        start = [corner[0] - next_heading[0] * thick, corner[1] - next_heading[1] * thick]
      end
      legs << { start: start, angle: angle, length: nil }
    end
    private_class_method :legs_for
    # Unit vector of the direction of travel (:y) or of the front-facing normal (:x)
    # after turning `degrees` from the first leg (travel +Y, front +X).
    def self.unit(degrees, axis)
      radians = degrees * Math::PI / 180.0
      axis == :y ? [-Math.sin(radians), Math.cos(radians)] : [Math.cos(radians), Math.sin(radians)]
    end
    private_class_method :unit

    # X of the back face of a piece: the carcass front, less the recess, less the piece's own thickness.
    def self.front_offset(params)
      params['target_depth'].to_f - params['toe_kick_recess'].to_f - params['toe_kick_thickness'].to_f
    end

    # Total length of the whole run.
    def self.total_length(params)
      total = params['toe_kick_total'].to_f
      total.positive? ? total : params['toe_kick_piece_length'].to_f * params['toe_kick_pieces'].to_i
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
