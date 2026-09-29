# frozen_string_literal: true

module KitchenCabinetMaster
  # Entry point for the Filler and End Panel actions: insert_filler,
  # insert_end_panel, update_part, delete_part. Mirrors CabinetManager's shape
  # (validate, wrap in one undoable operation, reply with a Response) but for
  # the much simpler parts: no catalog, no doors, no handles.
  module PartManager
    def self.perform(action, raw)
      case action
      when 'insert_filler' then insert_filler(raw)
      when 'insert_end_panel' then insert_end_panel(raw)
      when 'update_part' then update_part(raw)
      when 'delete_part' then delete_part
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # ---- filler ---------------------------------------------------------------

    def self.insert_filler(raw)
      params, failure = prepare_filler(raw)
      return failure if failure

      model = Sketchup.active_model
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Filler') do
          params['part_id'] = AttributeManager.next_part_id(model)
          layout = PartLayout.filler(params)
          entities, transformation = PlacementManager.target_row(model, params, PartLayout.filler_envelope(params))
          params['part_name'] = NamingManager.unique_name(entities, NamingManager.filler_name(params))
          PartGenerator.build(model, entities, params, transformation, layout)
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_filler

    # ---- end panel --------------------------------------------------------------

    # The target (whatever cabinet or filler is currently selected) is read once,
    # here, at Insert time. Its own size is copied into the end panel's stored
    # parameters, so later Updates never need to re-find the target (see
    # PartLayout.end_panel and PartGenerator.attributes_for).
    def self.insert_end_panel(raw)
      model = Sketchup.active_model
      target = SelectionManager.selected_occupant(model)
      return Response.fail('Select a cabinet or filler first, then choose which side gets the end panel.') unless target

      params, failure = prepare_end_panel(raw)
      return failure if failure

      target_params = AttributeManager.read(target)
      params['target_id'] = target.get_attribute(AttributeManager::DICTIONARY, 'cabinet_id') ||
                             target.get_attribute(AttributeManager::DICTIONARY, 'part_id')
      params['target_width'] = target_params['width'].to_f
      params['target_depth'] = target_params['depth'].to_f
      params['target_top'] = CabinetLayout.envelope(target_params)[2]

      layout = PartLayout.end_panel(params)
      transformation, collision = placed_transformation(target, params)
      return Response.fail(collision) if collision

      root = SelectionManager.suspend do
        with_operation(model, 'Insert End Panel') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(target.parent.entities, NamingManager.end_panel_name(params))
          PartGenerator.build(model, target.parent.entities, params, transformation, layout)
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted on the #{params['side']}.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_end_panel

    # Directly against the target's left or right face, in the target's own
    # coordinate frame (so it follows the target's position and rotation).
    # Refuses (rather than sliding, like a row insert would) if that side is
    # already occupied: an end panel belongs on a genuinely exposed face.
    def self.placed_transformation(target, params)
      offset = params['side'] == 'left' ? -params['thickness'] : params['target_width']
      transformation = target.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, offset.mm, 0))

      size = PartLayout.end_panel_envelope(params)
      if PlacementManager.collides?(target.parent.entities, transformation, size)
        return [nil, "The #{params['side']} side of #{target.name} already has something against it."]
      end

      [transformation, nil]
    end
    private_class_method :placed_transformation

    # ---- update / delete (both kinds) ------------------------------------------

    def self.update_part(raw)
      model = Sketchup.active_model
      root = SelectionManager.selected_part(model)
      return Response.fail('Select a filler or end panel to update.') unless root

      kind = AttributeManager.part_kind(root)
      if kind == 'filler'
        update_filler(model, root, raw)
      elsif kind == 'end_panel'
        update_end_panel(model, root, raw)
      else
        Response.fail('That selection is not a filler or an end panel.')
      end
    end
    private_class_method :update_part

    def self.update_filler(model, root, raw)
      params, failure = prepare_filler(raw)
      return failure if failure

      params['part_id'] = AttributeManager.part_id(root)
      layout = PartLayout.filler(params)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.filler_name(params))

      SelectionManager.suspend { with_operation(model, 'Update Filler') { PartGenerator.update(model, root, params, layout) } }
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_filler

    def self.update_end_panel(model, root, raw)
      params, failure = prepare_end_panel(raw)
      return failure if failure

      stored = AttributeManager.read(root)
      %w[target_id target_width target_depth target_top].each { |key| params[key] = stored[key] }

      layout = PartLayout.end_panel(params)
      offset = params['side'] == 'left' ? -params['thickness'] : params['target_width']
      local_move = Geom::Transformation.translation(Geom::Vector3d.new(0, offset.mm, 0))
      # The panel keeps the position it was placed at; only its own offset along
      # the target's face (which side, how thick) can move it.
      base = target_placement(root)
      transformation = base * local_move
      size = PartLayout.end_panel_envelope(params)

      if PlacementManager.collides?(root.parent.entities, transformation, size, exclude: root)
        return Response.fail("The #{params['side']} side already has something against it.")
      end

      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.end_panel_name(params))

      SelectionManager.suspend do
        with_operation(model, 'Update End Panel') { PartGenerator.update(model, root, params, layout, transformation) }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_end_panel

    # The target's own placement, recovered from the end panel's CURRENT
    # transformation and its CURRENT (pre-update) side/thickness, so a change of
    # side or thickness can be re-applied on top of the same base placement.
    def self.target_placement(root)
      stored = AttributeManager.read(root)
      offset = stored['side'] == 'left' ? -stored['thickness'].to_f : stored['target_width'].to_f
      root.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, -offset.mm, 0))
    end
    private_class_method :target_placement

    def self.delete_part
      model = Sketchup.active_model
      root = SelectionManager.selected_part(model)
      return Response.fail('Select a filler or end panel to delete.') unless root

      name = root.name
      SelectionManager.suspend { with_operation(model, 'Delete Part') { PartGenerator.remove(model, root) } }
      SelectionManager.push_selection(model)
      Response.ok("#{name} deleted. Use Edit > Undo to bring it back.")
    end
    private_class_method :delete_part

    # ---- shared -----------------------------------------------------------------

    def self.prepare_filler(raw)
      result = ValidationManager.validate_filler(raw)
      return [nil, Response.fail(summary(result.errors), result.errors)] unless result.errors.empty?

      model = Sketchup.active_model
      errors = material_errors(model, result.params, %w[material toe_kick_material])
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [result.params, nil]
    end
    private_class_method :prepare_filler

    def self.prepare_end_panel(raw)
      result = ValidationManager.validate_end_panel(raw)
      return [nil, Response.fail(summary(result.errors), result.errors)] unless result.errors.empty?

      model = Sketchup.active_model
      errors = material_errors(model, result.params, %w[material])
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      [result.params, nil]
    end
    private_class_method :prepare_end_panel

    def self.material_errors(model, params, fields)
      fields.each_with_object([]) do |field, errors|
        name = params[field].to_s
        next if MaterialManager.available?(model, name)

        errors << { 'field' => field, 'message' => "The material \"#{name}\" was not found in the model." }
      end
    end
    private_class_method :material_errors

    def self.summary(errors)
      return errors.first['message'] if errors.length == 1

      "#{errors.length} values need attention."
    end
    private_class_method :summary

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
