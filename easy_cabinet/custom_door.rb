# frozen_string_literal: true

module EasyCabinet
  # The door of a model of your own (My Catalog). The model is one drawing, but what stands on its front, thin and wide, in a group or a component
  # of its own, is its door (a front with more than one door counts as one). It is found when the model is inserted and kept as paths into the
  # model; the Door Reveal, Door Distance and Door Height Adjustment settings then size and place it as they do a cabinet's door:
  #   across  the door is as wide as the cabinet less a reveal at each end
  #   up      from a reveal above the toe kick to a reveal below the top (a wall unit's door grows downward by the adjustment, the others upward)
  #   out     its back face stands the Door Distance in front of the carcass front (the carcass front is where the door stood, less the distance
  #           it had when the model was inserted)
  # The handle follows the door. Everything is in the frame of the cabinet's component: X out of the door, Y along it, Z up.
  module CustomDoor
    KEYS = %w[door_reveal door_distance door_height_adjust].freeze
    MAX_THICKNESS = 40.0 # mm: a door is no thicker than this
    FRONT_TOLERANCE = 6.0
    MAX_DEPTH = 3 # how deep in groups it is looked for

    # The paths (see entity_at) of the door pieces of the cabinet `root`, and where the back of the door stands ([paths, x]); nil when the model has
    # no door that can be told from the rest.
    def self.detect(root)
      dictionary = AttributeManager::DICTIONARY
      inner = model_of(root)
      return nil unless inner

      depth = root.get_attribute(dictionary, 'envelope_depth').to_f
      width = root.get_attribute(dictionary, 'width').to_f
      height = root.get_attribute(dictionary, 'height').to_f
      found = []
      scan(inner, [inner], [], 0) do |entity, chain, path|
        x0, y0, z0, x1, y1, z1 = bounds(entity, chain)
        thin = (x1 - x0) <= MAX_THICKNESS && x1 >= depth - FRONT_TOLERANCE
        big = (y1 - y0) >= 0.15 * width && (z1 - z0) >= 0.25 * height
        found << [path, x0] if thin && big && entity.name.to_s !~ /handle/i
      end
      return nil if found.empty?

      thickness = found.map { |_, x0| depth - x0 }.max
      [found.map { |path, _| path.join('>') }, found.map(&:last).min, thickness.clamp(1.0, MAX_THICKNESS)]
    end

    # Sizes and places the door by the settings (reveal, distance, adjust in mm). False when the cabinet has no door.
    def self.apply(model, root, reveal, distance, adjust)
      dictionary = AttributeManager::DICTIONARY
      paths = root.get_attribute(dictionary, 'custom_door').to_s.split(';').reject(&:empty?)
      return false if paths.empty?

      root.make_unique if root.definition.count_instances > 1
      entries = paths.filter_map { |text| entity_at(root, text.split('>').map(&:to_i), unique: true) }
      return false if entries.empty?

      boxes = entries.map { |entity, chain| bounds(entity, chain) }
      low = [boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.min, boxes.map { |b| b[2] }.min]
      high = [boxes.map { |b| b[3] }.max, boxes.map { |b| b[4] }.max, boxes.map { |b| b[5] }.max]
      width = root.get_attribute(dictionary, 'width').to_f
      height = root.get_attribute(dictionary, 'height').to_f
      lift = root.get_attribute(dictionary, 'base_z').to_f
      front = root.get_attribute(dictionary, 'custom_carcass_front').to_f
      wall = root.get_attribute(dictionary, 'cabinet_category').to_s == 'wall'

      bottom = lift + reveal
      top = lift + height - reveal
      if adjust != 0.0
        wall ? bottom -= adjust : top += adjust
      end
      top = bottom + 60.0 if top - bottom < 60.0
      start = reveal
      stop = [width - reveal, start + 60.0].max
      thick = root.get_attribute(dictionary, 'custom_door_thickness').to_f
      thick = high[0] - low[0] unless thick.positive?
      out_of = thick / [high[0] - low[0], 0.001].max # (the door keeps its thickness when the model is scaled)
      across = (stop - start) / [high[1] - low[1], 0.001].max
      up = (top - bottom) / [high[2] - low[2], 0.001].max
      move = Geom::Transformation.translation(Geom::Vector3d.new((front + distance - low[0]).mm, (start - low[1]).mm, (bottom - low[2]).mm)) *
             Geom::Transformation.scaling(Geom::Point3d.new(low[0].mm, low[1].mm, low[2].mm), out_of, across, up)
      entries.each do |entity, chain|
        space = chain.reduce(Geom::Transformation.new) { |all, ancestor| all * ancestor.transformation }
        entity.transform!(space.inverse * move * space)
      end

      out = front + distance + thick
      AttributeManager.write(root, 'door_reveal' => reveal, 'door_distance' => distance, 'door_height_adjust' => adjust,
                                   'depth' => front, 'envelope_depth' => out.round(2))
      true
    end

    # Where the door is now, for the handle: [x of its front, y of its left end, z of its bottom, width, height], or nil.
    def self.frame(root)
      paths = root.get_attribute(AttributeManager::DICTIONARY, 'custom_door').to_s.split(';').reject(&:empty?)
      entries = paths.filter_map { |text| entity_at(root, text.split('>').map(&:to_i)) }
      return nil if entries.empty?

      boxes = entries.map { |entity, chain| bounds(entity, chain) }
      x1 = boxes.map { |b| b[3] }.max
      y0 = boxes.map { |b| b[1] }.min
      z0 = boxes.map { |b| b[2] }.min
      [x1, y0, z0, boxes.map { |b| b[4] }.max - y0, boxes.map { |b| b[5] }.max - z0]
    end

    # Shows or hides the door pieces (the Door tick).
    def self.show(root, visible)
      paths = root.get_attribute(AttributeManager::DICTIONARY, 'custom_door').to_s.split(';').reject(&:empty?)
      paths.each { |text| entity_at(root, text.split('>').map(&:to_i))&.first&.visible = visible }
    end

    # The model standing in the cabinet's component (everything in it but the handle).
    def self.model_of(root)
      root.definition.entities.grep(Sketchup::ComponentInstance).find { |item| item.name != 'Handle' }
    end

    # The groups and components under `entity` (to MAX_DEPTH), yielded with the chain of what holds them and their path of child numbers.
    def self.scan(entity, chain, path, depth, &block)
      children(entity).each_with_index do |child, index|
        block.call(child, chain, path + [index])
        scan(child, chain + [child], path + [index], depth + 1, &block) if depth + 1 < MAX_DEPTH
      end
    end

    def self.children(entity)
      entities = entity.respond_to?(:definition) ? entity.definition.entities : entity.entities
      entities.select { |item| item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance) }
    end

    # The entity at `path` below the cabinet's model, with what holds it ([entity, chain]); nil when it is not there. With `unique` each
    # holder is made unique first, so that a copy of the cabinet is not changed along with it.
    def self.entity_at(root, path, unique: false)
      inner = model_of(root)
      return nil unless inner

      entity = inner
      chain = [inner]
      path.each_with_index do |index, step|
        entity.make_unique if unique && entity.respond_to?(:make_unique) && entity.definition.count_instances > 1
        entity = children(entity)[index]
        return nil unless entity

        chain << entity unless step == path.length - 1
      end
      [entity, chain]
    end

    # [x0, y0, z0, x1, y1, z1] in mm, in the frame of the cabinet's component, of an entity held by `chain`.
    def self.bounds(entity, chain)
      space = chain.reduce(Geom::Transformation.new) { |all, ancestor| all * ancestor.transformation }
      box = entity.bounds
      points = (0..7).map { |i| space * box.corner(i) }
      [points.map { |p| p.x.to_mm }.min, points.map { |p| p.y.to_mm }.min, points.map { |p| p.z.to_mm }.min,
       points.map { |p| p.x.to_mm }.max, points.map { |p| p.y.to_mm }.max, points.map { |p| p.z.to_mm }.max]
    end
  end
end
