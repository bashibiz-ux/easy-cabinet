# frozen_string_literal: true

module KitchenCabinetMaster
  # Builds a cabinet and keeps it in step with its parameters.
  #
  # Component hierarchy (one unique definition per cabinet and container):
  #
  #   CABINET_0001                    root instance, holds the Attribute Dictionary
  #   ├─ Carcass                      container, lifted by the toe-kick height
  #   │  ├─ Left / Right Side Panel   ┐ instances of shared panel definitions
  #   │  ├─ Back Panel                │ (identical sizes share one definition)
  #   │  ├─ Bottom Panel              │
  #   │  ├─ Top Rear/Front Rail       │
  #   │  │   or Top Panel             │
  #   │  └─ Shelf 1..n                ┘
  #   ├─ Toe Kick                     container on the floor: Toe Kick 1..n (equal segments)
  #   ├─ Door 1..n                    containers, direct children so each can be selected
  #   │  ├─ Panel                     shared panel definition
  #   │  └─ Handle                    follows the door because it lives inside it
  #   └─ Opening Indicator            container of dashed guide lines
  #
  # Updating NEVER deletes and recreates the cabinet. `sync` compares what
  # exists with what the parameters require and only changes the difference:
  # it swaps an instance's definition when its size changed, moves it when its
  # position changed, adds missing parts and erases surplus ones. A door that is
  # open stays open (at the new angle) through an update.
  module CabinetGenerator
    CARCASS_ROLE = 'carcass'
    TOE_KICK_ROLE = 'toe_kick'
    INDICATOR_ROLE = 'indicator'
    DOOR_PREFIX = 'door_'
    DRAWER_PREFIX = 'drawer_'
    DOOR_PANEL_ROLE = 'panel'
    HANDLE_ROLE = 'handle'
    SIGNATURE_KEY = 'signature'
    TOLERANCE = 1e-6

    # Creates a new cabinet. `params` must already contain 'cabinet_id'.
    # Call inside an operation.
    def self.build(model, entities, params, transformation)
      label = params['cabinet_name'].to_s.empty? ? params['cabinet_id'] : params['cabinet_name']
      definition = AttributeManager.mark_managed(model.definitions.add(label))
      root = entities.add_instance(definition, transformation)
      root.name = label

      layout = sync(model, root, params)
      AttributeManager.write(root, attributes_for(params, layout))
      root
    end

    # Brings an existing cabinet in line with `params`, keeping its identity.
    # Call inside an operation.
    def self.update(model, root, params)
      params['cabinet_id'] = AttributeManager.cabinet_id(root)
      root.name = params['cabinet_name'] unless params['cabinet_name'].to_s.empty?

      layout = sync(model, root, params)
      AttributeManager.write(root, attributes_for(params, layout))
      root
    end

    # Erases a cabinet and any definitions that only it was using.
    # Call inside an operation.
    def self.remove(model, root)
      discard_instance(model, root)
    end

    # The DOOR material: the individual cabinet override wins over the unit
    # (base / wall / tall) door material.
    def self.door_material(params)
      override = params['cabinet_material'].to_s
      return override unless override.empty?

      params["#{params['cabinet_category']}_material"].to_s
    end

    # The carcass has its own colour when one is chosen; otherwise it follows the door material.
    # (Doors use the door material; the toe kick has its own choice, see ToeKick.material_name.)
    def self.carcass_material(params, door_material)
      own = params['carcass_material'].to_s
      own.empty? ? door_material : own
    end

    # Shows or hides the parts of a cabinet: carcass, toe kick, doors, and the
    # opening indicator (which needs doors to be visible AND its own switch on).
    # Only flips `visible` on existing containers; nothing is rebuilt.
    def self.apply_visibility(root, visibility, show_indicator)
      doors_visible = visibility['door'] != false

      index_by_role(root.definition.entities).each do |role, instance|
        if role == CARCASS_ROLE then instance.visible = visibility['carcass'] != false
        elsif role == TOE_KICK_ROLE then instance.visible = visibility['toe_kick'] != false
        elsif role == INDICATOR_ROLE then instance.visible = doors_visible && show_indicator
        elsif role.start_with?(DOOR_PREFIX) || role.start_with?(DRAWER_PREFIX) then instance.visible = doors_visible
        end
      end
    end

    # The door instances of a cabinet, in order (Door 1, Door 2 ...).
    def self.doors_of(root)
      by_role(root, DOOR_PREFIX)
    end

    # The drawer front instances of a cabinet, in order (Drawer 1, Drawer 2 ...).
    def self.drawers_of(root)
      by_role(root, DRAWER_PREFIX)
    end

    # Doors and drawers together, in role order: what Open / Close / Toggle acts on.
    def self.openables_of(root)
      doors_of(root) + drawers_of(root)
    end

    def self.by_role(root, prefix)
      index_by_role(root.definition.entities)
        .select { |role, _| role.start_with?(prefix) }
        .sort_by { |role, _| role.delete_prefix(prefix).to_i }
        .map { |_, instance| instance }
    end
    private_class_method :by_role

    # ---- internals -----------------------------------------------------------

    # Component definitions are named after the cabinet: BU600, BU600 Carcass,
    # BU600 Door 1 ... (no prefix). Called on every sync, so it also renames the
    # parts when the cabinet is renamed after a resize, and converts definitions
    # that older versions named "KCM CABINET_0001 ...".
    def self.name_parts(model, root)
      label = root.name.to_s
      return if label.empty?

      rename_definition(model, root.definition, label)
      root.definition.entities.grep(Sketchup::ComponentInstance).each do |part|
        title = part.name.to_s
        rename_definition(model, part.definition, "#{label} #{title}") unless title.empty?
      end
    end
    private_class_method :name_parts

    def self.rename_definition(model, definition, name)
      AttributeManager.mark_managed(definition)
      return if definition.name == name

      clash = model.definitions[name]
      return if clash && clash != definition # never fight over a name

      definition.name = name
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not rename #{name}: #{e.message}"
    end
    private_class_method :rename_definition

    def self.sync(model, root, params)
      name_parts(model, root)
      layout = CabinetLayout.compute(params)
      door_mat = door_material(params)
      carcass_mat = carcass_material(params, door_mat)
      visibility = params['visibility_settings'] || {}
      doors_visible = visibility['door'] != false

      # One scan of the cabinet's direct children (Carcass, Toe Kick, Door 1..n,
      # Opening Indicator), shared by everything below instead of each looking on
      # its own. No two of them ever read a role the others just created, so the
      # single snapshot stays correct for the whole pass.
      top = index_by_role(root.definition.entities)

      sync_carcass(model, root, top, layout, carcass_mat, visibility['carcass'] != false)
      sync_toe_kick(model, root, top, layout, ToeKick.material_name(params, door_mat, carcass_mat), visibility['toe_kick'] != false)
      sync_doors(model, root, top, params, layout, door_mat, doors_visible)
      sync_drawers(model, root, top, params, layout, door_mat, doors_visible)
      sync_indicator(model, root, top, params, layout, doors_visible)
      layout
    end
    private_class_method :sync

    # The Carcass container sits at Z = toe-kick height, so everything inside it
    # moves up with the toe kick.
    def self.sync_carcass(model, root, top, layout, material, visible)
      carcass = ensure_container(model, root, top, CARCASS_ROLE, 'Carcass', layout.base_z)
      reconcile(model, carcass.definition.entities, layout.panels, material) do |panel, _existing|
        Geom::Transformation.new(panel.offset.map(&:mm))
      end
      carcass.visible = visible
    end
    private_class_method :sync_carcass

    # The toe kick stays on the floor (Z 0 up to the toe-kick height) while the
    # carcass above it rises, so it lives in its own container that never lifts.
    # Wall units and a toe-kick height of 0 have none.
    # `material` is already resolved (own choice, or the door's / carcass's colour).
    def self.sync_toe_kick(model, root, top, layout, material, visible)
      if layout.toe_kick.empty?
        discard_instance(model, top[TOE_KICK_ROLE]) if top[TOE_KICK_ROLE]
        return
      end

      container = ensure_container(model, root, top, TOE_KICK_ROLE, 'Toe Kick', 0.0)
      reconcile(model, container.definition.entities, layout.toe_kick, material) do |piece, _existing|
        Geom::Transformation.new(piece.offset.map(&:mm))
      end
      container.visible = visible
    end
    private_class_method :sync_toe_kick

    # Each door is a container of its own (a unique definition) holding the door
    # panel and its handle, placed in cabinet coordinates (the offsets already
    # include the toe-kick height). Because the handle lives inside the door,
    # rotating the door carries the handle with it. An open door stays open,
    # re-posed at the new angle.
    def self.sync_doors(model, root, top, params, layout, material, visible)
      angle = params['door_opening_angle'].to_f
      transform = ->(door, fraction) { DoorAnimation.transformation(door, angle, fraction) }
      sync_openables(model, root, top, params, layout.doors, DOOR_PREFIX, material, visible, transform)
    end
    private_class_method :sync_doors

    # Drawer fronts are built exactly like doors (same overlay container, same
    # handle placement code) but close/open by sliding, not swinging.
    def self.sync_drawers(model, root, top, params, layout, material, visible)
      depth = params['depth'].to_f
      transform = ->(drawer, fraction) { DrawerAnimation.transformation(drawer, depth, fraction) }
      sync_openables(model, root, top, params, layout.drawers, DRAWER_PREFIX, material, visible, transform)
    end
    private_class_method :sync_drawers

    # Shared by doors and drawers: each is a small container (its own panel plus
    # an optional handle) whose closed-vs-open placement is worked out by
    # `transform` (rotation for a door, sliding for a drawer).
    def self.sync_openables(model, root, top, params, items, prefix, material, visible, transform)
      entities = root.definition.entities
      leftovers = top.select { |role, _| role.start_with?(prefix) }
      bundle = CatalogManager.handle_bundle(params['handle_id'])

      items.each do |item|
        existing = leftovers.delete(item.role)
        was_open = existing ? DoorAnimation.open?(existing) : false
        if existing && !AttributeManager.container?(existing)
          discard_instance(model, existing) # a bare panel left by an older version of the extension
          existing = nil
        end

        transformation = transform.call(item, was_open ? 1.0 : 0.0)
        container = door_container(model, entities, existing, item, root.name, transformation)
        DoorAnimation.set_open(container, true) if was_open && !existing
        container.visible = visible
        sync_door_contents(model, container, item, params, material, bundle)
      end

      leftovers.each_value { |surplus| discard_instance(model, surplus) }
    end
    private_class_method :sync_openables

    def self.door_container(model, entities, existing, door, cabinet_name, transformation)
      if existing
        existing.transformation = transformation unless same_transformation?(existing.transformation, transformation)
        existing.name = door.name
        return existing
      end

      definition = AttributeManager.mark_managed(model.definitions.add("#{cabinet_name} #{door.name}"))
      container = entities.add_instance(definition, transformation)
      AttributeManager.set_role(container, door.role)
      AttributeManager.mark_container(container)
      container.name = door.name
      container
    end
    private_class_method :door_container

    # Inside the container the door panel sits at the origin (the container itself
    # carries the door's position), and the handle sits on the panel's front face.
    def self.sync_door_contents(model, container, door, params, material, bundle)
      entities = container.definition.entities
      panel = CabinetLayout::Panel.new(role: DOOR_PANEL_ROLE, name: "#{door.name} Panel", extent: door.extent,
                                       offset: [0, 0, 0])
      reconcile(model, entities, [panel], material, scope: ->(role) { role == DOOR_PANEL_ROLE }) do |_item, _existing|
        Geom::Transformation.new
      end
      sync_handle(model, entities, door, params, bundle)
    end
    private_class_method :sync_door_contents

    def self.sync_handle(model, entities, door, params, bundle)
      existing = index_by_role(entities)[HANDLE_ROLE]
      unless bundle
        discard_instance(model, existing) if existing
        return
      end

      settings = HandleManager.settings(params, bundle)
      spot = HandleManager.placement(door, settings, bundle)
      definition = HandleManager.definition(model, bundle, settings['length'])
      handle = place_instance(model, entities, existing, HANDLE_ROLE, definition,
                              HandleManager.transformation(spot, door.extent[0]))
      handle.name = 'Handle'

      if settings['material'].to_s.empty?
        material_name, color = HandleManager.finish_material(bundle, settings['finish'])
        MaterialManager.apply(handle, material_name, model, color)
      else
        MaterialManager.apply(handle, settings['material'], model) # a material picked from the model
      end
    end
    private_class_method :sync_handle

    def self.sync_indicator(model, root, top, params, layout, doors_visible)
      if layout.doors.empty?
        discard_instance(model, top[INDICATOR_ROLE]) if top[INDICATOR_ROLE]
        return
      end

      container = ensure_container(model, root, top, INDICATOR_ROLE, 'Opening Indicator', layout.base_z)
      angle = params['door_opening_angle'].to_f
      style = params['door_symbol'].to_s.empty? ? 'plan' : params['door_symbol']
      signature = DoorAnimation.indicator_signature(layout.doors, angle, layout.base_z, style)

      unless container.get_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY) == signature
        rebuild_indicator(container, layout, angle, style)
        container.set_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY, signature)
      end

      container.visible = doors_visible && params['show_opening_direction'] != false
    end
    private_class_method :sync_indicator

    # Dashed guide lines (construction lines) so the indicator never becomes
    # solid geometry. Keep View > Guides switched on to see them.
    def self.rebuild_indicator(container, layout, angle, style)
      entities = container.definition.entities
      entities.clear!
      DoorAnimation.indicator_segments(layout.doors, angle, layout.base_z, style).each do |from, to|
        entities.add_cline(from.map(&:mm), to.map(&:mm), '-')
      end
    end
    private_class_method :rebuild_indicator

    # `top` is the shared snapshot from `sync`. A container this call creates is
    # not written back into it: each role is only ever looked up once per sync.
    def self.ensure_container(model, root, top, role, title, base_z)
      entities = root.definition.entities
      transformation = Geom::Transformation.new([0, 0, base_z.mm])
      container = top[role]

      if container
        container.transformation = transformation unless same_transformation?(container.transformation, transformation)
      else
        definition = AttributeManager.mark_managed(model.definitions.add("#{root.name} #{title}"))
        container = entities.add_instance(definition, transformation)
        AttributeManager.set_role(container, role)
        container.name = title
      end
      container
    end
    private_class_method :ensure_container

    # Makes `entities` contain exactly `items` (panels or doors). The block
    # returns the transformation for an item, given the instance that already
    # exists for it (or nil). `scope` limits which existing instances may be
    # erased as surplus.
    def self.reconcile(model, entities, items, material_name, scope: nil, visible: nil)
      leftovers = index_by_role(entities)
      leftovers = leftovers.select { |role, _| scope.call(role) } if scope

      items.each do |item|
        existing = leftovers.delete(item.role)
        instance = place_item(model, entities, existing, item, yield(item, existing))
        instance.name = item.name
        instance.visible = visible unless visible.nil?
        MaterialManager.apply(instance, material_name, model)
      end

      leftovers.each_value { |surplus| discard_instance(model, surplus) }
    end
    private_class_method :reconcile

    def self.place_item(model, entities, instance, item, transformation)
      definition = item.points ? PanelGenerator.polygon_definition(model, item.points, item.extent[2]) : PanelGenerator.definition(model, item.extent)
      place_instance(model, entities, instance, item.role, definition, transformation)
    end
    private_class_method :place_item

    # Adds the instance if it is missing; otherwise swaps its definition and moves
    # it only if something actually changed.
    def self.place_instance(model, entities, instance, role, definition, transformation)
      unless instance
        instance = entities.add_instance(definition, transformation)
        AttributeManager.set_role(instance, role)
        return instance
      end

      previous = instance.definition
      unless previous == definition
        instance.definition = definition
        PanelGenerator.discard_if_unused(model, previous)
      end
      instance.transformation = transformation unless same_transformation?(instance.transformation, transformation)
      instance
    end
    private_class_method :place_instance

    # Erases an instance and, walking down through what it contained (a door's
    # panel and handle, for example), any definition nothing else uses.
    def self.discard_instance(model, instance)
      definitions = collect_definitions(instance)
      instance.erase!
      definitions.each { |definition| PanelGenerator.discard_if_unused(model, definition) }
    end
    private_class_method :discard_instance

    def self.attributes_for(params, layout)
      attributes = params.dup
      attributes['material'] = door_material(params)
      attributes['base_z'] = layout.base_z
      attributes['top_z'] = layout.top_z
      envelope = CabinetLayout.envelope(params)
      attributes['envelope_depth'] = envelope[0]
      attributes['envelope_width'] = envelope[1]
      attributes['envelope_top'] = envelope[2]
      bundle = CatalogManager.handle_bundle(params['handle_id'])
      attributes['handle_settings'] = bundle ? HandleManager.settings(params, bundle) : {}
      attributes['shelf_settings'] = {
        'count' => params['shelf_count'].to_i,
        'thickness' => params['material_thickness'],
        'front_setback' => Defaults::SHELF_FRONT_SETBACK,
        'mode' => 'even'
      }
      attributes
    end
    private_class_method :attributes_for

    def self.index_by_role(entities)
      entities.grep(Sketchup::ComponentInstance).each_with_object({}) do |instance, index|
        role = AttributeManager.role(instance)
        index[role] = instance if role
      end
    end
    private_class_method :index_by_role

    def self.same_transformation?(first, second)
      first.to_a.zip(second.to_a).all? { |a, b| (a - b).abs < TOLERANCE }
    end
    private_class_method :same_transformation?

    # Pre-order list: a definition always comes before the definitions inside it,
    # which is the order they must be removed in.
    def self.collect_definitions(root)
      found = []
      walk = lambda do |definition|
        found << definition
        definition.entities.grep(Sketchup::ComponentInstance).each { |child| walk.call(child.definition) }
      end
      walk.call(root.definition)
      found.uniq
    end
    private_class_method :collect_definitions
  end
end
