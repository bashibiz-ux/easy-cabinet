# frozen_string_literal: true

module KitchenCabinetMaster
  # The things that are fitted into a cabinet and its worktop: a sink (one or two bowls, with or without a drainer
  # tray, turned any quarter turn), a built-in hob, and the hood of a hood cabinet. Pure maths, no SketchUp objects:
  # `parts` gives the boards they are drawn from (in the carcass frame, like the appliances), and `cutouts` the
  # openings the worktop needs over them. All numbers are millimetres in the cabinet's frame: X depth (0 at the wall),
  # Y width, Z up from the carcass bottom.
  module Fixtures
    SINK_BOWL = 400.0      # a bowl is up to this wide
    SINK_DEPTH = 420.0     # and this deep
    SINK_DIVIDER = 30.0    # between two bowls, and between the last bowl and the tray
    SINK_BOWL_DEPTH = 180.0
    SINK_RIM = 15.0        # the rim lies this far over the worktop around the opening
    SINK_STEEL = 2.0       # thickness of the steel
    HOB_WIDTH = 860.0      # the widest hob
    HOB_DEPTH = 510.0

    # The sink of a cabinet, or nil when it has none:
    #   rect     [x0, x1, y0, y1] the opening in the worktop
    #   bowls    [rect, ...]      each bowl        dividers [rect, ...] between the bowls
    #   tray     rect or nil      the drainer
    #   tap_u    where the tap stands along the sink (see `place`)
    #   fits     true when it lies inside the carcass
    # The sink is worked out un-turned, its length along Y (the bowls, then the drainer on the right), and then turned
    # about its middle by `sink_rotation` (0, 90, 180 or 270 degrees, anticlockwise seen from above).
    def self.sink_plan(params, dims)
      return nil unless params['sink'] == true

      bowls = params['sink_bowls'].to_i == 2 ? 2 : 1
      tray = params['sink_tray'] == true
      rotation = params['sink_rotation'].to_i % 360
      room_y = dims.inner_w - 40.0
      room_x = dims.depth - dims.interior_start - 60.0
      sideways = [90, 270].include?(rotation) # the length then runs front to back
      length_room, depth_room = sideways ? [room_x, room_y] : [room_y, room_x]

      wanted = (bowls * SINK_BOWL) + ((bowls - 1) * SINK_DIVIDER) + (tray ? SINK_BOWL + SINK_DIVIDER : 0.0)
      length = [wanted, length_room].min
      depth = [SINK_DEPTH, depth_room].min
      free = length - ((bowls - 1) * SINK_DIVIDER) - (tray ? SINK_DIVIDER : 0.0)
      tray_width = tray ? [free * 0.32, 450.0].min : 0.0
      bowl_width = (free - tray_width) / bowls

      frame = { centre: [(dims.depth / 2.0) - 10.0, dims.width / 2.0], length: length, depth: depth, rotation: rotation }
      turn = ->(u0, u1, v0, v1) { place(frame, u0, u1, v0, v1) }
      step = bowl_width + SINK_DIVIDER
      whole = turn.call(0.0, length, 0.0, depth)
      fits = length >= 200.0 && depth >= 200.0 && bowl_width >= 150.0 &&
             whole[0] >= dims.interior_start + 10.0 && whole[1] <= dims.depth - 30.0 &&
             whole[2] >= dims.thick + 10.0 && whole[3] <= dims.width - dims.thick - 10.0
      {
        rect: whole, fits: fits, length: length, depth: depth, tray_width: tray_width, turn: turn,
        bowls: (0...bowls).map { |i| turn.call(i * step, (i * step) + bowl_width, 0.0, depth) },
        dividers: (0...(bowls - 1)).map { |i| turn.call((i * step) + bowl_width, (i + 1) * step, 0.0, depth) },
        tray: tray ? turn.call(bowls * step, length, 0.0, depth) : nil,
        tap_u: bowls == 2 ? bowl_width + (SINK_DIVIDER / 2.0) : bowl_width / 2.0
      }
    end

    # The rectangle [x0, x1, y0, y1] that the part of the un-turned sink between u0..u1 (along its length) and v0..v1
    # (from its back to its front) covers once the sink is turned.
    def self.place(frame, u0, u1, v0, v1)
      cx, cy = frame[:centre]
      angle = frame[:rotation] * Math::PI / 180.0
      c = Math.cos(angle)
      s = Math.sin(angle)
      corners = [u0, u1].product([v0, v1]).map do |u, v|
        dx = v - (frame[:depth] / 2.0)
        dy = u - (frame[:length] / 2.0)
        [cx + (dx * c) - (dy * s), cy + (dx * s) + (dy * c)]
      end
      xs = corners.map(&:first)
      ys = corners.map(&:last)
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

    # The boards of the cabinet's fixtures (sink, hob, hood) as Panels in the carcass frame.
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
      add.call('rim_1', 'Sink Rim', [x0 - r, x0, y0 - r, y1 + r], top, steel)
      add.call('rim_2', 'Sink Rim', [x1, x1 + r, y0 - r, y1 + r], top, steel)
      add.call('rim_3', 'Sink Rim', [x0, x1, y0 - r, y0], top, steel)
      add.call('rim_4', 'Sink Rim', [x0, x1, y1, y1 + r], top, steel)

      floor = top - SINK_BOWL_DEPTH
      plan[:bowls].each_with_index do |rect, i|
        n = i + 1
        bx0, bx1, by0, by1 = rect
        add.call("bowl_#{n}_floor", "Sink Bowl #{n} Floor", rect, floor, steel)
        add.call("bowl_#{n}_wall_1", "Sink Bowl #{n} Wall", [bx0, bx0 + steel, by0, by1], floor, SINK_BOWL_DEPTH)
        add.call("bowl_#{n}_wall_2", "Sink Bowl #{n} Wall", [bx1 - steel, bx1, by0, by1], floor, SINK_BOWL_DEPTH)
        add.call("bowl_#{n}_wall_3", "Sink Bowl #{n} Wall", [bx0, bx1, by0, by0 + steel], floor, SINK_BOWL_DEPTH)
        add.call("bowl_#{n}_wall_4", "Sink Bowl #{n} Wall", [bx0, bx1, by1 - steel, by1], floor, SINK_BOWL_DEPTH)
      end
      plan[:dividers].each_with_index { |rect, i| add.call("divider_#{i + 1}", 'Sink Divider', rect, top - steel, steel) }

      if plan[:tray] # the drainer: a flat plate a little below the rim, with grooves running to the bowl
        add.call('tray', 'Sink Drainer', plan[:tray], top - 3.0, steel)
        from = plan[:length] - plan[:tray_width]
        5.times do |k|
          u = from + 20.0 + (k * ((plan[:tray_width] - 46.0) / 4.0))
          add.call("groove_#{k + 1}", 'Drainer Groove', plan[:turn].call(u, u + 6.0, 20.0, plan[:depth] - 20.0), top - 1.0, 1.5)
        end
      end

      u = plan[:tap_u]
      add.call('tap_body', 'Tap', plan[:turn].call(u - 20.0, u + 20.0, 25.0, 65.0), top, 70.0)
      add.call('tap_spout', 'Tap Spout', plan[:turn].call(u - 10.0, u + 10.0, 35.0, 215.0), top + 55.0, 18.0)
      out
    end
    private_class_method :sink_parts

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

    def self.hob_parts(plate, top)
      key = 'appliance_hob_1'
      x0, x1, y0, y1 = plate
      width = y1 - y0
      depth = x1 - x0
      out = [box("#{key}_glass", 'Hob', [x0, y0, top], [depth, width, 6.0])]
      # cooking zones as (fraction across, fraction back to front, size)
      zones = width >= 700.0 ? [[0.17, 0.3, 150.0], [0.17, 0.7, 150.0], [0.5, 0.5, 220.0], [0.83, 0.3, 150.0], [0.83, 0.7, 150.0]] :
                               [[0.27, 0.3, 150.0], [0.27, 0.7, 180.0], [0.73, 0.3, 150.0], [0.73, 0.7, 180.0]]
      zones.each_with_index do |(across, back, size), i|
        cx = x0 + (depth * back)
        cy = y0 + (width * across)
        out << box("#{key}_ring_#{i + 1}", "Hob Zone #{i + 1}", [cx - (size / 2.0), cy - (size / 2.0), top + 6.0], [size, size, 0.6])
      end
      out << box("#{key}_display", 'Hob Controls', [x1 - 45.0, y0 + (width / 2.0) - 70.0, top + 6.0], [22.0, 140.0, 0.6])
      out
    end
    private_class_method :hob_parts

    # ---- the hood -----------------------------------------------------------------------------

    # A pull-out cooker hood under a wall cabinet: a visor that reaches 90 mm past the doors, a lip along its front and
    # a dark filter under it. Below the carcass (negative Z).
    def self.hood_parts(dims)
      key = 'appliance_hood_1'
      width = dims.width - 40.0
      [
        box("#{key}_frame", 'Hood Visor', [60.0, 20.0, -22.0], [dims.depth + 30.0, width, 20.0]),
        box("#{key}_lip", 'Hood Lip', [dims.depth + 70.0, 20.0, -62.0], [20.0, width, 60.0]),
        box("#{key}_panel", 'Hood Filter', [120.0, 80.0, -24.0], [dims.depth - 120.0, width - 120.0, 2.0])
      ]
    end
    private_class_method :hood_parts

    # ---- shared -------------------------------------------------------------------------------

    def self.box(role, name, origin, size)
      CabinetLayout::Panel.new(role: role, name: name, extent: size.map { |v| round2(v) }, offset: origin.map { |v| round2(v) }, points: nil)
    end
    private_class_method :box

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
