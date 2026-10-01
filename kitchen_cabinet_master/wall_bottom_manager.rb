# frozen_string_literal: true

module KitchenCabinetMaster
  # The bottom panel under the wall units, for wall units whose carcass has been lifted
  # (Carcass bottom raise): one board for every run of wall units standing in a line at
  # the same height, as deep as their carcass and as long as the whole run. It sits
  # directly under the carcass, in the space the raise left. Each board is a part of its
  # own on the Wall Unit tag.
  module WallBottomManager
    KIND = 'wall_bottom'
    DEFAULT_THICKNESS = 18.0
    MIN_THICKNESS = 6.0
    MAX_THICKNESS = 50.0
    DEFAULT_LENGTH = 2000.0 # each piece, laid end to end along the run (0 = one piece for the whole run)
    DEFAULT_SETBACK = 20.0  # the panel stops this far short of the carcass front

    def self.perform(action, raw)
      case action
      when 'apply_wall_bottom' then apply(raw)
      when 'remove_wall_bottom' then remove
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # Puts a panel under every run of lifted wall units, replacing the ones already there.
    def self.apply(raw)
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      # A live edit only changes panels that are already there.
      if [true, 'true', 1, '1'].include?(raw['only_if_exists']) && pieces_in(Sketchup.active_model).empty?
        return Response.ok('No wall bottom panel applied yet. Press Apply Bottom Panel.')
      end

      params, problem = read_params(raw)
      return Response.fail(problem['message'], [problem]) if problem
      thickness = params['thickness']

      model = Sketchup.active_model
      items = items_of(model)
      return Response.fail('There are no wall units with a raised carcass. Set "Carcass bottom raise" on the wall units first.') if items.empty?

      runs = Worktop.runs(items)
      existing = pieces_in(model)
      SelectionManager.suspend do
        with_operation(model, 'Apply Wall Bottom Panel') do
          existing.each { |item| PartGenerator.remove(model, item) }
          runs.each { |run| build(model, run, params) }
        end
      end
      SelectionManager.push_selection(model)

      note = items.any? { |item| item[:raise] < thickness } ? ' Where the raise is less than the panel thickness, the panel hangs below the doors.' : ''
      count = runs.sum { |run| spans_of(run, params).length }
      Response.ok("#{count} bottom panel#{'s' unless count == 1} #{existing.empty? ? 'applied' : 'updated'}: #{format('%g', thickness)} mm thick.#{note}")
    end

    def self.remove
      model = Sketchup.active_model
      existing = pieces_in(model)
      return Response.ok('There is no wall bottom panel to remove.') if existing.empty?

      SelectionManager.suspend do
        with_operation(model, 'Remove Wall Bottom Panel') { existing.each { |item| PartGenerator.remove(model, item) } }
      end
      SelectionManager.push_selection(model)
      Response.ok('The wall bottom panels were removed.')
    end

    # Rebuilds the panels after a wall unit changed (its raise, width or place), with the
    # thickness they were built with. Does nothing until a panel has been applied once.
    # Call it inside an operation.
    def self.refresh(model)
      existing = pieces_in(model)
      return if existing.empty?

      stored = AttributeManager.read(existing.first)
      thickness = stored['wall_bottom_thickness'].to_f
      params = { 'thickness' => thickness.positive? ? thickness : DEFAULT_THICKNESS,
                 'length' => stored['wall_bottom_length'].to_f, 'depth' => stored['wall_bottom_depth'].to_f,
                 'setback' => stored['wall_bottom_setback'].nil? ? DEFAULT_SETBACK : stored['wall_bottom_setback'].to_f,
                 'material' => stored['wall_bottom_material'].to_s.empty? ? Defaults::SAME_AS_DOOR : stored['wall_bottom_material'] }
      runs = Worktop.runs(items_of(model))
      existing.each { |item| PartGenerator.remove(model, item) }
      runs.each { |run| build(model, run, params) }
    end

    def self.pieces_in(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.part_kind(item) == KIND }
    end

    # The wall units with a lifted carcass, as items for Worktop.runs. `top` is where the
    # carcass starts (so only units at one level share a run), `depth` the carcass depth.
    def self.items_of(model)
      model.entities.grep(Sketchup::ComponentInstance).filter_map do |item|
        next unless AttributeManager.cabinet?(item)

        stored = AttributeManager.read(item)
        next unless stored && stored['cabinet_category'] == 'wall'

        raise_mm = stored['carcass_raise'].to_f
        next unless raise_mm.positive?

        origin = item.transformation.origin
        heading = item.transformation.yaxis
        { x: origin.x.to_mm, y: origin.y.to_mm, hx: heading.x, hy: heading.y, width: stored['width'].to_f,
          depth: stored['depth'].to_f, top: origin.z.to_mm + raise_mm, corner: false, raise: raise_mm, ref: item,
          door_material: stored['material'].to_s.empty? ? CabinetGenerator.door_material(stored) : stored['material'] }
      end
    end

    # Thickness, piece length and depth from the panel: [params, nil] or [nil, error].
    def self.read_params(raw)
      number = lambda do |key, default|
        text = raw[key].to_s.strip
        text.empty? ? default : ValidationManager.to_float(text)
      end
      limits = { 'wall_bottom_thickness' => ['Bottom panel thickness', MIN_THICKNESS, MAX_THICKNESS],
                 'wall_bottom_length' => ['Bottom panel length', 0.0, 10_000.0],
                 'wall_bottom_depth' => ['Bottom panel depth', 0.0, 1200.0] }
      limits['wall_bottom_setback'] = ['Front setback', 0.0, 500.0]
      values = {}
      limits.each do |key, (label, min, max)|
        value = number.call(key, { 'wall_bottom_thickness' => DEFAULT_THICKNESS, 'wall_bottom_length' => DEFAULT_LENGTH, 'wall_bottom_depth' => 0.0,
                                   'wall_bottom_setback' => DEFAULT_SETBACK }[key])
        if value.nil? || value < min || value > max
          return [nil, { 'field' => key, 'message' => "#{label} must be between #{format('%g', min)} and #{format('%g', max)} mm." }]
        end
        values[key] = value
      end
      material = raw['wall_bottom_material'].to_s.strip
      material = Defaults::SAME_AS_DOOR if material.empty?
      [{ 'thickness' => values['wall_bottom_thickness'], 'length' => values['wall_bottom_length'], 'depth' => values['wall_bottom_depth'],
         'setback' => values['wall_bottom_setback'], 'material' => material }, nil]
    end
    private_class_method :read_params

    # The pieces of one run, [[from, to], ...] along it: laid end to end, each `length` long.
    def self.spans_of(run, params)
      Worktop.pieces(run[:length], 'worktop_piece' => params['length'], 'worktop_cuts' => '')
    end
    private_class_method :spans_of

    def self.build(model, run, params)
      thickness = params['thickness']
      first = run[:items].first
      depth = params['depth'].positive? ? params['depth'] : [run[:depth] - params['setback'], 10.0].max
      material = material_for(model, params['material'] == Defaults::SAME_AS_DOOR ? first[:door_material] : params['material'])

      spans_of(run, params).each do |from, to|
        placed = first[:ref].transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, from.mm, 0))
        lift = (run[:top] - thickness).mm - placed.origin.z
        placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * placed

        extent = [depth, to - from, thickness]
        stored = { 'part_kind' => KIND, 'wall_bottom_thickness' => thickness, 'wall_bottom_length' => params['length'],
                   'wall_bottom_depth' => params['depth'], 'wall_bottom_setback' => params['setback'],
                   'wall_bottom_material' => params['material'], 'width' => extent[1], 'depth' => extent[0], 'material' => material }
        stored['part_id'] = AttributeManager.next_part_id(model)
        stored['part_name'] = "Wall Bottom Panel #{stored['part_id'].to_s.split('_').last.to_i}"
        layout = PartLayout.worktop(extent, nil, 'Wall Bottom Panel', 0.0)
        root = PartGenerator.build(model, model.entities, stored, placed, layout)
        TagManager.assign(model, root, TagManager::WALL)
      end
    end
    private_class_method :build
    # The carcass material of the units above it, when the model has it.
    def self.material_for(model, name)
      MaterialManager.available?(model, name) ? name : Defaults::PARAMS['carcass_material']
    end
    private_class_method :material_for

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
