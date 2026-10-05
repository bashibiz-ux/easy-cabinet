# frozen_string_literal: true

module KitchenCabinetMaster
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
    SINK_RIM = 15.0        # the rim lies this far over the worktop around the opening
    SINK_STEEL = 2.0       # thickness of the steel
    SINK_CORNER = 28.0     # the radius of a bowl's corners
    HOB_WIDTH = 860.0      # the widest hob
    HOB_DEPTH = 510.0
    ARC_STEPS = 6

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
      depth_room = dims.depth - dims.interior_start - 60.0

      wanted = (bowls * SINK_BOWL) + ((bowls - 1) * SINK_DIVIDER) + (tray ? SINK_BOWL + SINK_DIVIDER : 0.0)
      length = [wanted, length_room].min
      depth = [SINK_DEPTH, depth_room].min
      free = length - ((bowls - 1) * SINK_DIVIDER) - (tray ? SINK_DIVIDER : 0.0)
      tray_width = tray ? [free * 0.32, 450.0].min : 0.0
      bowl_width = (free - tray_width) / bowls

      frame = { centre: [(dims.depth / 2.0) - 10.0, dims.width / 2.0], length: length, depth: depth, mirror: mirror }
      turn = ->(u0, u1, v0, v1) { place(frame, u0, u1, v0, v1) }
      step = bowl_width + SINK_DIVIDER
      whole = turn.call(0.0, length, 0.0, depth)
      fits = length >= 200.0 && depth >= 200.0 && bowl_width >= 150.0 &&
             whole[0] >= dims.interior_start + 10.0 && whole[1] <= dims.depth - 30.0 &&
             whole[2] >= dims.thick + 10.0 && whole[3] <= dims.width - dims.thick - 10.0
      {
        rect: whole, fits: fits, length: length, depth: depth, tray_width: tray_width, turn: turn, mirror: mirror,
        bowls: (0...bowls).map { |i| turn.call(i * step, (i * step) + bowl_width, 0.0, depth) },
        dividers: (0...(bowls - 1)).map { |i| turn.call((i * step) + bowl_width, (i + 1) * step, 0.0, depth) },
        tray: tray ? turn.call(bowls * step, length, 0.0, depth) : nil,
        tap_u: bowls == 2 ? bowl_width + (SINK_DIVIDER / 2.0) : bowl_width / 2.0
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
      out << inset(hob, 10.0) if hob
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

    # One bowl hanging from the worktop: a floor with rounded corners, straight walls and quarter-round corners, a
    # chrome waste with a dark hole.
    def self.bowl(key, n, rect, floor, top)
      x0, x1, y0, y1 = rect
      steel = SINK_STEEL
      depth = top - floor
      radius = [SINK_CORNER, (x1 - x0) / 4.0, (y1 - y0) / 4.0].min
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
      out << cyl("#{key}_bowl_#{n}_waste", "Sink Bowl #{n} Waste", :z, [cx, cy, floor + steel], 62.0, 2.0)
      out << cyl("#{key}_bowl_#{n}_hole", "Sink Bowl #{n} Waste Hole", :z, [cx, cy, floor + steel + 2.0], 40.0, 0.6)
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
      steps = 12
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
      depth = [HOB_DEPTH, dims.depth - 50.0].min
      y0 = (dims.width - width) / 2.0
      [30.0, 30.0 + depth, y0, y0 + width]
    end
    private_class_method :hob_plate

    # An induction hob: black glass with a thin steel bevel, cooking zones printed as two silver rings each, a
    # touch slider and display along the front.
    def self.hob_parts(plate, top)
      key = 'appliance_hob_1'
      x0, x1, y0, y1 = plate
      width = y1 - y0
      depth = x1 - x0
      glass = 6.0
      out = [box("#{key}_glass", 'Hob', [x0, y0, top], [depth, width, glass])]
      bevel = 3.0
      out << box("#{key}_trim_1", 'Hob Bevel', [x0, y0, top + glass], [bevel, width, 0.8])
      out << box("#{key}_trim_2", 'Hob Bevel', [x1 - bevel, y0, top + glass], [bevel, width, 0.8])
      out << box("#{key}_trim_3", 'Hob Bevel', [x0 + bevel, y0, top + glass], [depth - (2 * bevel), bevel, 0.8])
      out << box("#{key}_trim_4", 'Hob Bevel', [x0 + bevel, y1 - bevel, top + glass], [depth - (2 * bevel), bevel, 0.8])
      z = top + glass + 0.8
      # cooking zones as (fraction across, fraction back to front, size); the front row is kept clear for the controls
      zones = width >= 700.0 ? [[0.17, 0.3, 160.0], [0.17, 0.68, 160.0], [0.5, 0.45, 240.0], [0.83, 0.3, 160.0], [0.83, 0.68, 160.0]] :
                               [[0.27, 0.3, 160.0], [0.27, 0.68, 190.0], [0.73, 0.3, 160.0], [0.73, 0.68, 190.0]]
      zones.each_with_index do |(across, back, size), i|
        cx = x0 + (depth * back * 0.88)
        cy = y0 + (width * across)
        n = i + 1
        out << cyl("#{key}_zone_#{n}", "Hob Zone #{n}", :z, [cx, cy, z], size, 0.3)
        out << cyl("#{key}_gap_#{n}", "Hob Zone #{n} Glass", :z, [cx, cy, z + 0.3], size - 6.0, 0.3)
        out << cyl("#{key}_core_#{n}", "Hob Zone #{n} Ring", :z, [cx, cy, z + 0.6], size * 0.6, 0.3)
        out << cyl("#{key}_gap_#{n}b", "Hob Zone #{n} Centre", :z, [cx, cy, z + 0.9], (size * 0.6) - 5.0, 0.3)
      end
      # the controls: a power button, a touch slider and the display, on a dark strip at the front
      front = x1 - 55.0
      mid = y0 + (width / 2.0)
      out << cyl("#{key}_zone_power", 'Hob Power Button', :z, [front + 12.0, mid - (width * 0.3), z], 24.0, 0.3)
      out << cyl("#{key}_gap_power", 'Hob Power Button Glass', :z, [front + 12.0, mid - (width * 0.3), z + 0.3], 19.0, 0.3)
      slider = [width * 0.42, 340.0].min
      out << box("#{key}_zone_slider", 'Hob Touch Slider', [front + 8.0, mid - (slider / 2.0), z], [8.0, slider, 0.3])
      out << box("#{key}_led_1", 'Hob Display', [front + 24.0, mid - 30.0, z], [10.0, 60.0, 0.5])
      4.times do |k|
        out << box("#{key}_led_#{k + 2}", 'Hob Level Light', [front + 3.0, mid - (slider / 2.0) + 25.0 + (k * (slider - 50.0) / 3.0) - 2.0, z], [3.0, 4.0, 0.5])
      end
      out
    end
    private_class_method :hob_parts

    # ---- the hood -----------------------------------------------------------------------------

    # A slim pull-out cooker hood under a wall cabinet: a steel visor that reaches 90 mm past the doors with a black
    # glass front, three buttons, two LED lights and a ribbed grease filter. Below the carcass (negative Z).
    def self.hood_parts(dims)
      key = 'appliance_hood_1'
      width = dims.width - 40.0
      d = dims.depth
      out = [
        box("#{key}_frame", 'Hood Visor', [60.0, 20.0, -22.0], [d + 10.0, width, 14.0]),
        box("#{key}_lip", 'Hood Front Glass', [d + 70.0, 20.0, -44.0], [14.0, width, 36.0]),
        box("#{key}_trim_1", 'Hood Front Trim', [d + 68.0, 20.0, -10.0], [18.0, width, 3.0]),
        box("#{key}_trim_2", 'Hood Front Trim', [d + 68.0, 20.0, -48.0], [18.0, width, 4.0]),
        box("#{key}_panel", 'Hood Filter Frame', [110.0, 70.0, -24.0], [d - 110.0 + 20.0, width - 100.0, 2.0])
      ]
      3.times do |k|
        out << cyl("#{key}_knob_#{k + 1}", "Hood Button #{k + 1}", :x, [d + 84.0, 20.0 + width - 60.0 - (k * 40.0), -26.0], 14.0, 3.0)
      end
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
