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
  #   │  ├─ Handle                    follows the door because it lives inside it
  #   │  └─ Opening Symbol            dashed swing lines on the door face, also inside it
  #   └─ Opening Indicator            floor-level plan symbol
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
    DOOR_GLASS_ROLE = 'door_glass'
    HANDLE_ROLE = 'handle'
    DOOR_SYMBOL_ROLE = 'door_symbol'
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
      TagManager.assign(model, root, TagManager.for_category(params['cabinet_category']))
      root
    end

    # Brings an existing cabinet in line with `params`, keeping its identity.
    # Call inside an operation.
    def self.update(model, root, params)
      params['cabinet_id'] = AttributeManager.cabinet_id(root)
      root.name = params['cabinet_name'] unless params['cabinet_name'].to_s.empty?

      layout = sync(model, root, params)
      AttributeManager.write(root, attributes_for(params, layout))
      TagManager.assign(model, root, TagManager.for_category(params['cabinet_category']))
      root
    end

    # Erases a cabinet and any definitions that only it was using.
    # Call inside an operation.
    def self.remove(model, root)
      discard_instance(model, root)
    end

    # The DOOR material: the individual cabinet override wins over the unit
    # (base / wall / tall) door material.
    # A corner unit has no door material of its own: it uses the Base Unit one, so
    # whatever is chosen there applies to its door too. A unit type with no
    # material (or a cabinet stored before it had one) gets the plain white
    # default rather than an empty, unusable name.
    def self.door_material(params)
      override = params['cabinet_material'].to_s
      return override unless override.empty?

      category = params['cabinet_category'].to_s
      category = 'base' if category == 'corner'
      own = params["#{category}_material"].to_s
      own.empty? ? Defaults::DEFAULT_MATERIAL : own
    end

    # The carcass has its own colour when one is chosen; otherwise it follows the door material.
    # (Doors use the door material; the toe kick has its own choice, see ToeKick.material_name.)
    def self.carcass_material(params, door_material)
      own = params['carcass_material'].to_s
      own.empty? ? door_material : own
    end

    # Shows or hides the parts of a cabinet: carcass, doors, and the two
    # opening-direction symbols (each needs the doors visible AND its own switch
    # on): `show_floor_symbol` is the plan symbol on the floor, `show_door_symbol`
    # the dashed lines on each door. Only flips `visible` on existing containers;
    # nothing is rebuilt.
    def self.apply_visibility(root, visibility, show_floor_symbol, show_door_symbol, show_wall_symbol = false, hide_wall_handles = false,
                             hide_base_handles = false, hide_tall_handles = false)
      doors_visible = visibility['door'] != false
      wall = root.get_attribute(AttributeManager::DICTIONARY, 'cabinet_category') == 'wall'
      base_like = %w[base corner].include?(root.get_attribute(AttributeManager::DICTIONARY, 'cabinet_category'))
      tall = root.get_attribute(AttributeManager::DICTIONARY, 'cabinet_category') == 'tall'
      # A wall unit's plan line has its own switch.
      show_floor_symbol = show_wall_symbol if root.get_attribute(AttributeManager::DICTIONARY, 'cabinet_category') == 'wall'

      index_by_role(root.definition.entities).each do |role, instance|
        if role == CARCASS_ROLE then instance.visible = visibility['carcass'] != false
        elsif role == TOE_KICK_ROLE then instance.visible = visibility['toe_kick'] != false
        elsif role == INDICATOR_ROLE then instance.visible = doors_visible && show_floor_symbol
        elsif role == APPLIANCES_ROLE then apply_appliance_visibility(instance, visibility)
        elsif role.start_with?(DOOR_PREFIX) || role.start_with?(DRAWER_PREFIX)
          instance.visible = doors_visible
          symbol = index_by_role(instance.definition.entities)[DOOR_SYMBOL_ROLE]
          symbol.visible = show_door_symbol if symbol
          handle = index_by_role(instance.definition.entities)[HANDLE_ROLE]
          if handle
            hidden = if wall then hide_wall_handles elsif tall then hide_tall_handles else base_like && hide_base_handles end
            handle.visible = !hidden
          end
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
      layout = CabinetLayout.compute(with_rise(model, params))
      door_mat = door_material(params)
      carcass_mat = carcass_material(params, door_mat)
      visibility = params['visibility_settings'] || {}
      doors_visible = visibility['door'] != false

      # One scan of the cabinet's direct children (Carcass, Toe Kick, Door 1..n,
      # Opening Indicator), shared by everything below instead of each looking on
      # its own. No two of them ever read a role the others just created, so the
      # single snapshot stays correct for the whole pass.
      top = index_by_role(root.definition.entities)

      sync_carcass(model, root, top, layout, carcass_mat, visibility['carcass'] != false, door_mat)
      sync_toe_kick(model, root, top, layout, ToeKick.material_name(params, door_mat, carcass_mat), visibility['toe_kick'] != false)
      sync_doors(model, root, top, params, layout, door_mat, doors_visible)
      sync_drawers(model, root, top, params, layout, door_mat, doors_visible, carcass_mat)
      sync_indicator(model, root, top, params, layout, doors_visible)
      sync_appliances(model, root, top, params, layout)
      sync_name_label(model, root, top, params, layout)
      layout
    end
    private_class_method :sync

    # The Carcass container sits at Z = toe-kick height, so everything inside it
    # moves up with the toe kick.
    def self.sync_carcass(model, root, top, layout, material, visible, door_material = nil)
      carcass = ensure_container(model, root, top, CARCASS_ROLE, 'Carcass', layout.base_z)
      reconcile(model, carcass.definition.entities, layout.panels, material, front_material: door_material) do |panel, _existing|
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
    def self.sync_drawers(model, root, top, params, layout, material, visible, carcass_material = nil)
      depth = params['depth'].to_f
      transform = ->(drawer, fraction) { DrawerAnimation.transformation(drawer, depth, fraction) }
      boxes = { materials: carcass_material || material, panels: layout.drawer_boxes || {} }
      sync_openables(model, root, top, params, layout.drawers, DRAWER_PREFIX, material, visible, transform, boxes)
    end
    private_class_method :sync_drawers

    # Shared by doors and drawers: each is a small container (its own panel plus
    # an optional handle) whose closed-vs-open placement is worked out by
    # `transform` (rotation for a door, sliding for a drawer).
    def self.sync_openables(model, root, top, params, items, prefix, material, visible, transform, boxes = nil)
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
        sync_door_contents(model, container, item, params, material, bundle, boxes)
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
    def self.sync_door_contents(model, container, door, params, material, bundle, boxes = nil)
      entities = container.definition.entities
      drawer = door.role.start_with?(DRAWER_PREFIX)
      chosen = FrontDesign.clean(params['front_design'])
      # A door can be a frame round panes of glass: in the glass design that was chosen, or the wide frame of a glass cabinet. A drawer front
      # is never glass, and a door too small for the frame stays a plain board.
      glass_design = if drawer then nil
                     elsif !FrontDesign.clean_glass(params['glass_design']).empty? # (the Glass Door of the Models section)
                       params['glass_design'] if FrontDesign.glass_on_door?(door.role, params)
                     elsif params['glass_door'] == true then FrontDesign::GLASS_FRAME
                     end
      openings = glass_design ? FrontDesign.glass_openings(glass_design, door.extent[1], door.extent[2]) : []
      design = openings.empty? ? chosen : glass_design
      frame_material = openings.empty? ? nil : FrontDesign.frame_material(glass_design) # (aluminium or black, or the door material)
      panel = CabinetLayout::Panel.new(role: DOOR_PANEL_ROLE, name: "#{door.name} Panel", extent: door.extent, shape: "front_#{design}", round: params['front_radius'].to_f,
                                       offset: [0, 0, 0])
      reconcile(model, entities, [panel], frame_material || material, scope: ->(role) { role == DOOR_PANEL_ROLE }) do |_item, _existing|
        Geom::Transformation.new
      end
      if frame_material # (the frame of aluminium or black is painted by its own look, so it turns that colour whatever the list of materials has)
        look = FrontDesign::FRAME_LOOKS[frame_material]
        framed = index_by_role(entities)[DOOR_PANEL_ROLE]
        MaterialManager.apply(framed, frame_material, model, look && look[:color], look && look[:props]) if framed
      end
      sync_door_glass(model, entities, door, params, openings)
      sync_drawer_box(model, entities, door, boxes) if drawer
      sync_handle(model, entities, door, params, bundle, openings.empty? ? nil : openings.first[0]) # (on the frame of a glass door)
      sync_door_symbol(model, container, door, params)
    end
    private_class_method :sync_door_contents

    # The panes of a glass door: a thin sheet of glass in each opening of the frame, in the middle of its thickness. Without
    # `openings` (not a glass door, or too small for a frame) any pane there was is taken away.
    def self.sync_door_glass(model, entities, door, params, openings)
      thickness = FrontDesign::GLASS_THICKNESS
      fluted = params['glass_material'].to_s == FrontDesign::FLUTED_GLASS # (real flutes up the pane)
      panes = openings.each_with_index.map do |(y0, y1, z0, z1), index|
        CabinetLayout::Panel.new(role: index.zero? ? DOOR_GLASS_ROLE : "#{DOOR_GLASS_ROLE}_#{index + 1}", name: "#{door.name} Glass #{index + 1}",
                                 shape: fluted ? 'fluted' : nil,
                                 extent: [thickness, y1 - y0 - 0.4, z1 - z0 - 0.4].map { |v| v.round(2) },
                                 offset: [(door.extent[0] - thickness) / 2.0, y0 + 0.2, z0 + 0.2].map { |v| v.round(2) })
      end
      reconcile(model, entities, panes, params['glass_material'].to_s, scope: ->(role) { role.start_with?(DOOR_GLASS_ROLE) }) do |pane, _existing|
        Geom::Transformation.new(pane.offset.map(&:mm))
      end
    end
    private_class_method :sync_door_glass
    # The inner box of a drawer: inside its container, so it slides out with the front.
    def self.sync_drawer_box(model, entities, drawer, boxes)
      panels = boxes ? Array(boxes[:panels][drawer.role]) : []
      reconcile(model, entities, panels, boxes ? boxes[:materials] : nil, scope: ->(role) { role.include?('_box_') }) do |panel, _existing|
        Geom::Transformation.new(panel.offset.map(&:mm))
      end
    end
    private_class_method :sync_drawer_box

    # The dashed opening-direction lines ON the door. They are a small container
    # inside the door, so they swing with it. Every hinged door has them (a drawer
    # front has no hinge); whether they show is the "Door opening direction on the
    # door" tick, which only flips their visibility.
    def self.sync_door_symbol(model, container, door, params)
      entities = container.definition.entities
      existing = index_by_role(entities)[DOOR_SYMBOL_ROLE]



      unless existing
        definition = AttributeManager.mark_managed(model.definitions.add("#{container.definition.name} Opening Symbol"))
        existing = entities.add_instance(definition, Geom::Transformation.new)
        AttributeManager.set_role(existing, DOOR_SYMBOL_ROLE)
        existing.name = 'Opening Symbol'
      end

      signature = DoorAnimation.door_symbol_signature(door)
      unless existing.get_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY) == signature
        symbol_entities = existing.definition.entities
        symbol_entities.clear!
        DoorAnimation.door_symbol_segments(door).each do |from, to|
          symbol_entities.add_cline(from.map(&:mm), to.map(&:mm), '-')
        end
        existing.set_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY, signature)
      end

      existing.visible = params['show_door_symbol'] != false
    end
    private_class_method :sync_door_symbol

    def self.sync_handle(model, entities, door, params, bundle, frame = nil)
      existing = index_by_role(entities)[HANDLE_ROLE]
      # The drawers can have a handle of their own, not the doors'.
      if door.role.start_with?(DRAWER_PREFIX) && !params['drawer_handle_id'].to_s.empty?
        own = CatalogManager.handle_bundle(params['drawer_handle_id'])
        if own
          bundle = own
          params = HandleManager.drawer_params(params, own)
        end
      end
      unless bundle && door.handle != false # no handle on this door (an L corner has one, on its narrower door)
        discard_instance(model, existing) if existing
        return
      end

      settings = HandleManager.settings(params, bundle)
      spot = HandleManager.placement(door, settings, bundle, frame)
      definition = HandleManager.definition(model, bundle, settings['length'], spot['flip'] == true)
      handle = place_instance(model, entities, existing, HANDLE_ROLE, definition,
                              HandleManager.transformation(spot, door.extent[0]))
      handle.name = 'Handle'
      handle.visible = !case params['cabinet_category']
                        when 'wall' then params['hide_wall_handles'] == true
                        when 'tall' then params['hide_tall_handles'] == true
                        when 'base', 'corner' then params['hide_base_handles'] == true
                        else false
                        end

      paint_handle(model, handle, bundle, settings)
    end
    private_class_method :sync_handle

    # The material of a handle: the one picked in the Handle section, or the finish of its package.
    def self.paint_handle(model, handle, bundle, settings)
      if settings['material'].to_s.empty?
        if HandleManager.keeps_look?(bundle, settings['finish']) # a handle you drew, as you drew it
          handle.material = nil
          return
        end

        material_name, color, props = HandleManager.finish_material(bundle, settings['finish'])
        MaterialManager.apply(handle, material_name, model, color, props)
      else
        MaterialManager.apply(handle, settings['material'], model) # a material picked from the model
      end
    end

    # The FLOOR-level plan symbol, one container for the whole cabinet. Always
    # built; the "Door opening direction on the floor" tick only flips its
    # visibility. (The symbol on each door is sync_door_symbol.)
    def self.sync_indicator(model, root, top, params, layout, doors_visible)
      angle = params['door_opening_angle'].to_f

      moving = layout.doors + layout.drawers # doors swing, drawers slide out: both have a plan symbol
      if moving.empty?
        discard_instance(model, top[INDICATOR_ROLE]) if top[INDICATOR_ROLE]
        return
      end

      container = ensure_container(model, root, top, INDICATOR_ROLE, 'Opening Indicator', layout.base_z)
      signature = DoorAnimation.indicator_signature(moving, angle, layout.base_z)

      unless container.get_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY) == signature
        rebuild_indicator(container, layout, angle)
        container.set_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY, signature)
      end

      container.visible = doors_visible &&
                           (params['cabinet_category'] == 'wall' ? params['show_wall_opening_direction'] == true : params['show_opening_direction'] != false)
    end
    private_class_method :sync_indicator

    # Dashed guide lines (construction lines) so the indicator never becomes
    # solid geometry. Keep View > Guides switched on to see them.
    def self.rebuild_indicator(container, layout, angle)
      entities = container.definition.entities
      entities.clear!
      DoorAnimation.indicator_segments(layout.doors + layout.drawers, angle, layout.base_z).each do |from, to|
        entities.add_cline(from.map(&:mm), to.map(&:mm), '-')
      end
    end
    private_class_method :rebuild_indicator

    # ---- the appliances of an oven housing -------------------------------------------

    APPLIANCES_ROLE = 'appliances'
    # The material of an appliance part (see AppliancePieces.finish): [name, colour, how it looks].
    def self.appliance_finish(role)
      AppliancePieces.finish(role)
    end
    # The ovens, microwave and fridge, built from plain boxes, in a container of their own, shown or
    # hidden by the Show appliances / Show oven / Show microwave / Show fridge ticks.
    def self.sync_appliances(model, root, top, params, layout)
      items = layout.appliances || []
      existing = top[APPLIANCES_ROLE]
      if items.empty?
        discard_instance(model, existing) if existing
        return
      end

      container = ensure_container(model, root, top, APPLIANCES_ROLE, 'Appliances', layout.base_z)
      entities = container.definition.entities
      have = index_by_role(entities)
      items.each do |item|
        definition = appliance_definition(model, item)
        instance = place_instance(model, entities, have.delete(item.role), item.role, definition, Geom::Transformation.new(item.offset.map(&:mm)))
        instance.name = item.name
        material_name, color, look = appliance_finish(item.role)
        MaterialManager.apply(instance, material_name, model, color, look)
      end
      have.each_value { |surplus| discard_instance(model, surplus) }
      apply_appliance_visibility(container, params['visibility_settings'] || {})
    end
    private_class_method :sync_appliances

    # A box, a round bar (shape cyl_x / cyl_y / cyl_z) or a flat board with an outline (points).
    def self.appliance_definition(model, item)
      if item.points && !item.points.empty?
        PanelGenerator.polygon_definition(model, item.points, item.extent[2])
      elsif item.shape == 'tube'
        PanelGenerator.tube_definition(model, item.path, item.round)
      elsif item.shape.to_s.start_with?('cyl_')
        PanelGenerator.cylinder_definition(model, item.extent, item.shape.to_s[-1])
      else
        PanelGenerator.definition(model, item.extent)
      end
    end
    private_class_method :appliance_definition

    # Which tick shows an appliance part. The sink has its own tick (Fixtures). Every appliance is on view only under
    # Show appliances AND its own tick: oven, microwave, hob, hood, built-in fridge, freestanding fridge (the unit of
    # that name, and the fridge of a fridge housing).
    def self.apply_appliance_visibility(container, visibility)
      parts = index_by_role(container.definition.entities)
      shown = lambda do |role|
        if role.include?('_sink_')
          visibility['sink'] != false
        else
          tick = AppliancePieces.tick_for(role)
          visibility['appliances'] == true && (tick.nil? || visibility[tick] != false)
        end
      end
      container.visible = parts.keys.any?(&shown)
      parts.each { |role, instance| instance.visible = shown.call(role) }
    end
    # The sink and hob sit on the worktop: the layout needs how far its top stands over the carcass (nothing without one).
    def self.with_rise(model, params)
      return params unless params['sink'] == true || params['hob'] == true

      params.merge('worktop_rise' => label_lift(model, params))
    end
    private_class_method :with_rise

    # Puts the sinks and hobs back at the height of the worktop (after it was applied, changed or removed).
    def self.sync_fixtures(model)
      model.entities.grep(Sketchup::ComponentInstance).each do |item|
        next unless AttributeManager.cabinet?(item)

        params = AttributeManager.read(item)
        next unless params && (params['sink'] == true || params['hob'] == true)

        sync_appliances(model, item, index_by_role(item.definition.entities), params, CabinetLayout.compute(with_rise(model, params)))
      end
    end

    # ---- the cabinet's name, flat on its top ---------------------------------------

    NAME_ROLE = 'name_label'
    NAME_MATERIAL = 'Cabinet Name Label'
    NAME_HEIGHT_MM = 70.0 # letter height before it is shrunk to fit the top

    # The name as flat lettering on the top of the cabinet, readable from above (it runs along
    # the cabinet's WIDTH, with the tops of the letters towards the back, so it reads correctly
    # from the front). A little container of its own inside the
    # cabinet, so it moves, turns and copies with it. Shown only while the Show Cabinet Names
    # tick is on.
    def self.sync_name_label(model, root, top, params, layout)
      existing = top[NAME_ROLE]
      name = params['cabinet_name'].to_s.strip
      unless params['show_cabinet_names'] == true && !name.empty?
        discard_instance(model, existing) if existing
        return
      end

      depth = CabinetLayout.corner?(params) ? CabinetLayout.corner_extent(params) : params['depth'].to_f
      width = params['width'].to_f
      z = layout.top_z + label_lift(model, params) + 0.2
      # A base unit's name goes on the strip along its FRONT edge (where the front top rail is), so it
      # stays in view from the front and from straight above; everything else is centred.
      front = params['cabinet_category'].to_s == 'base'
      signature = [name, z.round(2), depth, width, 'along-width', front].join('|')
      container = ensure_container(model, root, top, NAME_ROLE, 'Cabinet Name', 0)
      unless container.get_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY) == signature
        rebuild_name_label(model, container, name, depth, width, z, front)
        container.set_attribute(AttributeManager::DICTIONARY, SIGNATURE_KEY, signature)
      end
      container.visible = true
    end
    private_class_method :sync_name_label

    # A worktop on top of a base or corner unit lifts the top surface the name must sit on.
    def self.label_lift(model, params)
      return 0.0 unless %w[base corner].include?(params['cabinet_category'].to_s)

      slab = WorktopManager.pieces_in(model).find { |item| AttributeManager.part_kind(item) == 'worktop' }
      slab ? AttributeManager.read(slab)['worktop_thickness'].to_f : 0.0
    rescue StandardError
      0.0
    end
    private_class_method :label_lift

    def self.rebuild_name_label(model, container, name, depth, width, z, front = false)
      entities = container.definition.entities
      entities.clear!
      group = entities.add_group
      # centred, flat (no extrusion), facing up
      group.entities.add_3d_text(name, 1, 'Arial', true, false, NAME_HEIGHT_MM.mm, 0.0, 0.0, true, 0.0)
      if group.entities.count.zero?
        group.erase!
        return
      end

      # turn it a quarter so it runs along Y (the width) and its letters stand towards the back
      group.transform!(Geom::Transformation.rotation(group.bounds.center, Geom::Vector3d.new(0, 0, 1), Math::PI / 2.0))
      bounds = group.bounds
      across = front ? [Defaults::RAIL_DEPTH * 0.7, depth * 0.6].min : depth * 0.6
      scale = [1.0, (width.mm * 0.8) / [bounds.height, 1.0.mm].max, across.mm / [bounds.width, 1.0.mm].max].min
      group.transform!(Geom::Transformation.scaling(bounds.center, scale)) if scale < 1.0
      bounds = group.bounds
      x = front ? depth - (Defaults::RAIL_DEPTH / 2.0) : depth / 2.0
      middle = Geom::Point3d.new(x.mm, width.mm / 2.0, z.mm)
      group.transform!(Geom::Transformation.translation(middle - bounds.center))
      group.name = 'Name'
      MaterialManager.apply(group, NAME_MATERIAL, model, '#1c1c1c')
    end
    private_class_method :rebuild_name_label

    # Brings one cabinet's name label in line with its stored settings (used when the tick
    # changes). Inside an operation.
    def self.sync_name_label_for(model, root)
      params = AttributeManager.read(root)
      return unless params

      sync_name_label(model, root, index_by_role(root.definition.entities), params, CabinetLayout.compute(params))
    end

    def self.sync_all_names(model)
      model.entities.grep(Sketchup::ComponentInstance).each do |item|
        sync_name_label_for(model, item) if AttributeManager.cabinet?(item)
      end
    end
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
    def self.reconcile(model, entities, items, material_name, scope: nil, visible: nil, front_material: nil)
      leftovers = index_by_role(entities)
      leftovers = leftovers.select { |role, _| scope.call(role) } if scope

      items.each do |item|
        existing = leftovers.delete(item.role)
        instance = place_item(model, entities, existing, item, yield(item, existing))
        instance.name = item.name
        instance.visible = visible unless visible.nil?
        # A panel that is part of the front (a blind corner's fixed panel) is the door's colour.
        front = front_material && item.respond_to?(:front) && item.front
        MaterialManager.apply(instance, front ? front_material : material_name, model)
      end

      leftovers.each_value { |surplus| discard_instance(model, surplus) }
    end
    private_class_method :reconcile

    def self.place_item(model, entities, instance, item, transformation)
      definition =
        if item.points then PanelGenerator.polygon_definition(model, item.points, item.extent[2])
        elsif item.shape.to_s == 'fluted' then PanelGenerator.fluted_definition(model, item.extent)
        elsif item.shape.to_s == 'notch' then PanelGenerator.notched_definition(model, item.extent, item.path)
        elsif item.shape.to_s.start_with?('front_') then PanelGenerator.front_definition(model, item.extent, item.shape.to_s.delete_prefix('front_'), item.round.to_f)
        else PanelGenerator.definition(model, item.extent)
        end
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
