# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # "Design on a selected path": the selected edges are the WALL LINE (the backs of the units stand against them). Edges that join up are one
  # run of walls; separate edges are separate runs (two walls with a gap between them). Where a run turns a right angle with the room inside the
  # turn (an inner corner) the kitchen turns with it, with an L corner unit, as the Auto Kitchen's L and U do; a turn any other way (an outer
  # corner, or not a right angle) ends the run there. A run of more than three walls is built in pieces of up to three (a straight, an L or a U).
  # Every piece is planned by KitchenPlanner from its walls' lengths and built by the same code as Design Kitchen.
  #
  # The geometry here is plain arrays ([x, y] in mm), so that it can be tested without SketchUp.
  module PathKitchen
    TOL = 1.0           # mm: two ends this close are one point
    CLEAR = 600.0       # mm: a piece that goes on after another one starts this far from the corner (the room the first one's last unit takes)
    MAX_WALLS = 3       # walls in one piece: A, B, C
    RIGHT_ANGLE = 3.0   # degrees either way that still count as a right angle
    LAYOUTS = %w[straight l u].freeze
    FITS = %w[auto u l straight all].freeze # the Design from Floor Plan choices: the best fit, a U, an L, one wall, every wall
    MIN_WALL = 1800.0   # mm: a wall shorter than this is left out when a layout is picked from a floor plan
    DICTIONARY = 'KitchenCabinetMaster'
    KEY_PATH = 'kitchen_path'

    # ---- geometry --------------------------------------------------------------

    def self.dist(a, b) = Math.hypot(b[0] - a[0], b[1] - a[1])
    def self.vec(a, b) = [b[0] - a[0], b[1] - a[1]]
    def self.cross(u, v) = (u[0] * v[1]) - (u[1] * v[0])
    def self.dot(u, v) = (u[0] * v[0]) + (u[1] * v[1])
    def self.near?(a, b) = (a[0] - b[0]).abs < TOL && (a[1] - b[1]).abs < TOL

    # segments: [[[x, y], [x, y]], ...] -> [{ points:, closed: }]: the pieces that join end to end, each as the list of its corner points.
    def self.chains(segments)
      remaining = segments.map { |a, b| [a, b] }.reject { |a, b| dist(a, b) < TOL }
      found = []
      until remaining.empty?
        points = remaining.shift.dup
        grew = true
        while grew
          grew = false
          remaining.each_with_index do |(a, b), index|
            if near?(points.last, a) then points << b
            elsif near?(points.last, b) then points << a
            elsif near?(points.first, b) then points.unshift(a)
            elsif near?(points.first, a) then points.unshift(b)
            else next
            end
            remaining.delete_at(index)
            grew = true
            break
          end
        end
        closed = points.length > 3 && near?(points.first, points.last)
        points.pop if closed
        found << { points: straighten(points, closed), closed: closed }
      end
      found
    end

    # Points where the line goes straight on are not corners: edges that split a wall are one wall.
    def self.straighten(points, closed)
      points = points.dup
      loop do
        count = points.length
        break if count <= (closed ? 3 : 2)

        range = closed ? (0...count) : (1...(count - 1))
        index = range.find do |i|
          before = points[(i - 1) % count]
          here = points[i]
          after = points[(i + 1) % count]
          u = vec(before, here)
          v = vec(here, after)
          cross(u, v).abs <= 1e-3 * dist(before, here) * dist(here, after) && dot(u, v).positive?
        end
        break unless index

        points.delete_at(index)
      end
      points
    end

    # True when the room (the side the units stand on) is on the left of the way the points go. A closed shape has its room inside; an open
    # run, on the side the eye is on ([x, y]; without an eye, the right).
    def self.room_on_left?(points, closed, eye)
      if closed
        area = points.each_with_index.sum { |p, i| q = points[(i + 1) % points.length]; (p[0] * q[1]) - (q[0] * p[1]) }
        return area.positive?
      end
      return false unless eye

      longest = (0...(points.length - 1)).max_by { |i| dist(points[i], points[i + 1]) }
      cross(vec(points[longest], points[longest + 1]), vec(points[longest], eye)).positive?
    end

    # The chain with the room on the right of the way it goes (the way a row of units runs in the extension).
    def self.oriented(chain, eye, flip)
      left = room_on_left?(chain[:points], chain[:closed], eye)
      left = !left if flip
      chain.merge(points: left ? chain[:points].reverse : chain[:points])
    end

    def self.walls(points, closed)
      count = closed ? points.length : points.length - 1
      (0...count).map do |i|
        from = points[i]
        to = points[(i + 1) % points.length]
        length = dist(from, to)
        { from: from, dir: [(to[0] - from[0]) / length, (to[1] - from[1]) / length], length: length }
      end
    end

    # The walls that turn into each other at a right turn with the room inside (clockwise, room on the right) are one run.
    def self.runs(walls, closed)
      count = walls.length
      joined = (0...count).map do |i|
        next false unless closed || i < count - 1

        u = walls[i][:dir]
        v = walls[(i + 1) % count][:dir]
        ((Math.atan2(cross(u, v), dot(u, v)) * 180.0 / Math::PI) + 90.0).abs <= RIGHT_ANGLE
      end
      return [{ walls: walls, loop: true }] if closed && joined.all?

      first = closed ? (0...count).find { |i| !joined[(i - 1) % count] } : 0
      found = []
      current = []
      (0...count).map { |k| (first + k) % count }.each do |i|
        current << walls[i]
        next if joined[i]

        found << { walls: current, loop: false }
        current = []
      end
      found << { walls: current, loop: false } unless current.empty?
      found
    end

    # A run as pieces of up to three walls: { layout:, origin:, dir:, lengths: }. A piece that goes on after another starts CLEAR from the corner,
    # and so does the last piece of a closed loop before the corner it meets the first one at.
    def self.pieces(run)
      groups = run[:walls].each_slice(MAX_WALLS).to_a
      groups.each_with_index.filter_map do |group, k|
        group = group.map(&:dup)
        if k.positive?
          group.first[:from] = [group.first[:from][0] + (group.first[:dir][0] * CLEAR), group.first[:from][1] + (group.first[:dir][1] * CLEAR)]
          group.first[:length] -= CLEAR
        end
        group.last[:length] -= CLEAR if run[:loop] && k == groups.length - 1
        next if group.any? { |wall| wall[:length] <= 0 }

        { layout: LAYOUTS[group.length - 1], origin: group.first[:from], dir: group.first[:dir], lengths: group.map { |wall| wall[:length].round(1) } }
      end
    end

    # The layout that fits a floor plan best, from the runs of walls round the room (room on the right): the walls that turn into each other
    # at the inner corners are candidates, 1 to 3 walls in a row, each at least MIN_WALL long. `fit`: 'u', 'l' and 'straight' ask for that layout
    # (the next smaller one when the room has none), 'auto' tries a U, then an L, then the longest wall. The one with the most wall wins.
    # => [piece, ...] (one), with the note for what could not be had.
    def self.fit_pieces(runs, fit)
      candidates = []
      runs.each do |run|
        walls = run[:walls]
        count = walls.length
        (1..[MAX_WALLS, count].min).each do |size|
          starts = run[:loop] ? (0...count).to_a : (0..(count - size)).to_a
          starts.each do |start|
            group = (0...size).map { |j| walls[(start + j) % count] }
            candidates << { size: size, walls: group, total: group.sum { |wall| wall[:length] }, shortest: group.map { |wall| wall[:length] }.min }
          end
        end
      end
      order = { 'u' => [3, 2, 1], 'l' => [2, 1], 'straight' => [1] }.fetch(fit, [3, 2, 1])
      best = nil
      order.each do |size|
        pool = candidates.select { |c| c[:size] == size && c[:shortest] >= MIN_WALL }
        next if pool.empty?

        best = pool.max_by { |c| c[:total] }
        break
      end
      best ||= candidates.select { |c| c[:size] == 1 }.max_by { |c| c[:total] }
      return [] unless best

      group = best[:walls]
      [{ layout: LAYOUTS[group.length - 1], origin: group.first[:from], dir: group.first[:dir], lengths: group.map { |wall| wall[:length].round(1) } }]
    end

    # Everything from the segments: { pieces: [...], notes: [...] }. `fit`: one of FITS other than 'all': only the layout that fits the floor plan best.
    def self.layout(segments, eye: nil, flip: false, fit: nil)
      pieces = []
      notes = []
      all_runs = []
      chains(segments).each do |chain|
        if chain[:points].length < 2
          notes << 'A selected edge is too short to be a wall.'
          next
        end
        chain = oriented(chain, eye, flip)
        runs(walls(chain[:points], chain[:closed]), chain[:closed]).each { |run| fit && fit != 'all' ? all_runs << run : pieces.concat(pieces(run)) }
      end
      pieces = fit_pieces(all_runs, fit) if fit && fit != 'all'
      notes << 'Some walls are too short to be built.' if pieces.empty? && !segments.empty?
      { pieces: pieces, notes: notes }
    end

    # ---- SketchUp ----------------------------------------------------------------

    def self.perform(raw)
      design(raw)
    end

    # The selected edges (or the edges round a selected face) as segments in mm, with a note for what cannot be a wall.
    def self.selected_segments(model)
      notes = []
      edges = model.selection.grep(Sketchup::Edge)
      edges = model.selection.grep(Sketchup::Face).flat_map { |face| face.outer_loop.edges }.uniq if edges.empty?
      segments = edges.filter_map do |edge|
        a = edge.start.position
        b = edge.end.position
        if (a.z - b.z).to_mm.abs > 1.0
          notes << 'An edge that is not level was left out.'
          next
        end
        [[a.x.to_mm, a.y.to_mm], [b.x.to_mm, b.y.to_mm]]
      end
      [segments, notes]
    end

    def self.eye_of(model)
      eye = model.active_view.camera.eye
      [eye.x.to_mm, eye.y.to_mm]
    rescue StandardError
      nil
    end

    def self.stored_pieces(model)
      JSON.parse(model.get_attribute(DICTIONARY, KEY_PATH, '[]')).map { |piece| piece.transform_keys(&:to_sym) }
    rescue JSON::ParserError
      []
    end

    def self.design(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      panel = raw['cabinet'].is_a?(Hash) ? raw['cabinet'] : {}
      panel = panel.merge('dishwasher_handle' => KitchenPlanner.normalise(raw['kitchen'])['dishwasher_handle'])
      catalog_id = panel['catalog_id'].to_s
      return Response.fail('Choose a model (catalog) first: the kitchen is built from its units.') if catalog_id.empty? || CatalogManager.catalog(catalog_id).nil?

      segments, notes = selected_segments(model)
      replace = raw['replace'] == true
      if replace && segments.empty?
        pieces = stored_pieces(model)
      else
        return Response.fail('Select the path first: the edges that are the walls (the backs of the units stand against them), or the face of the room (the floor plan).') if segments.empty?

        laid = layout(segments, eye: eye_of(model), flip: raw['flip'] == true, fit: FITS.include?(raw['fit'].to_s) ? raw['fit'] : nil)
        pieces = laid[:pieces]
        notes += laid[:notes]
      end
      return Response.fail("No wall of the path is long enough for a kitchen. #{notes.uniq.join(' ')}".strip) if pieces.empty?

      answers = (raw['kitchen'].is_a?(Hash) ? raw['kitchen'].transform_keys(&:to_s) : {}).merge('mirror' => false, 'island' => false, 'windows' => [])
      plans = pieces.map do |piece|
        lengths = piece[:lengths]
        [piece, KitchenPlanner.plan(answers.merge('layout' => piece[:layout], 'wall_a' => lengths[0], 'wall_b' => lengths[1] || lengths[0], 'wall_c' => lengths[2] || lengths[0]))]
      end
      built_plans = plans.reject { |_, plan| plan.error }
      plans.each { |piece, plan| notes << "A run of #{piece[:lengths].map { |n| format('%g', n) }.join(' + ')} mm was left out: #{plan.error}" if plan.error }
      return Response.fail(notes.uniq.join(' ')) if built_plans.empty?

      missing = built_plans.flat_map { |_, plan| plan.base + plan.wall }.map { |item| [item.category, item.type] }.uniq
                           .reject { |category, type| CatalogManager.cabinet(catalog_id, category, type) }
      return Response.fail("This model has no #{missing.map { |category, type| "#{category} unit \"#{type}\"" }.join(', ')}. Choose a kitchen model that has the standard units.") unless missing.empty?

      build(model, raw, panel, catalog_id, built_plans, pieces, notes, replace)
    end

    def self.build(model, raw, panel, catalog_id, built_plans, pieces, notes, replace)
      model.selection.clear
      parts = { toe_kicks: 0, end_panels: 0, hoods: 0, dimensions: 0, notes: [] }
      all = []
      kitchen = KitchenManager
      begin
        kitchen.send(:run_operation, model, 'Design Kitchen on Path') do
          kitchen.send(:erase_previous, model) if replace
          before = kitchen.send(:entity_ids, model)
          built_plans.each do |piece, plan|
            built = { base: [], wall: [], island: [] }
            plan.base.each_with_index do |item, position|
              gap = nil
              if position.positive? && item.gap_before.to_f.positive?
                gap = built[:base].last.transformation.yaxis
                gap.length = item.gap_before.mm
              end
              built[:base] << kitchen.send(:build_unit, model, panel, catalog_id, item, position.zero? ? frame_of(piece) : nil, gap)
            end
            kitchen.send(:build_wall, model, panel, catalog_id, plan, built) unless plan.wall.empty?
            all << built
            kitchen.send(:add_parts, model, plan, built, raw, parts)
          end
          kitchen.send(:remember, model, before, nil)
          model.set_attribute(DICTIONARY, KEY_PATH, JSON.generate(pieces.map { |piece| piece.transform_keys(&:to_s) }))
        end
      rescue StandardError => e
        return Response.fail("The kitchen could not be built: #{e.message}#{kitchen.send(:where, e)}")
      end

      SelectionManager.push_selection(model)
      described = built_plans.map { |_, plan| KitchenPlanner.describe(plan) }
      message = "Kitchen designed #{raw['fit'] ? 'from the floor plan' : 'on the path'}, #{built_plans.length} run#{'s' unless built_plans.length == 1}: #{described.join('; ')}."
      message += " Toe kicks: #{parts[:toe_kicks]}." if raw['toe_kick'].is_a?(Hash)
      message += " Side panels: #{parts[:end_panels]}." if raw['end_panel'].is_a?(Hash)
      notes += parts[:notes]
      message += " #{notes.uniq.join(' ')}" unless notes.empty?
      before = kitchen.send(:worktop_ids, model)
      message += kitchen.send(:worktop_message, raw['worktop'])
      kitchen.send(:remember_worktop, model, before)
      Response.ok(message, { 'cabinets' => all.sum { |built| built.values.sum(&:length) } })
    end
    private_class_method :build

    # Where a piece's first unit goes: at the start of its first wall, its back against the wall, its row running along it with the room on the right.
    def self.frame_of(piece)
      dir = Geom::Vector3d.new(piece[:dir][0], piece[:dir][1], 0)
      out = Geom::Vector3d.new(dir.y, -dir.x, 0)
      Geom::Transformation.axes(Geom::Point3d.new(piece[:origin][0].mm, piece[:origin][1].mm, 0), out, dir, Geom::Vector3d.new(0, 0, 1))
    end
    private_class_method :frame_of
  end
end
