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
      thickness = ValidationManager.to_float(raw['wall_bottom_thickness'].to_s.strip.empty? ? DEFAULT_THICKNESS : raw['wall_bottom_thickness'])
      if thickness.nil? || thickness < MIN_THICKNESS || thickness > MAX_THICKNESS
        message = "Bottom panel thickness must be between #{MIN_THICKNESS.to_i} and #{MAX_THICKNESS.to_i} mm."
        return Response.fail(message, [{ 'field' => 'wall_bottom_thickness', 'message' => message }])
      end

      model = Sketchup.active_model
      items = items_of(model)
      return Response.fail('There are no wall units with a raised carcass. Set "Carcass bottom raise" on the wall units first.') if items.empty?

      runs = Worktop.runs(items)
      existing = pieces_in(model)
      SelectionManager.suspend do
        with_operation(model, 'Apply Wall Bottom Panel') do
          existing.each { |item| PartGenerator.remove(model, item) }
          runs.each { |run| build(model, run, thickness) }
        end
      end
      SelectionManager.push_selection(model)

      note = items.any? { |item| item[:raise] < thickness } ? ' Where the raise is less than the panel thickness, the panel hangs below the doors.' : ''
      Response.ok("#{runs.length} bottom panel#{'s' unless runs.length == 1} #{existing.empty? ? 'applied' : 'updated'}: #{format('%g', thickness)} mm thick.#{note}")
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

      thickness = AttributeManager.read(existing.first)['wall_bottom_thickness'].to_f
      thickness = DEFAULT_THICKNESS unless thickness.positive?
      runs = Worktop.runs(items_of(model))
      existing.each { |item| PartGenerator.remove(model, item) }
      runs.each { |run| build(model, run, thickness) }
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
          material: stored['carcass_material'].to_s }
      end
    end

    def self.build(model, run, thickness)
      first = run[:items].first
      placed = first[:ref].transformation
      lift = (run[:top] - thickness).mm - placed.origin.z
      placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * placed

      extent = [run[:depth], run[:length], thickness]
      stored = { 'part_kind' => KIND, 'wall_bottom_thickness' => thickness, 'width' => extent[1], 'depth' => extent[0],
                 'material' => material_for(model, first[:material]) }
      stored['part_id'] = AttributeManager.next_part_id(model)
      stored['part_name'] = "Wall Bottom Panel #{stored['part_id'].to_s.split('_').last.to_i}"
      layout = PartLayout.worktop(extent, nil, 'Wall Bottom Panel', 0.0)
      root = PartGenerator.build(model, model.entities, stored, placed, layout)
      TagManager.assign(model, root, TagManager::WALL)
      root
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
