# frozen_string_literal: true

module KitchenCabinetMaster
  # "Design Kitchen": builds the whole kitchen of a KitchenPlanner plan in one Undo step, the units one after another exactly as if they were
  # inserted by hand (so a corner turns the row, a wall unit goes over the base units, and everything is an ordinary cabinet that can be
  # changed, moved or deleted afterwards). The values of the panel (materials, handle, door design, thickness ...) are used for every unit.
  module KitchenManager
    # What a unit of the catalog fixes for itself: the panel's values for these are left out so the catalog's own apply.
    PER_UNIT_BLANKS = {
      'appliance_set' => '', 'front_zone' => '', 'oven_height' => '', 'oven2_height' => '', 'bottom_zone' => '', 'top_front' => '', 'fridge_height' => '',
      'fridge_lift' => false, 'door_split' => false, 'split_height' => '', 'housing_lift' => '', 'drawer_heights' => '', 'drawer_number' => '',
      'blind_width' => '', 'lower_mode' => '', 'lower_drawers' => '', 'small_drawer' => '', 'micro_height' => '', 'leg2_length' => '', 'leg2_depth' => '',
      'sink_mirror' => false, 'lift_door' => false
    }.freeze

    def self.perform(action, raw)
      case action
      when 'design_kitchen' then design(raw)
      when 'design_kitchen_options' then design((raw.is_a?(Hash) ? raw : {}).merge('options' => true))
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    STYLE_NAMES = { 'classic' => 'doors', 'glass' => 'glass doors on the wall units', 'lift' => 'lift-up wall units over drawers' }.freeze
    OPTION_GAP = 2500.0 # between the kitchens of "Make 3 Options"

    # raw: { 'kitchen' => the answers (see KitchenPlanner), 'cabinet' => the panel's values, 'worktop' => the worktop section's values (optional),
    #        'options' => true to build one kitchen in each style side by side instead of one }.
    def self.design(raw)
      raw = {} unless raw.is_a?(Hash)
      panel = raw['cabinet'].is_a?(Hash) ? raw['cabinet'] : {}
      panel = panel.merge('dishwasher_handle' => KitchenPlanner.normalise(raw['kitchen'])['dishwasher_handle']) # (the dishwasher front's handle)
      catalog_id = panel['catalog_id'].to_s
      return Response.fail('Choose a model (catalog) first: the kitchen is built from its units.') if catalog_id.empty? || CatalogManager.catalog(catalog_id).nil?

      answers = raw['kitchen'].is_a?(Hash) ? raw['kitchen'].transform_keys(&:to_s) : {}
      styles = raw['options'] == true ? KitchenPlanner::STYLES : [KitchenPlanner.normalise(answers)['style']]
      plans = styles.map { |style| KitchenPlanner.plan(answers.merge('style' => style)) }
      return Response.fail(plans.first.error) if plans.first.error

      missing = plans.flat_map { |plan| plan.base + plan.wall + (plan.island ? plan.island.items : []) }.map { |item| [item.category, item.type] }.uniq
                     .reject { |category, type| CatalogManager.cabinet(catalog_id, category, type) }
      return Response.fail("This model has no #{missing.map { |category, type| "#{category} unit \"#{type}\"" }.join(', ')}. Choose a kitchen model that has the standard units.") unless missing.empty?

      step = plans.first.first_length + OPTION_GAP
      model = Sketchup.active_model
      model.selection.clear
      all = []
      parts = { toe_kicks: 0, end_panels: 0, hoods: 0, dimensions: 0, notes: [] }
      replace = raw['replace'] == true && plans.length == 1 # a live update: the kitchen designed before is taken away and built again where it stood
      origin = replace ? remembered_origin(model) : nil
      before = nil
      begin
        run_operation(model, plans.length > 1 ? 'Design Kitchen Options' : 'Design Kitchen') do
          erase_previous(model) if replace
          before = entity_ids(model)
          plans.each_with_index do |plan, index|
            built = { base: [], wall: [], island: [] }
            plan.base.each_with_index do |item, position|
              shifted = index.positive? && position.zero? ? all.first[:base].first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, (index * step).mm, 0)) : nil
              shifted = origin if shifted.nil? && origin && index.zero? && position.zero?
              gap = nil
              if shifted.nil? && position.positive? && item.gap_before.to_f.positive? # the room for a side panel between a tall unit and the one beside it
                gap = built[:base].last.transformation.yaxis
                gap.length = item.gap_before.mm
              end
              built[:base] << build_unit(model, panel, catalog_id, item, shifted, gap)
            end
            build_wall(model, panel, catalog_id, plan, built) unless plan.wall.empty?
            build_island(model, panel, catalog_id, plan, built, parts) if plan.island
            all << built
            add_parts(model, plan, built, raw, parts)
            if raw['kitchen'].is_a?(Hash) && raw['kitchen']['dimensions'] == true
              extra(parts, 'The dimensions') { parts[:dimensions] += DimensionManager.add(model, built.values.flatten) }
            end
          end
          remember(model, before, plans.length == 1 ? all.first[:base].first : nil)
        end
      rescue StandardError => e
        return Response.fail("The kitchen could not be built: #{e.message}#{where(e)}")
      end

      SelectionManager.push_selection(model)
      message = if plans.length > 1
                  lines = plans.each_with_index.map { |plan, index| "Option #{index + 1} (#{STYLE_NAMES[plan.style]}): #{KitchenPlanner.describe(plan)}." }
                  "Three kitchens designed side by side, #{fmt(step)} mm apart along wall A: #{lines.join(' ')} Delete the ones you do not want."
                else
                  "Kitchen designed: #{KitchenPlanner.describe(plans.first)}."
                end
      message += " #{plans.first.notes.join(' ')}" unless plans.first.notes.empty?
      message += " Toe kicks: #{parts[:toe_kicks]}." if raw['toe_kick'].is_a?(Hash)
      message += " Side panels: #{parts[:end_panels]}#{(parts[:panel_parts] || {}).empty? ? '' : " (#{parts[:panel_parts].select { |_, n| n.positive? }.map { |part, n| "#{part} #{n}" }.join(', ')})"}." if raw['end_panel'].is_a?(Hash)
      message += " Dimensions: #{parts[:dimensions]}." if parts[:dimensions].positive?
      message += " #{parts[:notes].uniq.join(' ')}" unless parts[:notes].empty?
      worktop_before = worktop_ids(model)
      message += worktop_message(raw['worktop'])
      remember_worktop(model, worktop_before) if plans.length == 1
      Response.ok(message, { 'cabinets' => all.sum { |built| built.values.sum(&:length) } })
    end

    # ---- remembering the kitchen, so that a change of the answers can build it again (live update) ----

    DICTIONARY = 'KitchenCabinetMaster'
    KEY_ENTITIES = 'kitchen_entities'
    KEY_WORKTOP = 'kitchen_worktop'
    KEY_ORIGIN = 'kitchen_origin'

    def self.entity_ids(model)
      model.entities.map(&:persistent_id)
    end
    private_class_method :entity_ids

    def self.worktop_ids(model)
      WorktopManager.respond_to?(:pieces_in) ? WorktopManager.pieces_in(model).map(&:persistent_id) : []
    end
    private_class_method :worktop_ids

    # What this design added to the model, and where its first unit stands (inside the design's own operation).
    def self.remember(model, before, first)
      return unless model.respond_to?(:set_attribute)

      added = before ? entity_ids(model) - before : []
      model.set_attribute(DICTIONARY, KEY_ENTITIES, added.join(','))
      model.set_attribute(DICTIONARY, KEY_WORKTOP, '')
      model.set_attribute(DICTIONARY, KEY_ORIGIN, first ? first.transformation.to_a.join(',') : '')
    end
    private_class_method :remember

    # The worktop is a separate Undo step; its pieces are written down in a step that joins it.
    def self.remember_worktop(model, before)
      return unless model.respond_to?(:set_attribute)

      added = worktop_ids(model) - before
      return if added.empty?

      model.start_operation('Remember Kitchen', true, false, true)
      model.set_attribute(DICTIONARY, KEY_WORKTOP, added.join(','))
      model.commit_operation
    rescue StandardError
      model.abort_operation
    end
    private_class_method :remember_worktop

    def self.remembered_origin(model)
      numbers = model.get_attribute(DICTIONARY, KEY_ORIGIN).to_s.split(',').map(&:to_f)
      numbers.length == 16 ? Geom::Transformation.new(numbers) : nil
    end
    private_class_method :remembered_origin

    # Takes away the kitchen designed before (its cabinets, parts, lights and worktop pieces).
    def self.erase_previous(model)
      [KEY_ENTITIES, KEY_WORKTOP].each do |key|
        model.get_attribute(DICTIONARY, key).to_s.split(',').map(&:to_i).each do |id|
          entity = model.find_entity_by_persistent_id(id)
          next unless entity&.valid?

          if AttributeManager.cabinet?(entity) then CabinetGenerator.remove(model, entity) else entity.erase! end
        end
      end
    end
    private_class_method :erase_previous

    def self.fmt(value)
      format('%g', value)
    end
    private_class_method :fmt

    def self.building? = @building == true

    # One Undo step round everything (the toe kicks and the side panels are made by the same code as their own buttons, which would otherwise start
    # operations of their own: "building?" tells them not to).
    def self.run_operation(model, name)
      model.start_operation(name, true)
      @building = true
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @building = false
      end
    end
    private_class_method :run_operation

    # The toe kick under each row (one that covers the whole row of the kitchen, turning at the corners, and one under the island) and the end
    # panels on the open ends (see KitchenPlanner.end_panel_targets), made by the same code as the Insert Toe Kick and Insert Side Panel buttons,
    # each against the unit it belongs to. What cannot be made is told in parts[:notes].
    def self.add_parts(model, plan, built, raw, parts)
      # The toe kicks come after the side panels, so that they can run on to the panels that stand on the floor at the ends of a row.
      toe_kicks = lambda do
        toe = raw['toe_kick']
        next unless toe.is_a?(Hash)

        values = toe.transform_keys(&:to_s).merge('toe_kick_cover_row' => true)
        anchors = [built[:base].first, (built[:island].first if plan.island)].compact
        anchors.each do |anchor|
          extra(parts, 'A toe kick') do
            answer = against(model, anchor) { PartManager.send(:insert_toe_kick, values) }
            answer['ok'] ? parts[:toe_kicks] += 1 : parts[:notes] << "A toe kick was not added: #{answer['message']}"
          end
        end
      end
      panel = raw['end_panel']
      unless panel.is_a?(Hash)
        toe_kicks.call
        return
      end

      ends = KitchenPlanner.end_panel_targets(plan).map { |target| [target[:part], target[:index], target[:side]] } # the open ends the answers ask for
      values = panel.transform_keys(&:to_s).merge('shift' => false) # (the kitchen made room for its panels itself: nothing is moved)
      # The tallest units first: the panel of a tall unit is the one that stands in the room between it and the lower units beside it.
      jobs = built.flat_map { |part, units| units.each_with_index.flat_map { |unit, index| %w[left right].map { |side| [part, units, unit, index, side] } } }
      jobs = jobs.each_with_index.sort_by { |job, position| [-job[2].get_attribute(AttributeManager::DICTIONARY, 'envelope_top').to_f, position] }.map(&:first)
      jobs.each do |part, units, unit, index, side|
        end_of_row = side == 'left' ? index.zero? : index == units.length - 1
        next if end_of_row && !ends.include?([part, index, side]) # (the end of a row that may stand against a wall)

        extra(parts, 'A side panel') do # a panel on every other side that shows (see PartManager.place_exposed_panels)
          made, _covered, trouble = PartManager.send(:place_exposed_panels, model, unit, side, values.merge('inner' => !end_of_row)) # (a side between two units is an inner one)
          parts[:end_panels] += made
        (parts[:panel_parts] ||= Hash.new(0))[part] += made
          trouble.each { |message| parts[:notes] << "A side panel was not added: #{message}" }
        end
      end
      toe_kicks.call
    ensure
      model.selection.clear
    end
    private_class_method :add_parts

    # Runs the block with only `unit` selected (what the part buttons take as the thing they go with).
    def self.against(model, unit)
      model.selection.clear
      if defined?(Sketchup::Drawingelement) && !unit.is_a?(Sketchup::Drawingelement)
        raise "the unit to work against is a #{unit.class}, not something that can be selected"
      end
      model.selection.add(unit)
      yield
    end
    private_class_method :against

    def self.worktop_message(values)
      return '' unless values.is_a?(Hash)

      answer = WorktopManager.apply(values)
      return " (The worktop was not added: #{answer['message']})" unless answer['ok']

      problems = WorktopManager.respond_to?(:problems) ? WorktopManager.problems.uniq : []
      ' Worktop and back splash added.' + (problems.empty? ? '' : " #{problems.join(' ')}")
    rescue StandardError => e
      " (The worktop was not added: #{e.message}#{where(e)})"
    end
    private_class_method :worktop_message

    # The wall units: the first goes over the start of the run (after a tall unit that stands at its start), the rest follow it along the wall.
    def self.build_wall(model, panel, catalog_id, plan, built)
      reference = built[:base].find { |instance| AttributeManager.read(instance)['cabinet_category'] != 'tall' } || built[:base].first
      start = built[:base].first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, plan.wall_start.mm, 0))
      plan.wall.each_with_index do |item, index|
        override = nil
        if index.zero?
          height = CatalogManager.cabinet(catalog_id, item.category, item.type).dig('defaults', 'height').to_f
          z = PlacementManager.wall_origin_z(model, { 'height' => height }, reference)
          override = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z.mm - start.origin.z)) * start
          override *= Geom::Transformation.translation(Geom::Vector3d.new(0, item.gap_before.to_f.mm, 0)) # (a window at the start of the wall)
        end
        gap = nil
        if !index.zero? && item.gap_before.to_f.positive? # the room a window leaves empty before this unit, along the wall of the unit before it
          gap = built[:wall].last.transformation.yaxis
          gap.length = item.gap_before.mm
        end
        built[:wall] << build_unit(model, panel, catalog_id, item, override, gap)
      end
    end
    private_class_method :build_wall

    # The island: a row of units standing in the room, turned round so that their fronts look at the units of wall A. Its first unit is put by
    # measure from the first unit of the kitchen (wall A, its start); the others follow it. A hob on it gets a hood hung from the ceiling.
    def self.build_island(model, panel, catalog_id, plan, built, parts)
      island = plan.island
      frame = built[:base].first.transformation
      place = frame * Geom::Transformation.translation(Geom::Vector3d.new(island.x.mm, island.y.mm, 0)) *
              Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), Math::PI)
      island.items.each_with_index { |item, index| built[:island] << build_unit(model, panel, catalog_id, item, index.zero? ? place : nil) }
      built[:island].each { |unit| unit.set_attribute(AttributeManager::DICTIONARY, 'island_side_panels', true) } if island.side_panels # (the knee panels then only fill the overhang)
      built[:island].each { |unit| unit.set_attribute(AttributeManager::DICTIONARY, 'island_seating', island.seating.to_f) } # (the worktop reaches this far beyond the back, and has no back splash)
      if island.back_panel # a board closing the room side of the units
        extra(parts, 'The island back panel') do
          top = built[:island].first.get_attribute(AttributeManager::DICTIONARY, 'top_z').to_f
          IslandBackPanel.build(model, model.active_entities, place, island.back_panel.merge(height: top, material: island.back_panel[:material].to_s.empty? ? panel['base_material'] : island.back_panel[:material]))
        end
      end
      return unless island.hood

      extra(parts, 'The island hood') do
        IslandHood.build(model, model.active_entities, place, island.hood) # hung from the ceiling over the island's hob
        parts[:hoods] += 1
      end
    end

    # Something extra (lights, a hood) that must not stop the kitchen: if it cannot be drawn the kitchen stays and the reply says why.
    def self.extra(parts, name)
      yield
    rescue StandardError => e
      parts[:notes] << "#{name} could not be drawn: #{e.message}#{where(e)}"
    end
    private_class_method :extra

    # Where in the extension a failure happened, for the reply ( (at island_hood.rb:30)).
    def self.where(error)
      line = Array(error.backtrace).find { |entry| entry.include?('kitchen_cabinet_master') }&.[](/\w+\.rb:\d+/)
      line ? " (at #{line})" : ''
    end
    private_class_method :where
    private_class_method :build_island

    def self.unit_raw(panel, entry, item, catalog_id)
      defaults = entry['defaults'] || {}
      own = (item.extra || {}).reject { |key, _| key == 'flip_hand' }
      raw = panel.merge(PER_UNIT_BLANKS).merge(own)
      if (item.extra || {})['flip_hand'] # a mirrored kitchen: the doors hinge on the other side and the drainer is on the other side
        raw['door_opening_direction'] = raw['door_opening_direction'].to_s == 'right' ? 'left' : 'right'
        raw['sink_mirror'] = !raw['sink_mirror']
      end
      raw.merge(
        'catalog_id' => catalog_id, 'cabinet_category' => item.category, 'cabinet_type' => item.type, 'width' => item.width,
        'depth' => defaults['depth'], 'height' => defaults['height'], 'shelf_count' => entry['shelves'].to_s, 'placement_gap' => 0.0,
        'sink_bowls' => (item.extra || {})['sink_bowls'] || entry['sink_bowls'] || 1, 'sink_tray' => (item.extra || {}).fetch('sink_tray', entry['sink_tray'] != false)
      )
    end
    private_class_method :unit_raw

    # One unit, as Insert builds it. `override` is where it goes when that is not just after the last one.
    def self.build_unit(model, panel, catalog_id, item, override = nil, gap = nil)
      entry = CatalogManager.cabinet(catalog_id, item.category, item.type)
      params, failure = CabinetManager.send(:prepare, unit_raw(panel, entry, item, catalog_id))
      raise "#{entry['name']} #{format('%g', item.width)} mm: #{failure['message']}" if failure

      params['cabinet_id'] = AttributeManager.next_cabinet_id(model)
      params['sequence'] = AttributeManager.next_sequence(model)
      entities, transformation = PlacementManager.target_for_new(model, params)
      if override
        entities = model.active_entities
        transformation = override
      elsif gap
        transformation = Geom::Transformation.translation(gap) * transformation
      end
      params['cabinet_name'] = NamingManager.unique_name(entities, NamingManager.base_name(params))
      CabinetGenerator.build(model, entities, params, transformation)
    end
    private_class_method :build_unit
  end
end
