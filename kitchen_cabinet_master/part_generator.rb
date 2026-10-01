# frozen_string_literal: true

module KitchenCabinetMaster
  # Builds a filler, end panel or toe kick and keeps it in step with its
  # parameters. Much simpler than CabinetGenerator: a board (or, for a toe kick,
  # a row of pieces), no doors, handles or indicator. Follows the same rules: Update never deletes
  # and recreates, only the parts that changed are touched.
  module PartGenerator
    TOE_KICK_ROLE = 'toe_kick'
    TOLERANCE = 1e-6

    # Creates a new part. `params` must already contain 'part_id' and 'part_name'.
    # Call inside an operation.
    def self.build(model, entities, params, transformation, layout)
      definition = AttributeManager.mark_managed(model.definitions.add(params['part_name']))
      root = entities.add_instance(definition, transformation)
      root.name = params['part_name']

      place(model, root, params, layout)
      AttributeManager.write(root, attributes_for(params, layout))
      TagManager.assign(model, root, TagManager.for_stored(params))
      root
    end

    # Brings an existing part in line with `params`, keeping its identity.
    # Call inside an operation.
    def self.update(model, root, params, layout, transformation = nil)
      params['part_id'] = AttributeManager.part_id(root)
      root.transformation = transformation if transformation
      root.name = params['part_name'] unless params['part_name'].to_s.empty?

      place(model, root, params, layout)
      AttributeManager.write(root, attributes_for(params, layout))
      TagManager.assign(model, root, TagManager.for_stored(params))
      root
    end

    # Erases a part and any definitions that only it was using.
    # Call inside an operation.
    def self.remove(model, root)
      definitions = collect_definitions(root)
      root.erase!
      definitions.each { |definition| PanelGenerator.discard_if_unused(model, definition) }
    end

    # ---- internals -----------------------------------------------------------

    def self.place(model, root, params, layout)
      entities = root.definition.entities
      material = params['material'].to_s
      top = index_by_role(entities)

      # A toe kick has no board: its pieces sit directly in the part, end to end.
      return reconcile(model, entities, layout.toe_kick, material) unless layout.board

      place_board(model, entities, top, layout.board, material)
      sync_toe_kick(model, root, top, layout.toe_kick, ToeKick.material_name(params, material, material))
    end
    private_class_method :place

    def self.place_board(model, entities, top, board, material)
      definition = board.points ? PanelGenerator.polygon_definition(model, board.points, board.extent[2]) : PanelGenerator.definition(model, board.extent)
      transformation = Geom::Transformation.new(board.offset.map(&:mm))
      instance = place_instance(model, entities, top[board.role], board.role, definition, transformation)
      instance.name = board.name
      MaterialManager.apply(instance, material, model)
    end
    private_class_method :place_board

    # A filler's toe kick lives in its own container, at floor level (Z 0), the
    # same pattern CabinetGenerator uses.
    def self.sync_toe_kick(model, root, top, pieces, material)
      existing = top[TOE_KICK_ROLE]

      if pieces.empty?
        discard_instance(model, existing) if existing
        return
      end

      container = ensure_container(model, root, existing, TOE_KICK_ROLE, 'Toe Kick')
      reconcile(model, container.definition.entities, pieces, material)
    end
    private_class_method :sync_toe_kick

    def self.ensure_container(model, root, existing, role, title)
      transformation = Geom::Transformation.new
      return existing if existing

      definition = AttributeManager.mark_managed(model.definitions.add("#{root.name} #{title}"))
      container = root.definition.entities.add_instance(definition, transformation)
      AttributeManager.set_role(container, role)
      container.name = title
      container
    end
    private_class_method :ensure_container

    # Makes `entities` contain exactly `items` (toe-kick pieces).
    def self.reconcile(model, entities, items, material_name)
      leftovers = index_by_role(entities)

      items.each do |item|
        existing = leftovers.delete(item.role)
        definition = PanelGenerator.definition(model, item.extent)
        transformation = Geom::Transformation.new(item.offset.map(&:mm))
        # A piece on a turned leg is rotated about its own origin before it is moved.
        if item.rotation.to_f.abs > TOLERANCE
          transformation *= Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1),
                                                          item.rotation * Math::PI / 180.0)
        end
        instance = place_instance(model, entities, existing, item.role, definition, transformation)
        instance.name = item.name
        MaterialManager.apply(instance, material_name, model)
      end

      leftovers.each_value { |surplus| discard_instance(model, surplus) }
    end
    private_class_method :reconcile

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

    def self.discard_instance(model, instance)
      definitions = collect_definitions(instance)
      instance.erase!
      definitions.each { |definition| PanelGenerator.discard_if_unused(model, definition) }
    end
    private_class_method :discard_instance

    def self.attributes_for(params, layout)
      attributes = params.dup
      attributes['base_z'] = layout.base_z
      attributes['top_z'] = layout.top_z
      unless layout.board
        # A toe kick: the run's footprint, so a later toe kick can start where it ends.
        attributes['width'] = ToeKick.total_length(params)
        attributes['envelope_depth'] = params['toe_kick_thickness'].to_f
        attributes['envelope_width'] = attributes['width']
        attributes['envelope_top'] = layout.top_z
        return attributes
      end

      envelope = layout.board.extent.dup
      envelope[2] = layout.top_z # the board's own Z extent is just its thickness; the envelope needs the full height
      # From the part's origin to the board's far (front) face; a filler is set forward of it.
      attributes['envelope_depth'] = layout.board.offset[0] + envelope[0]
      attributes['envelope_width'] = params['part_kind'] == 'filler' ? params['width'].to_f : envelope[1]
      attributes['envelope_top'] = layout.top_z
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
