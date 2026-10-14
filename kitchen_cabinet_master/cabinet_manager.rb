# frozen_string_literal: true

require 'fileutils'
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
      when 'delete' then delete(raw)
      when 'visibility' then set_visibility(raw)
      when 'toggle' then toggle_all
      when 'rotate' then rotate(raw)
      when 'apply_all' then apply_all(raw)
      when 'add_appliance' then MyAppliances.add(raw)
      when 'remove_appliance' then MyAppliances.remove(raw)
      when 'set_unit_sizes' then set_unit_sizes(raw)
      when 'reset_unit_sizes' then reset_unit_sizes(raw)
      when 'get_selection' then (SelectionManager.push_selection; Response.ok(''))
      when 'customize' then customize
      when 'apply_front_design' then apply_front_design(raw)
      when 'apply_glass_design' then apply_glass_design(raw)
      when 'save_to_catalog' then save_to_catalog(raw)
      when 'remove_from_catalog' then remove_from_catalog(raw)
      when 'add_handle' then add_handle(raw)
      when 'remove_handle' then remove_handle(raw)
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # ---- actions -------------------------------------------------------------

    def self.insert(raw)
      entry = raw.is_a?(Hash) ? CatalogManager.cabinet(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type']) : nil
      return insert_component(raw, entry) if entry && entry['component'] # a model from your own catalog
      params, failure = prepare(raw)
      return failure if failure

      model = Sketchup.active_model
      fit = entry && entry['loft'] ? PlacementManager.loft_fit(model) : nil # (a loft over a unit is as wide and as deep as it, and its doors line up with the unit's)
      if fit && fit['width'].positive? && fit['depth'].positive?
        params['width'] = fit['width']
        params['depth'] = fit['depth']
      end
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Cabinet') do
          clear_live_parts(model)
          params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
          params['sequence'] = AttributeManager.next_sequence(model)
          entities, transformation = PlacementManager.target_for_new(model, params)
          params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
          built = CabinetGenerator.build(model, entities, params, transformation)
          AttributeManager.write(built, 'loft_over' => fit['unit']) if fit # (the unit it is over: the next loft goes over the next one)
          fill_blind_gap(model, entities, built, params)
          WorktopManager.refresh(model) if params['sink'] || params['hob'] # an existing worktop gets its opening
          built
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

    # The side panels and wall fillers that follow the cabinets are taken away before a cabinet is put in the row, so that it stands against the
    # last one and not against its panel; they are placed again, at the new end of the row, when the action is done (see LiveParts.refresh).
    def self.clear_live_parts(model)
      PartManager.send(:remove_auto_panels, model) if LiveParts.side_panels?
    end
    private_class_method :clear_live_parts

    # Opens the Customize window for the selected cabinet.
    def self.customize
      model = Sketchup.active_model
      root = SelectionManager.selected_cabinet(model) || SelectionManager.selected_part(model)
      kinds = CustomizeManager::PART_KINDS
      return Response.fail('A model of your own has no parts to customize: it was drawn by you.') if root && AttributeManager.custom_model?(root)
      unless root && (AttributeManager.cabinet?(root) || kinds.include?(AttributeManager.part_kind(root)))
        return Response.fail('Select a cabinet, filler, side panel, toe kick or worktop in the model to customize it.')
      end

      CustomizeManager.open(root)
      Response.ok("Customize window opened for #{root.name}.")
    end
    private_class_method :customize

    # Keeps the selected cabinets in a catalog of your own, so they can be inserted again like any catalog cabinet.
    # The panel may send `catalog_name` and `cabinet_name`; without them a small box asks.
    def self.save_to_catalog(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      roots = selected_cabinets(model)
      return save_components(model, raw) if roots.empty? && model.selection.length.positive? # anything else you drew
      return Response.fail('Select what you want to keep in a catalog: a cabinet of this extension, or any group, component or geometry you drew.') if roots.empty?

      catalog_name = raw['catalog_name'].to_s.strip
      cabinet_name = raw['cabinet_name'].to_s.strip
      if catalog_name.empty? && defined?(UI) && UI.respond_to?(:inputbox)
        suggestion = roots.length == 1 ? suggested_name(roots.first) : ''
        fields = roots.length == 1 ? ['Catalog', 'Cabinet name'] : ['Catalog']
        answer = UI.inputbox(fields, [CatalogManager::DEFAULT_CUSTOM_NAME, suggestion].first(fields.length), 'Save to my catalog')
        return Response.fail('Nothing was saved.') unless answer

        catalog_name = answer[0].to_s.strip
        cabinet_name = answer[1].to_s.strip if roots.length == 1
      end

      saved = roots.map do |root|
        stored = AttributeManager.read(root)
        base = CatalogManager.cabinet(stored['catalog_id'], stored['cabinet_category'], stored['cabinet_type'])
        name = roots.length == 1 && !cabinet_name.empty? ? cabinet_name : suggested_name(root)
        ids = CatalogManager.save_custom(catalog_name, stored['cabinet_category'], CatalogManager.entry_from(stored, base, name))
        { 'catalog_id' => ids[0], 'cabinet_type' => ids[1], 'cabinet_category' => stored['cabinet_category'] }
      end
      Response.ok("#{saved.length} cabinet#{'s' if saved.length > 1} saved to the catalog \"#{catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name}\".",
                  saved.last.merge('catalogs' => CatalogManager.catalogs))
    end
    private_class_method :save_to_catalog

    # The front design chosen in the Models section goes on the selected cabinets (one, or several picked together); with nothing
    # selected, on every cabinet. Their doors and drawer fronts are redrawn in that design; nothing else about them changes.
    def self.apply_front_design(raw)
      raw = {} unless raw.is_a?(Hash)
      design = raw['front_design'].to_s
      return Response.fail('Choose one of the normal doors in the list.') unless FrontDesign.valid?(design)

      model = Sketchup.active_model
      cabinets = selected_cabinets(model)
      selected_only = !cabinets.empty?
      if cabinets.empty?
        return Response.fail('Select a cabinet to give it that normal door, or clear the selection to give it to every cabinet.') unless model.selection.empty?

        cabinets = model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
        return Response.ok('No cabinets in the model yet. New cabinets will use this normal door.') if cabinets.empty?
      end

      plans = []
      problems = []
      cabinets.each do |cabinet|
        stored = AttributeManager.read(cabinet)
        next if FrontDesign.clean(stored['front_design']) == design

        params, errors = restyle_params(model, stored, 'front_design' => design)
        errors.empty? ? plans << [cabinet, params] : problems << [cabinet, errors]
      end
      name = FrontDesign::DESIGNS.find { |item| item['id'] == design }['name']
      ids = cabinets.map { |cabinet| AttributeManager.cabinet_id(cabinet) }
      panels = following_end_panels(model, design, selected_only ? ids : nil)
      if plans.empty? && problems.empty? && panels.empty?
        return Response.ok("#{cabinets.length == 1 ? 'The cabinet already has' : 'They already have'} the normal door \"#{name}\".")
      end
      return Response.fail(problems.first[1].first['message'], problems.first[1]) if plans.empty? && panels.empty?

      SelectionManager.suspend do
        with_operation(model, 'Change Normal Door') do
          plans.each do |cabinet, params|
            params['cabinet_name'] = NamingManager.for_update(cabinet, params)
            CabinetGenerator.update(model, cabinet, params)
            PartManager.follow_door(model, cabinet)
          end
          panels.each do |panel, params|
            PartGenerator.update(model, panel, params, PartLayout.end_panel(params))
          end
        end
      end
      SelectionManager.push_selection(model)
      done = "Normal door \"#{name}\" on #{plans.length} cabinet#{'s' unless plans.length == 1}"
      done += " and #{panels.length} side panel#{'s' unless panels.length == 1}" unless panels.empty?
      Response.ok("#{done}.#{" #{problems.length} could not take it." unless problems.empty?}")
    end
    private_class_method :apply_front_design

    # The glass door chosen in the Models section goes on the selected cabinets (one, or several picked together); with nothing selected, on every
    # cabinet. Their doors become frames with panes of glass in them (the drawer fronts stay as they are); "None" takes the glass away.
    def self.apply_glass_design(raw)
      raw = {} unless raw.is_a?(Hash)
      design = FrontDesign.clean_glass(raw['glass_design'])
      return Response.fail('Choose one of the glass doors in the list.') unless raw['glass_design'].to_s.strip.empty? || !design.empty?

      model = Sketchup.active_model
      cabinets = selected_cabinets(model)
      if cabinets.empty?
        return Response.fail('Select a cabinet to give it that glass door, or clear the selection to give it to every cabinet.') unless model.selection.empty?

        cabinets = model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
        return Response.ok('No cabinets in the model yet. New cabinets will use this glass door.') if cabinets.empty?
      end

      plans = []
      problems = []
      cabinets.each do |cabinet|
        stored = AttributeManager.read(cabinet)
        next if stored['glass_design'].to_s == design

        params, errors = restyle_params(model, stored, 'glass_design' => design)
        errors.empty? ? plans << [cabinet, params] : problems << [cabinet, errors]
      end
      name = design.empty? ? 'no glass' : FrontDesign::GLASS_DESIGNS.find { |item| item['id'] == design }['name']
      if plans.empty?
        return Response.fail(problems.first[1].first['message'], problems.first[1]) unless problems.empty?

        return Response.ok("#{cabinets.length == 1 ? 'The cabinet already has' : 'They already have'} \"#{name}\".")
      end

      SelectionManager.suspend do
        with_operation(model, 'Change Glass Door') do
          plans.each do |cabinet, params|
            params['cabinet_name'] = NamingManager.for_update(cabinet, params)
            CabinetGenerator.update(model, cabinet, params)
            PartManager.follow_door(model, cabinet)
          end
        end
      end
      SelectionManager.push_selection(model)
      Response.ok("\"#{name}\" on #{plans.length} cabinet#{'s' unless plans.length == 1}.#{" #{problems.length} could not take it." unless problems.empty?}")
    end
    private_class_method :apply_glass_design

    # The side panels that are set to follow the front design (and are not in it yet): [[panel, new params], ...]. With `only` (the ids of
    # the cabinets that were changed) just the side panels standing against those; otherwise every one.
    def self.following_end_panels(model, design, only)
      model.entities.grep(Sketchup::ComponentInstance).filter_map do |part|
        next unless AttributeManager.part_kind(part) == 'end_panel'

        stored = AttributeManager.read(part)
        next unless stored['face'] == 'design' && FrontDesign.clean(stored['front_design']) != design
        next if only && !only.include?(stored['target_id'])

        [part, stored.merge('front_design' => design)]
      end
    end
    private_class_method :following_end_panels
    # Anything you drew in the model (a group, a component, loose geometry; one thing or several together) is kept as a
    # model file of its own in your catalog, and inserted again as a component beside the selected item. The catalog entry
    # has its size (width along X, depth along Y, height along Z). Several items together are grouped for the save only.
    def self.save_components(model, raw)
      catalog_name = raw['catalog_name'].to_s.strip
      name = raw['cabinet_name'].to_s.strip
      category = %w[base wall tall].include?(raw['cabinet_category'].to_s) ? raw['cabinet_category'].to_s : nil
      front = nil
      items = model.selection.to_a
      single = items.length == 1 && (items.first.is_a?(Sketchup::Group) || items.first.is_a?(Sketchup::ComponentInstance)) ? items.first : nil
      guess = guess_name(single)
      if name.empty? && defined?(UI) && UI.respond_to?(:inputbox)
        answer = UI.inputbox(['Catalog', 'Name', 'Kind', 'Door faces (as drawn)'], [catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name, guess, category || 'base', '+X'],
                             ['', '', 'base|wall|tall', '-Y|+X|+Y|-X'], 'Save to my catalog')
        return Response.fail('Nothing was saved.') unless answer

        catalog_name = answer[0].to_s.strip
        name = answer[1].to_s.strip
        category = answer[2].to_s
        front = answer[3].to_s
      end
      name = guess if name.empty?
      category ||= 'base'
      slug = CatalogManager.slug(catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name)
      file = File.join('models', "custom_#{slug}_#{CatalogManager.slug(name)}.skp")
      path = File.join(CatalogManager.user_dir.to_s, file)
      FileUtils.mkdir_p(File.dirname(path))
      size = write_model_file(model, items, single, path)
      return Response.fail('That could not be saved as a model file.') unless size && File.file?(path)

      entry = CatalogManager.component_entry(name, size, file, front || raw['front'])
      ids = CatalogManager.save_custom(catalog_name, category, entry)
      Response.ok("#{name} saved to the catalog \"#{catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name}\" as a model of #{size.map { |v| v.round }.join(' x ')} mm.",
                  { 'catalog_id' => ids[0], 'cabinet_type' => ids[1], 'cabinet_category' => category, 'catalogs' => CatalogManager.catalogs })
    end
    private_class_method :save_components

    def self.guess_name(single)
      label = single && (single.name.to_s.empty? ? single.definition.name.to_s : single.name.to_s)
      label.to_s.empty? ? 'My model' : label
    end
    private_class_method :guess_name

    # Writes the model file; returns [width, depth, height] in mm (its X, Y and Z extent) or nil.
    def self.write_model_file(model, items, single, path)
      if single
        definition = single.definition
        definition.save_as(path)
        return bounds_mm(definition.bounds)
      end

      size = nil
      model.start_operation('Save to catalog', true)
      begin
        group = model.active_entities.add_group(items)
        group.definition.save_as(path)
        size = bounds_mm(group.definition.bounds)
      ensure
        model.abort_operation # the model is left as it was
      end
      size
    end
    private_class_method :write_model_file

    def self.bounds_mm(bounds)
      [bounds.width, bounds.height, bounds.depth].map { |v| (v.to_mm * 10).round / 10.0 }
    end
    private_class_method :bounds_mm

    # Inserts a model from your catalog, in the row like a cabinet (beside the selected item). The model stands in a component of its own (the
    # "cabinet"): turned so that the side it was drawn with its door on faces +X and its width runs along +Y, with its back and its left end on the
    # origin of that component (measured, not worked out from the saved size), lifted by the toe kick height when it is a base or a tall unit. That
    # component carries a cabinet's attributes, so the rules of the extension (placement, snapping, worktop, toe kicks, side panels, naming, the
    # Update button, the Handle section, the materials) apply to it. Its handle is in that component too, on its +X face.
    def self.insert_component(raw, entry)
      path = CatalogManager.component_path(entry)
      return Response.fail('The model file of this catalog entry is missing.') unless path && File.file?(path)

      model = Sketchup.active_model
      size = [entry.dig('defaults', 'width'), entry.dig('defaults', 'depth'), entry.dig('defaults', 'height')].map(&:to_f)
      category = raw['cabinet_category'].to_s
      number = ->(key, fallback) { Float(raw[key].to_s.tr(',', '.'), exception: false) || fallback.to_f }
      toe = %w[base tall].include?(category) ? number.call('toe_kick_height', Defaults.params['toe_kick_height']) : 0.0
      params = Defaults.params.merge('width' => size[0], 'depth' => size[1], 'height' => size[2] + toe, 'cabinet_category' => category,
                                     'door_count' => 0, 'drawer_count' => 0, 'catalog_id' => raw['catalog_id'].to_s, 'cabinet_type' => raw['cabinet_type'].to_s, 'placement_gap' => number.call('placement_gap', 0.0))
      instance = nil
      with_operation(model, 'Insert Model') do
        clear_live_parts(model)
        definition = model.definitions.load(path)
        definition.entities.grep(Sketchup::ComponentInstance).select { |item| item.name == CUSTOM_HANDLE_NAME }.each(&:erase!) # (a handle left in the saved model: the cabinet gets its own, on its door)
        entities, target = PlacementManager.target_for_new(model, params)
        low = definition.bounds.min
        holder = AttributeManager.mark_managed(model.definitions.add(NamingManager.base_name(params.merge('width' => size[0]))))
        # turned so that its door (the side it was drawn with: front) faces +X and its width runs along +Y, as a cabinet of the extension's
        turned = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), CUSTOM_TURNS.fetch(CatalogManager.front_of(entry)) * Math::PI / 180.0) *
                 Geom::Transformation.translation(Geom::Vector3d.new(-low.x, -low.y, -low.z))
        inner = holder.entities.add_instance(definition, turned)
        corner = inner.bounds.min # (measured: its back and its left end go on the origin, whatever it was drawn like)
        inner.transform!(Geom::Transformation.translation(Geom::Vector3d.new(-corner.x, -corner.y, -corner.z + toe.mm)))
        inner.name = entry['name'].to_s
        depth, width, height = [inner.bounds.width, inner.bounds.height, inner.bounds.depth].map { |v| v.to_mm.round(2) }
        instance = entities.add_instance(holder, target)
        instance.name = NamingManager.base_name(params.merge('width' => width)) # (named like a cabinet of the extension: its kind and width, as B600)

        # The component is a cabinet as far as the rest of the extension can tell: its size (the carcass depth is what the front stands
        # in front of: door distance and door thickness are taken off so that a side panel or a filler comes flush with the front), its
        # place in the order of insertion, its kind and its toe kick height.
        reach = number.call('door_distance', Defaults.params['door_distance']) + number.call('material_thickness', Defaults.params['material_thickness'])
        stored = params.merge(
          'cabinet_id' => AttributeManager.next_cabinet_id(model), 'sequence' => AttributeManager.next_sequence(model), 'cabinet_name' => instance.name,
          'width' => width, 'depth' => [depth - reach, 50.0].max, 'height' => height, 'toe_kick_height' => toe, 'base_z' => toe, 'top_z' => (toe + height).round(2),
          'envelope_width' => width, 'envelope_depth' => depth, 'envelope_top' => (toe + height).round(2), 'custom_wrapper' => true,
          'custom_category' => category, 'custom_catalog' => raw['catalog_id'].to_s, 'custom_reach' => reach
        )
        AttributeManager.write(instance, stored)
        holder.name = NamingManager.definition_name(instance.name, stored['cabinet_id']) # (BU600 - 113)
        TagManager.assign(model, instance, TagManager.for_category(category))
        # its door (the thin wide piece on its front) takes the Door Reveal, Door Distance and Door Height Adjustment settings
        door = CustomDoor.detect(instance)
        if door
          instance.set_attribute(AttributeManager::DICTIONARY, 'custom_door', door[0].join(';'))
          instance.set_attribute(AttributeManager::DICTIONARY, 'custom_door_thickness', door[2].round(2))
          instance.set_attribute(AttributeManager::DICTIONARY, 'custom_carcass_front', (door[1] - number.call('door_distance', Defaults.params['door_distance'])).round(2))
          CustomDoor.apply(model, instance, number.call('door_reveal', Defaults.params['door_reveal']), number.call('door_distance', Defaults.params['door_distance']),
                           number.call('door_height_adjust', Defaults.params['door_height_adjust']))
        end
        # the material of its kind (Base, Wall or Tall material) from the Material section, and the handle from the Handle section
        paint_custom_model(model, instance, raw)
        settings = raw.slice(*CUSTOM_HANDLE_KEYS)
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_handle', JSON.generate(settings))
        sync_custom_handle(model, instance, settings)
        instance
      end
      SelectionManager.select(instance)
      Response.ok("#{entry['name']} inserted.")
    end
    private_class_method :insert_component

    # Adds a handle of your own to the Handle lists: what is selected in the model (a group, a component or geometry you drew as a handle), or,
    # when nothing is selected, a SketchUp model file you choose. Drawn as seen from the front of a door: the grip along the red axis (or the
    # blue one), the back of the handle on the high-Y side and the handle standing out towards low Y. It is kept as a handle package of
    # its own, with the finish "As drawn" (and the metal finishes for what you left unpainted).
    def self.add_handle(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      items = model.selection.to_a
      items = [] if items.any? { |item| AttributeManager.cabinet?(item) || AttributeManager.part?(item) } # (a cabinet is not a handle)
      from = ''
      return Response.fail('Select the handle you drew in the model first (a group or component), then press Save.') if items.empty?

      single = items.length == 1 && (items.first.is_a?(Sketchup::Group) || items.first.is_a?(Sketchup::ComponentInstance)) ? items.first : nil
      name = raw['handle_name'].to_s.strip
      guess = items.empty? ? File.basename(from, '.*').tr('_', ' ') : guess_name(single)
      if name.empty? && defined?(UI) && UI.respond_to?(:inputbox)
        answer = UI.inputbox(['Handle name'], [guess], 'Add my handle')
        return Response.fail('No handle was added.') unless answer

        name = answer[0].to_s.strip
      end
      name = guess if name.empty?
      file = File.join('models', "handle_#{CatalogManager.slug(name)}.skp")
      path = File.join(CatalogManager.user_dir.to_s, file)
      FileUtils.mkdir_p(File.dirname(path))
      size = items.empty? ? measure_model_file(model, from, path) : write_model_file(model, items, single, path)
      return Response.fail('That could not be kept as a handle.') unless size && File.file?(path)

      id = CatalogManager.save_custom_handle(CatalogManager.handle_from_model(name, size, file))
      Response.ok("#{name} added to the handles: #{size.map { |v| v.round(1) }.join(' x ')} mm. Choose it in Handle Bundle.", { 'handle_id' => id, 'handle_bundles' => CatalogManager.handle_bundles })
    end
    private_class_method :add_handle

    # Copies a model file into your folder and returns its size (X, Y, Z in mm).
    def self.measure_model_file(model, from, path)
      FileUtils.cp(from, path) unless File.expand_path(from) == File.expand_path(path)
      size = nil
      model.start_operation('Measure handle', true)
      begin
        size = bounds_mm(model.definitions.load(path).bounds)
      ensure
        model.abort_operation # the model is left as it was
      end
      size
    end
    private_class_method :measure_model_file

    def self.remove_handle(raw)
      raw = {} unless raw.is_a?(Hash)
      return Response.fail('Only a handle you added yourself can be removed.') unless CatalogManager.remove_custom_handle(raw['handle_id'])

      Response.ok('The handle was removed. Cabinets that have it need another one.', { 'handle_bundles' => CatalogManager.handle_bundles })
    end
    private_class_method :remove_handle

    CUSTOM_HANDLE_KEYS = HandleManager::MODEL_KEYS
    # How far a model is turned about the vertical so that the side it was drawn with its door on (-y, +x, +y, -x) faces +X.
    CUSTOM_TURNS = { '-y' => 90.0, '+x' => 0.0, '+y' => -90.0, '-x' => 180.0 }.freeze
    CUSTOM_HANDLE_NAME = 'Handle'

    # The handle settings a model of your own keeps.
    def self.custom_handle_settings(instance)
      text = instance.get_attribute(AttributeManager::DICTIONARY, 'custom_handle').to_s
      text.empty? ? {} : JSON.parse(text)
    rescue JSON::ParserError
      {}
    end
    private_class_method :custom_handle_settings

    # Puts the handle on the front of a model of your own (or takes it away when there is no handle package): in the component the model stands
    # in, on its +X face, by the rules of its kind (top of a base unit, bottom of a wall unit, hand height of a tall one). The door is as wide as
    # the cabinet and as high as the model; a handle longer than the door would be goes down to the longest length of its package that fits.
    def self.sync_custom_handle(model, instance, settings)
      dictionary = AttributeManager::DICTIONARY
      params, bundle = HandleManager.model_params(settings, instance.get_attribute(dictionary, 'custom_category'))
      find = -> { instance.definition.entities.grep(Sketchup::ComponentInstance).find { |item| item.name == CUSTOM_HANDLE_NAME } }
      if bundle.nil?
        find.call&.erase!
        return false
      end

      instance.make_unique if instance.definition.count_instances > 1 # (this cabinet's own handle, not every copy's)
      existing = find.call
      depth = instance.get_attribute(dictionary, 'envelope_depth').to_f
      width = instance.get_attribute(dictionary, 'width').to_f
      height = instance.get_attribute(dictionary, 'height').to_f
      lift = instance.get_attribute(dictionary, 'base_z').to_f
      across = 0.0
      if (door = CustomDoor.frame(instance)) # (the handle is on the door: its front, its left end and its bottom, its size)
        depth, across, lift, width, height = door
      end
      params['handle_length'] = fitting_handle_length(bundle, params['handle_length'], width)
      handle_settings = HandleManager.settings(params, bundle)
      spot = HandleManager.placement(HandleManager.model_door(width, height, params['door_opening_direction']), handle_settings, bundle)
      definition = HandleManager.definition(model, bundle, handle_settings['length'], spot['flip'] == true)
      transformation = Geom::Transformation.translation(Geom::Vector3d.new(depth.mm, across.mm, lift.mm)) * HandleManager.transformation(spot, 0.0)
      handle = existing || instance.definition.entities.add_instance(definition, transformation)
      handle.definition = definition unless handle.definition == definition
      handle.transformation = transformation
      handle.name = CUSTOM_HANDLE_NAME
      CabinetGenerator.paint_handle(model, handle, bundle, handle_settings)
      CabinetGenerator.apply_custom_visibility(instance, AttributeManager.read(instance).to_h)
      true
    end
    private_class_method :sync_custom_handle

    # The length of handle to use on a door `door` mm wide: the one asked for if it fits (with 40 mm to spare at each end), else the longest the
    # package offers that does, else its shortest.
    def self.fitting_handle_length(bundle, wanted, door)
      lengths = Array(bundle['lengths']).map(&:to_f).sort
      room = door - 80.0
      return wanted if wanted.to_f <= room || lengths.empty?

      lengths.select { |length| length <= room }.max || lengths.first
    end
    private_class_method :fitting_handle_length

    # The Handle section changed: keeps the new values with the model and puts its handle right.
    def self.refresh_custom_handle(model, instance, overrides)
      settings = custom_handle_settings(instance).merge(overrides.slice(*CUSTOM_HANDLE_KEYS))
      instance.set_attribute(AttributeManager::DICTIONARY, 'custom_handle', JSON.generate(settings))
      sync_custom_handle(model, instance, settings)
    end
    private_class_method :refresh_custom_handle

    CUSTOM_MATERIAL_KEYS = %w[base_material wall_material tall_material].freeze

    # The models of your own that were inserted from a catalog.
    def self.custom_models(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.custom_model?(instance) }
    end
    private_class_method :custom_models

    # Paints a model of your own with the material of its kind (raw has base_material, wall_material, tall_material). True if it was painted.
    def self.paint_custom_model(model, instance, raw)
      category = instance.get_attribute(AttributeManager::DICTIONARY, 'custom_category').to_s
      name = raw["#{category}_material"].to_s.strip
      return false if name.empty? || !MaterialManager.available?(model, name)

      MaterialManager.apply(instance, name, model)
    end
    private_class_method :paint_custom_model
    def self.remove_from_catalog(raw)
      raw = {} unless raw.is_a?(Hash)
      removed = CatalogManager.remove_custom(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type'])
      return Response.fail('Only a cabinet in one of your own catalogs can be removed.') unless removed

      Response.ok('Removed from the catalog. Cabinets already in the model stay as they are.', { 'catalogs' => CatalogManager.catalogs })
    end
    private_class_method :remove_from_catalog

    # The cabinets selected in the model (one, or several picked together).
    # Cabinets inside a selected group or component (a row you grouped, a copy of a kitchen) count too.
    def self.selected_cabinets(model)
      list = []
      model.selection.each { |item| collect_cabinets(item, list, 0) }
      list = [SelectionManager.selected_cabinet(model)].compact if list.empty?
      if list.empty?
        path = model.active_path
        path&.reverse_each { |item| (list << item) if AttributeManager.cabinet?(item) }
      end
      list.uniq
    end
    private_class_method :selected_cabinets

    def self.collect_cabinets(item, list, depth)
      if AttributeManager.cabinet?(item)
        list << item
      elsif depth < 4 && (item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance))
        definition = item.respond_to?(:definition) ? item.definition : nil
        entities = item.respond_to?(:entities) ? item.entities : definition&.entities
        entities&.each { |child| collect_cabinets(child, list, depth + 1) }
      end
    end
    private_class_method :collect_cabinets

    def self.suggested_name(root)
      stored = AttributeManager.read(root)
      base = CatalogManager.cabinet(stored['catalog_id'], stored['cabinet_category'], stored['cabinet_type'])
      label = (base && base['name']) || root.name
      "#{label} #{fmt(stored['width'].to_f)} x #{fmt(stored['height'].to_f)}"
    end
    private_class_method :suggested_name

    # A cabinet placed after a blind corner stands 50 mm off the blind panel: that gap gets a filler (as tall as the
    # cabinet, flush with its doors). The filler is made after the cabinet and, when it comes first in the row, the
    # cabinet is renumbered after it so the next cabinet still carries on from the cabinet.
    def self.fill_blind_gap(model, entities, root, params)
      gap = PlacementManager.blind_gap
      return unless gap

      width = PlacementManager::BLIND_CLEARANCE_MM
      PartManager.add_filler_beside(model, entities, root, gap == :before ? -width : params['width'].to_f, width)
      AttributeManager.write(root, 'sequence' => AttributeManager.next_sequence(model)) if gap == :before
    end
    private_class_method :fill_blind_gap

    # The Update button: every selected cabinet takes the values of the panel (one Undo step for the lot).
    def self.update(raw)
      model = Sketchup.active_model
      roots = selected_cabinets(model)
      return Response.fail('Select a cabinet in the model to update.') if roots.empty?
      return update_one(model, roots.first, raw) if roots.length == 1

      done = 0
      problems = []
      @batch = true
      model.start_operation('Update Cabinets', true)
      begin
        roots.each do |root|
          answer = update_one(model, root, raw)
          answer['ok'] ? done += 1 : problems << "#{root.name}: #{answer['message']}"
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @batch = false
      end
      SelectionManager.push_selection(model)
      return Response.fail(problems.first) if done.zero?

      Response.ok("#{done} cabinets updated.#{" #{problems.length} could not take the values (#{problems.first(2).join('; ')})." unless problems.empty?}")
    end
    private_class_method :update

    def self.update_one(model, root, raw)
      fields_only = raw.is_a?(Hash) && raw['fields_only'] == true && raw['fields'].is_a?(Hash) # (the panel does not follow the selection: only the field that was edited)
      return update_custom(model, root, fields_only ? raw['fields'].transform_keys(&:to_s) : raw) if AttributeManager.custom_model?(root)

      if fields_only
        params, errors = restyle_params(model, AttributeManager.read(root), raw['fields'].transform_keys(&:to_s))
        return Response.fail(errors.first['message'], errors) unless params
      else
        params, failure = prepare(raw)
        return failure if failure
      end

      # What was changed in the Customize window stays through an Update.
      params['custom_overrides'] = ValidationManager.clean_overrides(AttributeManager.read(root)['custom_overrides'])

      # A wider cabinet takes its space from the one next to it in the row, which
      # gets narrower (see RowResizer). Anything else it would run into refuses the edit.
      dictionary = AttributeManager::DICTIONARY
      growth = params['width'] - root.get_attribute(dictionary, 'width').to_f
      squeeze = nil
      resize = !raw.is_a?(Hash) || raw['resize_neighbours'] != false # (the Presets switch: the next cabinet gives or takes the room)
      if growth.abs > 0.01 && resize
        squeeze, problem = RowResizer.plan(model, root, growth)
        return Response.fail(problem) if problem
      end

      # A wall unit hangs by its top: when it gets taller it grows DOWNWARDS (and a
      # shorter one rises), so its top stays level with the tall units beside it.
      placed = root.transformation
      loft = root.get_attribute(dictionary, 'cabinet_type').to_s.start_with?('wall_loft') # (a loft keeps its bottom and grows upwards, towards the ceiling)
      if params['cabinet_category'] == 'wall' && root.get_attribute(dictionary, 'cabinet_category') == 'wall' && !loft
        taller = params['height'] - root.get_attribute(dictionary, 'height').to_f
        placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, -taller.mm)) * placed if taller.abs > 0.01
      end

      old_size = %w[envelope_depth envelope_width envelope_top].map { |key| root.get_attribute(dictionary, key).to_f }
      old_top = params['cabinet_category'] == 'tall' && root.get_attribute(dictionary, 'cabinet_category') == 'tall' ? PlacementManager.send(:top_of_item, root) : nil # (the wall units level with it go with it)
      lofts = params['cabinet_category'] == 'tall' ? PlacementManager.lofts(model) : [] # (a loft over a tall unit gives or takes the height the unit gets or loses: it is no obstacle)
      if old_top && !lofts.empty?
        rise = (root.transformation.origin.z.to_mm + params['toe_kick_height'].to_f + params['height'].to_f) - old_top
        over = lofts.select { |item| (item.transformation.origin.z.to_mm - old_top).abs < 1.0 } # (the lofts that stand on it)
        limit = over.map { |item| item.transformation.origin.z.to_mm + item.get_attribute(dictionary, 'top_z').to_f }.min
        if rise > 0.01 && limit && old_top + rise > limit - PlacementManager::LOFT_MIN_MM
          return Response.fail("The loft above would be lower than #{format('%g', PlacementManager::LOFT_MIN_MM)} mm. The unit can be #{format('%g', [(limit - PlacementManager::LOFT_MIN_MM - old_top).round(1), 0.0].max)} mm taller at most.")
        end
      end
      same_footprint = loft && (params['width'] - root.get_attribute(dictionary, 'width').to_f).abs < 0.01 && (params['depth'] - root.get_attribute(dictionary, 'depth').to_f).abs < 0.01
      if !same_footprint && PlacementManager.crowds?(root.parent.entities, root, placed, CabinetLayout.envelope(params), old_size, # (a loft that only gets taller has nothing in its way: the ceiling is its limit)
                                  also: [squeeze && squeeze[:neighbour], *lofts])
        return Response.fail('That size would make the cabinet overlap the item next to it. Make it smaller, or move the neighbour first.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Update Cabinet') do
          params['cabinet_name'] = NamingManager.for_update(root, params)
          CabinetGenerator.update(model, root, params)
          root.transformation = placed unless placed.equal?(root.transformation)
          WorktopManager.refresh(model) if params['sink'] || params['hob'] # its opening in the worktop follows
          RowResizer.apply(model, squeeze) if squeeze
          follow_tall(model, root, old_top) if old_top
          PartManager.send(:align_lofts, model) if old_top # (the lofts go up or down with the tall unit)
          # Its filler, side panels and toe kicks follow its door material.
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

    # A tall unit that got taller (or shorter): the wall units whose tops were level with its top rise (or fall) with it. Inside an operation.
    def self.follow_tall(model, tall, old_top)
      delta = PlacementManager.send(:top_of_item, tall) - old_top
      return if delta.abs < 0.01

      up = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta.mm))
      model.entities.grep(Sketchup::ComponentInstance).each do |item|
        next unless AttributeManager.cabinet?(item) && AttributeManager.read(item)['cabinet_category'] == 'wall'
        next unless (PlacementManager.send(:top_of_item, item) - old_top).abs < 1.0

        item.transformation = up * item.transformation
      end
    end
    private_class_method :follow_tall
    private_class_method :update_one

    # "Reset Unit Sizes": the selected units (every unit when none is selected) go back to the standard size of their own catalog entry. A loft is as wide
    # as the unit it is over (its depth is the common one again, see PlacementManager.loft_depth). Corner units and models of your own are left alone.
    def self.reset_unit_sizes(raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      picked = selected_cabinets(model)
      targets = picked.empty? ? model.active_entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.cabinet?(item) } : picked
      targets = targets.reject { |item| AttributeManager.custom_model?(item) || Defaults.corner?(AttributeManager.read(item)) }
      targets = targets.sort_by { |item| AttributeManager.read(item)['sequence'].to_i }
      return Response.ok('No units to put back to the standard sizes.') if targets.empty?

      resize = raw['resize_neighbours'] != false
      done = 0
      problems = []
      @batch = true
      model.start_operation('Reset Unit Sizes', true)
      begin
        model.set_attribute(AttributeManager::DICTIONARY, 'loft_depth', 0.0) # (the lofts have the common depth again)
        targets.each do |root|
          stored = AttributeManager.read(root)
          loft = stored['cabinet_type'].to_s.start_with?('wall_loft')
          entry = CatalogManager.cabinet(stored['catalog_id'], loft ? 'loft' : stored['cabinet_category'], stored['cabinet_type'])
          defaults = entry && entry['defaults']
          next unless defaults

          fields = { 'width' => defaults['width'], 'depth' => defaults['depth'], 'height' => defaults['height'] }
          if loft
            fields.delete('depth')
            unit = model.active_entities.grep(Sketchup::ComponentInstance).find { |item| AttributeManager.cabinet?(item) && AttributeManager.cabinet_id(item) == stored['loft_over'].to_s }
            fields['width'] = AttributeManager.read(unit)['width'] if unit
          end
          answer = update_one(model, root, { 'fields_only' => true, 'fields' => fields.compact, 'resize_neighbours' => resize })
          answer['ok'] ? done += 1 : problems << "#{root.name}: #{answer['message']}"
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @batch = false
      end
      SelectionManager.push_selection(model)
      return Response.fail(problems.first) if done.zero? && !problems.empty?

      message = "#{done} unit#{'s' unless done == 1} back to the standard size."
      message += " #{problems.length} could not (#{problems.first(2).join('; ')})." unless problems.empty?
      Response.ok(message)
    end
    private_class_method :reset_unit_sizes

    UNIT_SIZE_KEYS = %w[width depth height].freeze

    # The Unit Sizes of the Presets: a width, depth or height for the base, wall or tall units. It goes to the selected units of that kind, or, with
    # none selected, to every unit of that kind in the model (corner units keep their own sizes). One Undo step. Only what was typed is sent.
    def self.set_unit_sizes(raw)
      raw = {} unless raw.is_a?(Hash)
      category = raw['category'].to_s
      return Response.fail('Unknown kind of unit.') unless %w[base wall tall loft].include?(category)

      given = raw['fields'].is_a?(Hash) ? raw['fields'].transform_keys(&:to_s) : {}
      fields = UNIT_SIZE_KEYS.to_h { |key| [key, given[key].to_s.strip] }.reject { |_, value| value.empty? }
      return Response.fail('Type a width, a depth or a height.') if fields.empty?

      model = Sketchup.active_model
      kind = lambda do |item|
        stored = AttributeManager.read(item)
        stored['cabinet_type'].to_s.start_with?('wall_loft') ? 'loft' : (stored['cabinet_category'] || stored['custom_category']).to_s # (a loft is a wall unit of its own)
      end
      picked = selected_cabinets(model)
      if picked.empty?
        targets = model.active_entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.cabinet?(item) && kind.call(item) == category }
      else
        targets = picked.select { |item| kind.call(item) == category }
        return Response.fail("Select a #{category} unit to change its size here: what is selected is not one.") if targets.empty?
      end
      targets = targets.reject { |item| Defaults.corner?(AttributeManager.read(item)) }.sort_by { |item| AttributeManager.read(item)['sequence'].to_i }
      return Response.ok("No #{category} units (other than corner units) to change.") if targets.empty?

      resize = raw['resize_neighbours'] != false
      done = 0
      problems = []
      @batch = true
      model.start_operation('Unit Sizes', true)
      begin
        model.set_attribute(AttributeManager::DICTIONARY, 'loft_depth', fields['depth'].to_f) if category == 'loft' && fields['depth'] # (the lofts keep this depth)
        targets.each do |root|
          answer = update_one(model, root, { 'fields_only' => true, 'fields' => fields, 'resize_neighbours' => resize })
          answer['ok'] ? done += 1 : problems << "#{root.name}: #{answer['message']}"
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @batch = false
      end
      SelectionManager.push_selection(model)
      return Response.fail(problems.first) if done.zero?

      message = "#{done} #{category} unit#{'s' unless done == 1} changed (#{fields.map { |key, value| "#{key} #{value}" }.join(', ')} mm)."
      message += " #{problems.length} could not take it (#{problems.first(2).join('; ')})." unless problems.empty?
      Response.ok(message)
    end
    private_class_method :set_unit_sizes

    # One cabinet changed with the fields given, inside an operation that is already open (the refresh of the live parts).
    def self.update_quiet(model, root, fields)
      previous = @batch
      @batch = true
      update_one(model, root, { 'fields_only' => true, 'fields' => fields, 'resize_neighbours' => false })
    ensure
      @batch = previous
    end

    # ---- settings that belong to every cabinet -------------------------------------

    GLOBAL_NUMBERS = %w[door_gap door_reveal door_distance front_radius material_thickness back_thickness toe_kick_height carcass_raise door_height_adjust finger_gap finger_gap_drawer door_opening_angle
                      handle_length handle_side_offset handle_vertical_offset handle_custom_x handle_custom_z].freeze
    GLOBAL_FLAGS = %w[finger_all].freeze # ticks (true / false)
    GLOBAL_MATERIALS = %w[base_material wall_material tall_material carcass_material top_panel_style
                          handle_id handle_finish handle_material handle_orientation handle_position handle_horizontal_place door_opening_direction glass_material drawer_handle_id].freeze

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
      GLOBAL_FLAGS.each { |key| overrides[key] = ValidationManager.truthy_value?(raw[key]) if raw.key?(key) }

      model = Sketchup.active_model
      # A material picked in the Material section also goes on the models of your own: on the selected ones alone when some are selected
      # (and no cabinet), otherwise on all of them.
      painted = 0
      handle_changed = (overrides.keys & CUSTOM_HANDLE_KEYS).any?
      if (overrides.keys & CUSTOM_MATERIAL_KEYS).any? || handle_changed
        chosen = custom_models(model)
        picked = chosen.select { |item| model.selection.include?(item) }
        only_these = picked.any? && selected_cabinets(model).reject { |item| AttributeManager.custom_model?(item) }.empty?
        chosen = picked if only_these
        unless chosen.empty?
          with_operation(model, 'Apply Settings To My Models') do
            chosen.each do |item|
              done = paint_custom_model(model, item, overrides)
              done = true if handle_changed && refresh_custom_handle(model, item, overrides)
              painted += 1 if done
            end
          end
        end
        return Response.ok("#{painted} of your own model#{'s' unless painted == 1} painted.") if only_these
      end
      cabinets = model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
      chosen_cabinets = selected_cabinets(model) # (several picked together get the settings alone; none picked: every cabinet)
      cabinets = chosen_cabinets unless chosen_cabinets.empty?
      customs = cabinets.select { |item| AttributeManager.custom_model?(item) } # (models of your own: their handle and material are done above; a toe kick height lifts them below)
      if cabinets.empty?
        return Response.ok(painted.positive? ? "#{painted} of your own model#{'s' unless painted == 1} painted." : 'No cabinets in the model yet. New cabinets will use these settings.')
      end

      plans = []
      problems = []
      cabinets.each do |cabinet|
        next if customs.include?(cabinet)

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
      lifting = overrides.key?('toe_kick_height')
      doors = (overrides.keys & CustomDoor::KEYS).any? ? customs : []
      unless doors.empty? # (the door of a model of your own takes the door settings, and its handle follows it)
        with_operation(model, 'Apply Door Settings To My Models') do
          doors.each do |root|
            stored = AttributeManager.read(root)
            pick = ->(key) { ValidationManager.to_float(overrides[key]) || stored[key].to_f }
            CustomDoor.apply(model, root, pick.call('door_reveal'), pick.call('door_distance'), pick.call('door_height_adjust'))
            sync_custom_handle(model, root, custom_handle_settings(root))
          end
        end
      end
      return Response.ok(doors.empty? ? 'Every cabinet already has these settings.' : "#{doors.length} of your own model#{'s' unless doors.length == 1} updated.") if plans.empty? && !(lifting && customs.any?)

      # A higher toe kick lifts every cabinet standing on it: they are rebuilt with the new
      # height, and what is attached to them (fillers, side panels, the worktop) goes up too.
      before = lifted_from(cabinets)
      SelectionManager.suspend do
        with_operation(model, 'Apply Settings To All Cabinets') do
          plans.each do |cabinet, params|
            params['cabinet_name'] = NamingManager.for_update(cabinet, params)
            CabinetGenerator.update(model, cabinet, params)
            PartManager.follow_door(model, cabinet)
          end
          if lifting
            lift_custom_models(model, customs, ValidationManager.to_float(overrides['toe_kick_height']))
            PartManager.lift_attached(model, before, ValidationManager.to_float(overrides['toe_kick_height']))
            WorktopManager.refresh(model)
          end
          WallBottomManager.refresh(model) if defined?(WallBottomManager)
        end
      end
      SelectionManager.push_selection(model)

      done = "#{plans.length + (lifting ? customs.length : 0)} cabinet#{'s' unless plans.length + (lifting ? customs.length : 0) == 1} updated."
      return Response.ok(done) if problems.empty?

      skipped = problems.map { |cabinet, errors| "#{cabinet.name}: #{errors.first['message']}" }
      Response.ok("#{done} #{problems.length} could not take the new value and #{problems.length == 1 ? 'was' : 'were'} " \
                  "left as #{problems.length == 1 ? 'it was' : 'they were'} (#{skipped.first(2).join('; ')}).")
    end
    private_class_method :apply_all

    # A new toe kick height lifts the models of your own that stand on one (a base or a tall unit): the model moves up inside its component, and its
    # handle with it. Inside an operation.
    def self.lift_custom_models(model, roots, toe)
      return if toe.nil?

      roots.each do |root|
        stored = AttributeManager.read(root)
        next unless %w[base tall].include?(stored['cabinet_category'].to_s)

        delta = toe - stored['base_z'].to_f
        next if delta.abs < 0.01

        inner = root.definition.entities.grep(Sketchup::ComponentInstance).find { |item| item.name != CUSTOM_HANDLE_NAME }
        next unless inner

        inner.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta.mm)))
        top = (toe + stored['height'].to_f).round(2)
        AttributeManager.write(root, 'toe_kick_height' => toe, 'base_z' => toe, 'top_z' => top, 'envelope_top' => top)
        sync_custom_handle(model, root, custom_handle_settings(root))
      end
    end
    private_class_method :lift_custom_models

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
        next false if %w[finger_gap finger_gap_drawer finger_all].include?(key) && stored['finger_pull'] != true # only the model without handles has a finger gap
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

    # Turns the selected cabinet (or filler, side panel or toe kick) about a vertical
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
      visibility = %w[carcass door toe_kick appliances oven microwave sink hob hood free_fridge].to_h { |key| [key, on.call(raw[key])] }
      show_floor_symbol = on.call(raw['opening_direction'])
      show_door_symbol = on.call(raw['door_symbol'])
      show_wall_symbol = on.call(raw['wall_opening_direction'])
      hide_wall_handles = on.call(raw['hide_wall_handles'])
      show_names = on.call(raw['show_cabinet_names'])
      hide_base_handles = on.call(raw['hide_base_handles'])
      hide_tall_handles = on.call(raw['hide_tall_handles'])
      hide_loft_handles = on.call(raw['hide_loft_handles'])

      model = Sketchup.active_model
      instances = model.entities.grep(Sketchup::ComponentInstance)
      cabinets = instances.select { |instance| AttributeManager.cabinet?(instance) }
      toe_kicks = instances.select { |instance| AttributeManager.part_kind(instance) == 'toe_kick' }
      worktops = WorktopManager.pieces_in(model)
      # With something selected the ticks are for that item alone (its own cabinet, or the toe kick); with nothing selected, for all.
      picked = selected_cabinets(model) # one, or several picked together
      picked_kicks = toe_kicks.select { |item| model.selection.include?(item) }
      only = on.call(raw['selected_only']) || !picked.empty? || !picked_kicks.empty?
      if only
        cabinets = picked
        toe_kicks = picked_kicks
      end
      if cabinets.empty? && toe_kicks.empty? && worktops.empty?
        return Response.ok('No cabinets in the model yet. New cabinets will use these settings.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Change Cabinet Visibility') do
          # The worktop and its back splash (kept on the model, so pieces built later follow the ticks).
          show_worktop = raw.key?('worktop') && !only ? on.call(raw['worktop']) : WorktopManager.shown?(model, 'worktop')
          show_splash = raw.key?('backsplash') && !only ? on.call(raw['backsplash']) : WorktopManager.shown?(model, 'backsplash')
          WorktopManager.set_shown(model, show_worktop, show_splash)
          model.set_attribute(AttributeManager::DICTIONARY, 'hide_loft_handles', hide_loft_handles) unless only # (the lofts the Loft switch places follow it)
          cabinets.each do |cabinet|
            AttributeManager.write(cabinet, 'visibility_settings' => visibility,
                                            'show_opening_direction' => show_floor_symbol,
                                            'show_door_symbol' => show_door_symbol,
                                            'show_wall_opening_direction' => show_wall_symbol,
                                            'hide_wall_handles' => hide_wall_handles,
                                            'hide_base_handles' => hide_base_handles,
                                            'hide_tall_handles' => hide_tall_handles,
                                            'hide_loft_handles' => hide_loft_handles,
                                            'show_cabinet_names' => show_names)
            CabinetGenerator.apply_visibility(cabinet, visibility, show_floor_symbol, show_door_symbol, show_wall_symbol, hide_wall_handles,
                                              hide_base_handles, hide_tall_handles, hide_loft_handles)
            CabinetGenerator.sync_name_label_for(model, cabinet)
          end
          # The toe kicks are separate entities: the Toe Kick tick shows or hides them.
          toe_kicks.each { |toe_kick| toe_kick.visible = visibility['toe_kick'] }
        end
      end

      return Response.ok('Nothing of this extension is selected: select a cabinet, or clear the selection to change every cabinet.') if only && cabinets.empty? && toe_kicks.empty?

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
      sources = selected_cabinets(model).sort_by { |item| item.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i }
      return Response.fail('Select a cabinet in the model to duplicate.') if sources.empty?

      copies = SelectionManager.suspend do
        with_operation(model, sources.length == 1 ? 'Duplicate Cabinet' : 'Duplicate Cabinets') do
          clear_live_parts(model)
          model.selection.clear if sources.length > 1 # (the copies follow the end of the row, one after the other)
          sources.map { |source| copy_of(model, source) }
        end
      end

      if copies.length == 1
        SelectionManager.select(copies.first)
        return Response.ok("#{copies.first.name} created as a copy of #{sources.first.name}.", { 'cabinet_id' => AttributeManager.cabinet_id(copies.first), 'cabinet_name' => copies.first.name })
      end

      model.selection.clear
      copies.each { |copy| model.selection.add(copy) }
      SelectionManager.push_selection(model)
      Response.ok("#{copies.length} cabinets created as copies of the selected ones.")
    end
    private_class_method :duplicate

    # One cabinet copied exactly as it is stored (unsaved edits in the panel are not used; that is what Insert is for): a new id, and placed after the
    # one it follows with the same rule as Insert. Inside an operation. A model of your own is the same component again.
    def self.copy_of(model, source)
      stored = AttributeManager.read(source)
      params = Defaults.params.merge(stored)
      params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
      params['sequence'] = AttributeManager.next_sequence(model)
      entities, transformation = PlacementManager.target_for_new(model, params)
      if AttributeManager.custom_model?(source)
        made = entities.add_instance(source.definition, transformation)
        made.name = source.name
        AttributeManager.write(made, stored.merge('cabinet_id' => params['cabinet_id'], 'sequence' => params['sequence']))
        TagManager.assign(model, made, TagManager.for_category(params['cabinet_category']))
        return made
      end

      params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
      built = CabinetGenerator.build(model, entities, params, transformation)
      fill_blind_gap(model, entities, built, params)
      built
    end
    private_class_method :copy_of


    # The Update button on a model of your own: its size (the model is scaled to it), its toe kick height, its handle and its material follow
    # the panel, as a cabinet's do. The doors of such a model are its own, so the door settings (gap, reveal, door height ...) have nothing to act on.
    def self.update_custom(model, root, raw)
      raw = {} unless raw.is_a?(Hash)
      dictionary = AttributeManager::DICTIONARY
      inner = root.definition.entities.grep(Sketchup::ComponentInstance).find { |item| item.name != CUSTOM_HANDLE_NAME }
      return Response.fail("#{root.name} has no model inside to resize.") unless inner

      stored = AttributeManager.read(root)
      value = ->(key) { ValidationManager.to_float(raw[key]) }
      reach = stored['custom_reach'].to_f
      category = stored['cabinet_category'].to_s
      door = !stored['custom_door'].to_s.empty? # (with a door the Depth field is the depth of the carcass: where the door's distance is measured from)
      old = { depth: door ? stored['custom_carcass_front'].to_f : stored['envelope_depth'].to_f, width: stored['width'].to_f, height: stored['height'].to_f, toe: stored['base_z'].to_f }
      fresh = {
        depth: value.call('depth') ? value.call('depth') + (door ? 0.0 : reach) : old[:depth],
        width: value.call('width') || old[:width],
        height: value.call('height') || old[:height],
        toe: %w[base tall].include?(category) ? (value.call('toe_kick_height') || old[:toe]) : 0.0
      }
      return Response.fail('The size of the cabinet must be between 50 and 3000 mm.') unless %i[depth width height].all? { |key| fresh[key].between?(50.0, 3000.0) && old[key] > 0.0 }
      return Response.fail('The toe kick height must be between 0 and 400 mm.') unless fresh[:toe].between?(0.0, 400.0)

      placed = root.transformation
      grew = fresh[:height] - old[:height]
      placed = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, -grew.mm)) * placed if category == 'wall' && grew.abs > 0.01 # (a wall unit hangs by its top)
      beyond = door ? stored['envelope_depth'].to_f - old[:depth] : 0.0 # (what the door adds in front of the carcass)
      old_size = [old[:depth] + beyond, old[:width], old[:toe] + old[:height]]
      new_size = [fresh[:depth] + beyond, fresh[:width], fresh[:toe] + fresh[:height]]
      if old_size != new_size && PlacementManager.crowds?(root.parent.entities, root, placed, new_size, old_size)
        return Response.fail('That size would make the cabinet overlap the item next to it. Make it smaller, or move the neighbour first.')
      end

      SelectionManager.suspend do
        with_operation(model, 'Update Cabinet') do
          corner = inner.bounds.min
          scale = Geom::Transformation.scaling(corner, fresh[:depth] / old[:depth], fresh[:width] / old[:width], fresh[:height] / old[:height])
          inner.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, (fresh[:toe] - old[:toe]).mm)) * scale)
          name = NamingManager.base_name(stored.merge('width' => fresh[:width]))
          AttributeManager.write(root, 'cabinet_name' => name, 'width' => fresh[:width], 'depth' => door ? fresh[:depth] : [fresh[:depth] - reach, 50.0].max, 'height' => fresh[:height],
                                       'toe_kick_height' => fresh[:toe], 'base_z' => fresh[:toe], 'top_z' => (fresh[:toe] + fresh[:height]).round(2),
                                       'envelope_width' => fresh[:width], 'envelope_depth' => fresh[:depth] + beyond, 'envelope_top' => (fresh[:toe] + fresh[:height]).round(2))
          root.name = name
          root.set_attribute(dictionary, 'custom_carcass_front', fresh[:depth]) if door
          root.transformation = placed unless placed.equal?(root.transformation)
          settings = %w[door_reveal door_distance door_height_adjust].map { |key| [key, value.call(key) || stored[key].to_f] }.to_h
          CustomDoor.apply(model, root, settings['door_reveal'], settings['door_distance'], settings['door_height_adjust'])
          paint_custom_model(model, root, raw)
          refresh_custom_handle(model, root, raw)
          PartManager.follow_door(model, root)
          WallBottomManager.refresh(model) if defined?(WallBottomManager)
        end
      end
      SelectionManager.push_selection(model)
      Response.ok("#{root.name} updated. Base Z #{fmt(fresh[:toe])} mm, top Z #{fmt(fresh[:toe] + fresh[:height])} mm.")
    end
    private_class_method :update_custom


    # The Delete button: whatever is selected in the model: the cabinets, the parts (filler, side panel, toe kick, worktop or bottom panel piece)
    # and anything else (a group, a component, loose geometry). With nothing selected and the Category on Wall Bottom Panel it takes the bottom
    # panels away.
    def self.delete(raw = nil)
      model = Sketchup.active_model
      roots = selected_cabinets(model)
      parts = model.selection.select { |item| AttributeManager.part?(item) }
      others = model.selection.to_a.reject { |item| parts.any? { |part| part.equal?(item) } || roots.any? { |root| root.equal?(item) } }
      if roots.empty? && parts.empty? && others.empty?
        return WallBottomManager.perform('remove_wall_bottom', {}) if raw.is_a?(Hash) && raw['when_empty'] == 'remove_wall_bottom'

        return Response.fail('Select something in the model to delete.')
      end

      count = roots.length + parts.length + others.length
      first = roots.first || parts.first || others.first
      name = first.respond_to?(:name) ? first.name.to_s : ''
      label = count == 1 ? (name.empty? ? 'It' : name) : "#{count} items"
      LiveParts.dismiss_parts(model, parts + roots) # (what a Settings switch made and is deleted stays deleted)
      SelectionManager.suspend do
        with_operation(model, count == 1 ? 'Delete Cabinet' : 'Delete Selected') do
          parts.each { |part| PartGenerator.remove(model, part) if part.valid? }
          roots.each { |root| CabinetGenerator.remove(model, root) if root.valid? }
          others.each { |item| item.erase! if item.valid? }
        end
      end

      SelectionManager.push_selection(model)
      Response.ok("#{label} deleted. Use Edit > Undo to bring #{count == 1 ? 'it' : 'them'} back.")
    end
    private_class_method :delete

    # Toggle: with a cabinet selected, only THAT cabinet's doors and drawers; with
    # nothing selected, every cabinet in the model (the top level of the model,
    # like Visibility). If any of them is open they all close; otherwise they all
    # open. The animation runs as one undoable step.
    def self.toggle_all
      model = Sketchup.active_model
      selected = selected_cabinets(model) # one, or several picked together
      cabinets = if selected.any?
                   selected
                 else
                   model.entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.cabinet?(instance) }
                 end
      return Response.fail('There are no cabinets in the model yet.') if cabinets.empty?

      openables = cabinets.to_h { |cabinet| [cabinet, CabinetGenerator.openables_of(cabinet)] }
      return Response.fail(selected.length == 1 ? "#{selected.first.name} has no doors or drawers." : 'None of the selected cabinets has doors or drawers.') if selected.any? && openables.values.all?(&:empty?)
      return Response.fail('None of the cabinets has doors or drawers.') if openables.values.all?(&:empty?)

      opening = openables.values.flatten.none? { |door| DoorAnimation.open?(door) }
      moves = openables.flat_map { |cabinet, doors| moves_for(cabinet, doors, opening) }
      return Response.ok('Nothing to do: the doors and drawers are already in that position.') if moves.empty?

      DoorAnimation.run(model, moves, opening ? 'Open Doors' : 'Close Doors')
      scope = selected.length == 1 ? selected.first.name : "#{cabinets.length} cabinet#{'s' unless cabinets.length == 1}"
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

      # (the two doors of a bi-fold always move together: both go if either has to)
      linked = doors.select { |door| (item = specs[AttributeManager.role(door)]) && item[1] == :door && item[0].respond_to?(:bifold) && item[0].bifold }
      together = linked.any? { |door| DoorAnimation.open?(door) != opening }

      doors.each_with_object([]) do |door, list|
        spec, kind = specs[AttributeManager.role(door)]
        next if spec.nil?
        next if DoorAnimation.open?(door) == opening && !(together && linked.include?(door))

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
      raw = raw.merge('cabinet_category' => 'wall') if raw['cabinet_category'].to_s == 'loft' # (a loft unit is a wall unit that stands over the others)
      model = Sketchup.active_model

      cabinet = CatalogManager.cabinet(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type'])
      # A catalog entry can be a corner shape ("corner": "l_shape" / "blind" / "diagonal"; blind ones
      # also say how wide the blind part is): the shape travels with the cabinet.
      raw = raw.merge('appliance_set' => (cabinet && cabinet['appliances'] ? (raw['appliance_set'].to_s.empty? ? cabinet['appliances'] : raw['appliance_set']) : ''),
                      'corner_style' => cabinet && cabinet['corner'].to_s, 'blind_width' => adjustable(raw, cabinet, 'blind_width', 'blind_label', 'blind'), 'front_zone' => zone_height_for(raw, cabinet), 'door_stacked' => cabinet && cabinet['stacked'] == true,
                      'bottom_zone' => adjustable(raw, cabinet, 'bottom_zone', 'bottom_label', 'zone_bottom'),
                      'top_front' => adjustable(raw, cabinet, 'top_front', 'top_front_label', 'top_front'),
                      'fridge' => !!(cabinet && cabinet['fridge']),
                      'door_split' => !!(cabinet && cabinet['split'] && ValidationManager.truthy_value?(raw['door_split'])),
                      'split_height' => adjustable(raw, cabinet, 'split_height', 'split_label', 'split'),
                      'sink' => !!(cabinet && cabinet['sink']),
                      'hob' => !!(cabinet && cabinet['hob']),
                      'dishwasher' => !!(cabinet && cabinet['dishwasher']),
                      'hood' => !!(cabinet && cabinet['hood']),
                      'freestanding' => !!(cabinet && cabinet['freestanding']),
                      'free_housing' => !!(cabinet && cabinet['free_housing']),
                      'pullout' => !!(cabinet && cabinet['pullout']),
                      'glass_door' => !!(cabinet && cabinet['glass']),
                      'bifold' => !!(cabinet && cabinet['bifold']),
                      'lift_door' => !!(cabinet && (cabinet['lift_door'] || (cabinet['glass'] && ValidationManager.truthy_value?(raw['lift_door'])))), # (a glass door unit can be a lift-up one too)
                      'finger_pull' => !!(CatalogManager.catalog(raw['catalog_id']) || {})['finger_pull'],
                      'housing_lift' => adjustable(raw, cabinet, 'housing_lift', 'lift_label', 'lift'),
                      'fridge_height' => adjustable(raw, cabinet, 'fridge_height', 'fridge_label', 'fridge'),
                      'drawer_pattern' => cabinet && cabinet['pattern'].to_s)
      raw = raw.merge('sink_bowls' => 1, 'sink_rotation' => 0) if cabinet && cabinet['sink_single'] # a narrow sink: one bowl, not turned
      door_count = cabinet ? cabinet['doors'].to_i : nil
      drawer_count = cabinet ? cabinet['drawers'].to_i : nil
      if cabinet && drawers_only?(cabinet) # a unit of drawers alone (also the hob unit): how many is the panel's to say
        number = ValidationManager.to_float(raw['drawer_number'])
        drawer_count = number.round.clamp(1, 6) if number
      end
      if cabinet && cabinet['lower'] # an oven housing: its lower part is drawers, a door, or a small drawer over a door
        mode = Defaults::LOWER_MODES.include?(raw['lower_mode'].to_s) ? raw['lower_mode'].to_s : 'drawers'
        number = ValidationManager.to_float(raw['lower_drawers'])
        number = number ? number.round.clamp(1, 6) : cabinet['drawers'].to_i
        raw = raw.merge('lower_mode' => mode, 'lower_drawers' => number)
        door_count += 1 unless mode == 'drawers'
        drawer_count = { 'drawers' => number, 'door' => 0, 'drawer_door' => 1 }[mode]
      end

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

    # A catalog entry that is drawers and nothing else: no doors, no zone over a door, no oven or fridge housing.
    def self.drawers_only?(cabinet)
      cabinet['drawers'].to_i.positive? && cabinet['doors'].to_i.zero? && !cabinet['zone'] && !cabinet['zone_bottom'] &&
        !cabinet['lower'] && !cabinet['fridge'] && !cabinet['corner'] && !cabinet['freestanding']
    end
    private_class_method :drawers_only?

    # The height of a zone (a fridge housing's door, the drawers over a door, the top door of a stacked
    # pair): what the panel sent when the catalog entry lets it be adjusted ("zone_label"), else the
    # catalog's own value.
    def self.zone_height_for(raw, cabinet)
      return nil unless cabinet

      sent = ValidationManager.to_float(raw['front_zone'])
      cabinet['zone_label'] && sent && sent.positive? ? sent : cabinet['zone']
    end
    private_class_method :zone_height_for

    # A measurement that a catalog entry lets the panel adjust (the entry has `label_key`): what the panel
    # sent in raw[key], else the entry's own value (`catalog_key`).
    def self.adjustable(raw, cabinet, key, label_key, catalog_key)
      return nil unless cabinet

      sent = ValidationManager.to_float(raw[key])
      cabinet[label_key] && sent && sent.positive? ? sent : cabinet[catalog_key]
    end
    private_class_method :adjustable

    # One Undo step. Any error rolls the whole operation back, so a failed
    # insert or update never leaves half-built geometry behind.
    def self.with_operation(model, name)
      return yield if (defined?(KitchenManager) && KitchenManager.building?) || @batch # (inside Design Kitchen or an update of several cabinets: its own one Undo step)

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
      drawer_handle = raw['drawer_handle_id'].to_s.strip
      if !drawer_handle.empty? && CatalogManager.handle_bundle(drawer_handle).nil?
        errors << { 'field' => 'drawer_handle_id', 'message' => 'That drawer handle bundle could not be found.' }
      end

      errors
    end
    private_class_method :catalog_errors

    # Completes the handle settings from the bundle's defaults, then checks the
    # handle is offered in that length and finish and fits on every door.
    def self.handle_errors(params)
      bundle = CatalogManager.handle_bundle(params['handle_id'])
      own = CatalogManager.handle_bundle(params['drawer_handle_id'])
      return [] unless bundle || own

      HandleManager.apply_defaults!(params, bundle) if bundle
      layout = nil
      errors = []
      if bundle && params['door_count'].positive?
        layout = CabinetLayout.compute(params)
        errors = HandleManager.errors(params, layout, bundle)
      end
      # The drawers with a handle of their own: it has to fit on each drawer front too.
      if own && (params['drawer_count'].to_i.positive? || params['pullout'])
        layout ||= CabinetLayout.compute(params)
        drawer_params = HandleManager.drawer_params(params, own)
        errors += HandleManager.errors(drawer_params, CabinetLayout::Layout.new(doors: layout.drawers), own) if errors.empty?
      end
      errors
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