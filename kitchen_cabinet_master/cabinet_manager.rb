# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Entry point for every panel action. It validates, wraps model changes in a
  # SketchUp operation (one Undo step, rolled back on any error) and replies
  # with a Response.
  #
  # Actions: insert, update, duplicate, delete, open, close, toggle, visibility.
  module CabinetManager
    DOOR_ACTIONS = %w[open close toggle].freeze

    def self.perform(action, raw)
      case action
      when 'insert' then insert(raw)
      when 'update' then update(raw)
      when 'duplicate' then duplicate
      when 'delete' then delete
      when 'visibility' then set_visibility(raw)
      when *DOOR_ACTIONS then animate(action)
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # ---- actions -------------------------------------------------------------

    def self.insert(raw)
      params, failure = prepare(raw)
      return failure if failure

      model = Sketchup.active_model
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Cabinet') do
          params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
          entities, transformation = PlacementManager.target_for_new(model, params)
          params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
          CabinetGenerator.build(model, entities, params, transformation)
        end
      end

      SelectionManager.select(root)
      stored = AttributeManager.read(root)
      Response.ok(
        "#{stored['cabinet_name']} inserted. Base Z #{fmt(stored['base_z'])} mm, top Z #{fmt(stored['top_z'])} mm.",
        { 'cabinet_id' => stored['cabinet_id'], 'cabinet_name' => stored['cabinet_name'] }
      )
    end
    private_class_method :insert

    def self.update(raw)
      model = Sketchup.active_model
      root = SelectionManager.selected_cabinet(model)
      return Response.fail('Select a cabinet in the model to update.') unless root

      params, failure = prepare(raw)
      return failure if failure

      SelectionManager.suspend do
        with_operation(model, 'Update Cabinet') do
          params['cabinet_name'] = NamingManager.for_update(root, params)
          CabinetGenerator.update(model, root, params)
        end
      end

      SelectionManager.push_selection(model)
      stored = AttributeManager.read(root)
      Response.ok("#{stored['cabinet_name']} updated. Base Z #{fmt(stored['base_z'])} mm, top Z #{fmt(stored['top_z'])} mm.")
    end
    private_class_method :update

    # Carcass / Door / Toe Kick / Opening Direction checkboxes: applied straight away to every cabinet
    # in the model (the top level of the model), as one undoable step. Only the
    # visible flag of existing containers changes; nothing is rebuilt.
    def self.set_visibility(raw)
      raw = {} unless raw.is_a?(Hash)
      visibility = %w[carcass door toe_kick].to_h { |key| [key, [true, 'true', 1, '1'].include?(raw[key])] }
      show_indicator = [true, 'true', 1, '1'].include?(raw['opening_direction'])

      model = Sketchup.active_model
      cabinets = model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
      return Response.ok('No cabinets in the model yet. New cabinets will use these settings.') if cabinets.empty?

      SelectionManager.suspend do
        with_operation(model, 'Change Cabinet Visibility') do
          cabinets.each do |cabinet|
            AttributeManager.write(cabinet, 'visibility_settings' => visibility, 'show_opening_direction' => show_indicator)
            CabinetGenerator.apply_visibility(cabinet, visibility, show_indicator)
          end
        end
      end

      Response.ok("Visibility updated on #{cabinets.length} cabinet#{'s' unless cabinets.length == 1}.")
    end
    private_class_method :set_visibility

    # A copy of the selected cabinet exactly as it is stored (unsaved edits in the
    # panel are not used; that is what Insert is for). It gets a new ID, is placed
    # after the original with the same rule as Insert, and starts with its doors
    # closed. It is built from the stored parameters, so it shares panel and handle
    # definitions with the original but has its own containers.
    def self.duplicate
      model = Sketchup.active_model
      source = SelectionManager.selected_cabinet(model)
      return Response.fail('Select a cabinet in the model to duplicate.') unless source

      params = Defaults.params.merge(AttributeManager.read(source))
      source_name = source.name.to_s
      copy = SelectionManager.suspend do
        with_operation(model, 'Duplicate Cabinet') do
          params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
          entities, transformation = PlacementManager.target_for_new(model, params)
          params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
          CabinetGenerator.build(model, entities, params, transformation)
        end
      end

      SelectionManager.select(copy)
      Response.ok("#{copy.name} created as a copy of #{source_name}.", { 'cabinet_id' => AttributeManager.cabinet_id(copy), 'cabinet_name' => copy.name })
    end
    private_class_method :duplicate

    def self.delete
      model = Sketchup.active_model
      root = SelectionManager.selected_cabinet(model)
      return Response.fail('Select a cabinet in the model to delete.') unless root

      cabinet_id = root.name.to_s.empty? ? AttributeManager.cabinet_id(root) : root.name
      SelectionManager.suspend do
        with_operation(model, 'Delete Cabinet') { CabinetGenerator.remove(model, root) }
      end

      SelectionManager.push_selection(model)
      Response.ok("#{cabinet_id} deleted. Use Edit > Undo to bring it back.")
    end
    private_class_method :delete

    # Open / Close / Toggle. Acts on the selected door(s), or on every door of
    # the selected cabinet. The animation runs as one undoable step.
    def self.animate(action)
      model = Sketchup.active_model
      target = SelectionManager.selected_doors(model)
      return Response.fail('Select a cabinet, or one of its doors or drawers, first.') unless target
      return Response.fail('This cabinet has no doors or drawers.') if target[:doors].empty?

      params = AttributeManager.read(target[:cabinet])
      angle = params['door_opening_angle'].to_f
      depth = params['depth'].to_f
      layout = CabinetLayout.compute(params)
      specs = layout.doors.to_h { |door| [door.role, [door, :door]] }
                    .merge(layout.drawers.to_h { |drawer| [drawer.role, [drawer, :drawer]] })

      any_open = target[:doors].any? { |door| DoorAnimation.open?(door) }
      moves = target[:doors].each_with_object([]) do |door, list|
        spec, kind = specs[AttributeManager.role(door)]
        goal = door_goal(action, door, target[:explicit], any_open)
        next if spec.nil? || DoorAnimation.open?(door) == goal

        list << DoorAnimation::Move.new(door: door, spec: spec, angle: angle, depth: depth, kind: kind,
                                         from: goal ? 0.0 : 1.0, to: goal ? 1.0 : 0.0)
      end

      return Response.ok('Nothing to do: the doors and drawers are already in that position.') if moves.empty?

      DoorAnimation.run(model, moves, "#{action.capitalize} Doors")
      opening = moves.first.to.positive?
      Response.ok("#{opening ? 'Opening' : 'Closing'} #{moves.length} item#{'s' unless moves.length == 1}.")
    end
    private_class_method :animate

    # true = open, false = closed. Toggle flips a single selected door, but for a
    # whole cabinet it closes everything if anything is open, otherwise opens everything.
    def self.door_goal(action, door, explicit, any_open)
      case action
      when 'open' then true
      when 'close' then false
      else explicit ? !DoorAnimation.open?(door) : !any_open
      end
    end
    private_class_method :door_goal

    # ---- shared steps --------------------------------------------------------

    # Validates the raw panel values against the rules, the catalog and the model.
    # Returns [params, nil] when valid, or [nil, failure_response].
    def self.prepare(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model

      cabinet = CatalogManager.cabinet(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type'])
      door_count = cabinet ? cabinet['doors'].to_i : nil
      drawer_count = cabinet ? cabinet['drawers'].to_i : nil

      result = ValidationManager.validate(raw, door_count: door_count, drawer_count: drawer_count)
      errors = result.errors + catalog_errors(raw, result, cabinet)
      params = result.params
      params['door_count'] = door_count.to_i
      params['drawer_count'] = drawer_count.to_i
      params['name_code'] = (cabinet && cabinet['code']).to_s

      errors += handle_errors(params) if errors.empty?
      errors += material_errors(model, params) if errors.empty?
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [params, nil]
    end
    private_class_method :prepare

    # One Undo step. Any error rolls the whole operation back, so a failed
    # insert or update never leaves half-built geometry behind.
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

    # Problems that need the catalog to detect (unknown catalog, cabinet or handle).
    def self.catalog_errors(raw, result, cabinet)
      errors = []
      params = result.params
      already = result.errors.map { |e| e['field'] }

      if !params['catalog_id'].empty? && CatalogManager.catalog(params['catalog_id']).nil?
        errors << { 'field' => 'catalog_id', 'message' => 'That catalog could not be found.' }
      elsif cabinet.nil? && !already.include?('cabinet_type') && !already.include?('cabinet_category')
        errors << { 'field' => 'cabinet_type', 'message' => 'That cabinet is not in the selected catalog and category.' }
      end

      handle_id = raw['handle_id'].to_s.strip
      if !handle_id.empty? && CatalogManager.handle_bundle(handle_id).nil?
        errors << { 'field' => 'handle_id', 'message' => 'That handle bundle could not be found.' }
      end

      errors
    end
    private_class_method :catalog_errors

    # Completes the handle settings from the bundle's defaults, then checks the
    # handle is offered in that length and finish and fits on every door.
    def self.handle_errors(params)
      bundle = CatalogManager.handle_bundle(params['handle_id'])
      return [] unless bundle

      HandleManager.apply_defaults!(params, bundle)
      return [] unless params['door_count'].positive?

      HandleManager.errors(params, CabinetLayout.compute(params), bundle)
    end
    private_class_method :handle_errors

    # Materials must exist in the model or be a known preset (which is created on first use).
    def self.material_errors(model, params)
      errors = []

      material = CabinetGenerator.door_material(params)
      unless MaterialManager.available?(model, material)
        field = params['cabinet_material'].to_s.empty? ? "#{params['cabinet_category']}_material" : 'cabinet_material'
        errors << { 'field' => field, 'message' => "The door material \"#{material}\" was not found in the model." }
      end

      carcass = params['carcass_material'].to_s
      unless carcass.empty? || MaterialManager.available?(model, carcass)
        errors << { 'field' => 'carcass_material', 'message' => "The material \"#{carcass}\" was not found in the model." }
      end

      handle_material = params['handle_material'].to_s
      unless handle_material.empty? || MaterialManager.available?(model, handle_material)
        errors << { 'field' => 'handle_material', 'message' => "The handle material \"#{handle_material}\" was not found in the model." }
      end

      toe_material = params['toe_kick_material'].to_s
      unless MaterialManager.available?(model, toe_material)
        errors << { 'field' => 'toe_kick_material', 'message' => "The material \"#{toe_material}\" was not found in the model." }
      end

      errors
    end
    private_class_method :material_errors

    def self.summary(errors)
      return errors.first['message'] if errors.length == 1

      "#{errors.length} values need attention."
    end
    private_class_method :summary

    def self.fmt(number)
      format('%g', number.to_f)
    end
    private_class_method :fmt
  end
end
