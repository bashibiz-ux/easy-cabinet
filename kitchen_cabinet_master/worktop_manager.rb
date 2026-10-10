# frozen_string_literal: true

module KitchenCabinetMaster
  # The worktop: slabs laid over the base units (and the fillers between them).
  #
  # Units that stand in one line, at the same height, with next to no gap between
  # them get ONE run, so a row of five base units has a single worktop. A turn at a
  # corner, a gap, or a tall unit starts another run. A corner unit gets its own slab
  # in the shape of its footprint (the front is cut across the diagonal, like its
  # door). A run is one slab unless it is cut into pieces (a piece length, or the
  # distances to cut at); every piece is a part of its own. A back splash of an
  # adjustable height stands on the back edge of every piece.
  #
  #   plan view (front is up)
  #        ┌─────────────┬──────────────┐   ◄ front overhang beyond the doors
  #        │   piece 1   │   piece 2    │      (a cut between pieces)
  #        └─────────────┴──────────────┘
  #          ▲ the base units under it
  module Worktop
    GAP_MM = 150.0       # units this close are one run
    LINE_MM = 5.0        # how closely the back lines must agree
    LEVEL_MM = 1.0       # and the tops
    SQRT2 = Math.sqrt(2.0)

    DEFAULTS = {
      'worktop_thickness' => 20.0,
      'worktop_front' => 20.0,
      'worktop_end' => 0.0,
      'worktop_round' => 5.0,        # radius of the rounded front edge (0 = square)
      'worktop_piece' => 0.0,        # 0 = no maximum length
      'worktop_cuts' => '',          # distances (mm) from the start of a run to cut at, e.g. "1500,3000"
      'backsplash_height' => 100.0,  # 0 = no back splash
      'backsplash_thickness' => 20.0,
      'material' => 'White',
      'backsplash_material' => ''     # ''= the material of the worktop
    }.freeze

    # items: Hashes in world millimetres, one per base unit / filler:
    #   x, y        where its origin is (rear-left corner)
    #   hx, hy      unit vector of its own Y axis (the way its width runs)
    #   width       its width
    #   depth       from its origin to the front of its doors
    #   top         world height of its top
    #   corner      true for a corner unit;  return_depth  its Depth setting (a corner)
    #   ref         whatever the caller wants back (the entity)
    # Returns an Array of runs: { items:, along:, length:, depth:, top:, corner: }
    # where `along` is where the first item starts, measured along the run.
    def self.runs(items, panels = [], merge: false)
      corners, lines = items.partition { |item| item[:corner] }
      found = corners.map { |item| { items: [item], along: 0.0, length: item[:width], depth: item[:width], top: item[:top], corner: true } }

      lines.group_by { |item| line_key(item) }.each_value do |group|
        chain(group.sort_by { |item| along(item) }).each { |run| found << run }
      end
      found.each { |run| attach_panels(run, panels) unless run[:corner] } # the slab reaches over the side panels at its ends
      # A corner's worktop is as deep as the cabinets beside it (the nearest straight unit).
      found.each do |run|
        next unless run[:corner]

        item = run[:items].first
        nearest = lines.min_by { |other| Math.hypot(other[:x] - item[:x], other[:y] - item[:y]) }
        run[:neighbor_depth] = nearest[:depth] if nearest
        # An L corner's two arms each take the depth of the run they join: the one the unit's own way along (leg 1), the one across (leg 2).
        near = lambda do |same|
          list = lines.select { |other| (((other[:hx] * item[:hx]) + (other[:hy] * item[:hy])).abs > 0.9) == same }
          list.min_by { |other| Math.hypot(other[:x] - item[:x], other[:y] - item[:y]) }
        end
        run[:neighbor_depth_leg1] = (near.call(true) || nearest)&.[](:depth)
        run[:neighbor_depth_leg2] = (near.call(false) || nearest)&.[](:depth)
      end
      merge ? join_corners(found) : found
    end

    # A corner worktop and the runs on either side of it become ONE slab, wall to wall (no seams): the corner's arms are carried on along the
    # runs that touch it. The runs are measured in the corner's own frame (x: depth, y: along its first leg). Only when the worktop is not cut
    # into pieces. `merged` keeps what the slab needs: the arms (each: how far it reaches, how deep it is).
    def self.join_corners(runs)
      joined = runs.dup
      runs.select { |run| run[:corner] }.each do |corner|
        item = corner[:items].first
        la = item[:width].to_f
        lb = item[:corner_style] == 'l_shape' && item[:leg2_length].to_f.positive? ? item[:leg2_length].to_f : la
        arms = {}
        (runs - [corner]).each do |other|
          next if other[:corner] || other[:back] || (other[:top].to_f - corner[:top].to_f).abs > LEVEL_MM + 0.5

          heading = other[:items].first
          dot = (heading[:hx] * item[:hx]) + (heading[:hy] * item[:hy])
          x0, x1, y0, y1 = local_bounds(other, item)
          if dot.abs > 0.98 && x0.abs < 6.0 && (y0 - la).abs < GAP_MM + 6.0
            arms[:one] = { run: other, reach: y1, forward: dot.positive?, depth: other[:depth], gap: (y0 - la).abs } if arms[:one].nil? || (y0 - la).abs < arms[:one][:gap]
          elsif dot.abs < 0.02 && y0.abs < 6.0 && (x0 - lb).abs < GAP_MM + 6.0
            toward = (heading[:hx] * item[:hy]) + (heading[:hy] * -item[:hx])
            arms[:two] = { run: other, reach: x1, forward: toward.positive?, depth: other[:depth], gap: (x0 - lb).abs } if arms[:two].nil? || (x0 - lb).abs < arms[:two][:gap]
          end
        end
        next if arms.empty?

        corner[:merged] = arms
        corner[:items] = corner[:items] + arms.values.flat_map { |arm| arm[:run][:items] }
        joined -= arms.values.map { |arm| arm[:run] }
      end
      joined
    end
    private_class_method :join_corners

    # [x0, x1, y0, y1] of a run's units in the corner's frame.
    def self.local_bounds(run, corner)
      xs = []
      ys = []
      run[:items].each do |unit|
        [0.0, unit[:depth].to_f].each do |d|
          [0.0, unit[:width].to_f].each do |w|
            px = unit[:x] + (unit[:hy] * d) + (unit[:hx] * w) - corner[:x]
            py = unit[:y] + (-unit[:hx] * d) + (unit[:hy] * w) - corner[:y]
            xs << ((px * corner[:hy]) + (py * -corner[:hx]))
            ys << ((px * corner[:hx]) + (py * corner[:hy]))
          end
        end
      end
      [xs.min, xs.max, ys.min, ys.max]
    end
    private_class_method :local_bounds


    # A side panel standing at an end of a run (touching its first or its last unit, as high as the units, along the same line) is something the
    # worktop must cover: `lead` / `trail` are the thickness of the panel at the start / the end of the run, so the slab reaches its far face.
    # panels: [{ x:, y:, hx:, hy:, thickness:, top: }] (x, y where the panel's own origin is: its low end along its length of thickness).
    def self.attach_panels(run, panels)
      first = run[:items].first
      stop = run[:along] + run[:length]
      panels.each do |panel|
        next unless ((panel[:hx] * first[:hx]) + (panel[:hy] * first[:hy])) > 0.98 # (the same direction)
        next unless (lateral_mm(panel) - lateral_mm(first)).abs < 5.0
        next unless (panel[:top].to_f - run[:top].to_f).abs < 5.0 # (only a panel that ends at the worktop: a taller one stands beside it, a lower one is under it)

        low = along(panel)
        high = low + panel[:thickness].to_f
        run[:lead] = [run[:lead].to_f, panel[:thickness].to_f].max if (high - run[:along]).abs < 3.0
        run[:trail] = [run[:trail].to_f, panel[:thickness].to_f].max if (low - stop).abs < 3.0
      end
    end
    private_class_method :attach_panels

    def self.lateral_mm(item) = (item[:x] * -item[:hy]) + (item[:y] * item[:hx])
    private_class_method :lateral_mm

    def self.line_key(item)
      angle = (Math.atan2(item[:hy], item[:hx]) * 180.0 / Math::PI).round
      lateral = ((item[:x] * -item[:hy]) + (item[:y] * item[:hx])) / LINE_MM
      [angle, lateral.round, (item[:top] / LEVEL_MM).round]
    end
    private_class_method :line_key

    def self.along(item) = (item[:x] * item[:hx]) + (item[:y] * item[:hy])
    private_class_method :along

    def self.chain(sorted)
      runs = []
      current = []
      sorted.each do |item|
        if current.any? && along(item) - (along(current.last) + current.last[:width]) > GAP_MM
          runs << finish(current)
          current = []
        end
        current << item
      end
      runs << finish(current) if current.any?
      runs
    end
    private_class_method :chain

    def self.finish(items)
      start = along(items.first)
      stop = items.map { |item| along(item) + item[:width] }.max
      { items: items, along: start, length: stop - start, depth: items.map { |item| item[:depth] }.max,
        top: items.first[:top], corner: false, back: items.first[:island_back], sided: items.first[:island_sided] }
    end
    private_class_method :finish

    # Whether the worktop goes on round a corner as one slab: when it is not cut into pieces.
    def self.continuous?(params)
      (parse_cuts(params['worktop_cuts']) || []).empty? && !params['worktop_piece'].to_f.positive?
    end

    # The distances typed in the Cut At field ("1500, 3000"), as a sorted Array of mm.
    # Returns nil when something in it is not a positive number.
    def self.parse_cuts(text)
      tokens = text.to_s.split(/[\s,;]+/).reject(&:empty?)
      numbers = tokens.map { |token| Float(token.tr(',', '.'), exception: false) }
      return nil if numbers.any? { |n| n.nil? || !n.positive? }

      numbers.sort.uniq
    end

    # Splits a run of `total` mm into pieces: at the listed cut distances, else every
    # `piece` mm, else not at all. Returns [[from, to], ...] along the run.
    def self.pieces(total, params)
      cuts = parse_cuts(params['worktop_cuts']) || []
      cuts = cuts.select { |c| c > 1.0 && c < total - 1.0 }
      if cuts.empty?
        piece = params['worktop_piece'].to_f
        cuts = piece.positive? && piece < total - 1.0 ? (1..((total / piece).ceil - 1)).map { |i| i * piece } : []
      end
      edges = [0.0] + cuts + [total]
      edges.each_cons(2).to_a
    end

    # What one slab of a run looks like, in the frame of the run's first item (X back to
    # front, Y along the run, Z up from the top of the carcass):
    #   { extent: [depth, length, thickness], offset: [0, y, 0], points: [...] or nil }
    # A straight run reaches the front of the doors plus the front overhang; `from` and
    # `to` (mm along the slab, 0 = its start) pick one piece of it. A corner unit's
    # slab follows its footprint, the front cut across the diagonal.
    # How far the slab reaches past the units at each end: the End overhang setting, and at least the thickness of the knee panels under a
    # seating overhang, so that the slab covers their tops.
    def self.ends(run, params)
      set = params['worktop_end'].to_f
      return set if run[:corner] || run[:back].to_f <= 1.0

      [set, params['worktop_thickness'].to_f].max
    end

