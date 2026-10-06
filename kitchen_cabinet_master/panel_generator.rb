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
    # `holes` ([[x0, x1, y0, y1], ...] in mm, in the top face) are openings cut right through it (a worktop's sink or hob).
    def self.definition(model, size, holes = nil)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      name = format('%<prefix>s%<x>g x %<y>g x %<z>g', prefix: NAME_PREFIX, x: dx, y: dy, z: dz) + hole_suffix(holes)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_box(definition.entities, dx.mm, dy.mm, dz.mm)
      cut_holes(definition.entities, holes, dz)
      definition
    end

    # A name part that tells slabs with different openings apart.
    def self.hole_suffix(holes)
      return '' if holes.nil? || holes.empty?

      ' h' + holes.map { |hole| hole.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('.') }.join('_')
    end

    # Cuts each hole (a rectangle in the top face, at height `top` mm) through to the bottom. A hole that cannot be
    # cut is skipped rather than failing the whole worktop.
    def self.cut_holes(entities, holes, top)
      Array(holes).each do |x0, x1, y0, y1|
        z = top.mm
        face = entities.add_face([x0.mm, y0.mm, z], [x1.mm, y0.mm, z], [x1.mm, y1.mm, z], [x0.mm, y1.mm, z])
        face.pushpull(face.normal.z.positive? ? -z : z)
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Could not cut an opening: #{e.message}"
      end
    end

    # A solid extruded from an arbitrary flat outline in the X-Y plane, `points`
    # -> [[x, y], ...] in millimetres, going around in order. Used for a corner
    # unit's bottom panel and shelves, which are not plain rectangles (see
    # CabinetLayout.corner_footprint). Named after its own points, so two
    # shelves of the same corner cabinet (identical shape, different height)
    # share one definition.
    def self.polygon_definition(model, points, thickness, holes = nil)
      key = points.flatten.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('-')
      thick = (thickness.to_f * 100).round / 100.0
      name = format('%sCorner %s t%g', NAME_PREFIX, key, thick) + hole_suffix(holes)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_polygon(definition.entities, points, thick.mm)
      soften(definition.entities)
      cut_holes(definition.entities, holes, thick)
      definition
    end

    # How a front (thickness along x, width along y, height along z, outer face at high x) is turned into a part: `map` takes a
    # point of the front to one of the part, `flip` says the turn mirrors it (faces are then drawn the other way round), `outward` is
    # the way the outer face looks in the part.
    Frame = Struct.new(:map, :flip, :outward)
    FRONT_FRAME = Frame.new(->(x, y, z) { [x, y, z] }, false, [1.0, 0.0, 0.0]).freeze

    # The frame of an end panel `thickness` thick, whose outer face is the low-Y face on the left of a cabinet, the high-Y one on
    # its right. (Across that face runs the depth, up it the height.)
    def self.end_panel_frame(side, thickness)
      if side.to_s == 'left'
        Frame.new(->(x, y, z) { [y, thickness - x, z] }, false, [0.0, -1.0, 0.0])
      else
        Frame.new(->(x, y, z) { [y, x, z] }, true, [0.0, 1.0, 0.0])
      end
    end

    # A door or drawer front (size [thickness, width, height] in mm; its outer face is the high-X face) with the shapes of a design
    # cut into that face (see FrontDesign). A front too small for the design is a plain board. Named after its design and size, so
    # equal fronts share one definition.
    # The edges around the outer face are rounded with `radius` mm (0 = square edges), smooth like a worktop's front edge.
    def self.front_definition(model, size, design, radius = 0.0)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      r = front_radius(dx, dy, dz, radius)
      cuts = FrontDesign.cuts(design, dy, dz, dx)
      return definition(model, size) if cuts.empty? && r.zero?

      name = format('%<prefix>sFront %<design>s %<x>g x %<y>g x %<z>g r%<r>g s%<s>d', prefix: NAME_PREFIX, design: design, x: dx, y: dy, z: dz, r: r, s: FRONT_STEPS)
      faced_definition(model, name, [dx, dy, dz], [dx, dy, dz], r, cuts, FRONT_FRAME)
    end

    # An end panel (size [depth, thickness, height] in mm) with its outer face rounded and the shapes of a design cut into it.
    def self.panel_face_definition(model, size, design, side, radius = 0.0)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      r = front_radius(dy, dx, dz, radius)
      cuts = FrontDesign.cuts(design, dx, dz, dy)
      return definition(model, size) if cuts.empty? && r.zero?

      name = format('%<prefix>sFace %<design>s %<side>s %<x>g x %<y>g x %<z>g r%<r>g s%<s>d', prefix: NAME_PREFIX, design: design, side: side, x: dx, y: dy, z: dz, r: r, s: FRONT_STEPS)
      faced_definition(model, name, [dy, dx, dz], [dx, dy, dz], r, cuts, end_panel_frame(side, dy))
    end

    # `front` is [thickness, width, height] of the front in its own frame, `box` the size of the part (the same numbers in the
    # part's own order).
    def self.faced_definition(model, name, front, box, r, cuts, frame)
      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      thickness, width, height = front
      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      if r.positive?
        rounded_front_faces(thickness, width, height, r).each { |corners| add_mapped(definition.entities, corners, frame) }
      else
        build_box(definition.entities, box[0].mm, box[1].mm, box[2].mm)
      end
      # (the rounded border is not flat: a cut stays inside the flat middle of the face)
      cut_front(definition.entities, clip_cuts(cuts, width, height, r), thickness, r, frame)
      soften(definition.entities)
      definition
    end

    def self.add_mapped(entities, corners, frame, flip = true)
      corners = corners.reverse if flip && frame.flip
      entities.add_face(corners.map { |x, y, z| frame.map.call(x, y, z).map(&:mm) })
    end
    private_class_method :add_mapped

    FRONT_STEPS = 16

    # The radius a front of this size can have: never more than its thickness less 1 mm, or under 1 mm from half its width or height.
    def self.front_radius(thickness, width, height, radius)
      r = [radius.to_f, thickness - 1.0, (width / 2.0) - 1.0, (height / 2.0) - 1.0].min
      r < 0.2 ? 0.0 : (r * 100).round / 100.0
    end

    # The cuts of a design kept inside the flat face (`radius` in from every edge, twice that for a pocket with a rounded lip); a cut that is left under 1 mm is dropped.
    def self.clip_cuts(cuts, width, height, radius)
      return cuts unless radius.positive?

      cuts.filter_map do |y0, y1, z0, z1, from, to|
        margin = round_lip?([y0, y1, z0, z1, from, to]) ? radius * 2.0 : radius # (a rounded lip needs room for its curve too)
        y0 = [y0, margin].max
        y1 = [y1, width - margin].min
        z0 = [z0, margin].max
        z1 = [z1, height - margin].min
        [y0, y1, z0, z1, from, to] if y1 - y0 >= 1.0 && z1 - z0 >= 1.0
      end
    end

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of a front `dx` x `dy` x `dz` (its outer face is the high-X one)
    # whose outer edges are rounded with `r`: rings of rectangles, each a little further in and out than the one before, joined
    # by flat strips (mitred at the corners). Pure maths.
    def self.rounded_front_faces(dx, dy, dz, r)
      rings = (0..FRONT_STEPS).map do |step|
        angle = (Math::PI / 2.0) * step / FRONT_STEPS
        inset = (r - (r * Math.cos(angle))).round(4)
        x = (dx - r + (r * Math.sin(angle))).round(4)
        [[x, inset, inset], [x, dy - inset, inset], [x, dy - inset, dz - inset], [x, inset, dz - inset]]
      end
      rings.unshift([[0.0, 0.0, 0.0], [0.0, dy, 0.0], [0.0, dy, dz], [0.0, 0.0, dz]]) # the back
      faces = [rings.first, rings.last]
      rings.each_cons(2) { |a, b| 4.times { |e| faces << [a[e], a[(e + 1) % 4], b[(e + 1) % 4], b[e]] } }
      centre = [dx / 2.0, dy / 2.0, dz / 2.0]
      faces.map do |corners|
        normal = newell_normal(corners)
        mid = corners.transpose.map { |values| values.sum / corners.length }
        outward = (0..2).sum { |i| normal[i] * (mid[i] - centre[i]) }
        outward.negative? ? corners.reverse : corners
      end
    end

    def self.newell_normal(corners)
      n = [0.0, 0.0, 0.0]
      corners.each_with_index do |(x, y, z), i|
        nx, ny, nz = corners[(i + 1) % corners.length]
        n[0] += (y - ny) * (z + nz)
        n[1] += (z - nz) * (x + nx)
        n[2] += (x - nx) * (y + ny)
      end
      n
    end
    private_class_method :newell_normal

    # A pocket big enough (20 mm either way) gets a rounded lip and rounded inner corners.
    MIN_ROUND_POCKET = 20.0

    def self.round_lip?(cut)
      [cut[1] - cut[0], cut[3] - cut[2]].min >= MIN_ROUND_POCKET
    end

    # The faces (arrays of [x, y, z] in mm, each facing into the pocket) of a pocket y0..y1 x z0..z1 cut from `from` to `to` mm inside the
    # face of a front `thickness` thick. Its lip (the edge where the face meets the wall) is rounded with `radius` and so is the inner
    # corner where the wall meets the floor (as far as the depth allows): rings of rectangles, each a little further in and out than the
    # one before, joined by flat strips. The first ring (the outline of the pocket's mouth, `radius` mm outside the wall) is where the
    # pocket joins the face. Pure maths.
    def self.rounded_pocket_faces(y0, y1, z0, z1, from, to, thickness, radius)
      top = thickness - from
      depth = to - from
      ring = lambda do |x, grow|
        [[x, y0 - grow, z0 - grow], [x, y1 + grow, z0 - grow], [x, y1 + grow, z1 + grow], [x, y0 - grow, z1 + grow]].map { |p| p.map { |v| v.round(4) } }
      end
      rings = (0..FRONT_STEPS).map do |step|
        angle = (Math::PI / 2.0) * step / FRONT_STEPS
        ring.call(top - (radius * (1.0 - Math.cos(angle))), radius * (1.0 - Math.sin(angle)))
      end
      corner = [radius, depth - radius].min
      if corner >= 0.3
        (0..FRONT_STEPS).each do |step|
          angle = (Math::PI / 2.0) * step / FRONT_STEPS
          rings << ring.call(top - depth + corner - (corner * Math.sin(angle)), -corner * (1.0 - Math.cos(angle)))
        end
      else
        rings << ring.call(top - depth, 0.0)
      end
      rings = rings.each_with_object([]) { |item, kept| kept << item unless kept.last == item }
      faces = [rings.last]
      rings.each_cons(2) { |a, b| 4.times { |e| faces << [a[e], a[(e + 1) % 4], b[(e + 1) % 4], b[e]] } }
      centre = [(y0 + y1) / 2.0, (z0 + z1) / 2.0]
      faces.map do |corners|
        normal = newell_normal(corners)
        mid = corners.transpose.map { |values| values.sum / corners.length }
        toward = [centre[0] - mid[1], centre[1] - mid[2]]
        length = Math.sqrt((toward[0]**2) + (toward[1]**2))
        inward = length < 1e-9 ? 0.0 : ((normal[1] * toward[0]) + (normal[2] * toward[1])) / length
        (normal[0] + inward).negative? ? corners.reverse : corners
      end
    end

    # Cuts each rectangle into the outer face: a face drawn on the plane `from` mm inside it, pushed in to `to` mm. With `lip` above
    # zero a big pocket has its lip and inner corners rounded (see rounded_pocket_faces).
    def self.cut_front(entities, cuts, thickness, lip = 0.0, frame = FRONT_FRAME)
      cuts.each do |y0, y1, z0, z1, from, to|
        s = [lip, to - from - 0.5].min # (the curve is never deeper than the pocket)
        if s >= 0.3 && round_lip?([y0, y1, z0, z1, from, to])
          x = thickness - from
          mouth = [[x, y0 - s, z0 - s], [x, y1 + s, z0 - s], [x, y1 + s, z1 + s], [x, y0 - s, z1 + s]]
          add_mapped(entities, mouth, frame, false).erase! # a hole in the face, the pocket's mouth
          rounded_pocket_faces(y0, y1, z0, z1, from, to, thickness, s).each { |corners| add_mapped(entities, corners, frame) }
          next
        end
        cut_flat(entities, y0, y1, z0, z1, from, to, thickness, frame)
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Could not cut a front design: #{e.message}"
      end
    end

    def self.cut_flat(entities, y0, y1, z0, z1, from, to, thickness, frame)
      x = thickness - from
      face = add_mapped(entities, [[x, y0, z0], [x, y1, z0], [x, y1, z1], [x, y0, z1]], frame, false)
      depth = (to - from).mm
      normal = face.normal
      outward = (normal.x * frame.outward[0]) + (normal.y * frame.outward[1]) + (normal.z * frame.outward[2])
      face.pushpull(outward.positive? ? -depth : depth)
    end
    # A round bar or disc inside the box `size` ([x, y, z] in mm): a circle across the two short sides, pushed out along
    # `axis` ('x', 'y' or 'z'). Named after its size and axis, so equal bars share one definition.
    # Round things are drawn with many sides and their edges smoothed, so that they look round: 16 sides for a pin, 32 for a
    # knob, 48 for anything wider.
    def self.segments_for(diameter)
      diameter <= 14.0 ? 16 : (diameter <= 40.0 ? 32 : 48)
    end
    TUBE_SEGMENTS = 32

    def self.cylinder_definition(model, size, axis)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      sides = segments_for(across_of(dx, dy, dz, axis.to_s).max)
      name = format('%<prefix>sCylinder %<a>s %<x>g x %<y>g x %<z>g s%<s>d', prefix: NAME_PREFIX, a: axis, x: dx, y: dy, z: dz, s: sides)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_cylinder(definition.entities, dx, dy, dz, axis.to_s, sides)
      soften(definition.entities)
      definition
    end

    def self.across_of(dx, dy, dz, axis)
      { 'x' => [dy, dz], 'y' => [dx, dz], 'z' => [dx, dy] }[axis]
    end
    private_class_method :across_of

    # Edges between faces that are nearly flat to each other (the sides of a round part, a rounded edge) are made soft and
    # smooth, so the surface shades as one curve; the sharp edges stay.
    def self.soften(entities, limit_degrees = 40.0)
      limit = limit_degrees * Math::PI / 180.0
      entities.grep(Sketchup::Edge).each do |edge|
        faces = edge.faces
        next unless faces.length == 2 && faces[0].normal.angle_between(faces[1].normal) < limit

        edge.soft = true
        edge.smooth = true
      end
    end

    # A bent pipe `diameter` mm thick that follows `path` (points [x, y, z] in mm, the first at the origin): a circle swept
    # along the path with Follow Me. Should that fail, the pipe is made of one straight piece per leg of the path.
    def self.tube_definition(model, path, diameter)
      key = path.flatten.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('-')
      name = format('%<prefix>sTube %<key>s d%<d>g s%<s>d', prefix: NAME_PREFIX, key: key, d: diameter, s: TUBE_SEGMENTS)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_tube(definition.entities, path, diameter)
      soften(definition.entities)
      definition
    end

    # A slab (size [x, y, z] in mm) whose FRONT-TOP edge (the high X side, top Z) is
    # rounded with `radius`: the profile in the X-Z plane, pushed out along Y. Named after
    # its size and radius, so equal pieces share one definition.
    ROUND_STEPS = 24

    def self.rounded_definition(model, size, radius, holes = nil)
      dx, dy, dz = size.map { |v| (v.to_f * 100).round / 100.0 }
      r = [[radius.to_f, dz].min, dx].min
      name = format('%<prefix>sRounded %<x>g x %<y>g x %<z>g r%<r>g', prefix: NAME_PREFIX, x: dx, y: dy, z: dz, r: r) + " s#{ROUND_STEPS}" + hole_suffix(holes)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      build_rounded(definition.entities, dx, dy, dz, r)
      soften(definition.entities)
      cut_holes(definition.entities, holes, dz)
      definition
    end

    # A flat slab with an outline of `points` whose top edge number `edge` (the one from
    # points[edge] to the next point) is rounded with `radius`. Named after its points,
    # thickness, radius and edge, so equal slabs share one definition.
    def self.rounded_polygon_definition(model, points, thickness, radius, edge, holes = nil)
      key = points.flatten.map { |v| format('%g', (v.to_f * 100).round / 100.0) }.join('-')
      thick = (thickness.to_f * 100).round / 100.0
      r = [radius.to_f, thick].min
      name = format('%sCorner %s t%g r%g e%s s%d', NAME_PREFIX, key, thick, r, Array(edge).join('.'), ROUND_STEPS) + hole_suffix(holes)

      existing = model.definitions[name]
      return existing if existing && AttributeManager.managed?(existing)

      definition = model.definitions.add(name)
      AttributeManager.mark_managed(definition)
      rounded_polygon_faces(points, thick, r, edge).each do |corners|
        definition.entities.add_face(corners.map { |x, y, z| [x.mm, y.mm, z.mm] })
      end
      soften(definition.entities)
      cut_holes(definition.entities, holes, thick)
      definition
    end

    # The faces (arrays of [x, y, z] in mm, each facing outwards) of that solid. Pure maths:
    # the edge's profile (square at the bottom, a quarter circle at the top) is swept along the
    # edge, and the two faces next to it follow the profile so the solid stays closed.
    def self.rounded_polygon_faces(points, thickness, radius, edge)
      return rounded_orthogonal_faces(points, thickness, radius, edge) if edge.is_a?(Array) # several edges (an L worktop's two fronts)

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

    # The same for an outline whose corners are all right angles (an L), with a list of edges to round. Each ring of
    # the profile moves the corners of the rounded edges in, along the inward direction of every rounded edge that
    # meets there, so the front of an L keeps its inside corner square in plan and round in section.
    def self.rounded_orthogonal_faces(points, thickness, radius, edges)
      count = points.length
      area = points.each_with_index.sum { |(x, y), i| nx, ny = points[(i + 1) % count]; (x * ny) - (nx * y) }
      outward = lambda do |i|
        along = unit2([points[(i + 1) % count][0] - points[i][0], points[(i + 1) % count][1] - points[i][1]])
        area.positive? ? [along[1], -along[0]] : [-along[1], along[0]]
      end
      profile = [[0.0, 0.0], [0.0, thickness - radius]]
      (1..ROUND_STEPS).each do |step|
        angle = (Math::PI / 2.0) * step / ROUND_STEPS
        profile << [radius - (radius * Math.cos(angle)), thickness - radius + (radius * Math.sin(angle))]
      end
      profile = [[0.0, 0.0], [0.0, thickness]] if radius <= 0.0

      rings = profile.map do |off, z|
        points.each_with_index.map do |(x, y), i|
          moved = edges.select { |e| i == e || i == (e + 1) % count }
          [x - moved.sum { |e| outward.call(e)[0] * off }, y - moved.sum { |e| outward.call(e)[1] * off }, z]
        end
      end

      faces = []
      faces << orient(points.map { |x, y| [x, y, 0.0] }) { |n| n[2].negative? }
      faces << orient(rings.last.dup) { |n| n[2].positive? }
      rings.each_cons(2) do |low, high|
        count.times do |i|
          j = (i + 1) % count
          face = [low[i], low[j], high[j], high[i]].each_with_object([]) { |p, kept| kept << p unless kept.last == p }
          face.pop if face.length > 1 && face.first == face.last
          next if face.length < 3

          out = outward.call(i)
          faces << orient(face) { |n| ((n[0] * out[0]) + (n[1] * out[1])) > 1e-9 || (n[0].abs < 1e-9 && n[1].abs < 1e-9) }
        end
      end
      faces
    end

    # `face` turned round if the test on its normal says it faces the wrong way.
    def self.orient(face)
      normal = [0.0, 0.0, 0.0]
      face.each_with_index do |p, i|
        q = face[(i + 1) % face.length]
        normal[0] += (p[1] - q[1]) * (p[2] + q[2])
        normal[1] += (p[2] - q[2]) * (p[0] + q[0])
        normal[2] += (p[0] - q[0]) * (p[1] + q[1])
      end
      yield(normal) ? face : face.reverse
    end
    private_class_method :orient

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

    # The circle of the pipe at the start of the path, swept along it.
    def self.build_tube(entities, path, diameter)
      points = path.map { |x, y, z| Geom::Point3d.new(x.mm, y.mm, z.mm) }
      radius = (diameter / 2.0).mm
      begin
        edges = entities.add_curve(points)
        circle = entities.add_circle(points[0], points[0].vector_to(points[1]), radius, TUBE_SEGMENTS)
        face = entities.add_face(circle)
        face.followme(edges)
        edges.each { |edge| edge.erase! if edge.valid? && edge.faces.empty? } # the path inside the pipe is no longer needed
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] A bent pipe could not be swept (#{e.message}); drawn in straight pieces."
        entities.clear!
        points.each_cons(2) do |from, to|
          direction = from.vector_to(to)
          next if direction.length.zero?

          ring = entities.add_face(entities.add_circle(from, direction, radius, TUBE_SEGMENTS))
          ring.reverse! if ring.normal.dot(direction).negative?
          ring.pushpull(from.distance(to))
        end
      end
    end
    private_class_method :build_tube

    # The circle of the bar (in the plane across its axis, its middle at the middle of the box) pushed along the axis.
    def self.build_cylinder(entities, dx, dy, dz, axis, sides)
      across = { 'x' => [dy, dz], 'y' => [dx, dz], 'z' => [dx, dy] }[axis]
      length = { 'x' => dx, 'y' => dy, 'z' => dz }[axis]
      ra = across[0] / 2.0
      rb = across[1] / 2.0
      ring = (0...sides).map do |i|
        angle = 2.0 * Math::PI * i / sides
        [ra + (ra * Math.cos(angle)), rb + (rb * Math.sin(angle))]
      end
      points = ring.map do |a, b|
        case axis
        when 'x' then [0, a.mm, b.mm]
        when 'y' then [a.mm, 0, b.mm]
        else [a.mm, b.mm, 0]
        end
      end
      face = entities.add_face(points)
      normal = { 'x' => :x, 'y' => :y, 'z' => :z }[axis]
      face.reverse! if face.normal.send(normal).negative?
      face.pushpull(length.mm)
    end
    private_class_method :build_cylinder

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
