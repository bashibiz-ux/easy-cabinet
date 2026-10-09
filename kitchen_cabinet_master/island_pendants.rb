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
    SHAPES = %w[drum cone dome globe].freeze # a straight drum, a cone, a half sphere, a ball
    SEGMENTS = 24
    SIZES = { 'small' => 0.75, 'medium' => 1.0, 'large' => 1.4 }.freeze # how much of the usual shade (across and tall); the underside stays put
    MATERIAL = 'Stainless Steel'
    COLOURS = ['Stainless Steel', 'Matt Black Metal', 'Brass', 'Brushed Brass', 'Copper', 'Chrome', 'Gunmetal', 'PVC White', 'Navy Blue', 'Sage Green'].freeze

    # Where the lights are along an island of `length`: the middles of equal parts.
    def self.positions(length)
      count = [(length.to_f / SPACING).floor, 1].max
      count = 1 if length.to_f < 2 * SHADE_RADIUS
      Array.new(count) { |i| ((i + 0.5) * length.to_f / count).round(2) }
    end

    # The outline of a shade, from its underside to its top, as [radius, height above the floor] points that are turned round its axis.
    def self.profile(shape, size = 'medium')
      scale = SIZES.fetch(size.to_s, 1.0)
      b = SHADE_BOTTOM
      h = SHADE_HEIGHT
      r = SHADE_RADIUS
      case shape
      when 'cone' then [[r, b], [50.0, b + h]]
      when 'dome' then (0..4).map { |i| a = i * Math::PI / 8.0; [(r * Math.cos(a)).round(2), (b + (h * Math.sin(a))).round(2)] }
      when 'globe' then (0..6).map { |i| a = i * Math::PI / 6.0; [(120.0 * Math.sin(a)).round(2), (b + 120.0 - (120.0 * Math.cos(a))).round(2)] }
      else [[r, b], [r, b + h]]
      end.map { |radius, z| [(radius * scale).round(2), (b + ((z - b) * scale)).round(2)] }
    end

    # [{ centre: [x, y], shade: [bottom, top], cord: [z0, z1], profile: [[radius, z]] }] for the lights of `pendants` ({ positions:, back:, top:,
    # material:, shape: }); the cord stops at the ceiling.
    def self.parts(pendants)
      x = -pendants[:back].to_f / 2.0 # over the middle of the overhang, where the stools are
      top = pendants[:top].to_f
      outline = profile(pendants[:shape].to_s, pendants[:size])
      shade_top = outline.last[1]
      pendants[:positions].map do |y|
        { centre: [x, y], shade: [SHADE_BOTTOM, shade_top], cord: [shade_top, [top, shade_top].max], profile: outline }
      end
    end
    # One group "Island Pendants" in the model, placed by `frame` (the transformation of the island's first unit).
    def self.build(model, entities, frame, pendants)
      group = entities.add_group
      group.name = 'Island Pendants'
      material = MaterialManager.ensure_material(model, pendants[:material] || MATERIAL)
      parts(pendants).each_with_index do |light, index|
        one = group.entities.add_group
        one.name = "Island Pendant #{index + 1}"
        x, y = light[:centre]
        lathe(one.entities, x, y, light[:profile])
        cylinder(one.entities, x, y, light[:cord], CORD / 2.0) if light[:cord][1] - light[:cord][0] > 1.0
        one.material = material if material
      end
      group.transformation = frame
      group
    end

    # The shade: rings of SEGMENTS points at each point of the outline, joined by faces, with a flat cap on an end that has a radius.
    def self.lathe(entities, x, y, outline)
      rings = outline.map do |radius, z|
        radius.zero? ? [Geom::Point3d.new(x.mm, y.mm, z.mm)] : Array.new(SEGMENTS) { |k| a = k * 2 * Math::PI / SEGMENTS; Geom::Point3d.new((x + (radius * Math.cos(a))).mm, (y + (radius * Math.sin(a))).mm, z.mm) }
      end
      rings.each_cons(2) do |low, high|
        SEGMENTS.times do |k|
          n = (k + 1) % SEGMENTS
          corners = [low[k % low.length], low[n % low.length], high[n % high.length], high[k % high.length]].chunk_while { |a, b| a == b }.map(&:first)
          entities.add_face(corners) if corners.length >= 3
        end
      end
      [rings.first, rings.last].each { |ring| entities.add_face(ring) if ring.length > 2 }
    end
    private_class_method :lathe

    def self.cylinder(entities, x, y, (z0, z1), radius)
      edges = entities.add_circle(Geom::Point3d.new(x.mm, y.mm, z0.mm), Geom::Vector3d.new(0, 0, 1), radius.mm, 24)
      face = entities.add_face(edges)
      face.reverse! if face.normal.z.negative?
      face.pushpull((z1 - z0).mm)
    end
    private_class_method :cylinder
  end
end