# [start, end]: how far the slab reaches past the first and the last unit: `ends`, or as far as the face of a side panel standing there.
    def self.extension(run, params)
      base = ends(run, params)
      [[base, run[:lead].to_f].max, [base, run[:trail].to_f].max]
    end

    def self.slab(run, params, from: 0.0, to: nil)
      front = params['worktop_front'].to_f
      lead, trail = extension(run, params)
      thickness = params['worktop_thickness'].to_f
      return merged_slab(run, params, front, thickness) if run[:merged]
      return corner_slab(run, front, thickness, run[:neighbor_depth], run[:neighbor_depth_leg1], run[:neighbor_depth_leg2]) if run[:corner]

      total = run[:length] + lead + trail
      to ||= total
      back = run[:back].to_f # an island's seating overhang: the slab reaches this much beyond the back of the units
      { extent: [run[:depth] + front + back, to - from, thickness], offset: [-back, -lead + from, 0.0], points: nil }
    end

    # A corner and the runs beside it as one slab (see join_corners): the corner's outline carried on along both walls, as deep as the runs it
    # joins, reaching as far as their slabs would (over their end panels too). In the corner's frame (X back to front, Y along its first leg).
    def self.merged_slab(run, params, front, thickness)
      item = run[:items].first
      arms = run[:merged]
      la = item[:width].to_f
      l_shape = item[:corner_style] == 'l_shape'
      lb = l_shape && item[:leg2_length].to_f.positive? ? item[:leg2_length].to_f : la
      reach = lambda do |arm, own|
        next own unless arm

        ext = extension(arm[:run], params)
        arm[:reach] + (arm[:forward] ? ext[1] : ext[0])
      end
      y_end = reach.call(arms[:one], la)
      x_end = reach.call(arms[:two], lb)
      a = (arms[:one] ? arms[:one][:depth] : (run[:neighbor_depth_leg1] || run[:neighbor_depth] || item[:return_depth] || la)) + front
      b = (arms[:two] ? arms[:two][:depth] : (run[:neighbor_depth_leg2] || run[:neighbor_depth] || item[:leg2_depth].to_f.nonzero? || item[:return_depth] || la)) + front
      extent = [x_end, y_end, thickness]
      if l_shape
        a = [a, x_end].min
        b = [b, y_end].min
        return { extent: extent, offset: [0.0, 0.0, 0.0], points: nil } if a >= x_end - 0.5 || b >= y_end - 0.5

        return { extent: extent, offset: [0.0, 0.0, 0.0], points: [[0.0, 0.0], [0.0, y_end], [a, y_end], [a, b], [x_end, b], [x_end, 0.0]], round_edge: [2, 3] }
      end

      # The diagonal corner: a square la x la, its front cut across between the two arms.
      a = [a, la].min
      b = [b, la].min
      points = [[0.0, 0.0], [0.0, y_end]]
      points << [a, y_end] if y_end > la + 0.5
      points += [[a, la], [la, b]]
      points << [x_end, b] if x_end > la + 0.5
      points << [x_end, 0.0]
      first_front = y_end > la + 0.5 ? 2 : 1 # (the front edges: from the end of the first arm to the end of the second)
      { extent: extent, offset: [0.0, 0.0, 0.0], points: points, round_edge: (first_front...(points.length - 1)).to_a }
    end
    private_class_method :merged_slab

    # The corner's outline: back wall and side wall edges square, the front-right corner
    # cut along the diagonal that the door runs along, pushed out by the front overhang.
    def self.corner_slab(run, front, thickness, neighbor_depth = nil, leg1_depth = nil, leg2_depth = nil)
      width = run[:length]
      returned = run[:items].first[:return_depth] || width
      return l_slab(run[:items].first, front, thickness, neighbor_depth, leg1_depth, leg2_depth) if run[:items].first[:corner_style] == 'l_shape'
