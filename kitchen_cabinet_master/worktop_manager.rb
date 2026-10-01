# frozen_string_literal: true

module KitchenCabinetMaster
  # The worktop: a slab laid over the base units (and the fillers between them).
  #
  # Units that stand in one line, at the same height, with next to no gap between
  # them get ONE slab, so a row of five base units has a single worktop. A turn at a
  # corner, a gap, or a tall unit starts another. A corner unit gets its own square
  # slab. The slab reaches the front of the doors plus the front overhang, and sits
  # on top of the carcass.
  #
  #   plan view (front is up)
  #        ┌─────────────────────────┐   ◄ front overhang beyond the doors
  #        │        one slab         │
  #        └─────────────────────────┘
  #          ▲ the base units under it
  module Worktop
    GAP_MM = 150.0       # units this close are one run
    LINE_MM = 5.0        # how closely the back lines must agree
    LEVEL_MM = 1.0       # and the tops

    DEFAULTS = {
      'worktop_thickness' => 38.0,
      'worktop_front' => 20.0,
      'worktop_end' => 0.0,
      'material' => 'White'
    }.freeze

    # items: Hashes in world millimetres, one per base unit / filler:
    #   x, y        where its origin is (rear-left corner)
    #   hx, hy      unit vector of its own Y axis (the way its width runs)
    #   width       its width
    #   depth       from its origin to the front of its doors
    #   top         world height of its top
    #   corner      true for a corner unit
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

    # The size and place of one run's slab, in the frame of its first item (X back to
    # front, Y along the run, Z up from the top of the carcass). `params` are the
    # worktop settings. A corner unit's slab is exactly its square.
    def self.slab(run, params)
      front = params['worktop_front'].to_f
      ends = params['worktop_end'].to_f
      thickness = params['worktop_thickness'].to_f
      return { extent: [run[:depth], run[:length], thickness], offset: [0.0, 0.0, 0.0] } if run[:corner]

      { extent: [run[:depth] + front, run[:length] + (2 * ends), thickness], offset: [0.0, -ends, 0.0] }
    end
  end

  # Applies, rebuilds and removes the worktops (the Worktop section of the panel).
  module WorktopManager
    ACTIONS = %w[apply_worktop remove_worktop create_scene].freeze

    def self.perform(action, raw)
      case action
      when 'apply_worktop' then apply(raw)
      when 'remove_worktop' then remove
      when 'create_scene' then SceneManager.create
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # Puts a worktop on every run of base units, replacing any worktop already there
    # (so Apply is also how a change of thickness or overhang is applied). With
    # `only_if_exists` it does nothing until a worktop has been applied once: that is
    # how live edits behave.
    def self.apply(raw, only_if_exists: nil)
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      only_if_exists = raw['only_if_exists'] if only_if_exists.nil?
      only_if_exists = [true, 'true', 1, '1'].include?(only_if_exists)
      model = Sketchup.active_model
      existing = worktops(model)
      return Response.ok('No worktop applied yet. Press Apply Worktop.') if only_if_exists && existing.empty?

      result = ValidationManager.validate_worktop(raw)
      errors = result.errors.dup
      unless errors.any? || MaterialManager.available?(model, result.params['material'])
        errors << { 'field' => 'material', 'message' => "The material \"#{result.params['material']}\" was not found in the model." }
      end
      return Response.fail(errors.first['message'], errors) unless errors.empty?

      runs = Worktop.runs(items_of(model))
      return Response.fail('There are no base units to put a worktop on. Insert a base unit first.') if runs.empty?

      count = SelectionManager.suspend do
        with_operation(model, 'Apply Worktop') do
          existing.each { |item| PartGenerator.remove(model, item) }
          runs.each { |run| build(model, run, result.params) }
          runs.length
        end
      end
      SelectionManager.push_selection(model)
      Response.ok("#{count} worktop#{'s' unless count == 1} #{existing.empty? ? 'applied' : 'updated'}: #{format('%g', result.params['worktop_thickness'])} mm thick.")
    end

    def self.remove
      model = Sketchup.active_model
      existing = worktops(model)
      return Response.ok('There is no worktop to remove.') if existing.empty?

      SelectionManager.suspend do
        with_operation(model, 'Remove Worktop') { existing.each { |item| PartGenerator.remove(model, item) } }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{existing.length} worktop#{'s' unless existing.length == 1} removed.")
    end

    # Rebuilds the worktops after something under them changed height (the toe kick
    # was raised, say), using the settings they were built with. Inside an operation.
    def self.refresh(model)
      existing = worktops(model)
      return if existing.empty?

      params = AttributeManager.read(existing.first).slice(*Worktop::DEFAULTS.keys)
      runs = Worktop.runs(items_of(model))
      existing.each { |item| PartGenerator.remove(model, item) }
      runs.each { |run| build(model, run, params) }
    end

    def self.worktops(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.part_kind(item) == 'worktop' }
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
          corner: corner, ref: item }
      end
    end

    # One slab, as a part of its own (so it can be selected, moved or deleted), on the
    # Worktop tag.
    def self.build(model, run, params)
      first = run[:items].first[:ref]
      slab = Worktop.slab(run, params)
      placed = first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, slab[:offset][1].mm, 0))
      lift = (run[:top].mm - placed.origin.z)
      placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * placed

      stored = params.dup
      stored['part_kind'] = 'worktop'
      stored['part_id'] = AttributeManager.next_part_id(model)
      stored['part_name'] = "Worktop #{stored['part_id'].to_s.split('_').last.to_i}"
      stored['width'] = slab[:extent][1]
      stored['depth'] = slab[:extent][0]
      layout = PartLayout.worktop(slab[:extent])
      root = PartGenerator.build(model, model.entities, stored, placed, layout)
      TagManager.assign(model, root, TagManager::WORKTOP)
      root
    end

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

  # The 3D perspective scene (SketchUp's "scenes" / pages): a view of the whole
  # kitchen from the front-right and above, in perspective.
  module SceneManager
    NAME = 'Kitchen 3D'
    FIELD_OF_VIEW = 35.0

    # Where to stand to see a box of `size` (mm) centred on `centre` (mm): in front of
    # it (the doors face +X), to one side and above, far enough back to fit.
    # Returns [eye, target], both [x, y, z] in millimetres.
    def self.viewpoint(centre, size)
      diagonal = Math.sqrt(size.sum { |v| v * v })
      distance = [diagonal * 1.15, 2500.0].max
      direction = [0.72, -0.55, 0.42]
      length = Math.sqrt(direction.sum { |v| v * v })
      eye = centre.zip(direction).map { |c, d| c + (d / length * distance) }
      [eye, centre]
    end

    def self.create
      model = Sketchup.active_model
      boxes = model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.occupant?(item) || AttributeManager.part_kind(item) == 'worktop' }
      return Response.fail('There is nothing to show yet. Insert a cabinet first.') if boxes.empty?

      bounds = Geom::BoundingBox.new
      boxes.each { |item| bounds.add(item.bounds) }
      centre = [bounds.center.x, bounds.center.y, bounds.center.z].map(&:to_mm)
      size = [bounds.width, bounds.height, bounds.depth].map(&:to_mm)
      eye, target = viewpoint(centre, size)

      model.start_operation('Create 3D Scene', true)
      begin
        camera = Sketchup::Camera.new(point(eye), point(target), Geom::Vector3d.new(0, 0, 1), true, FIELD_OF_VIEW)
        model.active_view.camera = camera
        model.active_view.zoom_extents
        page = model.pages[NAME]
        if page
          page.update # take the new camera into the existing scene
        else
          page = model.pages.add(NAME)
        end
        model.pages.selected_page = page
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      Response.ok("The scene \"#{NAME}\" is ready (perspective view of the whole kitchen). Find it in the Scenes tab.")
    end

    def self.point(values) = Geom::Point3d.new(*values.map(&:mm))
    private_class_method :point
  end
end