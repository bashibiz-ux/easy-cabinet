# frozen_string_literal: true

module EasyCabinet
  # The things that are fitted into a cabinet and its worktop: a sink (one or two bowls, with or without a drainer
  # tray, mirrored if you want the drainer on the other side) with a mixer tap, a built-in induction hob, and the
  # hood of a hood cabinet. Pure maths, no SketchUp objects: `parts` gives the boards and round bars they are drawn
  # from (in the carcass frame, like the appliances), and `cutouts` the openings the worktop needs over them. All
  # numbers are millimetres in the cabinet's frame: X depth (0 at the wall), Y width, Z up from the carcass bottom.
  module Fixtures
    SINK_BOWL = 400.0      # a bowl is up to this wide
    SINK_DEPTH = 420.0     # and this deep
    SINK_DIVIDER = 30.0    # between two bowls, and between the last bowl and the tray
    SINK_BOWL_DEPTH = 180.0
    SINK_SHIFT = 40.0      # the sink stands this far further to the front
    SINK_RIM = 15.0        # the rim lies this far over the worktop around the opening
    SINK_STEEL = 2.0       # thickness of the steel
    SINK_CORNER = 28.0     # the radius of a bowl's corners
    TEKA_LENGTH = 830.0    # the opening of the Teka sink (860 wide with its 15 mm deck round it)
    TEKA_DEPTH = 480.0     # (510 deep)
    HOB_WIDTH = 860.0      # the widest hob
    HOB_DEPTH = 500.0
    HOB_SHIFT = 40.0       # the hob stands this far further to the front, like the sink (see SINK_SHIFT)
    ARC_STEPS = 12
    TAP_STEPS = 24

    # The sink of a cabinet, or nil when it has none:
    #   rect     [x0, x1, y0, y1] the opening in the worktop
    #   bowls    [rect, ...]      each bowl        dividers [rect, ...] between the bowls
    #   tray     rect or nil      the drainer
    #   tap_u    where the tap stands along the sink (see `place`)
    #   fits     true when it lies inside the carcass
    # The sink is worked out with its length along Y: the bowls, then the drainer on the right. `sink_mirror` (or an
    # older cabinet's half turn) puts the drainer on the left instead: the whole sink is a mirror image.
    def self.sink_plan(params, dims)
      return nil unless params['sink'] == true

      bowls = params['sink_bowls'].to_i == 2 ? 2 : 1
      tray = params['sink_tray'] == true
      mirror = mirrored?(params)
      length_room = dims.inner_w - 40.0
      centre_x = (dims.depth / 2.0) - 10.0 + SINK_SHIFT
      depth_room = [dims.depth - dims.interior_start - 60.0, 2.0 * (dims.depth - 30.0 - centre_x)].min

      # one bowl and a drainer: the Teka Diamond RS15 1B 1D 86 (860 x 510, a 400 x 400 bowl, a white glass deck); two bowls and a drainer: the Teka Zenit RS15 2B 1D R
      # (1160 x 520, two 340 x 400 bowls, all stainless steel); two bowls and no drainer: the Teka Flexlinea RS15 2B 740 (740 x 440, two 340 x 400 bowls); one bowl and
      # no drainer: the Teka Zenit RS15 1B (600 x 520, one 500 x 400 bowl, all stainless steel)
      teka = tray ? (bowls == 1 ? :diamond : :zenit) : (bowls == 2 ? :flexlinea : :zenit1)
      wanted = (bowls * SINK_BOWL) + ((bowls - 1) * SINK_DIVIDER) + (tray ? SINK_BOWL + SINK_DIVIDER : 0.0)
      length = [{ diamond: TEKA_LENGTH, zenit: 1130.0, flexlinea: 710.0, zenit1: 570.0 }.fetch(teka, wanted), length_room].min
      depth = [{ diamond: TEKA_DEPTH, zenit: 490.0, flexlinea: 410.0, zenit1: 490.0 }.fetch(teka, SINK_DEPTH), depth_room].min
      free = length - ((bowls - 1) * SINK_DIVIDER) - (tray ? SINK_DIVIDER : 0.0)
      tray_width = tray ? [free * 0.32, 450.0].min : 0.0
      bowl_width = (free - tray_width) / bowls

      frame = { centre: [centre_x, dims.width / 2.0], length: length, depth: depth, mirror: mirror }
      turn = ->(u0, u1, v0, v1) { place(frame, u0, u1, v0, v1) }
      step = bowl_width + SINK_DIVIDER
      spans = nil # where the bowls lie along the sink: [[u0, u1], ...]
      if teka == :diamond
        bowl_width = [SINK_BOWL, length * 0.482].min
        bowl_depth = [SINK_BOWL, depth - 80.0].min
        bowl_v0 = (depth - bowl_depth) / 2.0
        spans = [[16.0, 16.0 + bowl_width]]
        tap = [spans.last[1] + 54.0, 37.0]
      elsif teka == :zenit
        bowl_width = [355.0, (length - 37.0 - 300.0) / 2.0].min
        bowl_depth = [SINK_BOWL, depth - 55.0 - 20.0].min
        bowl_v0 = 55.0
        spans = [[15.0, 15.0 + bowl_width], [37.0 + bowl_width, 37.0 + (2 * bowl_width)]]
        tap = [spans.first[1] + 11.0, 20.0]
      elsif teka == :zenit1
        bowl_width = [500.0, length - 40.0].min
        bowl_depth = [SINK_BOWL, depth - 55.0 - 20.0].min
        bowl_v0 = 55.0
        edge = (length - bowl_width) / 2.0
        spans = [[edge, edge + bowl_width]]
        tap = [edge + (bowl_width / 2.0), 20.0] # (at the back, over the middle of the bowl; the pop-up button 195 mm further along)
      elsif teka == :flexlinea
        bowl_width = [345.0, (length - 20.0) / 2.0].min
        bowl_depth = [SINK_BOWL, depth - 10.0].min
        bowl_v0 = (depth - bowl_depth) / 2.0
        spans = [[0.0, bowl_width], [bowl_width + 20.0, (2 * bowl_width) + 20.0]]
        tap = [bowl_width + 10.0, -50.0] # (on the worktop behind the sink: this sink has no hole for it)
      end
      tray_width = length - spans.last[1] if spans
      whole = turn.call(0.0, length, 0.0, depth)
      fits = length >= 200.0 && depth >= 200.0 && bowl_width >= (teka ? 240.0 : 150.0) &&
             whole[0] >= dims.interior_start + 10.0 && whole[1] <= dims.depth - 30.0 &&
             whole[2] >= dims.thick + 10.0 && whole[3] <= dims.width - dims.thick - 10.0
      {
        rect: whole, fits: fits, length: length, depth: depth, tray_width: tray_width, turn: turn, mirror: mirror,
        bowls: teka ? spans.map { |a, b| turn.call(a, b, bowl_v0, bowl_v0 + bowl_depth) } : (0...bowls).map { |i| turn.call(i * step, (i * step) + bowl_width, 0.0, depth) },
        dividers: teka ? [] : (0...(bowls - 1)).map { |i| turn.call((i * step) + bowl_width, (i + 1) * step, 0.0, depth) },
        tray: if teka == :flexlinea then nil elsif teka then turn.call(spans.last[1], length, 0.0, depth) elsif tray then turn.call(bowls * step, length, 0.0, depth) end,
        tap_u: if teka then tap[0] elsif bowls == 2 then bowl_width + (SINK_DIVIDER / 2.0) else bowl_width / 2.0 end,
        teka: teka, spans: spans, bowl_width: bowl_width, bowl_v0: bowl_v0, bowl_depth: bowl_depth, tap_v: tap&.last
      }
    end

    # Mirrored: asked for, or (a cabinet made with the old Turn Sink) turned half a turn.
    def self.mirrored?(params)
      params['sink_mirror'] == true || (params['sink_rotation'].to_i % 360) == 180
    end

    # The rectangle [x0, x1, y0, y1] that the part of the sink between u0..u1 (along its length) and v0..v1 (from its
    # back to its front) covers.
    def self.place(frame, u0, u1, v0, v1)
      cx, cy = frame[:centre]
      u0, u1 = frame[:length] - u1, frame[:length] - u0 if frame[:mirror]
      xs = [cx + (v0 - (frame[:depth] / 2.0)), cx + (v1 - (frame[:depth] / 2.0))]
      ys = [cy + (u0 - (frame[:length] / 2.0)), cy + (u1 - (frame[:length] / 2.0))]
      [xs.min, xs.max, ys.min, ys.max].map { |v| (v * 100).round / 100.0 }
    end
    private_class_method :place

    # The openings the worktop needs over this cabinet's fixtures: [[x0, x1, y0, y1], ...] in the cabinet's frame.
    # A hidden fixture still leaves its opening.
    def self.cutouts(params)
      return [] unless params['sink'] == true || params['hob'] == true

      dims = CabinetLayout.send(:dimensions, params)
      out = []
      sink = sink_plan(params, dims)
      out << sink[:rect] if sink && sink[:fits]
      hob = hob_plate(params, dims)
      out << [hob[0] + 12.5, hob[1] - 12.5, hob[2] + 13.5, hob[3] - 13.5] if hob # (the opening of a 860 x 500 hob is 833 x 475)
      out
    end

    # The parts of the cabinet's fixtures (sink, hob, hood) as Panels in the carcass frame.
    def self.parts(params, dims)
      out = []
      top = dims.height + params['worktop_rise'].to_f # the top of the worktop (the carcass top when there is none)
      sink = sink_plan(params, dims)
      out.concat(sink_parts(sink, top)) if sink && sink[:fits]
      hob = hob_plate(params, dims)
      out.concat(hob_parts(hob, top)) if hob
      out.concat(hood_parts(dims)) if params['hood'] == true
      out
    end

    # ---- the sink -----------------------------------------------------------------------------

    def self.sink_parts(plan, top)
      return teka_sink_parts(plan, top) if plan[:teka]

      key = 'appliance_sink_1'
      steel = SINK_STEEL
      out = []
      add = lambda do |suffix, label, rect, z, height|
        out << box("#{key}_#{suffix}", label, [rect[0], rect[2], z], [rect[1] - rect[0], rect[3] - rect[2], height])
      end
      x0, x1, y0, y1 = plan[:rect]
      r = SINK_RIM
      add.call('rim_1', 'Sink Rim', [x0 - r, x0, y0 - r, y1 + r], top, 3.0)
      add.call('rim_2', 'Sink Rim', [x1, x1 + r, y0 - r, y1 + r], top, 3.0)
      add.call('rim_3', 'Sink Rim', [x0, x1, y0 - r, y0], top, 3.0)
      add.call('rim_4', 'Sink Rim', [x0, x1, y1, y1 + r], top, 3.0)
      [[x0, y0, 180.0], [x1, y0, 270.0], [x1, y1, 0.0], [x0, y1, 90.0]].each_with_index do |(cx, cy, from), i| # the rim's outer corners are rounded
        out << shaped("#{key}_rim_#{i + 5}", 'Sink Rim Corner', [[cx, cy]] + arc(cx, cy, r, from), top, 3.0)
      end

      floor = top - SINK_BOWL_DEPTH
      plan[:bowls].each_with_index do |rect, i|
        out.concat(bowl(key, i + 1, rect, floor, top))
      end
      plan[:dividers].each_with_index { |rect, i| add.call("divider_#{i + 1}", 'Sink Divider', rect, floor, SINK_BOWL_DEPTH - 6.0) }

      if plan[:tray] # the drainer: a flat plate a little below the rim, with grooves running to the bowl
        add.call('tray', 'Sink Drainer', plan[:tray], top - 3.0, steel)
        from = plan[:length] - plan[:tray_width]
        count = 7
        count.times do |k|
          u = from + 20.0 + (k * ((plan[:tray_width] - 46.0) / (count - 1)))
          add.call("groove_#{k + 1}", 'Drainer Groove', plan[:turn].call(u, u + 5.0, 25.0, plan[:depth] - 25.0), top - 1.0, 1.5)
        end
      end
      out.concat(mixer_tap(key, plan, top))
      out
    end
    private_class_method :sink_parts

    # The Teka Diamond RS15 1B 1D 86 (a white glass deck 860 x 510 lying on the worktop, a stainless bowl 400 x 400 with a square waste sunk in it on the left, the
    # drainer on the right with five grooves and a pop-up button) or the Teka Zenit RS15 2B 1D R (a stainless steel deck 1160 x 520 with two bowls and the drainer;
    # the pop-up button at the back, over the second bowl), each with the Teka Uni 9310 mixer standing at the back.
    def self.teka_sink_parts(plan, top)
      key = 'appliance_sink_1'
      single = plan[:teka] == :zenit1 # (one bowl, no drainer: the steel deck of the Zenit)
      zenit = plan[:teka] == :zenit || single
      flex = plan[:teka] == :flexlinea
      turn = plan[:turn]
      length = plan[:length]
      depth = plan[:depth]
      spans = plan[:spans]
      bw = plan[:bowl_width]
      bv0 = plan[:bowl_v0]
      bd = plan[:bowl_depth]
      deck = flex ? 3.0 : 6.0
      out = []
      piece = lambda do |name, label, ua, ub, va, vb, z, height|
        rect = turn.call(ua, ub, va, vb)
        out << box("#{key}_#{name}", label, [rect[0], rect[2], z], [rect[1] - rect[0], rect[3] - rect[2], height])
      end
      last = spans.last[1]
      # the deck is ONE slab with an opening for each bowl (no joints between pieces): white glass for the Diamond, steel for the others
      slab = turn.call(-15.0, length + 15.0, -15.0, depth + 15.0)
      openings = plan[:bowls].map { |rect| [rect[0] - slab[0], rect[1] - slab[0], rect[2] - slab[2], rect[3] - slab[2], 12.0] }
      out << CabinetLayout::Panel.new(role: "#{key}_#{plan[:teka] == :diamond ? 'deck_1' : 'rim_1'}", name: flex ? 'Sink Rim' : 'Sink Deck',
                                      extent: [slab[1] - slab[0], slab[3] - slab[2], deck].map { |v| round2(v) }, offset: [slab[0], slab[2], top].map { |v| round2(v) },
                                      points: nil, shape: 'deck', path: openings.map { |hole| hole.map { |v| round2(v) } })
      spans.each_with_index do |(ua, ub), i|
        rect = plan[:bowls][i] # (the bowl is one hollow solid, not walls and a floor in pieces)
        out << CabinetLayout::Panel.new(role: "#{key}_bowl_#{i + 1}_floor", name: "Sink Bowl #{i + 1}", extent: [rect[1] - rect[0], rect[3] - rect[2], SINK_BOWL_DEPTH + deck].map { |v| round2(v) },
                                        offset: [rect[0], rect[2], top - SINK_BOWL_DEPTH].map { |v| round2(v) }, points: nil, shape: 'bowl', path: [SINK_STEEL], round: 12.0)
        shown = zenit ? ((ub - ua) / 2.0) + 22.0 : ((ub - ua) / 2.0) + (flex ? 0.0 : 73.0) # the square waste: a little towards the drainer, and towards the back
        back = zenit ? bv0 + 50.0 : bv0 + (bd / 2.0) - (flex ? 107.0 : 51.0)
        sq = turn.call(ua + shown - 35.0, ua + shown + 35.0, back, back + 70.0)
        out << box("#{key}_bowl_#{i + 1}_waste", 'Sink Bowl Waste', [sq[0], sq[2], top - SINK_BOWL_DEPTH + SINK_STEEL], [70.0, 70.0, 2.0])
      end
      if flex
        out.concat(uni_tap(key, plan, top + deck))
        return out
      end

      if single # the second tap hole, 195 mm from the first, has the pop-up button
        piece.call('drain_waste', 'Pop-up Button', plan[:tap_u] + 195.0 - 18.0, plan[:tap_u] + 195.0 + 18.0, 2.0, 38.0, top + deck, 1.5)
        out.concat(uni_tap(key, plan, top + deck))
        return out
      end

      from = last + (zenit ? 12.0 : 11.0)
      to = last + ((length - last) * (zenit ? 0.8 : 0.835))
      5.times do |k|
        v = depth * (zenit ? 0.247 + (k * 0.1437) : 0.252 + (k * 0.128))
        piece.call("groove_#{k + 1}", 'Drainer Groove', from, to, v - 1.5, v + 1.5, top + deck, 0.8)
      end
      if zenit # the pop-up button at the back, over the second bowl
        piece.call('drain_waste', 'Pop-up Button', last - 150.0 - 18.0, last - 150.0 + 18.0, 2.0, 38.0, top + deck, 1.5)
      else
        piece.call('drain_waste', 'Drainer Button', last + 40.0, last + 68.0, depth - 38.0, depth - 10.0, top + deck, 1.0)
      end
      out.concat(uni_tap(key, plan, top + deck))
      out
    end
    private_class_method :teka_sink_parts

    # The Teka Uni 9310: a stainless single-lever mixer 365 mm high. A 52 mm foot, a 42 mm body, a 24 mm neck that rises and arches 200 mm over the bowl,
    # and the lever on the other side. It stands at the back (by the first bowl; with two bowls on the join between them), the spout over the first bowl.
    def self.uni_tap(key, plan, top)
      cx, _, cy, = plan[:turn].call(plan[:tap_u], plan[:tap_u], plan[:tap_v], plan[:tap_v])
      turn = Math::PI / 4.0 # the spout is turned 45 degrees inwards (towards the front) from pointing along the sink
      sx = Math.sin(turn)
      sy = (plan[:mirror] ? 1.0 : -1.0) * Math.cos(turn) # (towards the bowl along Y)
      arc_z = top + 255.0
      radius = 100.0
      neck = [[cx, cy, top + 88.0], [cx, cy, arc_z]]
      TAP_STEPS.times do |i|
        angle = Math::PI * (i + 1) / TAP_STEPS
        reach = radius * (1.0 - Math.cos(angle))
        neck << [cx + (sx * reach), cy + (sy * reach), arc_z + (radius * Math.sin(angle))]
      end
      neck << [cx + (sx * 2.0 * radius), cy + (sy * 2.0 * radius), arc_z - 14.0]
      [
        cyl("#{key}_tap_base", 'Tap Base Plate', :z, [cx, cy, top], 52.0, 6.0),
        cyl("#{key}_tap_body", 'Tap Body', :z, [cx, cy, top + 6.0], 42.0, 82.0),
        cyl("#{key}_tap_collar", 'Tap Collar', :z, [cx, cy, top + 88.0], 28.0, 6.0),
        AppliancePieces.tube("#{key}_tap_neck", 'Tap Swan Neck', neck, 24.0),
        cyl("#{key}_tap_aerator", 'Tap Aerator', :z, [cx + (sx * 2.0 * radius), cy + (sy * 2.0 * radius), arc_z - 32.0], 22.0, 18.0),
        AppliancePieces.tube("#{key}_tap_boss", 'Tap Lever Housing', [[cx - (sx * 10.0), cy - (sy * 10.0), top + 62.0], [cx - (sx * 44.0), cy - (sy * 44.0), top + 62.0]], 40.0),
        cyl("#{key}_tap_lever", 'Tap Lever', :z, [cx - (sx * 32.0), cy - (sy * 32.0), top + 72.0], 12.0, 58.0)
      ]
    end
    private_class_method :uni_tap

    # One bowl hanging from the worktop: a floor with rounded corners, straight walls and quarter-round corners, a
    # chrome waste with a dark hole.
    def self.bowl(key, n, rect, floor, top, radius: SINK_CORNER, waste: true)
      x0, x1, y0, y1 = rect
      steel = SINK_STEEL
      depth = top - floor
      radius = [radius, (x1 - x0) / 4.0, (y1 - y0) / 4.0].min
      out = []
      outline = rounded_outline(x0, x1, y0, y1, radius)
      out << shaped("#{key}_bowl_#{n}_floor", "Sink Bowl #{n} Floor", outline, floor, steel)
      walls = [
        ['wall_1', [x0, x0 + steel, y0 + radius, y1 - radius]], ['wall_2', [x1 - steel, x1, y0 + radius, y1 - radius]],
        ['wall_3', [x0 + radius, x1 - radius, y0, y0 + steel]], ['wall_4', [x0 + radius, x1 - radius, y1 - steel, y1]]
      ]
      walls.each do |suffix, (a, b, c, d)|
        out << box("#{key}_bowl_#{n}_#{suffix}", "Sink Bowl #{n} Wall", [a, c, floor], [b - a, d - c, depth])
      end
      [[x0 + radius, y0 + radius, 180.0], [x1 - radius, y0 + radius, 270.0], [x1 - radius, y1 - radius, 0.0], [x0 + radius, y1 - radius, 90.0]].each_with_index do |(cx, cy, from), i|
        out << shaped("#{key}_bowl_#{n}_corner_#{i + 1}", "Sink Bowl #{n} Corner", quarter_ring(cx, cy, radius, steel, from), floor, depth)
      end
      cx = (x0 + x1) / 2.0
      cy = (y0 + y1) / 2.0
      if waste
        out << cyl("#{key}_bowl_#{n}_waste", "Sink Bowl #{n} Waste", :z, [cx, cy, floor + steel], 62.0, 2.0)
        out << cyl("#{key}_bowl_#{n}_hole", "Sink Bowl #{n} Waste Hole", :z, [cx, cy, floor + steel + 2.0], 40.0, 0.6)
        out << cyl("#{key}_bowl_#{n}_plug", "Sink Bowl #{n} Plug", :z, [cx, cy, floor + steel + 2.6], 30.0, 2.0)
      end
      out << box("#{key}_bowl_#{n}_overflow", "Sink Bowl #{n} Overflow", [x0 + steel, cy - 30.0, top - 40.0], [0.8, 60.0, 8.0])
      out
    end
    private_class_method :bowl

    # A single-lever mixer tap in polished chrome: a round base plate, a tapering body with the lever on one side, and
    # a high swan neck (one smooth bent pipe) that rises, arches over the bowl and points down at the aerator.
    def self.mixer_tap(key, plan, top)
      u = plan[:tap_u]
      cx, _, cy, = plan[:turn].call(u, u, 48.0, 48.0)
      dir = plan[:mirror] ? -1.0 : 1.0 # the lever is on the right-hand side (the left once mirrored)
      reach = [plan[:depth] * 0.45, 190.0].min # from the column to the aerator
      radius = reach / 2.0
      arc_z = top + 255.0
      neck = [[cx, cy, top + 140.0], [cx, cy, arc_z]]
      steps = TAP_STEPS
      (1..steps).each do |i|
        angle = Math::PI * i / steps
        neck << [cx + (radius * (1.0 - Math.cos(angle))), cy, arc_z + (radius * Math.sin(angle))]
      end
      neck << [cx + reach, cy, arc_z - 52.0]
      out = [
        cyl("#{key}_tap_base", 'Tap Base Plate', :z, [cx, cy, top], 66.0, 4.0),
        cyl("#{key}_tap_foot", 'Tap Foot', :z, [cx, cy, top + 4.0], 52.0, 14.0),
        cyl("#{key}_tap_body", 'Tap Body', :z, [cx, cy, top + 18.0], 42.0, 40.0),
        cyl("#{key}_tap_column", 'Tap Column', :z, [cx, cy, top + 58.0], 34.0, 70.0),
        cyl("#{key}_tap_collar", 'Tap Collar', :z, [cx, cy, top + 126.0], 38.0, 8.0),
        AppliancePieces.tube("#{key}_tap_neck", 'Tap Swan Neck', neck, 24.0),
        cyl("#{key}_tap_aerator", 'Tap Aerator', :z, [cx + reach, cy, arc_z - 70.0], 22.0, 22.0)
      ]
      arm = dir.positive? ? cy + 14.0 : cy - 14.0 - 56.0
      grip = dir.positive? ? cy + 14.0 + 44.0 : cy - 14.0 - 56.0
      out << cyl("#{key}_tap_boss", 'Tap Lever Boss', :y, [cx, dir.positive? ? cy + 12.0 : cy - 20.0, top + 94.0], 24.0, 8.0)
      out << cyl("#{key}_tap_lever", 'Tap Lever', :y, [cx, arm, top + 94.0], 12.0, 56.0)
      out << cyl("#{key}_tap_lever_tip", 'Tap Lever Grip', :y, [cx, grip, top + 94.0], 18.0, 14.0)
      out
    end
    private_class_method :mixer_tap
    # ---- the hob ------------------------------------------------------------------------------

    # The glass plate of a built-in hob as [x0, x1, y0, y1], or nil when the cabinet has none.
    def self.hob_plate(params, dims)
      return nil unless params['hob'] == true

      width = [dims.width - 20.0, HOB_WIDTH].min
      x0 = 30.0 + HOB_SHIFT
      depth = [HOB_DEPTH, dims.depth - 20.0 - x0].min # (its front stays inside the cabinet's depth)
      y0 = (dims.width - width) / 2.0
      [x0, x0 + depth, y0, y0 + width]
    end
    private_class_method :hob_plate

    # A gas hob in stainless steel, like the Teka EX 90 1 5G AI AL DR CI: a steel plate, five gas burners (four on a narrow hob) with a blue flame ring, three
    # cast iron pan supports (two on a narrow hob) and a row of knobs along the front.
    # Each burner is [across, front to back, flame ring diameter] as fractions of the plate; each pan support [across from, across to, burners].
    WIDE_HOB = [[0.018, 0.32, [[0.174, 0.48, 160.0]]], [0.337, 0.65, [[0.498, 0.24, 115.0], [0.498, 0.68, 115.0]]], [0.67, 0.98, [[0.828, 0.25, 135.0], [0.828, 0.69, 105.0]]]].freeze
    NARROW_HOB = [[0.03, 0.48, [[0.255, 0.3, 115.0], [0.255, 0.68, 135.0]]], [0.52, 0.97, [[0.745, 0.3, 115.0], [0.745, 0.68, 135.0]]]].freeze
    WIDE_KNOBS = [0.09, 0.248, 0.5, 0.75, 0.906].freeze
    NARROW_KNOBS = [0.14, 0.38, 0.62, 0.86].freeze

    def self.hob_parts(plate, top)
      key = 'appliance_hob_1'
      x0, x1, y0, y1 = plate
      width = y1 - y0
      depth = x1 - x0
      thick = 5.0
      z = top + thick # the top of the steel plate
      wide = width >= 700.0
      out = [box("#{key}_plate", 'Hob', [x0, y0, top], [depth, width, thick])]
      out << box("#{key}_trim_1", 'Hob Front Strip', [x1 - 14.0, y0, z], [14.0, width, 2.0])
      count = 0
      (wide ? WIDE_HOB : NARROW_HOB).each_with_index do |(a0, a1, burners), index|
        gy0 = y0 + (width * a0)
        gy1 = y0 + (width * a1)
        gx0 = x0 + (depth * 0.03)
        gx1 = x0 + (depth * 0.94)
        out.concat(pan_support(key, index + 1, [gx0, gx1, gy0, gy1], burners.map { |across, back, size| [x0 + (depth * back), y0 + (width * across), size] }, z))
        burners.each do |across, back, size|
          count += 1
          cx = x0 + (depth * back)
          cy = y0 + (width * across)
          out << cyl("#{key}_head_#{count}", "Hob Burner #{count}", :z, [cx, cy, z], size * 1.15, 3.0)
          out << cyl("#{key}_flame_#{count}", "Hob Flame #{count}", :z, [cx, cy, z + 3.0], size, 3.0) # (the blue ring round the cap, as it was)
          out << cyl("#{key}_flamecore_#{count}", "Hob Flame Core #{count}", :z, [cx, cy, z + 6.0], size * 0.86, 0.8) # (a lighter, hotter band inside it)
          out << cyl("#{key}_cap_#{count}", "Hob Burner Cap #{count}", :z, [cx, cy, z + 3.0], size * 0.74, 9.0)
          out << cyl("#{key}_flame_#{count}b", "Hob Flame #{count} Inner", :z, [cx, cy, z + 12.0], size * 0.5, 1.0) if size >= 150.0
          out << cyl("#{key}_cap_#{count}b", "Hob Burner Centre #{count}", :z, [cx, cy, z + 12.0], size * 0.3, 1.5) if size >= 150.0
        end
      end
      (wide ? WIDE_KNOBS : NARROW_KNOBS).each_with_index do |across, index|
        out << cyl("#{key}_knob_#{index + 1}", "Hob Knob #{index + 1}", :x, [x1, y0 + (width * across), z + 8.0], 26.0, 30.0)
        out << cyl("#{key}_cap_k#{index + 1}", "Hob Knob Centre #{index + 1}", :x, [x1 + 29.0, y0 + (width * across), z + 8.0], 12.0, 1.5)
      end
      out
    end

    # The cast iron pan support round some burners: a frame and four fingers towards each burner. `rect` = [x0, x1, y0, y1], `burners` = [[x, y, size], ...].
    def self.pan_support(key, number, rect, burners, z)
      x0, x1, y0, y1 = rect
      frame = 12.0
      finger = 9.0
      base = z + 4.0
      n = 0
      out = []
      add = lambda do |ox, oy, dx, dy, high|
        next unless dx > 1.0 && dy > 1.0

        n += 1
        out << box("#{key}_grate_#{number}_#{n}", 'Hob Pan Support', [ox, oy, base], [dx, dy, high])
      end
      add.call(x0, y0, x1 - x0, frame, 12.0)
      add.call(x0, y1 - frame, x1 - x0, frame, 12.0)
      add.call(x0, y0, frame, y1 - y0, 12.0)
      add.call(x1 - frame, y0, frame, y1 - y0, 12.0)
      sorted = burners.sort_by(&:first)
      sorted.each_with_index do |(cx, cy, size), i|
        reach = size * 0.55
        back = i.zero? ? x0 : (sorted[i - 1][0] + cx) / 2.0
        front = i == sorted.length - 1 ? x1 : (sorted[i + 1][0] + cx) / 2.0
        add.call(back, cy - (finger / 2.0), (cx - reach) - back, finger, 10.0)
        add.call(cx + reach, cy - (finger / 2.0), front - (cx + reach), finger, 10.0)
        add.call(cx - (finger / 2.0), y0, finger, (cy - reach) - y0, 10.0)
        add.call(cx - (finger / 2.0), cy + reach, finger, y1 - (cy + reach), 10.0)
      end
      out
    end
    private_class_method :pan_support
    private_class_method :hob_parts

    # ---- the hood -----------------------------------------------------------------------------

    # A slim integrated pull-out cooker hood under a wall cabinet, like the Teka Integra GFI 67350: a steel visor that reaches 90 mm past the doors with a 51 mm black
    # glass front (the logo on the left, touch controls and the fan speed on the right), two LED lights and a ribbed grease filter. Below the carcass (negative Z).
    def self.hood_parts(dims)
      key = 'appliance_hood_1'
      width = dims.width - 40.0
      d = dims.depth
      front = d + 84.0 # the face of the glass front
      out = [
        box("#{key}_frame", 'Hood Visor', [60.0, 20.0, -22.0], [d + 10.0, width, 14.0]),
        box("#{key}_doorglass", 'Hood Front Glass', [d + 70.0, 20.0, -58.0], [14.0, width, 51.0]),
        box("#{key}_trim_1", 'Hood Front Trim', [d + 68.0, 20.0, -7.0], [18.0, width, 3.0]),
        box("#{key}_trim_2", 'Hood Front Trim', [d + 68.0, 20.0, -62.0], [18.0, width, 4.0]),
        box("#{key}_panel", 'Hood Filter Frame', [110.0, 70.0, -24.0], [d - 110.0 + 20.0, width - 100.0, 2.0]),
      ]
      out.concat(AppliancePieces.text(key, 'TEKA', front, 83.0, -44.0, 9.0))
      # the touch controls on the glass, on the right: power, less, the fan speed, more, the light
      [-120.0, -90.0, 0.0, 90.0, 120.0].each_with_index do |from_mid, k|
        out << cyl("#{key}_icon_#{k + 1}", "Hood Control #{k + 1}", :x, [front, 20.0 + (width * 0.72) + from_mid, -34.0], 9.0, 0.5) unless k == 2
      end
      out.concat(AppliancePieces.digits(key, '2', :x, front, 20.0 + (width * 0.72), -34.0, 14.0, kind: 'ledfig'))
      ribs = [((width - 130.0) / 22.0).floor, 4].max
      ribs.times do |k|
        out << box("#{key}_filter_#{k + 1}", 'Hood Filter Rib', [120.0, 90.0 + (k * ((width - 140.0) / (ribs - 1.0))), -26.0], [d - 150.0 + 20.0, 4.0, 2.0])
      end
      out << box("#{key}_led_1", 'Hood Light', [d - 130.0, 60.0, -24.0], [70.0, 90.0, 1.5])
      out << box("#{key}_led_2", 'Hood Light', [d - 130.0, 20.0 + width - 140.0, -24.0], [70.0, 90.0, 1.5])
      out
    end
    private_class_method :hood_parts

    # ---- shared -------------------------------------------------------------------------------

    def self.box(role, name, origin, size)
      AppliancePieces.box(role, name, origin, size)
    end
    private_class_method :box

    def self.cyl(role, name, axis, start, diameter, length)
      AppliancePieces.cyl(role, name, axis, start, diameter, length)
    end
    private_class_method :cyl

    # A flat board with the outline `points`, `height` thick, standing at z.
    def self.shaped(role, name, points, z, height)
      CabinetLayout::Panel.new(role: role, name: name, extent: [nil, nil, round2(height)], offset: [0.0, 0.0, round2(z)],
                               points: points.map { |x, y| [round2(x), round2(y)] })
    end
    private_class_method :shaped

    # A rectangle with rounded corners, as a list of points going round.
    def self.rounded_outline(x0, x1, y0, y1, radius)
      corners = [[x0 + radius, y0 + radius, 180.0], [x1 - radius, y0 + radius, 270.0], [x1 - radius, y1 - radius, 0.0], [x0 + radius, y1 - radius, 90.0]]
      corners.flat_map do |cx, cy, from|
        (0..ARC_STEPS).map do |step|
          angle = (from + (90.0 * step / ARC_STEPS)) * Math::PI / 180.0
          [cx + (radius * Math.cos(angle)), cy + (radius * Math.sin(angle))]
        end
      end
    end
    private_class_method :rounded_outline

    # Points on an arc of 90 degrees round (cx, cy), starting at angle rom degrees.
    def self.arc(cx, cy, radius, from)
      (0..ARC_STEPS).map do |step|
        angle = (from + (90.0 * step / ARC_STEPS)) * Math::PI / 180.0
        [cx + (radius * Math.cos(angle)), cy + (radius * Math.sin(angle))]
      end
    end
    private_class_method :arc

    # A quarter of a ring (outer radius `radius`, `thickness` thick) starting at angle `from` degrees.
    def self.quarter_ring(cx, cy, radius, thickness, from)
      inner = [radius - thickness, 0.5].max
      outer = (0..ARC_STEPS).map { |s| (from + (90.0 * s / ARC_STEPS)) * Math::PI / 180.0 }
      outer.map { |a| [cx + (radius * Math.cos(a)), cy + (radius * Math.sin(a))] } +
        outer.reverse.map { |a| [cx + (inner * Math.cos(a)), cy + (inner * Math.sin(a))] }
    end
    private_class_method :quarter_ring

    def self.inset(rect, by)
      [rect[0] + by, rect[1] - by, rect[2] + by, rect[3] - by]
    end
    private_class_method :inset

    def self.round2(value)
      (value.to_f * 100).round / 100.0
    end
    private_class_method :round2
  end
end
