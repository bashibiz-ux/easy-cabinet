# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Entry point for every panel action. It validates, wraps model changes in a
  # SketchUp operation (one Undo step, rolled back on any error) and replies
  # with a Response.
  #
  # Actions: insert, update, duplicate, delete, toggle (every cabinet), visibility.
  module CabinetManager
    def self.perform(action, raw)
      case action
      when 'insert' then insert(raw)
      when 'update' then update(raw)
      when 'duplicate' then duplicate
      when 'delete' then delete
      when 'visibility' then set_visibility(raw)
      when 'toggle' then toggle_all
      when 'rotate' then rotate(raw)
      when 'apply_all' then apply_all(raw)
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
          params['sequence'] = AttributeManager.next_sequence(model)
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

      # A wider cabinet takes its space from the one next to it in the row, which
      # gets narrower (see RowResizer). Anything else it would run into refuses the edit.
      dictionary = AttributeManager::DICTIONARY
      growth = params['width'] - root.get_attribute(dictionary, 'width').to_f
      squeeze = nil
      if growth.abs > 0.01
        squeeze, problem = RowResizer.plan(model, root, growth)
        return Response.fail(problem) if problem
      end

      # A wall unit hangs by its top: when it gets taller it grows DOWNWARDS (and a
      # shorter one rises), so its top stays level with the tall units beside it.
      placed = root.transformation
      if params['cabinet_category'] == 'wall' && root.get_attribute(dictionary, 'cabinet_category') == 'wall'
        taller = params['height'] - root.get_attribute(dictionary, 'height').to_f
        placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, -taller.mm)) * placed if taller.abs > 0.01
      end

      old_size = %w[envelope_depth envelope_width envelope_top].map { |key| root.get_attribute(dictionary, key).to_f }
      if PlacementManager.crowds?(root.parent.entities, root, placed, CabinetLayout.envelope(params), old_size,
                                  also: squeeze && squeeze[:neighbour])
        return Response.fail('That size would make the cabinet overlap the item next to it. Make it smaller, or move the neighbour first.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Update Cabinet') do
          params['cabinet_name'] = NamingManager.for_update(root, params)
          CabinetGenerator.update(model, root, params)
          root.transformation = placed unless placed.equal?(root.transformation)
          RowResizer.apply(model, squeeze) if squeeze
          # Its filler, end panels and toe kicks follow its door material.
          PartManager.follow_door(model, root)
          WallBottomManager.refresh(model) if defined?(WallBottomManager)
        end
      end

      SelectionManager.push_selection(model)
      stored = AttributeManager.read(root)
      note = ''
      if squeeze
        how = squeeze[:need].positive? ? 'narrower to make room' : 'wider to fill the space'
        note = " #{squeeze[:neighbour].name} was made #{fmt(squeeze[:need].abs)} mm #{how}."
      end
      Response.ok("#{stored['cabinet_name']} updated. Base Z #{fmt(stored['base_z'])} mm, top Z #{fmt(stored['top_z'])} mm.#{note}")
    end
    private_class_method :update

    # ---- settings that belong to every cabinet -------------------------------------

    GLOBAL_NUMBERS = %w[door_gap door_reveal door_distance material_thickness back_thickness toe_kick_height carcass_raise
                      handle_length handle_side_offset handle_vertical_offset handle_custom_x handle_custom_z].freeze
    GLOBAL_MATERIALS = %w[base_material wall_material tall_material carcass_material top_panel_style
                          handle_id handle_finish handle_material handle_orientation handle_position handle_horizontal_place].freeze

    # Door gap, door reveal, door distance, panel thickness, back panel thickness, the
    # Handle section and the materials of the Material section are settings for the whole job: changing one changes
    # every cabinet in the model, live, as one Undo step. A cabinet's own size,
    # handle and other choices are left exactly as they are. A cabinet that cannot
    # take a value (a door that would become too small, say) is left as it was and
    # the reply says so.
    def self.apply_all(raw)
      raw = {} unless raw.is_a?(Hash)
      overrides = {}
      GLOBAL_NUMBERS.each do |key|
        text = raw[key].to_s.strip
        overrides[key] = text unless text.empty? # blank: keep what each cabinet has
      end
      GLOBAL_MATERIALS.each { |key| overrides[key] = raw[key].to_s.strip if raw.key?(key) }

      model = Sketchup.active_model
      cabinets = model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
      return Response.ok('No cabinets in the model yet. New cabinets will use these settings.') if cabinets.empty?

      plans = []
      problems = []
      cabinets.each do |cabinet|
        stored = AttributeManager.read(cabinet)
        next unless differs?(stored, overrides)

        params, errors = restyle_params(model, stored, overrides)
        if errors.empty?
          plans << [cabinet, params]
        else
          problems << [cabinet, errors]
        end
      end

      if plans.empty? && problems.any?
        errors = problems.first[1]
        message = problems.length == 1 ? errors.first['message'] : "#{problems.first[0].name}: #{errors.first['message']}"
        return Response.fail(message, errors)
      end
      return Response.ok('Every cabinet already has these settings.') if plans.empty?

      # A higher toe kick lifts every cabinet standing on it: they are rebuilt with the new
      # height, and what is attached to them (fillers, end panels, the worktop) goes up too.
      lifting = overrides.key?('toe_kick_height')
      before = lifted_from(cabinets)
      SelectionManager.suspend do
        with_operation(model, 'Apply Settings To All Cabinets') do
          plans.each do |cabinet, params|
            params['cabinet_name'] = NamingManager.for_update(cabinet, params)
            CabinetGenerator.update(model, cabinet, params)
            PartManager.follow_door(model, cabinet)
          end
          if lifting
            PartManager.lift_attached(model, before, ValidationManager.to_float(overrides['toe_kick_height']))
            WorktopManager.refresh(model)
          end
          WallBottomManager.refresh(model) if defined?(WallBottomManager)
        end
      end
      SelectionManager.push_selection(model)

      done = "#{plans.length} cabinet#{'s' unless plans.length == 1} updated."
      return Response.ok(done) if problems.empty?

      skipped = problems.map { |cabinet, errors| "#{cabinet.name}: #{errors.first['message']}" }
      Response.ok("#{done} #{problems.length} could not take the new value and #{problems.length == 1 ? 'was' : 'were'} " \
                  "left as #{problems.length == 1 ? 'it was' : 'they were'} (#{skipped.first(2).join('; ')}).")
    end
    private_class_method :apply_all

    # The toe-kick height the standing cabinets have now (before it is changed).
    def self.lifted_from(cabinets)
      standing = cabinets.map { |cabinet| AttributeManager.read(cabinet) }.reject { |stored| stored['cabinet_category'] == 'wall' }
      standing.empty? ? 0.0 : standing.first['toe_kick_height'].to_f
    end
    private_class_method :lifted_from

    # Does any override change what this cabinet already has?
    def self.differs?(stored, overrides)
      overrides.any? do |key, value|
        next false if key == 'toe_kick_height' && stored['cabinet_category'] == 'wall' # a wall unit hangs: no toe kick
        next false if key == 'carcass_raise' && stored['cabinet_category'] != 'wall' # only wall units lift their carcass
        if GLOBAL_NUMBERS.include?(key)
          ValidationManager.to_float(stored[key]) != ValidationManager.to_float(value)
        else
          stored[key].to_s != value.to_s
        end
      end
    end
    private_class_method :differs?

    # A stored cabinet's parameters with `overrides` put in, checked by the same rules
    # as an Update. Returns [params, []] or [nil, errors].
    def self.restyle_params(model, stored, overrides)
      result = ValidationManager.validate(stored.merge(overrides), door_count: stored['door_count'].to_i,
                                                                    drawer_count: stored['drawer_count'].to_i)
      params = result.params
      params['door_count'] = stored['door_count'].to_i
      params['drawer_count'] = stored['drawer_count'].to_i
      params['name_code'] = stored['name_code'].to_s
      errors = result.errors
      errors += handle_errors(params) if errors.empty?
      errors += material_errors(model, params) if errors.empty?
      errors.empty? ? [params, []] : [nil, errors]
    end
    private_class_method :restyle_params

    # Turns the selected cabinet (or filler, end panel or toe kick) about a vertical
    # axis through the middle of its footprint, by the number of degrees typed in the
    # panel. Positive turns CLOCKWISE seen from above, negative anticlockwise. One
    # Undo step. Its own doors, handles and the rest turn with it; other items are
    # left where they are.
    def self.rotate(raw)
      raw = {} unless raw.is_a?(Hash)
      degrees = ValidationManager.to_float(raw['degrees'])
      return Response.fail('Enter the rotation in degrees, for example 90 or -45.') if degrees.nil?
      if degrees.abs < 1e-9 || degrees.abs > 360
        return Response.fail('The rotation must be between -360 and 360 degrees, and not 0.')
      end

      model = Sketchup.active_model
      target = SelectionManager.selected_cabinet(model) || SelectionManager.selected_part(model)
      return Response.fail('Select a cabinet in the model to rotate.') unless target

      SelectionManager.suspend do
        with_operation(model, 'Rotate Cabinet') { target.transformation = target.transformation * rotation_of(target, degrees) }
      end
      SelectionManager.push_selection(model)
      Response.ok("#{target.name} rotated #{fmt(degrees)} degrees.")
    end
    private_class_method :rotate

    # The turn, in the item's own frame, about the middle of its footprint (from its
    # stored envelope: depth is X, width is Y).
    def self.rotation_of(entity, degrees)
      dictionary = AttributeManager::DICTIONARY
      depth = entity.get_attribute(dictionary, 'envelope_depth').to_f
      width = entity.get_attribute(dictionary, 'envelope_width').to_f
      centre = Geom::Point3d.new(depth.mm / 2.0, width.mm / 2.0, 0)
      # SketchUp turns anticlockwise for a positive angle about +Z, so the sign is
      # flipped here: a positive angle in the panel is clockwise.
      Geom::Transformation.rotation(centre, Geom::Vector3d.new(0, 0, 1), -degrees * Math::PI / 180.0)
    end
    private_class_method :rotation_of

    # Carcass / Door / Toe Kick / the two opening-direction checkboxes: applied
    # straight away to every cabinet in the model (the top level of the model), as
    # one undoable step. Only the visible flag of existing containers changes;
    # nothing is rebuilt.
    #   opening_direction  the plan symbol on the floor
    #   door_symbol        the dashed swing lines on each door
    def self.set_visibility(raw)
      raw = {} unless raw.is_a?(Hash)
      on = ->(value) { [true, 'true', 1, '1'].include?(value) }
      visibility = %w[carcass door toe_kick].to_h { |key| [key, on.call(raw[key])] }
      show_floor_symbol = on.call(raw['opening_direction'])
      show_door_symbol = on.call(raw['door_symbol'])
      show_wall_symbol = on.call(raw['wall_opening_direction'])
      hide_wall_handles = on.call(raw['hide_wall_handles'])
      show_names = on.call(raw['show_cabinet_names'])
      hide_base_handles = on.call(raw['hide_base_handles'])

      model = Sketchup.active_model
      instances = model.entities.grep(Sketchup::ComponentInstance)
      cabinets = instances.select { |instance| AttributeManager.cabinet?(instance) }
      toe_kicks = instances.select { |instance| AttributeManager.part_kind(instance) == 'toe_kick' }
      if cabinets.empty? && toe_kicks.empty?
        return Response.ok('No cabinets in the model yet. New cabinets will use these settings.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Change Cabinet Visibility') do
          cabinets.each do |cabinet|
            AttributeManager.write(cabinet, 'visibility_settings' => visibility,
                                            'show_opening_direction' => show_floor_symbol,
                                            'show_door_symbol' => show_door_symbol,
                                            'show_wall_opening_direction' => show_wall_symbol,
                                            'hide_wall_handles' => hide_wall_handles,
                                            'hide_base_handles' => hide_base_handles,
                                            'show_cabinet_names' => show_names)
            CabinetGenerator.apply_visibility(cabinet, visibility, show_floor_symbol, show_door_symbol, show_wall_symbol, hide_wall_handles,
                                              hide_base_handles)
            CabinetGenerator.sync_name_label_for(model, cabinet)
          end
          # The toe kicks are separate entities: the Toe Kick tick shows or hides them.
          toe_kicks.each { |toe_kick| toe_kick.visible = visibility['toe_kick'] }
        end
      end

      Response.ok("Visibility updated on #{cabinets.length} cabinet#{'s' unless cabinets.length == 1}" \
                  "#{" and #{toe_kicks.length} toe kick#{'s' unless toe_kicks.length == 1}" unless toe_kicks.empty?}.")
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
          params['sequence'] = AttributeManager.next_sequence(model)
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

    # Toggle: with a cabinet selected, only THAT cabinet's doors and drawers; with
    # nothing selected, every cabinet in the model (the top level of the model,
    # like Visibility). If any of them is open they all close; otherwise they all
    # open. The animation runs as one undoable step.
    def self.toggle_all
      model = Sketchup.active_model
      selected = SelectionManager.selected_cabinet(model)
      cabinets = if selected
                   [selected]
                 else
                   model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
                 end
      return Response.fail('There are no cabinets in the model yet.') if cabinets.empty?

      openables = cabinets.to_h { |cabinet| [cabinet, CabinetGenerator.openables_of(cabinet)] }
      return Response.fail("#{selected.name} has no doors or drawers.") if selected && openables.values.all?(&:empty?)
      return Response.fail('None of the cabinets has doors or drawers.') if openables.values.all?(&:empty?)

      opening = openables.values.flatten.none? { |door| DoorAnimation.open?(door) }
      moves = openables.flat_map { |cabinet, doors| moves_for(cabinet, doors, opening) }
      return Response.ok('Nothing to do: the doors and drawers are already in that position.') if moves.empty?

      DoorAnimation.run(model, moves, opening ? 'Open Doors' : 'Close Doors')
      scope = selected ? selected.name : "#{cabinets.length} cabinet#{'s' unless cabinets.length == 1}"
      Response.ok("#{opening ? 'Opening' : 'Closing'} #{moves.length} item#{'s' unless moves.length == 1} in #{scope}.")
    end
    private_class_method :toggle_all

    # The Moves that take one cabinet's doors and drawers to open (true) or closed (false).
    def self.moves_for(cabinet, doors, opening)
      return [] if doors.empty?

      params = AttributeManager.read(cabinet)
      angle = params['door_opening_angle'].to_f
      depth = params['depth'].to_f
      layout = CabinetLayout.compute(params)
      specs = layout.doors.to_h { |door| [door.role, [door, :door]] }
                    .merge(layout.drawers.to_h { |drawer| [drawer.role, [drawer, :drawer]] })

      doors.each_with_object([]) do |door, list|
        spec, kind = specs[AttributeManager.role(door)]
        next if spec.nil? || DoorAnimation.open?(door) == opening

        list << DoorAnimation::Move.new(door: door, spec: spec, angle: angle, depth: depth, kind: kind,
                                         from: opening ? 0.0 : 1.0, to: opening ? 1.0 : 0.0)
      end
    end
    private_class_method :moves_for

    # ---- shared steps --------------------------------------------------------

    # Validates the raw panel values against the rules, the catalog and the model.
    # Returns [params, nil] when valid, or [nil, failure_response].
    def self.prepare(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model

      cabinet = CatalogManager.cabinet(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type'])
      # A catalog entry can be a corner shape ("corner": "l_shape" / "blind" / "diagonal"; blind ones
      # also say how wide the blind part is): the shape travels with the cabinet.
      raw = raw.merge('corner_style' => cabinet && cabinet['corner'].to_s, 'blind_width' => cabinet && cabinet['blind'], 'front_zone' => cabinet && cabinet['zone'], 'bottom_zone' => cabinet && cabinet['zone_bottom'])
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

module KitchenCabinetMaster
  # Makes room in a row when a cabinet is made wider. The cabinet grows towards the
  # NEXT item in its row (the cabinet or filler that follows it along its own Y
  # axis, on the same wall and at the same height). Free space between the two is
  # used first; whatever is still needed comes out of that neighbour's width: it
  # gets narrower, and its start moves along so its far end stays where it was.
  # A corner unit cannot be narrowed, and nothing goes below the smallest width.
  module RowResizer
    SAME_LINE_MM = 5.0   # how closely the next item must line up (back and height)
    MAX_GAP_MM = 3000.0  # further than this, it is not the next item
    MIN_FILLER_MM = 5.0
    MAX_FILLER_MM = 1000.0

    # Returns [plan, nil] (the neighbour to narrow), [nil, nil] (no neighbour that
    # needs to give way) or [nil, problem message].
    def self.plan(model, root, growth)
      neighbour, gap = next_in_row(root)
      return [nil, nil] unless neighbour
      return follow_back(model, neighbour, growth) if growth.negative?

      need = growth - gap
      return [nil, nil] if need <= 0.01

      stored = AttributeManager.read(neighbour)
      width = stored['width'].to_f
      new_width = width - need
      if AttributeManager.part_kind(neighbour) == 'filler'
        return too_narrow(neighbour, new_width, MIN_FILLER_MM) if new_width < MIN_FILLER_MM

        return [{ neighbour: neighbour, need: need, width: new_width, filler: true }, nil]
      end

      if CabinetLayout.corner?(stored)
        return [nil, "#{neighbour.name} is a corner unit and cannot be made narrower, so there is no room for that width."]
      end

      minimum = ValidationManager::NUMERIC_FIELDS['width'][:min]
      return too_narrow(neighbour, new_width, minimum) if new_width < minimum

      params, errors = CabinetManager.send(:restyle_params, model, stored, 'width' => new_width)
      unless errors.empty?
        return [nil, "#{neighbour.name} cannot be made #{format('%g', new_width)} mm wide: #{errors.first['message']}"]
      end

      [{ neighbour: neighbour, need: need, width: new_width, params: params }, nil]
    end

    # The cabinet got narrower by `-growth`: the next item follows it back, getting
    # that much wider and starting that much sooner, so its far end stays where it is
    # and the space between the two stays as it was. A corner unit is left alone, and
    # so is a neighbour that cannot take the width (the gap simply stays).
    def self.follow_back(model, neighbour, growth)
      stored = AttributeManager.read(neighbour)
      new_width = stored['width'].to_f - growth
      if AttributeManager.part_kind(neighbour) == 'filler'
        return [nil, nil] if new_width > MAX_FILLER_MM

        return [{ neighbour: neighbour, need: growth, width: new_width, filler: true }, nil]
      end

      return [nil, nil] if CabinetLayout.corner?(stored) || new_width > ValidationManager::NUMERIC_FIELDS['width'][:max]

      params, errors = CabinetManager.send(:restyle_params, model, stored, 'width' => new_width)
      return [nil, nil] unless errors.empty?

      [{ neighbour: neighbour, need: growth, width: new_width, params: params }, nil]
    end

    # Resizes the neighbour and moves its start along by `need` (negative: back).
    # Call inside an operation.
    def self.apply(model, plan)
      neighbour = plan[:neighbour]
      moved = neighbour.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, plan[:need].mm, 0))
      if plan[:filler]
        PartManager.resize_filler(model, neighbour, plan[:width], moved)
      else
        params = plan[:params]
        params['cabinet_name'] = NamingManager.for_update(neighbour, params)
        CabinetGenerator.update(model, neighbour, params)
        neighbour.transformation = moved
        PartManager.follow_door(model, neighbour)
      end
    end

    # The item that follows `root` along its own Y axis, and the free gap (mm)
    # between them; nil when there is none.
    def self.next_in_row(root)
      dictionary = AttributeManager::DICTIONARY
      width = root.get_attribute(dictionary, 'width').to_f
      to_local = root.transformation.inverse

      found = root.parent.entities.grep(Sketchup::ComponentInstance).filter_map do |item|
        next if item.equal?(root)
        next unless AttributeManager.cabinet?(item) || AttributeManager.part_kind(item) == 'filler'

        relative = to_local * item.transformation
        along = relative.origin.y.to_mm
        aligned = relative.yaxis.y > 0.999 && relative.origin.x.to_mm.abs <= SAME_LINE_MM && relative.origin.z.to_mm.abs <= SAME_LINE_MM
        next unless aligned && along >= width - 1.0 && along - width <= MAX_GAP_MM

        [item, along - width]
      end
      found.min_by { |_item, gap| gap }
    end

    def self.too_narrow(neighbour, new_width, minimum)
      [nil, "#{neighbour.name} would have to be #{format('%g', [new_width, 0].max)} mm wide (the smallest is #{format('%g', minimum)} mm), so there is no room for that width."]
    end
    private_class_method :too_narrow
  end
end