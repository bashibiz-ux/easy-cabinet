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
      when 'delete' then delete
      when 'visibility' then set_visibility(raw)
      when 'toggle' then toggle_all
      when 'rotate' then rotate(raw)
      when 'apply_all' then apply_all(raw)
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
      root = SelectionManager.suspend do
        with_operation(model, 'Insert Cabinet') do
          params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
          params['sequence'] = AttributeManager.next_sequence(model)
          entities, transformation = PlacementManager.target_for_new(model, params)
          params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
          built = CabinetGenerator.build(model, entities, params, transformation)
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

    # Opens the Customize window for the selected cabinet.
    def self.customize
      model = Sketchup.active_model
      root = SelectionManager.selected_cabinet(model) || SelectionManager.selected_part(model)
      kinds = CustomizeManager::PART_KINDS
      unless root && (AttributeManager.cabinet?(root) || kinds.include?(AttributeManager.part_kind(root)))
        return Response.fail('Select a cabinet, filler, end panel, toe kick or worktop in the model to customize it.')
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
      done += " and #{panels.length} end panel#{'s' unless panels.length == 1}" unless panels.empty?
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

    # The end panels that are set to follow the front design (and are not in it yet): [[panel, new params], ...]. With `only` (the ids of
    # the cabinets that were changed) just the end panels standing against those; otherwise every one.
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
      items = model.selection.to_a
      single = items.length == 1 && (items.first.is_a?(Sketchup::Group) || items.first.is_a?(Sketchup::ComponentInstance)) ? items.first : nil
      guess = guess_name(single)
      if name.empty? && defined?(UI) && UI.respond_to?(:inputbox)
        answer = UI.inputbox(['Catalog', 'Name', 'Kind'], [catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name, guess, category || 'base'],
                             ['', '', 'base|wall|tall'], 'Save to my catalog')
        return Response.fail('Nothing was saved.') unless answer

        catalog_name = answer[0].to_s.strip
        name = answer[1].to_s.strip
        category = answer[2].to_s
      end
      name = guess if name.empty?
      category ||= 'base'
      slug = CatalogManager.slug(catalog_name.empty? ? CatalogManager::DEFAULT_CUSTOM_NAME : catalog_name)
      file = File.join('models', "custom_#{slug}_#{CatalogManager.slug(name)}.skp")
      path = File.join(CatalogManager.user_dir.to_s, file)
      FileUtils.mkdir_p(File.dirname(path))
      size = write_model_file(model, items, single, path)
      return Response.fail('That could not be saved as a model file.') unless size && File.file?(path)

      entry = CatalogManager.component_entry(name, size, file)
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

    # Inserts a model from your catalog as a component, in the row like a cabinet (beside the selected item).
    def self.insert_component(raw, entry)
      path = CatalogManager.component_path(entry)
      return Response.fail('The model file of this catalog entry is missing.') unless path && File.file?(path)

      model = Sketchup.active_model
      size = [entry.dig('defaults', 'width'), entry.dig('defaults', 'depth'), entry.dig('defaults', 'height')].map(&:to_f)
      category = raw['cabinet_category'].to_s
      params = Defaults.params.merge('width' => size[0], 'depth' => size[1], 'height' => size[2], 'cabinet_category' => category,
                                     'door_count' => 0, 'drawer_count' => 0, 'catalog_id' => raw['catalog_id'].to_s)
      instance = nil
      with_operation(model, 'Insert Model') do
        definition = model.definitions.load(path)
        entities, target = PlacementManager.target_for_new(model, params)
        low = definition.bounds.min
        # the model's X runs along the row (its width), its Y front to back: turn it a quarter so the width lies along the row
        local = Geom::Transformation.translation(Geom::Vector3d.new(size[1].mm, 0, 0)) *
                Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), Math::PI / 2) *
                Geom::Transformation.translation(Geom::Vector3d.new(-low.x, -low.y, -low.z))
        instance = entities.add_instance(definition, target * local)
        instance.name = entry['name'].to_s
        box = [low.x.to_mm, low.y.to_mm, low.z.to_mm, definition.bounds.width.to_mm, definition.bounds.height.to_mm, definition.bounds.depth.to_mm].map { |v| v.round(2) }
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_box', JSON.generate(box)) # (where its front is, before it has a handle)
        # What marks it as a model of your own (it is not a cabinet of the extension, so it has no settings of its own): its kind, and
        # the material of that kind (Base, Wall or Tall material) from the Material section goes on it, like on a cabinet.
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_model', true)
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_category', category)
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_catalog', raw['catalog_id'].to_s)
        paint_custom_model(model, instance, raw)
        settings = raw.slice(*CUSTOM_HANDLE_KEYS)
        instance.set_attribute(AttributeManager::DICTIONARY, 'custom_handle', JSON.generate(settings))
        sync_custom_handle(model, instance, settings) # a handle on its front, from the Handle section
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
      from = raw['file'].to_s.strip
      if items.empty? && from.empty?
        return Response.fail('Select the handle you drew in the model, or choose a model file.') unless defined?(UI) && UI.respond_to?(:openpanel)

        from = UI.openpanel('Choose the model file of your handle', '', 'SketchUp Model|*.skp||').to_s
        return Response.fail('No handle was added.') if from.empty?
      end
      return Response.fail('That model file could not be found.') if items.empty? && !File.file?(from)

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
    CUSTOM_HANDLE_NAME = 'Handle'

    # The handle settings a model of your own keeps.
    def self.custom_handle_settings(instance)
      text = instance.get_attribute(AttributeManager::DICTIONARY, 'custom_handle').to_s
      text.empty? ? {} : JSON.parse(text)
    rescue JSON::ParserError
      {}
    end
    private_class_method :custom_handle_settings

    # Puts the handle on the front of a model of your own (or takes it away when there is no handle package): inside the model, on its front face
    # (the low-Y side of it as it was drawn), by the rules of its kind (top of a base unit, bottom of a wall unit, hand height of a tall one).
    # The box was kept when the model was inserted: [low X, low Y, low Z, width, depth, height] in mm.
    def self.sync_custom_handle(model, instance, settings)
      box = begin
        JSON.parse(instance.get_attribute(AttributeManager::DICTIONARY, 'custom_box').to_s)
      rescue JSON::ParserError
        nil
      end
      params, bundle = HandleManager.model_params(settings, instance.get_attribute(AttributeManager::DICTIONARY, 'custom_category'))
      find = -> { instance.definition.entities.grep(Sketchup::ComponentInstance).find { |item| item.name == CUSTOM_HANDLE_NAME } }
      if bundle.nil? || !box.is_a?(Array) || box.length < 6
        find.call&.erase!
        return false
      end

      instance.make_unique if instance.definition.count_instances > 1 # (this model's own handle, not every copy's)
      existing = find.call
      handle_settings = HandleManager.settings(params, bundle)
      spot = HandleManager.placement(HandleManager.model_door(box[3].to_f, box[5].to_f, params['door_opening_direction']), handle_settings, bundle)
      definition = HandleManager.definition(model, bundle, handle_settings['length'], spot['flip'] == true)
      front = Geom::Transformation.translation(Geom::Vector3d.new(box[0].to_f.mm, box[1].to_f.mm, box[2].to_f.mm)) *
              Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), -Math::PI / 2)
      transformation = front * HandleManager.transformation(spot, 0.0)
      handle = existing || instance.definition.entities.add_instance(definition, transformation)
      handle.definition = definition unless handle.definition == definition
      handle.transformation = transformation
      handle.name = CUSTOM_HANDLE_NAME
      CabinetGenerator.paint_handle(model, handle, bundle, handle_settings)
      true
    end
    private_class_method :sync_custom_handle

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
      model.entities.grep(Sketchup::ComponentInstance).select { |instance| instance.get_attribute(AttributeManager::DICTIONARY, 'custom_model') == true }
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

    def self.update(raw)
      model = Sketchup.active_model
      root = SelectionManager.selected_cabinet(model)
      return Response.fail('Select a cabinet in the model to update.') unless root

      params, failure = prepare(raw)
      return failure if failure

      # What was changed in the Customize window stays through an Update.
      params['custom_overrides'] = ValidationManager.clean_overrides(AttributeManager.read(root)['custom_overrides'])

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
          WorktopManager.refresh(model) if params['sink'] || params['hob'] # its opening in the worktop follows
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

    GLOBAL_NUMBERS = %w[door_gap door_reveal door_distance front_radius material_thickness back_thickness toe_kick_height carcass_raise finger_gap finger_gap_drawer door_opening_angle
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
        only_these = picked.any? && selected_cabinets(model).empty?
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
      if cabinets.empty?
        return Response.ok(painted.positive? ? "#{painted} of your own model#{'s' unless painted == 1} painted." : 'No cabinets in the model yet. New cabinets will use these settings.')
      end

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
      visibility = %w[carcass door toe_kick appliances oven microwave sink hob hood free_fridge].to_h { |key| [key, on.call(raw[key])] }
      show_floor_symbol = on.call(raw['opening_direction'])
      show_door_symbol = on.call(raw['door_symbol'])
      show_wall_symbol = on.call(raw['wall_opening_direction'])
      hide_wall_handles = on.call(raw['hide_wall_handles'])
      show_names = on.call(raw['show_cabinet_names'])
      hide_base_handles = on.call(raw['hide_base_handles'])
      hide_tall_handles = on.call(raw['hide_tall_handles'])

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
          cabinets.each do |cabinet|
            AttributeManager.write(cabinet, 'visibility_settings' => visibility,
                                            'show_opening_direction' => show_floor_symbol,
                                            'show_door_symbol' => show_door_symbol,
                                            'show_wall_opening_direction' => show_wall_symbol,
                                            'hide_wall_handles' => hide_wall_handles,
                                            'hide_base_handles' => hide_base_handles,
                                            'hide_tall_handles' => hide_tall_handles,
                                            'show_cabinet_names' => show_names)
            CabinetGenerator.apply_visibility(cabinet, visibility, show_floor_symbol, show_door_symbol, show_wall_symbol, hide_wall_handles,
                                              hide_base_handles, hide_tall_handles)
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
          built = CabinetGenerator.build(model, entities, params, transformation)
          fill_blind_gap(model, entities, built, params)
          built
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