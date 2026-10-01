# frozen_string_literal: true

module KitchenCabinetMaster
  # Creates the plain rectangular panel component definitions.
  #
  # Definitions are shared: two panels of the same size (e.g. the left and right
  # side) use ONE definition and are separate instances. A definition is named
  # after its size, so any cabinet needing that size finds and reuses it.
  # Panels are unpainted; the material is applied to each instance.
  module PanelGenerator
    NAME_PREFIX = 'Panel '

    # size - [x, y, z] in millimetres (depth, width, height)
    def self.definition(model, size)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      name = format('%<prefix>s%<x>g x %<y>g x %<z>g', prefix: NAME_PREFIX, x: dx, y: dy, z: dz)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_box(definition.entities, dx.mm, dy.mm, dz.mm)
      definition
    end

    # A solid extruded from an arbitrary flat outline in the X-Y plane, `points`
    # -> [[x, y], ...] in millimetres, going around in order. Used for a corner
    # unit's bottom panel and shelves, which are not plain rectangles (see
    # CabinetLayout.corner_footprint). Named after its own points, so two
    # shelves of the same corner cabinet (identical shape, different height)
    # share one definition.
    def self.polygon_definition(model, points, thickness)
      key = points.flatten.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('-')
      thick = (thickness.to_f * 100).round / 100.0
      name = format('%sCorner %s t%g', NAME_PREFIX, key, thick)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_polygon(definition.entities, points, thick.mm)
      definition
    end

    # A slab (size [x, y, z] in mm) whose FRONT-TOP edge (the high X side, top Z) is
    # rounded with `radius`: the profile in the X-Z plane, pushed out along Y. Named after
    # its size and radius, so equal pieces share one definition.
    ROUND_STEPS = 8

    def self.rounded_definition(model, size, radius)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      r = [[radius.to_f, dz].min, dx].min
      name = format('%<prefix>sRounded %<x>g x %<y>g x %<z>g r%<r>g', prefix: NAME_PREFIX, x: dx, y: dy, z: dz, r: r)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_rounded(definition.entities, dx, dy, dz, r)
      definition
    end

    # Removes a definition this extension created once nothing uses it any more.
    def self.discard_if_unused(model, definition)
      return unless definition && definition.valid?
      return unless AttributeManager.managed?(definition)
      return unless definition.count_instances.zero?

      # Definitions nested inside (a handle's parts, for example) may become unused too.
      children = definition.entities.grep(Sketchup::ComponentInstance).map(&:definition).uniq
      model.definitions.remove(definition)
      children.each { |child| discard_if_unused(model, child) }
    rescue StandardError => e
      # Clean-up is optional (Purge Unused would catch it later), so never fail an operation for it.
      warn "[Kitchen Cabinet Master] Could not remove unused definition: #{e.message}"
    end

    # A solid box with its minimum corner at the definition origin.
    def self.build_box(entities, dx, dy, dz)
      face = entities.add_face([0, 0, 0], [dx, 0, 0], [dx, dy, 0], [0, dy, 0])
      face.reverse! if face.normal.z < 0
      face.pushpull(dz)
    end
    private_class_method :build_box

    # The slab's profile (X across, Z up) with one rounded corner, extruded along Y.
    def self.build_rounded(entities, dx, dy, dz, radius)
      profile = [[0.0, 0.0], [dx, 0.0]]
      if radius.positive?
        centre = [dx - radius, dz - radius]
        profile << [dx, dz - radius]
        (1...ROUND_STEPS).each do |step|
          angle = (Math::PI / 2.0) * step / ROUND_STEPS
          profile << [centre[0] + (radius * Math.cos(angle)), centre[1] + (radius * Math.sin(angle))]
        end
        profile << [dx - radius, dz]
      else
        profile << [dx, dz]
      end
      profile << [0.0, dz]

      face = entities.add_face(profile.map { |x, z| [x.mm, 0, z.mm] })
      face.reverse! if face.normal.y < 0
      face.pushpull(dy.mm)
    end
    private_class_method :build_rounded

    # A flat, horizontal solid: `points` outline pushed up by `thickness`.
    def self.build_polygon(entities, points, thickness)
      face = entities.add_face(points.map { |x, y| [x.mm, y.mm, 0] })
      face.reverse! if face.normal.z < 0
      face.pushpull(thickness)
    end
    private_class_method :build_polygon
  end
end
