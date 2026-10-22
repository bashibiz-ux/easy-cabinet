# frozen_string_literal: true

module EasyCabinet
  # The appliances of a cabinet drawn as parts (boxes and round bars) in the carcass frame, modelled on built-in
  # appliances of the big brands (a Siemens iQ700 or Teka oven: stainless frame, black glass door with a dark window,
  # a control strip with a display and two rotary knobs, a round handle on two posts). Pure maths, no SketchUp
  # objects: every part is a CabinetLayout::Panel, and CabinetGenerator.appliance_finish picks its material from the
  # end of its role (glass, window, panel, display, steel, cap, seal, led, chrome, white, trim, mesh, zone ...).
  #
  # All numbers are millimetres in the cabinet's frame: X depth (0 at the wall), Y width, Z up from the carcass bottom.
  module AppliancePieces
    # Raised whenever the look of the appliances changes: a cabinet with appliances that was built under an older revision is built again when the panel opens
    # (see CabinetManager.refresh_stale_gola), so models made earlier show the new look.
    REVISION = 5

    # Does a cabinet with these parameters hold appliances (a sink, a hob, a hood, ovens, a fridge)?
    def self.any?(params)
      params['sink'] == true || params['hob'] == true || params['hood'] == true || !params['appliance_set'].to_s.empty? || params['cabinet_type'].to_s.include?('fridge')
    end

    # A box: `origin` its low corner, `size` [dx, dy, dz].
    def self.box(role, name, origin, size)
      CabinetLayout::Panel.new(role: role, name: name, extent: size.map { |v| r2(v) }, offset: origin.map { |v| r2(v) }, points: nil)
    end

    # A round bar or disc: `start` is the centre of its first end, `axis` (:x, :y or :z) the way it runs, `length`
    # how far it runs (towards +X, +Y or +Z) and `diameter` how thick it is.
    def self.cyl(role, name, axis, start, diameter, length)
      extent, offset =
        case axis
        when :x then [[length, diameter, diameter], [start[0], start[1] - (diameter / 2.0), start[2] - (diameter / 2.0)]]
        when :y then [[diameter, length, diameter], [start[0] - (diameter / 2.0), start[1], start[2] - (diameter / 2.0)]]
        else [[diameter, diameter, length], [start[0] - (diameter / 2.0), start[1] - (diameter / 2.0), start[2]]]
        end
      CabinetLayout::Panel.new(role: role, name: name, extent: extent.map { |v| r2(v) }, offset: offset.map { |v| r2(v) },
                               points: nil, shape: "cyl_#{axis}")
    end

    def self.r2(value)
      (value.to_f * 100).round / 100.0
    end

    # A plate as wide as the unit less 8 mm (a 900 mm unit takes a 900 mm oven), centred.
    def self.plate_width(dims)
      [dims.width - 8.0, 900.0].min
    end

    # ---- what the parts are made of ---------------------------------------------------------------------

    # What a part of an appliance is made of: [material name, colour, how it looks]. The look is what a renderer
    # needs (roughness 0 = a mirror, metalness 1 = bare metal, `texture` a picture in data/textures). It is applied
    # where SketchUp has these settings; the colour and the picture always are. The palette is stainless steel,
    # graphite glass and light greys (no black), as on a Siemens iQ700 or a Teka built-in line in inox.
    APPLIANCE_FINISHES = {
      'body'   => ['Appliance - Body Grey', '#8a919b', { 'roughness' => 0.7, 'metalness' => 0.0 }],
      'steel'  => ['Appliance - Stainless Steel', '#cfd3d8', { 'roughness' => 0.3, 'metalness' => 1.0, 'texture' => 'appliance_steel.png', 'size' => 700 }],
      'chrome' => ['Appliance - Polished Chrome', '#eef0f2', { 'roughness' => 0.05, 'metalness' => 1.0 }],
      'glass'  => ['Appliance - Graphite Glass', '#59616b', { 'roughness' => 0.04, 'metalness' => 0.0 }],
      'window' => ['Appliance - Smoked Window', '#363d45', { 'roughness' => 0.02, 'metalness' => 0.0 }],
      'panel'  => ['Appliance - Satin Stainless', '#b4bac1', { 'roughness' => 0.4, 'metalness' => 1.0, 'texture' => 'appliance_steel.png', 'size' => 700 }],
      'led'    => ['Appliance - LED Glow', '#d7efff', { 'roughness' => 0.2, 'metalness' => 0.0, 'emissive' => 1.0 }],
      'black'  => ['Appliance - Graphite Plastic', '#4a5159', { 'roughness' => 0.55, 'metalness' => 0.0 }],
      'seal'   => ['Appliance - Graphite Trim', '#3e454d', { 'roughness' => 0.8, 'metalness' => 0.0 }],
      'white'  => ['Appliance - Gloss White', '#eef0f2', { 'roughness' => 0.15, 'metalness' => 0.0 }],
      'zone'   => ['Appliance - Silver Ring', '#dde1e5', { 'roughness' => 0.3, 'metalness' => 0.2 }],
      'filter' => ['Appliance - Mesh Steel', '#aab1b8', { 'roughness' => 0.45, 'metalness' => 1.0 }],
      'basin'  => ['Appliance - Sink Stainless', '#d2d6da', { 'roughness' => 0.25, 'metalness' => 1.0, 'texture' => 'appliance_sink_steel.png', 'size' => 400 }],
      'groove' => ['Appliance - Sink Groove Steel', '#7d848c', { 'roughness' => 0.45, 'metalness' => 1.0 }],
      'wastesteel' => ['Appliance - Waste Steel', '#b9bfc6', { 'roughness' => 0.35, 'metalness' => 1.0, 'texture' => 'appliance_sink_steel.png', 'size' => 400 }],
      'castiron' => ['Appliance - Cast Iron', '#3a3d42', { 'roughness' => 0.8, 'metalness' => 0.4, 'texture' => 'appliance_cast_iron.png', 'size' => 300 }],
      'whiteglass' => ['Appliance - White Glass', '#f1f3f5', { 'roughness' => 0.03, 'metalness' => 0.0, 'texture' => 'appliance_white_glass.png', 'size' => 1000 }],
      'flamecore' => ['Appliance - Gas Flame Core', '#bfe0ff', { 'roughness' => 0.2, 'metalness' => 0.0, 'emissive' => 1.0 }],
      'flame'    => ['Appliance - Gas Flame', '#2f80ff', { 'roughness' => 0.2, 'metalness' => 0.0, 'emissive' => 1.0 }],
      'doorglass' => ['Appliance - Black Door Glass', '#30343a', { 'roughness' => 0.03, 'metalness' => 0.0, 'texture' => 'appliance_black_glass.png', 'size' => 1000 }],
      'doorwin'   => ['Appliance - Black Oven Window', '#2c3036', { 'roughness' => 0.02, 'metalness' => 0.0, 'texture' => 'appliance_dark_window.png', 'size' => 800 }]
    }.freeze
    # The first rule that matches the end of a role (its number taken off) says which finish the part gets.
    APPLIANCE_RULES = [
      [/\Atap_aerator/, 'steel'], [/\Atap_/, 'chrome'], [/waste\z/, 'wastesteel'], [/hole\z/, 'seal'], [/\Agroove/, 'groove'],
      [/\A(rim|divider|tray|bowl)/, 'basin'], [/\A(zone|core)/, 'zone'], [/\Agap/, 'glass'], [/\Alip\z/, 'glass'],
      [/\A(display|icon|ledfig)/, 'led'], [/\Alogo\z/, 'white'], [/\Adeck/, 'whiteglass'], [/\Agrate/, 'castiron'], [/\Aflamecore/, 'flamecore'], [/\Aflame/, 'flame'], [/\Actrlglass/, 'doorglass'], [/\Akey/, 'seal'], [/\Adigit\z/, 'seal'], [/\Acap\z/, 'black'], [/\Aplinth\z/, 'black'], [/\A(recess|bezel)\z/, 'seal'], [/\Afilter/, 'filter'], [/\Aposts?_/, 'steel']
    ].freeze
    FRIDGE_FINISHES = { 'body' => ['Appliance - Gloss White', '#eef0f2', { 'roughness' => 0.15, 'metalness' => 0.0 }] }.freeze

    # The material of an appliance part: by the end of its role (a built-in fridge's body is white, the glass of an
    # oven graphite, handles and fronts stainless steel, the tap chrome ...).
    def self.finish(role)
      kind = role.split('_')[1]
      suffix = role.sub(/\Aappliance_[a-z]+_\d+_(?:free_|housed_)?/, '')
      suffix = suffix.sub(/_\d+\z/, '') # knob_1, post_2 ...
      return FRIDGE_FINISHES['body'] if kind == 'fridge' && suffix == 'body'
      return APPLIANCE_FINISHES[suffix] if APPLIANCE_FINISHES.key?(suffix) && !suffix.start_with?('bowl')

      rule = APPLIANCE_RULES.find { |pattern, _| suffix.match?(pattern) }
      APPLIANCE_FINISHES[rule ? rule[1] : 'steel']
    end

    # The Visibility tick that shows an appliance part (see CabinetGenerator.apply_appliance_visibility).
    TICKS = { '_hob_' => 'hob', '_hood_' => 'hood', '_free_' => 'free_fridge', '_housed_' => 'free_fridge',
              '_micro_' => 'microwave', '_sink_' => 'sink' }.freeze

    def self.tick_for(role)
      found = TICKS.find { |marker, _| role.include?(marker) }
      return found[1] if found

      role.include?('_fridge_') ? nil : 'oven' # a built-in fridge has no tick of its own: it follows Show appliances
    end

    # A tube that follows `path` (points [x, y, z] in the cabinet's frame): a bent pipe, such as a tap's swan neck.
    # The part sits at the first point and keeps the path relative to it.
    def self.tube(role, name, path, diameter)
      first = path.first
      relative = path.map { |p| [r2(p[0] - first[0]), r2(p[1] - first[1]), r2(p[2] - first[2])] }
      lo = [0, 1, 2].map { |i| relative.map { |p| p[i] }.min - (diameter / 2.0) }
      hi = [0, 1, 2].map { |i| relative.map { |p| p[i] }.max + (diameter / 2.0) }
      CabinetLayout::Panel.new(role: role, name: name, extent: [0, 1, 2].map { |i| r2(hi[i] - lo[i]) }, offset: first.map { |v| r2(v) },
                               points: nil, shape: 'tube', path: relative, round: diameter) # ound is its thickness
    end

    # ---- letters ----------------------------------------------------------------------------------------

    # The letters of a logo: [width, [outline, ...]] in units of the letter height, the outlines as [[across, up], ...].
    GLYPHS = {
      'T' => [0.75, [[[0.0, 1.0], [0.75, 1.0], [0.75, 0.83], [0.46, 0.83], [0.46, 0.0], [0.29, 0.0], [0.29, 0.83], [0.0, 0.83]]]],
      'E' => [0.62, [[[0.0, 0.0], [0.62, 0.0], [0.62, 0.17], [0.17, 0.17], [0.17, 0.42], [0.55, 0.42], [0.55, 0.59], [0.17, 0.59], [0.17, 0.83], [0.62, 0.83], [0.62, 1.0], [0.0, 1.0]]]],
      'K' => [0.78, [[[0.0, 0.0], [0.17, 0.0], [0.17, 1.0], [0.0, 1.0]], [[0.17, 0.40], [0.36, 0.40], [0.78, 1.0], [0.59, 1.0]], [[0.30, 0.58], [0.49, 0.58], [0.78, 0.0], [0.59, 0.0]]]],
      'A' => [0.85, [[[0.0, 0.0], [0.18, 0.0], [0.52, 1.0], [0.33, 1.0]], [[0.67, 0.0], [0.85, 0.0], [0.52, 1.0], [0.33, 1.0]], [[0.20, 0.20], [0.65, 0.20], [0.65, 0.36], [0.20, 0.36]]]]
    }.freeze

    # `text` in capital letters TEKA, `height` mm high, standing on a front whose face is at `x`, centred along Y on `u_mid`, its foot at `z`. Each letter shape is a
    # plate `thick` mm thick with the role "<key>_<kind>_<n>" (the finish "logo": white).
    def self.text(key, text, x, u_mid, z, height, kind: 'logo', thick: 0.5)
      glyphs = text.each_char.map { |ch| GLYPHS[ch] }.compact
      gap = 0.2
      cursor = -((glyphs.sum { |width, _| width } + (gap * (glyphs.length - 1))) / 2.0)
      count = 0
      glyphs.flat_map do |width, outlines|
        parts = outlines.map do |outline|
          count += 1
          points = outline.map { |across, up| [(cursor + across) * height, up * height] }
          y0 = points.map(&:first).min
          z0 = points.map(&:last).min
          relative = points.map { |py, pz| [r2(py - y0), r2(pz - z0)] }
          CabinetLayout::Panel.new(role: "#{key}_#{kind}_#{count}", name: 'Logo Letter', extent: [thick, r2(points.map(&:first).max - y0), r2(points.map(&:last).max - z0)],
                                   offset: [x, r2(u_mid + y0), r2(z + z0)], points: nil, shape: 'plate_x', path: relative)
        end
        cursor += width + gap
        parts
      end
    end

    # ---- numbers on a display ---------------------------------------------------------------------------
    # Which segments (a top, b top right, c bottom right, d bottom, e bottom left, f top left, g middle) make each sign.
    SEGMENTS = { '0' => 'abcdef', '1' => 'bc', '2' => 'abdeg', '3' => 'abcdg', '4' => 'bcfg', '5' => 'acdfg', '6' => 'acdefg',
                 '7' => 'abc', '8' => 'abcdefg', '9' => 'abcdfg', 'C' => 'adef', 'P' => 'abefg', '-' => 'g' }.freeze

    # Writes `text` (digits, ':', a degree sign written as '*', and C, P, -) in seven-segment figures `height` mm high, centred on
    # (u_mid, v_mid) of a display. `plane` :x is a display on a vertical front (u runs along Y, v up Z, `depth` is the X of the
    # glass); :z is a display lying flat (u along Y, v towards the back, so -X; `depth` is the Z of the glass). Each segment is a
    # thin box with the role "<key>_<kind>_<n>" (kind "digit": dark figures on the lit display; "ledfig": lit figures on a dark display).
    def self.digits(key, text, plane, depth, u_mid, v_mid, height, kind: 'digit')
      t = [height * 0.13, 1.0].max
      w = height * 0.55
      gap = t * 1.3
      advance = ->(ch) { { ':' => t, '*' => t * 1.6, ' ' => w * 0.5 }.fetch(ch, w) + gap }
      total = text.each_char.sum { |ch| advance.call(ch) } - gap
      rects = []
      cursor = -total / 2.0
      text.each_char do |ch|
        case ch
        when ':' then [0.3, 0.7].each { |k| rects << [cursor, cursor + t, (height * k) - (t / 2.0), (height * k) + (t / 2.0)] }
        when '*' then rects << [cursor, cursor + (t * 1.6), height - (t * 1.6), height]
        when ' ' then nil
        else
          on = SEGMENTS[ch] || ''
          shapes = { 'a' => [t, w - t, height - t, height], 'd' => [t, w - t, 0.0, t], 'g' => [t, w - t, (height - t) / 2.0, (height + t) / 2.0],
                     'f' => [0.0, t, height / 2.0, height - (t / 2.0)], 'b' => [w - t, w, height / 2.0, height - (t / 2.0)],
                     'e' => [0.0, t, t / 2.0, height / 2.0], 'c' => [w - t, w, t / 2.0, height / 2.0] }
          on.each_char { |s| u0, u1, v0, v1 = shapes[s]; rects << [cursor + u0, cursor + u1, v0, v1] }
        end
        cursor += advance.call(ch)
      end
      thin = 0.3
      rects.each_with_index.map do |(u0, u1, v0, v1), i|
        v_lo = v_mid - (height / 2.0) + v0
        size_v = v1 - v0
        if plane == :x
          box("#{key}_#{kind}_#{i + 1}", 'Display Figure', [depth, u_mid + u0, v_lo], [thin, u1 - u0, size_v])
        else
          box("#{key}_#{kind}_#{i + 1}", 'Display Figure', [v_mid + (height / 2.0) - v1, u_mid + u0, depth], [size_v, u1 - u0, thin])
        end
      end
    end
    # ---- the oven -------------------------------------------------------------------------------------

    # `item` = { z:, height: }: where the oven stands (on its shelf) and how tall it is. Modelled on the Teka HSB 6456 SS: a stainless control strip across the
    # top (two rotary knobs and a dark display with the time), a black glass door edge to edge under it, a long flat stainless handle just under the strip,
    # a wide dark window and the logo low in the middle.
    def self.oven(key, dims, item)
      front = dims.depth
      h = item[:height]
      z0 = item[:z]
      w = plate_width(dims)
      y0 = (dims.width - w) / 2.0
      mid = y0 + (w / 2.0)
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 550.0].min
      trim = 6.0 # the frame behind the glass
      inset = 1.0 # the glass runs to the edge
      glass_x = front + trim
      glass_t = 2.5
      face = glass_x + glass_t
      strip = [h * 0.19, 112.0].min # the control strip
      strip_z = z0 + h - inset - strip
      door_top = strip_z - 3.0
      door_bottom = z0 + inset
      inner_y = y0 + inset
      inner_w = w - (2 * inset)
      knob_z = strip_z + (strip * 0.46)
      knob_off = [w * 0.2, 122.0].min # the knobs stand this far from the sides

      parts = [
        box("#{key}_body", 'Oven Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        box("#{key}_frame", 'Oven Frame', [front, y0, z0], [trim, w, h]),
        box("#{key}_panel", 'Oven Control Strip', [glass_x, inner_y, strip_z], [glass_t, inner_w, strip]),
        box("#{key}_seal", 'Oven Door Gap', [glass_x, inner_y, door_top], [glass_t + 0.2, inner_w, strip_z - door_top]),
        box("#{key}_bezel", 'Oven Display', [face, mid - 105.0, knob_z - 17.0], [0.5, 210.0, 34.0]),
        *digits(key, '19:24', :x, face + 1.0, mid, knob_z, 20.0, kind: 'ledfig'),
        box("#{key}_icon_1", 'Oven Function Light', [face, mid - 86.0, knob_z - 22.0], [0.5, 5.0, 5.0]),
        box("#{key}_icon_2", 'Oven Function Light', [face, mid - 70.0, knob_z - 22.0], [0.5, 5.0, 5.0]),
        box("#{key}_icon_3", 'Oven Function Light', [face, mid + 65.0, knob_z - 22.0], [0.5, 5.0, 5.0]),
        box("#{key}_icon_4", 'Oven Function Light', [face, mid + 81.0, knob_z - 22.0], [0.5, 5.0, 5.0]),
        cyl("#{key}_knob_1", 'Oven Knob 1', :x, [face, inner_y + knob_off, knob_z], 46.0, 13.0),
        cyl("#{key}_cap_1", 'Oven Knob Centre 1', :x, [face, inner_y + knob_off, knob_z], 30.0, 14.0),
        cyl("#{key}_knob_2", 'Oven Knob 2', :x, [face, y0 + w - inset - knob_off, knob_z], 46.0, 13.0),
        cyl("#{key}_cap_2", 'Oven Knob Centre 2', :x, [face, y0 + w - inset - knob_off, knob_z], 30.0, 14.0)
      ]
      door_h = door_top - door_bottom
      return parts if door_h < 60.0

      handle_h = 26.0
      handle_top = door_top - (door_h >= 300.0 ? 21.0 : 10.0)
      handle_len = w * 0.87
      handle_y = mid - (handle_len / 2.0)
      parts + [
        box("#{key}_doorglass", 'Oven Door Glass', [glass_x, inner_y, door_bottom], [glass_t, inner_w, door_h]),
        box("#{key}_doorwin", 'Oven Window', [face, inner_y + (inner_w * 0.155), door_bottom + (door_h * 0.19)], [0.4, inner_w * 0.70, [door_h * 0.59, 10.0].max]),
        box("#{key}_handle", 'Oven Handle', [face, handle_y, handle_top - handle_h], [20.0, handle_len, handle_h]),
        *text(key, 'TEKA', face, mid, door_bottom + [door_h * 0.1, 12.0].max, 9.0)
      ]
    end

    # ---- the microwave --------------------------------------------------------------------------------

    # Modelled on the Teka MWE 255 FI: a stainless trim frame round a black glass front, the door on the left with a dark window and the logo under it, and a
    # narrow control column on the right (a display, a block of keys, a dial and a recessed button). It has no handle: the door opens with the button.
    def self.microwave(key, dims, item)
      front = dims.depth
      h = item[:height]
      z0 = item[:z]
      w = plate_width(dims)
      y0 = (dims.width - w) / 2.0
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 350.0].min
      trim = 6.0 # the frame
      glass_x = front + trim
      glass_t = 2.5
      face = glass_x + glass_t
      side = w * 0.067 # the stainless trim round the glass
      band = h * 0.13
      iy0 = y0 + side
      iw = w - (2 * side)
      iz0 = z0 + band
      ih = h - (2 * band)
      door_w = iw * 0.805
      ctrl_y = iy0 + door_w + 2.0
      ctrl_w = iw - door_w - 2.0
      ctrl_mid = ctrl_y + (ctrl_w / 2.0)
      shown = iz0 + (ih * 0.825) # the display

      parts = [
        box("#{key}_body", 'Microwave Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        box("#{key}_frame", 'Microwave Frame', [front, y0, z0], [trim, w, h]),
        box("#{key}_ctrlglass", 'Microwave Control Glass', [glass_x, ctrl_y, iz0], [glass_t, ctrl_w, ih]),
        box("#{key}_seal", 'Microwave Door Gap', [glass_x, ctrl_y - 2.0, iz0], [glass_t + 0.2, 2.0, ih]),
        box("#{key}_bezel", 'Microwave Display', [face, ctrl_y + 6.0, shown - 11.0], [0.5, ctrl_w - 12.0, 22.0]),
        *digits(key, 'P100', :x, face + 1.0, ctrl_mid, shown, 14.0, kind: 'ledfig'),
        box("#{key}_bezel_2", 'Microwave Release Button', [face, ctrl_y + (ctrl_w * 0.1), iz0 + (ih * 0.065)], [0.5, ctrl_w * 0.8, 24.0]),
        cyl("#{key}_knob_1", 'Microwave Dial', :x, [face, ctrl_mid, iz0 + (ih * 0.31)], 27.0, 8.0),
        cyl("#{key}_cap_1", 'Microwave Dial Centre', :x, [face, ctrl_mid, iz0 + (ih * 0.31)], 15.0, 9.0),
        box("#{key}_key_5", 'Microwave Key', [face, ctrl_y + (ctrl_w * 0.1), iz0 + (ih * 0.48) - 4.0], [0.5, ctrl_w * 0.8, 8.0])
      ]
      [[0.71, 0.3], [0.71, 0.7], [0.6, 0.3], [0.6, 0.7]].each_with_index do |(zk, yk), index|
        parts << box("#{key}_key_#{index + 1}", 'Microwave Key', [face, ctrl_y + (ctrl_w * yk) - 10.0, iz0 + (ih * zk) - 6.5], [0.5, 20.0, 13.0])
      end
      return parts if door_w < 60.0

      parts + [
        box("#{key}_doorglass", 'Microwave Door Glass', [glass_x, iy0, iz0], [glass_t, door_w, ih]),
        box("#{key}_doorwin", 'Microwave Window', [face, iy0 + (door_w * 0.18), iz0 + (ih * 0.24)], [0.4, door_w * 0.61, ih * 0.53]),
        *text(key, 'TEKA', face, iy0 + (door_w * 0.62), iz0 + (ih * 0.12), 8.0)
      ]
    end

    # ---- a fridge that stands by itself ----------------------------------------------------------------

    # A stainless steel fridge-freezer with its front face at `x + d`, standing on the floor `z0`, `w` wide from `y0`,
    # `d` deep and `h` high. Narrow (under 800 mm): like the Teka RBF 3450 SS (a bottom-freezer: a tall fridge door over a freezer door with a dark recessed
    # handle groove between them, a black display and the logo on the fridge door; every size follows the width and the height). 800 to 1100: two tall
    # doors side by side with a water dispenser. Wider: French doors over a freezer drawer.
    def self.free_fridge(key, x, y0, z0, w, d, h, hinge_left)
      plinth = w < 800.0 ? 35.0 : 45.0
      door_t = 24.0
      body_h = h - plinth
      sx = x + d - door_t
      gap = 3.0
      parts = [
        box("#{key}_plinth", 'Fridge Plinth', [x + 30.0, y0 + 20.0, z0], [d - 80.0, w - 40.0, plinth]),
        box("#{key}_shell", 'Fridge Body', [x, y0, z0 + plinth], [d - door_t, w, body_h]),
        box("#{key}_hinge_1", 'Fridge Hinge', [sx - 2.0, hinge_left ? y0 - 3.0 : y0 + w - 3.0, z0 + plinth + 40.0], [8.0, 6.0, 60.0]),
        box("#{key}_hinge_2", 'Fridge Hinge', [sx - 2.0, hinge_left ? y0 - 3.0 : y0 + w - 3.0, z0 + h - 100.0], [8.0, 6.0, 60.0])
      ]
      add_door = lambda do |n, name, oy, ow, oz, oh|
        parts << box("#{key}_plate_#{n}", name, [sx, oy, oz], [door_t, ow, oh])
      end
      add_bar = lambda do |n, bar_y, mid_z, length|
        parts << box("#{key}_bar_#{n}", 'Fridge Handle', [x + d, bar_y - 10.0, mid_z - (length / 2.0)], [26.0, 20.0, length])
      end
      bottom = z0 + plinth
      top = z0 + h
      face = x + d

      if w < 800.0
        lower = (body_h * 0.42).round # the freezer door
        band = [h * 0.0286, 20.0].max # the dark handle groove between the doors
        split = bottom + lower
        mid_y = y0 + (w / 2.0)
        add_door.call(1, 'Fridge Freezer Door', y0, w, bottom, lower)
        add_door.call(2, 'Fridge Door', y0, w, split + band, top - split - band)
        parts << box("#{key}_bezel", 'Fridge Handle Groove', [sx + door_t - 4.0, y0, split], [4.2, w, band])
        parts << box("#{key}_bezel_2", 'Fridge Handle Groove Top', [sx + door_t - 10.0, y0, split + band - 6.0], [10.0, w, 6.0]) # (the lip of the door above)
        display_w = [w * 0.075, 36.0].max
        display_h = h * 0.106
        display_top = top - (h * 0.092)
        parts << box("#{key}_ctrlglass", 'Fridge Display', [face, mid_y - (display_w / 2.0), display_top - display_h], [0.8, display_w, display_h])
        parts.concat(digits(key, '4*C', :x, face + 0.8, mid_y, display_top - (display_h * 0.3), display_w * 0.42, kind: 'ledfig'))
        parts.concat(digits(key, '-18', :x, face + 0.8, mid_y, display_top - (display_h * 0.68), display_w * 0.42, kind: 'ledfig'))
        parts.concat(text(key, 'TEKA', face, mid_y, top - (h * 0.058), 7.0, thick: 0.4))
      elsif w < 1100.0
        half = w / 2.0
        add_door.call(1, 'Fridge Freezer Door', y0, half - (gap / 2.0), bottom, top - bottom)
        add_door.call(2, 'Fridge Door', y0 + half + (gap / 2.0), half - (gap / 2.0), bottom, top - bottom)
        mid_y = y0 + half
        add_bar.call(1, mid_y - 36.0, bottom + (body_h * 0.55), 700.0)
        add_bar.call(2, mid_y + 36.0, bottom + (body_h * 0.55), 700.0)
        dispenser_y = y0 + (half / 2.0)
        parts << box("#{key}_ctrlglass", 'Water Dispenser', [face, dispenser_y - 90.0, bottom + (body_h * 0.55) - 120.0], [1.5, 180.0, 330.0])
        parts.concat(digits(key, '4*C', :x, face + 1.5, dispenser_y, bottom + (body_h * 0.55) + 135.0, 26.0, kind: 'ledfig'))
        parts << box("#{key}_bezel", 'Dispenser Tray', [face + 1.5, dispenser_y - 55.0, bottom + (body_h * 0.55) - 80.0], [0.6, 110.0, 110.0])
      else
        freezer = (body_h * 0.3).round
        split = bottom + freezer
        half = w / 2.0
        add_door.call(1, 'Fridge Freezer Door', y0, w, bottom, freezer - gap)
        add_door.call(2, 'Fridge Door Left', y0, half - (gap / 2.0), split + gap, top - split - gap)
        add_door.call(3, 'Fridge Door Right', y0 + half + (gap / 2.0), half - (gap / 2.0), split + gap, top - split - gap)
        mid_y = y0 + half
        add_bar.call(2, mid_y - 36.0, split + 60.0 + 350.0, 700.0)
        add_bar.call(3, mid_y + 36.0, split + 60.0 + 350.0, 700.0)
        length = [w * 0.5, 600.0].min
        parts << box("#{key}_bar_1", 'Freezer Handle', [x + d, mid_y - (length / 2.0), split - 65.0], [26.0, length, 20.0])
        parts << box("#{key}_ctrlglass", 'Fridge Display', [face, mid_y - 60.0, top - 150.0], [1.5, 120.0, 40.0])
        parts.concat(digits(key, '4*C', :x, face + 1.5, mid_y, top - 130.0, 22.0, kind: 'ledfig'))
      end
      parts
    end
  end
end
