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
      'worktop_thickness' => 38.0,
      'worktop_front' => 20.0,
      'worktop_end' => 0.0,
      'worktop_piece' => 0.0,        # 0 = no maximum length
      'worktop_cuts' => '',          # distances (mm) from the start of a run to cut at, e.g. "1500,3000"
      'backsplash_height' => 100.0,  # 0 = no back splash
      'backsplash_thickness' => 20.0,
      'material' => 'White'
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
    def self.runs(items)
      corners, lines = items.partition { |item| item[:corner] }
      found = corners.map { |item| { items: [item], along: 0.0, length: item[:width], depth: item[:width], top: item[:top], corner: true } }

      lines.group_by { |item| line_key(item) }.each_value do |group|
        chain(group.sort_by { |item| along(item) }).each { |run| found << run }
      end
      found
    end

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
        top: items.first[:top], corner: false }
    end
    private_class_method :finish

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
    def self.slab(run, params, from: 0.0, to: nil)
      front = params['worktop_front'].to_f
      ends = params['worktop_end'].to_f
      thickness = params['worktop_thickness'].to_f
      return corner_slab(run, front, thickness) if run[:corner]

      total = run[:length] + (2 * ends)
      to ||= total
      { extent: [run[:depth] + front, to - from, thickness], offset: [0.0, -ends + from, 0.0], points: nil }
    end

    # The corner's outline: back wall and side wall edges square, the front-right corner
    # cut along the diagonal that the door runs along, pushed out by the front overhang.
    def self.corner_slab(run, front, thickness)
      width = run[:length]
      returned = run[:items].first[:return_depth] || width
      cut = [returned + (front * SQRT2), width].min
      points = [[0.0, 0.0], [0.0, width], [cut, width], [width, cut], [width, 0.0]]
      { extent: [width, width, thickness], offset: [0.0, 0.0, 0.0], points: points }
    end
    private_class_method :corner_slab

    # The back splash pieces that go with a slab: [{ extent:, offset: }] in the slab's
    # own frame, standing on its top. A straight slab has one along its back edge; a
    # corner has one along each of the two walls.
    def self.splash(run, slab, params)
      height = params['backsplash_height'].to_f
      thick = params['backsplash_thickness'].to_f
      return [] unless height.positive? && thick.positive?

      top = slab[:extent][2]
      if run[:corner]
        width = slab[:extent][0]
        [{ extent: [thick, width, height], offset: [0.0, 0.0, top] },
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
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # Puts a worktop on every run of base units, replacing any worktop already there
    # (so Apply is also how a change of thickness, overhang, cuts or back splash is
    # applied). With `only_if_exists` it does nothing until a worktop has been applied
    # once: that is how live edits behave.
    def self.apply(raw, only_if_exists: nil)
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
      return Response.fail(errors.first['message'], errors) unless errors.empty?

      runs = Worktop.runs(items_of(model))
      return Response.fail('There are no base units to put a worktop on. Insert a base unit first.') if runs.empty?

      count = SelectionManager.suspend do
        with_operation(model, 'Apply Worktop') do
          existing.each { |item| PartGenerator.remove(model, item) }
          runs.sum { |run| build(model, run, params) }
        end
      end
      SelectionManager.push_selection(model)
      Response.ok("#{count} worktop piece#{'s' unless count == 1} #{existing.empty? ? 'applied' : 'updated'}: #{format('%g', params['worktop_thickness'])} mm thick" \
                  "#{", back splash #{format('%g', params['backsplash_height'])} mm" if params['backsplash_height'].positive?}.")
    end

    def self.remove
      model = Sketchup.active_model
      existing = pieces_in(model)
      return Response.ok('There is no worktop to remove.') if existing.empty?

      SelectionManager.suspend do
        with_operation(model, 'Remove Worktop') { existing.each { |item| PartGenerator.remove(model, item) } }
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
      stored = existing.map { |item| AttributeManager.read(item) }.find { |s| s['part_kind'] == 'worktop' } || {}
      params = Worktop::DEFAULTS.merge(stored.slice(*keys))
      runs = Worktop.runs(items_of(model))
      existing.each { |item| PartGenerator.remove(model, item) }
      runs.each { |run| build(model, run, params) }
    end

    # Every slab and back splash piece in the model.
    def self.pieces_in(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |item| KINDS.include?(AttributeManager.part_kind(item)) }
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
        corner = !filler && category == 'corner'
        { x: origin.x.to_mm, y: origin.y.to_mm, hx: heading.x, hy: heading.y, width: stored['width'].to_f,
          depth: stored['envelope_depth'].to_f, top: origin.z.to_mm + item.get_attribute(dictionary, 'top_z').to_f,
          corner: corner, return_depth: stored['depth'].to_f, ref: item }
      end
    end

    # One run: its slab(s) and back splash(es), each a part of its own so it can be
    # selected, moved or deleted, all on the Worktop tag. Returns how many slabs.
    def self.build(model, run, params)
      first = run[:items].first[:ref]
      total = run[:corner] ? 0.0 : run[:length] + (2 * params['worktop_end'].to_f)
      spans = run[:corner] ? [[0.0, nil]] : Worktop.pieces(total, params)

      spans.each do |from, to|
        slab = Worktop.slab(run, params, from: from, to: to)
        placed = first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, slab[:offset][1].mm, 0))
        lift = run[:top].mm - placed.origin.z
        placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * placed

        make_part(model, 'worktop', slab[:extent], slab[:points], placed, params)
        Worktop.splash(run, slab, params).each do |piece|
          up = placed * Geom::Transformation.translation(Geom::Vector3d.new(piece[:offset][0].mm, piece[:offset][1].mm, piece[:offset][2].mm))
          make_part(model, 'backsplash', piece[:extent], nil, up, params)
        end
      end
      spans.length
    end

    def self.make_part(model, kind, extent, points, transformation, params)
      stored = params.dup
      stored['part_kind'] = kind
      stored['part_id'] = AttributeManager.next_part_id(model)
      stored['part_name'] = "#{kind == 'worktop' ? 'Worktop' : 'Back Splash'} #{stored['part_id'].to_s.split('_').last.to_i}"
      stored['width'] = extent[1]
      stored['depth'] = extent[0]
      layout = PartLayout.worktop(extent, points, kind == 'worktop' ? 'Worktop' : 'Back Splash')
      root = PartGenerator.build(model, model.entities, stored, transformation, layout)
      TagManager.assign(model, root, TagManager::WORKTOP)
      root
    end
    private_class_method :make_part

    def self.with_operation(model, name)
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