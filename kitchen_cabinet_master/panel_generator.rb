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

    # A flat slab with an outline of `points` whose top edge number `edge` (the one from
    # points[edge] to the next point) is rounded with `radius`. Named after its points,
    # thickness, radius and edge, so equal slabs share one definition.
    def self.rounded_polygon_definition(model, points, thickness, radius, edge)
      key = points.flatten.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('-')
      thick = (thickness.to_f * 100).round / 100.0
      r = [radius.to_f, thick].min
      name = format('%sCorner %s t%g r%g e%d', NAME_PREFIX, key, thick, r, edge)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      rounded_polygon_faces(points, thick, r, edge).each do |corners|
        definition.entities.add_face(corners.map { |x, y, z| [x.mm, y.mm, z.mm] })
      end
      definition
    end

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of that solid. Pure maths:
    # the edge's profile (square at the bottom, a quarter circle at the top) is swept along the
    # edge, and the two faces next to it follow the profile so the solid stays closed.
    def self.rounded_polygon_faces(points, thickness, radius, edge)
      count = points.length
      area = points.each_with_index.sum { |(x, y), i| nx, ny = points[(i + 1) % count]; (x * ny) - (nx * y) }
      a = points[edge]
      b = points[(edge + 1) % count]
      before = points[(edge - 1) % count]
      after = points[(edge + 2) % count]

      along = unit2([b[0] - a[0], b[1] - a[1]])
      inward = area.positive? ? [-along[1], along[0]] : [along[1], -along[0]]
      toward_a = unit2([before[0] - a[0], before[1] - a[1]])
      toward_b = unit2([after[0] - b[0], after[1] - b[1]])

      # The profile: [how far in from the edge, height], bottom to top.
      profile = [[0.0, 0.0]]
      (0..ROUND_STEPS).each do |step|
        angle = (Math::PI / 2.0) * step / ROUND_STEPS
        profile << [radius - (radius * Math.cos(angle)), thickness - radius + (radius * Math.sin(angle))]
      end
      profile = [[0.0, 0.0], [0.0, thickness]] if radius <= 0.0

      slide = lambda do |origin, direction, offset|
        slant = (direction[0] * inward[0]) + (direction[1] * inward[1])
        step = slant > 0.05 ? offset / slant : 0.0
        [origin[0] + (direction[0] * step), origin[1] + (direction[1] * step)]
      end
      ring_a = profile.map { |off, z| [*slide.call(a, toward_a, off), z] }
      ring_b = profile.map { |off, z| [*slide.call(b, toward_b, off), z] }

      at = ->(point, z) { [point[0], point[1], z] }
      faces = [points.map { |p| at.call(p, 0.0) }]
      top = points.each_with_index.map do |p, i|
        if i == edge then ring_a.last
        elsif i == (edge + 1) % count then ring_b.last
        else at.call(p, thickness)
        end
      end
      faces << top

      count.times do |i|
        next_i = (i + 1) % count
        p = points[i]
        q = points[next_i]
        faces << if i == edge
                   nil
                 elsif next_i == edge
                   [at.call(p, 0.0)] + ring_a + [at.call(p, thickness)]
                 elsif i == (edge + 1) % count
                   [ring_b.first, at.call(q, 0.0), at.call(q, thickness)] + ring_b.reverse[0...-1]
                 else
                   [at.call(p, 0.0), at.call(q, 0.0), at.call(q, thickness), at.call(p, thickness)]
                 end
      end
      faces.compact!

      (0...(profile.length - 1)).each { |k| faces << [ring_a[k], ring_b[k], ring_b[k + 1], ring_a[k + 1]] }
      outwards(faces)
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
    def self.unit2(vector)
      length = Math.sqrt((vector[0]**2) + (vector[1]**2))
      length.zero? ? [0.0, 0.0] : [vector[0] / length, vector[1] / length]
    end
    private_class_method :unit2

    # Turns every face so its normal points away from the middle of the solid.
    def self.outwards(faces)
      points = faces.flatten(1)
      middle = [0, 1, 2].map { |axis| points.sum { |p| p[axis] } / points.length }
      faces.map do |face|
        normal = [0.0, 0.0, 0.0]
        face.each_with_index do |p, i|
          q = face[(i + 1) % face.length]
          normal[0] += (p[1] - q[1]) * (p[2] + q[2])
          normal[1] += (p[2] - q[2]) * (p[0] + q[0])
          normal[2] += (p[0] - q[0]) * (p[1] + q[1])
        end
        centre = [0, 1, 2].map { |axis| face.sum { |p| p[axis] } / face.length }
        facing = (0..2).sum { |axis| normal[axis] * (centre[axis] - middle[axis]) }
        facing.negative? ? face.reverse : face
      end
    end
    private_class_method :outwards
  end
end
