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
      catalog_id = panel['catalog_id'].to_s
      return Response.fail('Choose a model (catalog) first: the kitchen is built from its units.') if catalog_id.empty? || CatalogManager.catalog(catalog_id).nil?

      answers = raw['kitchen'].is_a?(Hash) ? raw['kitchen'].transform_keys(&:to_s) : {}
      styles = raw['options'] == true ? KitchenPlanner::STYLES : [KitchenPlanner.normalise(answers)['style']]
      plans = styles.map { |style| KitchenPlanner.plan(answers.merge('style' => style)) }
      return Response.fail(plans.first.error) if plans.first.error

      missing = plans.flat_map { |plan| plan.base + plan.wall + (plan.island ? plan.island.items : []) }.map { |item| [item.category, item.type] }.uniq
                     .reject { |category, type| CatalogManager.cabinet(catalog_id, category, type) }
      return Response.fail("This model has no #{missing.map { |category, type| "#{category} unit \"#{type}\"" }.join(', ')}. Choose a kitchen model that has the standard units.") unless missing.empty?

      step = KitchenPlanner.normalise(answers)['wall_a'] + OPTION_GAP
      model = Sketchup.active_model
      model.selection.clear
      all = []
      begin
        CabinetManager.send(:with_operation, model, plans.length > 1 ? 'Design Kitchen Options' : 'Design Kitchen') do
          plans.each_with_index do |plan, index|
            built = { base: [], wall: [], island: [] }
            plan.base.each_with_index do |item, position|
              shifted = index.positive? && position.zero? ? all.first[:base].first.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, (index * step).mm, 0)) : nil
              built[:base] << build_unit(model, panel, catalog_id, item, shifted)
            end
            build_wall(model, panel, catalog_id, plan, built) unless plan.wall.empty?
            build_island(model, panel, catalog_id, plan, built) if plan.island
            all << built
          end
        end
      rescue StandardError => e
        return Response.fail("The kitchen could not be built: #{e.message}")
      end

      SelectionManager.push_selection(model)
      message = if plans.length > 1
                  lines = plans.each_with_index.map { |plan, index| "Option #{index + 1} (#{STYLE_NAMES[plan.style]}): #{KitchenPlanner.describe(plan)}." }
                  "Three kitchens designed side by side, #{fmt(step)} mm apart along wall A: #{lines.join(' ')} Delete the ones you do not want."
                else
                  "Kitchen designed: #{KitchenPlanner.describe(plans.first)}."
                end
      message += " #{plans.first.notes.join(' ')}" unless plans.first.notes.empty?
      message += worktop_message(raw['worktop'])
      Response.ok(message, { 'cabinets' => all.sum { |built| built.values.sum(&:length) } })
    end

    def self.fmt(value)
      format('%g', value)
    end
    private_class_method :fmt
    def self.worktop_message(values)
      return '' unless values.is_a?(Hash)

      answer = WorktopManager.apply(values)
      answer['ok'] ? ' Worktop and back splash added.' : " (The worktop was not added: #{answer['message']})"
    rescue StandardError => e
      " (The worktop was not added: #{e.message})"
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
    # measure from the first unit of the kitchen (wall A, its start); the others follow it.
    def self.build_island(model, panel, catalog_id, plan, built)
      island = plan.island
      frame = built[:base].first.transformation
      place = frame * Geom::Transformation.translation(Geom::Vector3d.new(island.x.mm, island.y.mm, 0)) *
              Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), Math::PI)
      island.items.each_with_index { |item, index| built[:island] << build_unit(model, panel, catalog_id, item, index.zero? ? place : nil) }
    end
    private_class_method :build_island

    def self.unit_raw(panel, entry, item, catalog_id)
      defaults = entry['defaults'] || {}
      panel.merge(PER_UNIT_BLANKS).merge(item.extra || {}).merge(
        'catalog_id' => catalog_id, 'cabinet_category' => item.category, 'cabinet_type' => item.type, 'width' => item.width,
        'depth' => defaults['depth'], 'height' => defaults['height'], 'shelf_count' => entry['shelves'].to_s, 'placement_gap' => 0.0,
        'sink_bowls' => entry['sink_bowls'] || 1, 'sink_tray' => entry['sink_tray'] != false
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
