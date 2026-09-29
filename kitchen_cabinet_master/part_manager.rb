# frozen_string_literal: true

module KitchenCabinetMaster
  # Entry point for the Filler, End Panel and Toe Kick actions: insert_filler,
  # insert_end_panel, insert_toe_kick, update_part, delete_part. Mirrors
  # CabinetManager's shape (validate, wrap in one undoable operation, reply with
  # a Response) but for the much simpler parts: no catalog, no doors, no handles.
  module PartManager
    def self.perform(action, raw)
      case action
      when 'insert_filler' then insert_filler(raw)
      when 'insert_end_panel' then insert_end_panel(raw)
      when 'insert_toe_kick' then insert_toe_kick(raw)
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
          params['sequence'] = AttributeManager.next_sequence(model)
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

    # ---- toe kick ---------------------------------------------------------------

    # A toe kick is its own entity, a run of equal pieces laid end to end. What it
    # goes against is decided by the selection, once, at Insert time:
    #
    #   a cabinet or filler  -> it starts at that item's left end, under its front,
    #                           set back `recess` from the carcass front
    #   another toe kick     -> it carries straight on from where that one ends
    #   nothing              -> at the origin, under a carcass as deep as the
    #                           panel's Depth field
    #
    # The depth and door / carcass colours it needs are copied into its stored
    # parameters, so a later Update never has to look the target up again.
    def self.insert_toe_kick(raw)
      model = Sketchup.active_model
      anchor = toe_kick_anchor(model)
      params, failure = prepare_toe_kick(raw, anchor)
      return failure if failure

      layout = PartLayout.toe_kick(params)
      entities, transformation = toe_kick_placement(model, anchor)
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Toe Kick') do
          params['part_id'] = AttributeManager.next_part_id(model)
          params['part_name'] = NamingManager.unique_name(entities, NamingManager.toe_kick_name(params))
          built = PartGenerator.build(model, entities, params, transformation, layout)
          # A new toe kick follows the Toe Kick tick in the Visibility section.
          built.visible = false if raw.is_a?(Hash) && [false, 'false', 0, '0'].include?(raw['visible'])
          built
        end
      end

      SelectionManager.select(root)
      Response.ok("#{root.name} inserted: #{layout.toe_kick.length} piece#{'s' unless layout.toe_kick.length == 1}, " \
                  "#{format('%g', ToeKick.total_length(params))} mm long.", { 'part_id' => AttributeManager.part_id(root) })
    end
    private_class_method :insert_toe_kick

    # The selected toe kick (to carry on from it), else the selected cabinet or filler, else nil.
    def self.toe_kick_anchor(model)
      part = SelectionManager.selected_part(model)
      return part if part && AttributeManager.part_kind(part) == 'toe_kick'

      SelectionManager.selected_occupant(model)
    end
    private_class_method :toe_kick_anchor

    def self.toe_kick_placement(model, anchor)
      return [model.active_entities, Geom::Transformation.new] unless anchor

      transformation = anchor.transformation
      if AttributeManager.part_kind(anchor) == 'toe_kick'
        length = anchor.get_attribute(AttributeManager::DICTIONARY, 'width').to_f
        transformation *= Geom::Transformation.translation(Geom::Vector3d.new(0, length.mm, 0))
      end
      [anchor.parent.entities, transformation]
    end
    private_class_method :toe_kick_placement

    # Validates the panel values, adds what the selection supplies (see
    # insert_toe_kick) and checks the plinth actually fits under the carcass.
    def self.prepare_toe_kick(raw, anchor)
      result = ValidationManager.validate_toe_kick(raw)
      params = result.params
      errors = result.errors.dup
      params.merge!(toe_kick_target(raw, anchor)) if errors.empty?

      errors.concat(toe_kick_fit_errors(Sketchup.active_model, params)) if errors.empty?
      return [nil, Response.fail(summary(errors), errors)] unless errors.empty?

      params['width'] = ToeKick.total_length(params)
      [params, nil]
    end
    private_class_method :prepare_toe_kick

    # Works out the material (see ToeKick.material_name), then checks that the
    # plinth fits under the carcass and that the material exists.
    def self.toe_kick_fit_errors(model, params)
      errors = []
      if ToeKick.front_offset(params).negative?
        together = params['toe_kick_recess'] + params['toe_kick_thickness']
        errors << { 'field' => 'toe_kick_recess',
                    'message' => "The recess and thickness together (#{format('%g', together)} mm) are more than " \
                                 "the carcass depth (#{format('%g', params['target_depth'])} mm)." }
      end

      params['material'] = ToeKick.material_name(params, params['target_door_material'], params['target_carcass_material'])
      unless MaterialManager.available?(model, params['material'])
        errors << { 'field' => 'toe_kick_material', 'message' => "The material \"#{params['material']}\" was not found in the model." }
      end
      errors
    end
    private_class_method :toe_kick_fit_errors

    # target_depth, target_door_material, target_carcass_material for `anchor`.
    def self.toe_kick_target(raw, anchor)
      stored = anchor ? AttributeManager.read(anchor) : nil
      return fallback_target(raw) unless stored

      if AttributeManager.part_kind(anchor) == 'toe_kick'
        stored.slice('target_depth', 'target_door_material', 'target_carcass_material')
      elsif AttributeManager.part_kind(anchor) == 'filler'
        { 'target_depth' => stored['depth'].to_f, 'target_door_material' => stored['material'].to_s,
          'target_carcass_material' => stored['material'].to_s }
      else
        # The door material the cabinet was actually built with; if it never
        # recorded one (an older cabinet), work it out so this is never blank.
        door = stored['material'].to_s
        door = CabinetGenerator.door_material(stored) if door.empty?
        # A corner unit is a square: its carcass reaches Width, not its Depth field.
        depth = stored['cabinet_category'] == 'corner' ? stored['width'] : stored['depth']
        { 'target_depth' => depth.to_f, 'target_door_material' => door,
          'target_carcass_material' => CabinetGenerator.carcass_material(stored, door) }
      end
    end
    private_class_method :toe_kick_target

    def self.fallback_target(raw)
      depth = ValidationManager.to_float(stringify(raw)['depth'])
      material = Defaults::PARAMS['base_material']
      { 'target_depth' => depth&.positive? ? depth : Defaults::DEFAULT_TOE_KICK_DEPTH,
        'target_door_material' => material, 'target_carcass_material' => material }
    end
    private_class_method :fallback_target

    def self.stringify(hash)
      hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
    end
    private_class_method :stringify

    def self.update_toe_kick(model, root, raw)
      result = ValidationManager.validate_toe_kick(raw)
      params = result.params
      errors = result.errors.dup

      stored = AttributeManager.read(root)
      %w[target_depth target_door_material target_carcass_material].each { |key| params[key] = stored[key] }
      errors.concat(toe_kick_fit_errors(model, params)) if errors.empty?
      return Response.fail(summary(errors), errors) unless errors.empty?

      params['width'] = ToeKick.total_length(params)
      params['part_id'] = AttributeManager.part_id(root)
      params['part_name'] = NamingManager.for_update_base(root, NamingManager.toe_kick_name(params))
      layout = PartLayout.toe_kick(params)

      SelectionManager.suspend { with_operation(model, 'Update Toe Kick') { PartGenerator.update(model, root, params, layout) } }
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated.")
    end
    private_class_method :update_toe_kick

    # ---- update / delete (all kinds) -------------------------------------------

    def self.update_part(raw)
      model = Sketchup.active_model
      root = SelectionManager.selected_part(model)
      return Response.fail('Select a filler, end panel or toe kick to update.') unless root

      case AttributeManager.part_kind(root)
      when 'filler' then update_filler(model, root, raw)
      when 'end_panel' then update_end_panel(model, root, raw)
      when 'toe_kick' then update_toe_kick(model, root, raw)
      else Response.fail('That selection is not a filler, an end panel or a toe kick.')
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
      errors = material_errors(model, result.params, %w[material])
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
