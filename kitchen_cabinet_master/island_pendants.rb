# frozen_string_literal: true

module KitchenCabinetMaster
  # Pendant lights hung from the ceiling over an island's seating overhang: a thin cord and a round shade each, evenly spread along the island.
  # Pure maths in `positions` / `parts` (millimetres, in the frame of the island's first unit: Y along the island, X from its back to its front),
  # `build` draws them.
  module IslandPendants
    SPACING = 800.0      # about one light for this much island
    SHADE_RADIUS = 150.0
    SHADE_HEIGHT = 180.0
    SHADE_BOTTOM = 1700.0 # the underside of the shade above the floor (the worktop is at 900)
    CORD = 8.0
    MATERIAL = 'Stainless Steel'

    # Where the lights are along an island of `length`: the middles of equal parts.
    def self.positions(length)
      count = [(length.to_f / SPACING).floor, 1].max
      count = 1 if length.to_f < 2 * SHADE_RADIUS
      Array.new(count) { |i| ((i + 0.5) * length.to_f / count).round(2) }
    end

    # [{ centre: [x, y], shade: [z0, z1], cord: [z0, z1] }] for the lights of `pendants` ({ positions:, back:, top: }); the cord stops at the ceiling.
    def self.parts(pendants)
      x = -pendants[:back].to_f / 2.0 # over the middle of the overhang, where the stools are
      top = pendants[:top].to_f
      shade_top = SHADE_BOTTOM + SHADE_HEIGHT
      pendants[:positions].map do |y|
        { centre: [x, y], shade: [SHADE_BOTTOM, shade_top], cord: [shade_top, [top, shade_top].max] }
      end
    end

    # One group "Island Pendants" in the model, placed by `frame` (the transformation of the island's first unit).
    def self.build(model, entities, frame, pendants)
      group = entities.add_group
      group.name = 'Island Pendants'
      material = model.materials[MATERIAL]
      parts(pendants).each_with_index do |light, index|
        one = group.entities.add_group
        one.name = "Island Pendant #{index + 1}"
        x, y = light[:centre]
        cylinder(one.entities, x, y, light[:shade], SHADE_RADIUS)
        cylinder(one.entities, x, y, light[:cord], CORD / 2.0) if light[:cord][1] - light[:cord][0] > 1.0
        one.material = material if material
      end
      group.transformation = frame
      group
    end

    def self.cylinder(entities, x, y, (z0, z1), radius)
      edges = entities.add_circle(Geom::Point3d.new(x.mm, y.mm, z0.mm), Geom::Vector3d.new(0, 0, 1), radius.mm, 24)
      face = entities.add_face(edges)
      face.reverse! if face.normal.z.negative?
      face.pushpull((z1 - z0).mm)
    end
    private_class_method :cylinder
  end
end