# Each straight edge is as deep as the run it joins (so the worktop goes on without a step), the front cut across between them.
cut = [returned + (front * SQRT2), width].min
a = leg1_depth ? [leg1_depth + front, width].min : cut
b = leg2_depth ? [leg2_depth + front, width].min : cut
points = [[0.0, 0.0], [0.0, width], [a, width], [width, b], [width, 0.0]]
      { extent: [width, width, thickness], offset: [0.0, 0.0, 0.0], points: points, round_edge: 2 } # the diagonal runs from point 2 to 3
    end
    private_class_method :corner_slab

    # An L-shaped corner unit has an L-shaped worktop: two arms as deep as the unit (plus the
    # front overhang) along the walls.
    def self.l_slab(item, front, thickness, neighbor_depth = nil, leg1_depth = nil, leg2_depth = nil)
      la = item[:width]                                               # leg 1: along Y (its length) ...
      da = item[:return_depth] || la                                  # ... and how deep it is
      lb = item[:leg2_length].to_f.positive? ? item[:leg2_length] : la # leg 2: along X
      db = item[:leg2_depth].to_f.positive? ? item[:leg2_depth] : da
      # As deep as the cabinets next to it (their doors included), with the same front overhang, and its two fronts rounded.
      a = [(leg1_depth || neighbor_depth || da) + front, lb].min
      b = [(leg2_depth || neighbor_depth || db) + front, la].min
      # Arms as deep as the unit is long leave no L at all (two corners would be the same point): a plain square slab.
      return { extent: [lb, la, thickness], offset: [0.0, 0.0, 0.0], points: nil } if a >= lb - 0.5 || b >= la - 0.5

      points = [[0.0, 0.0], [0.0, la], [a, la], [a, b], [lb, b], [lb, 0.0]]
      { extent: [lb, la, thickness], offset: [0.0, 0.0, 0.0], points: points, round_edge: [2, 3] } # the fronts: points 2 to 3 and 3 to 4
    end
    private_class_method :l_slab

    # The knee panels: an upright board of the worktop's thickness at each end of a slab with a seating overhang, in the slab's own frame. Each
    # stands on the floor against the side of the units (the slab reaches past them, over its top) and covers the whole depth of the slab, the
    # front to the edge of the overhang; when the island has side panels of its own on the units only the overhang is left for them.
    # `first` / `last` pick the start and / or the end of the slab (a slab cut into pieces).
    # [{ extent: [depth, thickness, height], offset: [x, y, z] }]
    def self.knee_panels(run, slab, thickness:, ends:, last_ends: nil, first: true, last: true)
      back = run[:back].to_f
      return [] if run[:corner] || back <= 1.0

      depth = run[:sided] ? back : slab[:extent][0]
      height = run[:top].to_f
      ys = []
      ys << ends - thickness if first
      ys << slab[:extent][1] - (last_ends || ends) if last
      ys.map { |y| { extent: [depth, thickness, height], offset: [0.0, y, -height] } }
    end

    # The back splash pieces that go with a slab: [{ extent:, offset: }] in the slab's
    # own frame, standing on its top. A straight slab has one along its back edge; a
    # corner has one along each of the two walls.
    def self.splash(run, slab, params)
      height = params['backsplash_height'].to_f
      thick = params['backsplash_thickness'].to_f
      return [] unless height.positive? && thick.positive?
      return [] if run[:back] # (an island has no wall behind it)

      top = slab[:extent][2]
      if run[:corner]
        width = slab[:extent][0]
        length = slab[:extent][1] # (an L corner can be longer one way: each splash runs the whole of its wall, to meet the one beside it)
        [{ extent: [thick, length, height], offset: [0.0, 0.0, top] },
         { extent: [width - thick, thick, height], offset: [thick, 0.0, top] }]
      else
        [{ extent: [thick, slab[:extent][1], height], offset: [0.0, 0.0, top] }]
      end
    end
  end

  # Applies, rebuilds and removes the worktops (the Worktop section of the panel).
  module WorktopManager
    KINDS = %w[worktop backsplash].freeze

    def self.perform(action, raw)
      case action
      when 'apply_worktop' then apply(raw)
      when 'remove_worktop' then remove
      when 'apply_wall_bottom' then WallBottomManager.perform(action, raw)
      when 'remove_wall_bottom' then WallBottomManager.perform(action, raw)
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # Puts a worktop on every run of base units, replacing any worktop already there
    # (so Apply is also how a change of thickness, overhang, cuts or back splash is
    # applied). With `only_if_exists` it does nothing until a worktop has been applied
    # once: that is how live edits behave.
    def self.apply(raw, only_if_exists: nil)
      @problems = []
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      only_if_exists = raw['only_if_exists'] if only_if_exists.nil?
      only_if_exists = [true, 'true', 1, '1'].include?(only_if_exists)
      model = Sketchup.active_model
      existing = pieces_in(model)
      return Response.ok('No worktop applied yet. Press Apply Worktop.') if only_if_exists && existing.empty?

      result = ValidationManager.validate_worktop(raw)
      errors = result.errors.dup
      params = Worktop::DEFAULTS.merge(result.params)
      unless errors.any? || MaterialManager.available?(model, params['material'])
        errors << { 'field' => 'material', 'message' => "The material \"#{params['material']}\" was not found in the model." }
      end
      splash = params['backsplash_material'].to_s
      unless errors.any? || splash.empty? || MaterialManager.available?(model, splash)
        errors << { 'field' => 'backsplash_material', 'message' => "The material \"#{splash}\" was not found in the model." }
      end
      return Response.fail(errors.first['message'], errors) unless errors.empty?

      runs = Worktop.runs(items_of(model), panels_of(model), merge: Worktop.continuous?(params))
      return Response.fail('There are no base units to put a worktop on. Insert a base unit first.') if runs.empty?

      # With a worktop piece selected the settings are for the run it belongs to; with none selected they are for every run.
      keys = selected_run_keys(model) # (the pieces selected, one or several; none selected: every run)
      unless keys.empty?
        runs = runs.select { |run| keys.include?(run_key(run)) }
        existing = existing.select { |item| keys.include?(AttributeManager.read(item)['run_key'].to_s) }
        return Response.fail('The selected worktop does not sit on base units any more.') if runs.empty?
      end

      count = SelectionManager.suspend do
        with_operation(model, 'Apply Worktop') do
          existing.each { |item| PartGenerator.remove(model, item) }
          built = runs.sum { |run| build(model, run, params) }
          CabinetGenerator.sync_all_names(model) # the names sit on top of the worktop
          CabinetGenerator.sync_fixtures(model)  # and so do the sinks and hobs
          built
        end
      end
      SelectionManager.push_selection(model)
      Response.ok("#{count} worktop piece#{'s' unless count == 1} #{existing.empty? ? 'applied' : 'updated'}: #{format('%g', params['worktop_thickness'])} mm thick" \
                  "#{", back splash #{format('%g', params['backsplash_height'])} mm" if params['backsplash_height'].positive?}." \
                  "#{" #{problems.uniq.join(' ')}" unless problems.empty?}")
    end

    # What went wrong with the extras of the worktop being made (see build).
    def self.problems = (@problems ||= [])

    def self.remove
      model = Sketchup.active_model
      existing = pieces_in(model)
      return Response.ok('There is no worktop to remove.') if existing.empty?

      SelectionManager.suspend do
        with_operation(model, 'Remove Worktop') do
          existing.each { |item| PartGenerator.remove(model, item) }
          CabinetGenerator.sync_all_names(model)
          CabinetGenerator.sync_fixtures(model)
        end
      end
      SelectionManager.push_selection(model)
      Response.ok('The worktop and its back splash were removed.')
    end

    # Rebuilds the worktops after something under them changed height (the toe kick
    # was raised, say), using the settings they were built with. Inside an operation.
    def self.refresh(model)
      existing = pieces_in(model)
      return if existing.empty?

      keys = Worktop::DEFAULTS.keys
      records = existing.map { |item| AttributeManager.read(item) }
      fallback = records.find { |s| s['part_kind'] == 'worktop' && !s['part_label'] } || {}
      # Each run is rebuilt with the settings its own pieces were built with.
      own = records.select { |s| s['part_kind'] == 'worktop' && !s['part_label'] && !s['run_key'].to_s.empty? }.to_h { |s| [s['run_key'].to_s, s] }
      runs = Worktop.runs(items_of(model), panels_of(model), merge: Worktop.continuous?(Worktop::DEFAULTS.merge(fallback.slice(*keys))))
      existing.each { |item| PartGenerator.remove(model, item) }
      runs.each { |run| build(model, run, Worktop::DEFAULTS.merge((own[run_key(run)] || fallback).slice(*keys))) }
      CabinetGenerator.sync_fixtures(model)
    end

    # What tells a run of units apart: its first unit. Kept on its pieces, so a piece can be rebuilt on its own.
    def self.run_key(run)
      run[:items].first[:ref].persistent_id.to_s
    end

    # The runs the selected worktop / back splash pieces belong to (none: nothing selected, or pieces from before this was kept).
    def self.selected_run_keys(model)
      pieces_in(model).select { |item| model.selection.include?(item) }.map { |item| AttributeManager.read(item)['run_key'].to_s }.reject(&:empty?).uniq
    end

    # Every slab and back splash piece in the model.
    def self.pieces_in(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |item| KINDS.include?(AttributeManager.part_kind(item)) }
    end

    # The side panels in the model, as the worktop needs them to reach over their tops (see Worktop.attach_panels).
    def self.panels_of(model)
      dictionary = AttributeManager::DICTIONARY
      model.entities.grep(Sketchup::ComponentInstance).filter_map do |part|
        next unless AttributeManager.part_kind(part) == 'end_panel'

        stored = AttributeManager.read(part)
        origin = part.transformation.origin
        heading = part.transformation.yaxis
        { x: origin.x.to_mm, y: origin.y.to_mm, hx: heading.x, hy: heading.y, thickness: stored['thickness'].to_f,
          top: origin.z.to_mm + stored['target_base_z'].to_f + stored['height'].to_f }
      end
    end

    # What carries a worktop: base and corner units and the fillers beside them.
    def self.items_of(model)
      dictionary = AttributeManager::DICTIONARY
      model.entities.grep(Sketchup::ComponentInstance).filter_map do |item|
        stored = AttributeManager.read(item)
        next unless stored

        filler = stored['part_kind'] == 'filler'
        next unless AttributeManager.cabinet?(item) || filler

        category = filler ? stored['target_category'] : stored['cabinet_category']
        next if %w[wall tall].include?(category.to_s)

        origin = item.transformation.origin
        heading = item.transformation.yaxis
        corner = !filler && CabinetLayout.corner?(stored)
        { x: origin.x.to_mm, y: origin.y.to_mm, hx: heading.x, hy: heading.y, width: stored['width'].to_f,
          depth: stored['envelope_depth'].to_f, top: origin.z.to_mm + item.get_attribute(dictionary, 'top_z').to_f,
          island_back: item.get_attribute(dictionary, 'island_seating')&.to_f, island_sided: item.get_attribute(dictionary, 'island_side_panels') == true, corner: corner, corner_style: CabinetLayout.corner_style(stored), return_depth: stored['depth'].to_f,
          leg2_length: stored['leg2_length'].to_f, leg2_depth: stored['leg2_depth'].to_f, ref: item,
          cutouts: filler ? [] : Fixtures.cutouts(stored) }
      end
    end

    # One run: its slab(s) and back splash(es), each a part of its own so it can be
    # selected, moved or deleted, all on the Worktop tag. Returns how many slabs.
    def self.build(model, run, params)
      params = params.merge('run_key' => run_key(run))
      first = run[:items].first[:ref]
      total = run[:corner] ? 0.0 : run[:length] + Worktop.extension(run, params).sum
      spans = run[:corner] ? [[0.0, nil]] : Worktop.pieces(total, params)

      spans.each do |from, to|
        slab = Worktop.slab(run, params, from: from, to: to)
        placed = first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(slab[:offset][0].mm, slab[:offset][1].mm, 0))
        lift = run[:top].mm - placed.origin.z
        placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * placed

        begin # (the knee boards are extras: if they cannot be drawn the worktop is still made, and the reply says why)
          Worktop.knee_panels(run, slab, thickness: params['worktop_thickness'].to_f, ends: Worktop.extension(run, params)[0], last_ends: Worktop.extension(run, params)[1], first: from.zero?, last: to.nil? || to >= total - 0.5).each do |panel| # (the sides of the knee space, to the floor)
            make_part(model, 'worktop', panel[:extent], nil, placed * Geom::Transformation.translation(Geom::Vector3d.new(panel[:offset][0].mm, panel[:offset][1].mm, panel[:offset][2].mm)),
                      params.merge('part_label' => 'Knee Panel', 'worktop_round' => 0.0))
          end
        rescue StandardError => e
          problems << "The knee boards under the overhang could not be drawn: #{e.message}#{Array(e.backtrace).find { |entry| entry.include?('kitchen_cabinet_master') }&.[](/\w+\.rb:\d+/)&.then { |line| " (at #{line})" }}"
        end
        make_part(model, 'worktop', slab[:extent], slab[:points], placed, params, slab[:round_edge], holes_for(run, placed, slab))
        Worktop.splash(run, slab, params).each do |piece|
          up = placed * Geom::Transformation.translation(Geom::Vector3d.new(piece[:offset][0].mm, piece[:offset][1].mm, piece[:offset][2].mm))
          make_part(model, 'backsplash', piece[:extent], nil, up, params)
        end
      end
      spans.length
    end

    # The openings this piece needs over its cabinets' sinks and hobs, as [x0, x1, y0, y1] in the piece's own frame. One
    # that does not lie wholly inside the piece (a cut between pieces runs through it) is left out.
    def self.holes_for(run, placed, slab)
      return [] if !run[:merged] && (run[:corner] || slab[:points])

      to_slab = placed.inverse
      holes = []
      run[:items].each do |item|
        item[:cutouts].to_a.each do |x0, x1, y0, y1|
          corners = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]].map do |x, y|
            point = to_slab * (item[:ref].transformation * Geom::Point3d.new(x.mm, y.mm, 0))
            [point.x.to_mm, point.y.to_mm]
          end
          xs = corners.map(&:first)
          ys = corners.map(&:last)
          next unless xs.min > 1.0 && xs.max < slab[:extent][0] - 1.0 && ys.min > 1.0 && ys.max < slab[:extent][1] - 1.0

          holes << [xs.min, xs.max, ys.min, ys.max].map { |v| (v * 100).round / 100.0 }
        end
      end
      holes
    end

    # Whether the worktop pieces / back splash pieces are shown (the Worktop and Back splash ticks in Visibility). Kept on
    # the model, so a piece built later follows it.
    def self.shown?(model, kind)
      key = kind == 'worktop' ? 'show_worktop' : 'show_backsplash'
      model.get_attribute(AttributeManager::DICTIONARY, key, true) != false
    end

    def self.set_shown(model, worktop, backsplash)
      model.set_attribute(AttributeManager::DICTIONARY, 'show_worktop', worktop ? true : false)
      model.set_attribute(AttributeManager::DICTIONARY, 'show_backsplash', backsplash ? true : false)
      pieces_in(model).each { |item| item.visible = AttributeManager.part_kind(item) == 'worktop' ? worktop : backsplash }
    end

    def self.make_part(model, kind, extent, points, transformation, params, round_edge = nil, holes = nil)
      stored = params.dup
      stored['part_kind'] = kind
      stored['material'] = params['backsplash_material'] if kind == 'backsplash' && !params['backsplash_material'].to_s.empty? # (its own material)
      stored['part_id'] = AttributeManager.next_part_id(model)
      stored['part_name'] = "#{params['part_label'] || (kind == 'worktop' ? 'Worktop' : 'Back Splash')} #{stored['part_id'].to_s.split('_').last.to_i}"
      stored['width'] = extent[1]
      stored['depth'] = extent[0]
      if params['part_label'] # (the cut list takes the board's size from here: an upright board is as high as it is long, thin the other way)
        upright = params['part_label'] == 'Knee Panel'
        stored['worktop_thickness'] = upright ? extent[1] : extent[2]
        stored['width'] = extent[2] if upright
      end
      slab = kind == 'worktop'
      round = slab ? [params['worktop_round'].to_f, extent[2]].min : 0.0 # (the knee panels have round 0)
      # What the piece is made of, kept so that it can be rebuilt (the Customize window changes its board).
      stored['board_extent'] = extent
      stored['board_points'] = points
      stored['board_round'] = round
      stored['board_round_edge'] = round_edge
      stored['board_holes'] = holes || []
      layout = PartLayout.worktop(extent, points, slab ? 'Worktop' : 'Back Splash', round, round_edge, stored, holes)
      root = PartGenerator.build(model, model.entities, stored, transformation, layout)
      TagManager.assign(model, root, TagManager::WORKTOP)
      root.visible = shown?(model, kind)
      root
    end
    private_class_method :make_part

    def self.with_operation(model, name)
      return yield if defined?(KitchenManager) && KitchenManager.building? # (inside Design Kitchen: its own one Undo step)

      model.start_operation(name, true)
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      end
    end
    private_class_method :with_operation
  end
end