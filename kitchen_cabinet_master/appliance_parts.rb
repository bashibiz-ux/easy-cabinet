# frozen_string_literal: true

module KitchenCabinetMaster
  # The appliances of a cabinet drawn as parts (boxes and round bars) in the carcass frame, modelled on built-in
  # appliances of the big brands (a Siemens iQ700 or Teka oven: stainless frame, black glass door with a dark window,
  # a control strip with a display and two rotary knobs, a round handle on two posts). Pure maths, no SketchUp
  # objects: every part is a CabinetLayout::Panel, and CabinetGenerator.appliance_finish picks its material from the
  # end of its role (glass, window, panel, display, steel, cap, seal, led, chrome, white, trim, mesh, zone ...).
  #
  # All numbers are millimetres in the cabinet's frame: X depth (0 at the wall), Y width, Z up from the carcass bottom.
  module AppliancePieces
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
      'steel'  => ['Appliance - Inox', '#cfd3d8', { 'roughness' => 0.3, 'metalness' => 1.0, 'texture' => 'brushed_steel.png', 'size' => 400 }],
      'chrome' => ['Appliance - Polished Chrome', '#eef0f2', { 'roughness' => 0.05, 'metalness' => 1.0 }],
      'glass'  => ['Appliance - Graphite Glass', '#59616b', { 'roughness' => 0.04, 'metalness' => 0.0 }],
      'window' => ['Appliance - Smoked Window', '#363d45', { 'roughness' => 0.02, 'metalness' => 0.0 }],
      'panel'  => ['Appliance - Satin Steel', '#b4bac1', { 'roughness' => 0.4, 'metalness' => 1.0 }],
      'led'    => ['Appliance - LED Glow', '#d7efff', { 'roughness' => 0.2, 'metalness' => 0.0, 'emissive' => 1.0 }],
      'black'  => ['Appliance - Graphite Plastic', '#4a5159', { 'roughness' => 0.55, 'metalness' => 0.0 }],
      'seal'   => ['Appliance - Graphite Trim', '#3e454d', { 'roughness' => 0.8, 'metalness' => 0.0 }],
      'white'  => ['Appliance - Gloss White', '#eef0f2', { 'roughness' => 0.15, 'metalness' => 0.0 }],
      'zone'   => ['Appliance - Silver Ring', '#dde1e5', { 'roughness' => 0.3, 'metalness' => 0.2 }],
      'filter' => ['Appliance - Mesh Steel', '#aab1b8', { 'roughness' => 0.45, 'metalness' => 1.0 }],
      'basin'  => ['Appliance - Sink Inox', '#d2d6da', { 'roughness' => 0.25, 'metalness' => 1.0, 'texture' => 'brushed_steel.png', 'size' => 400 }],
      'groove' => ['Appliance - Sink Groove Inox', '#a7aeb5', { 'roughness' => 0.45, 'metalness' => 1.0 }]
    }.freeze
    # The first rule that matches the end of a role (its number taken off) says which finish the part gets.
    APPLIANCE_RULES = [
      [/\Atap_aerator/, 'steel'], [/\Atap_/, 'chrome'], [/waste\z/, 'chrome'], [/hole\z/, 'seal'], [/\Agroove/, 'groove'],
      [/\A(rim|divider|tray|bowl)/, 'basin'], [/\A(zone|core)/, 'zone'], [/\Agap/, 'glass'], [/\Alip\z/, 'glass'],
      [/\A(display|icon)/, 'led'], [/\Acap\z/, 'black'], [/\Aplinth\z/, 'black'], [/\A(recess|bezel)\z/, 'seal'], [/\Afilter/, 'filter'], [/\Aposts?_/, 'steel']
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
              '_micro_' => 'microwave', '_fridge_' => 'fridge', '_sink_' => 'sink' }.freeze

    def self.tick_for(role)
      found = TICKS.find { |marker, _| role.include?(marker) }
      found ? found[1] : 'oven'
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

    # ---- the oven -------------------------------------------------------------------------------------

    # `item` = { z:, height: }: where the oven stands (on its shelf) and how tall it is.
    def self.oven(key, dims, item)
      front = dims.depth
      h = item[:height]
      z0 = item[:z]
      w = plate_width(dims)
      y0 = (dims.width - w) / 2.0
      mid = y0 + (w / 2.0)
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 550.0].min
      trim = 6.0 # the stainless frame
      inset = 7.0 # steel showing round the glass
      glass_x = front + trim
      glass_t = 2.5
      face = glass_x + glass_t
      strip = [60.0, h * 0.13].min
      strip_z = z0 + h - inset - strip
      door_top = strip_z - 5.0
      door_bottom = z0 + inset
      inner_y = y0 + inset
      inner_w = w - (2 * inset)
      knob_z = strip_z + (strip / 2.0)

      parts = [
        box("#{key}_body", 'Oven Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        box("#{key}_frame", 'Oven Frame', [front, y0, z0], [trim, w, h]),
        box("#{key}_panel", 'Oven Control Glass', [glass_x, inner_y, strip_z], [glass_t, inner_w, strip]),
        box("#{key}_seal", 'Oven Door Gap', [glass_x, inner_y, door_top], [glass_t + 0.2, inner_w, strip_z - door_top]),
        box("#{key}_bezel", 'Oven Display Surround', [face, mid - 46.0, knob_z - 16.0], [0.5, 92.0, 32.0]),
        box("#{key}_display", 'Oven Display', [face + 0.5, mid - 38.0, knob_z - 11.0], [0.5, 76.0, 22.0]),
        box("#{key}_icon_1", 'Oven Function Light', [face, mid - 62.0, knob_z - 3.0], [0.5, 6.0, 6.0]),
        box("#{key}_icon_2", 'Oven Function Light', [face, mid - 74.0, knob_z - 3.0], [0.5, 6.0, 6.0]),
        box("#{key}_icon_3", 'Oven Function Light', [face, mid + 56.0, knob_z - 3.0], [0.5, 6.0, 6.0]),
        box("#{key}_icon_4", 'Oven Function Light', [face, mid + 68.0, knob_z - 3.0], [0.5, 6.0, 6.0]),
        cyl("#{key}_knob_1", 'Oven Knob 1', :x, [face, inner_y + 38.0, knob_z], 36.0, 13.0),
        cyl("#{key}_cap_1", 'Oven Knob Ring 1', :x, [face, inner_y + 38.0, knob_z], 24.0, 14.0),
        cyl("#{key}_knob_2", 'Oven Knob 2', :x, [face, y0 + w - inset - 38.0, knob_z], 36.0, 13.0),
        cyl("#{key}_cap_2", 'Oven Knob Ring 2', :x, [face, y0 + w - inset - 38.0, knob_z], 24.0, 14.0)
      ]
      return parts if door_top - door_bottom < 60.0

      handle_z = door_top - 34.0
      handle_len = [w - 150.0, 120.0].max
      handle_y = mid - (handle_len / 2.0)
      parts + [
        box("#{key}_glass", 'Oven Door Glass', [glass_x, inner_y, door_bottom], [glass_t, inner_w, door_top - door_bottom]),
        box("#{key}_window", 'Oven Window', [face, inner_y + 22.0, door_bottom + 26.0], [0.4, inner_w - 44.0, [door_top - door_bottom - 80.0, 10.0].max]),
        cyl("#{key}_handle", 'Oven Handle', :y, [face + 36.0, handle_y, handle_z], 18.0, handle_len),
        cyl("#{key}_post_1", 'Oven Handle Post 1', :x, [face, handle_y + 14.0, handle_z], 12.0, 36.0),
        cyl("#{key}_post_2", 'Oven Handle Post 2', :x, [face, handle_y + handle_len - 14.0, handle_z], 12.0, 36.0),
        box("#{key}_badge", 'Oven Badge', [face, mid - 22.0, door_bottom + 8.0], [0.5, 44.0, 5.0])
      ]
    end

    # ---- the microwave --------------------------------------------------------------------------------

    def self.microwave(key, dims, item)
      front = dims.depth
      h = item[:height]
      z0 = item[:z]
      w = plate_width(dims)
      y0 = (dims.width - w) / 2.0
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 350.0].min
      trim = 6.0
      inset = 7.0
      glass_x = front + trim
      glass_t = 2.5
      face = glass_x + glass_t
      ctrl_w = (w * 0.22).round
      ctrl_y = y0 + w - inset - ctrl_w
      door_y = y0 + inset
      door_w = ctrl_y - 6.0 - door_y
      mid_z = z0 + (h / 2.0)
      handle_len = h * 0.55

      parts = [
        box("#{key}_body", 'Microwave Body', [front - body_d, (dims.width - body_w) / 2.0, z0 + 2.0], [body_d, body_w, h - 4.0]),
        box("#{key}_frame", 'Microwave Frame', [front, y0, z0], [trim, w, h]),
        box("#{key}_panel", 'Microwave Control Glass', [glass_x, ctrl_y, z0 + inset], [glass_t, ctrl_w, h - (2 * inset)]),
        box("#{key}_bezel", 'Microwave Display Surround', [face, ctrl_y + 6.0, z0 + h - inset - 10.0 - 32.0], [0.5, ctrl_w - 12.0, 32.0]),
        box("#{key}_display", 'Microwave Display', [face + 0.5, ctrl_y + 12.0, z0 + h - inset - 14.0 - 24.0], [0.5, ctrl_w - 24.0, 24.0]),
        cyl("#{key}_knob_1", 'Microwave Dial', :x, [face, ctrl_y + (ctrl_w / 2.0), mid_z - 10.0], 44.0, 12.0),
        cyl("#{key}_cap_1", 'Microwave Dial Centre', :x, [face, ctrl_y + (ctrl_w / 2.0), mid_z - 10.0], 30.0, 13.0)
      ]
      3.times do |index|
        parts << cyl("#{key}_knob_#{index + 2}", "Microwave Button #{index + 1}", :x,
                     [face, ctrl_y + (ctrl_w * (0.25 + (index * 0.25))), z0 + inset + 22.0], 14.0, 3.0)
      end
      return parts if door_w < 60.0

      parts + [
        box("#{key}_glass", 'Microwave Door Glass', [glass_x, door_y, z0 + inset], [glass_t, door_w, h - (2 * inset)]),
        box("#{key}_window", 'Microwave Window', [face, door_y + 14.0, z0 + inset + 14.0], [0.4, door_w - 28.0 - 24.0, h - (2 * inset) - 28.0]),
        cyl("#{key}_handle", 'Microwave Handle', :z, [face + 26.0, ctrl_y - 18.0, mid_z - (handle_len / 2.0)], 14.0, handle_len),
        cyl("#{key}_post_1", 'Microwave Handle Post 1', :x, [face, ctrl_y - 18.0, mid_z - (handle_len / 2.0) + 12.0], 10.0, 26.0),
        cyl("#{key}_post_2", 'Microwave Handle Post 2', :x, [face, ctrl_y - 18.0, mid_z + (handle_len / 2.0) - 12.0], 10.0, 26.0)
      ]
    end

    # ---- a built-in fridge ----------------------------------------------------------------------------

    # `fridge` = fridge_layout (body: [bottom, top], split: z between two doors or nil).
    def self.built_in_fridge(dims, fridge, hinge_left)
      bottom, top = fridge[:body]
      return [] unless top - bottom >= 200.0

      front = dims.depth
      body_w = dims.inner_w - 4.0
      body_d = [dims.interior_d - 30.0, 560.0].min
      w = plate_width(dims)
      y0 = (dims.width - w) / 2.0
      key = 'appliance_fridge_1'
      handle_y = hinge_left ? y0 + w - 34.0 : y0 + 34.0 # next to the free edge
      parts = [box("#{key}_body", 'Fridge Body', [front - body_d, (dims.width - body_w) / 2.0, bottom], [body_d, body_w, top - bottom])]
      fronts = fridge[:split] ? [[bottom, fridge[:split] - 2.0], [fridge[:split] + 2.0, top]] : [[bottom, top]]
      fronts.each_with_index do |(z0, z1), index|
        n = index + 1
        parts << box("#{key}_plate_#{n}", n == 1 && fronts.length > 1 ? 'Fridge Lower Front' : (fronts.length > 1 ? 'Fridge Upper Front' : 'Fridge Front'),
                     [front, y0, z0], [2.0, w, z1 - z0])
        length = [[(z1 - z0) * 0.55, 700.0].min, 160.0].max
        next if z1 - z0 < 240.0

        mid = (z0 + z1) / 2.0
        parts << cyl("#{key}_bar_#{n}", 'Fridge Handle', :z, [front + 26.0, handle_y, mid - (length / 2.0)], 16.0, length)
        parts << cyl("#{key}_post_#{n}a", 'Fridge Handle Post', :x, [front + 2.0, handle_y, mid - (length / 2.0) + 14.0], 10.0, 24.0)
        parts << cyl("#{key}_post_#{n}b", 'Fridge Handle Post', :x, [front + 2.0, handle_y, mid + (length / 2.0) - 14.0], 10.0, 24.0)
      end
      parts
    end

    # ---- a fridge that stands by itself ----------------------------------------------------------------

    # A stainless steel fridge-freezer with its front face at `x + d`, standing on the floor `z0`, `w` wide from `y0`,
    # `d` deep and `h` high. Narrow (under 800 mm): a fridge door over a freezer drawer-door. 800 to 1100: two tall
    # doors side by side with a water dispenser. Wider: French doors over a freezer drawer.
    def self.free_fridge(key, x, y0, z0, w, d, h, hinge_left)
      plinth = 45.0
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
        parts << cyl("#{key}_bar_#{n}", 'Fridge Handle', :z, [x + d + 32.0, bar_y, mid_z - (length / 2.0)], 20.0, length)
        parts << cyl("#{key}_post_#{n}a", 'Fridge Handle Post', :x, [sx + door_t, bar_y, mid_z - (length / 2.0) + 18.0], 12.0, 32.0)
        parts << cyl("#{key}_post_#{n}b", 'Fridge Handle Post', :x, [sx + door_t, bar_y, mid_z + (length / 2.0) - 18.0], 12.0, 32.0)
      end
      bottom = z0 + plinth
      top = z0 + h
      face = x + d

      if w < 800.0
        freezer = (body_h * 0.3).round
        split = bottom + freezer
        add_door.call(1, 'Fridge Freezer Door', y0, w, bottom, freezer - gap)
        add_door.call(2, 'Fridge Door', y0, w, split + gap, top - split - gap)
        bar_y = hinge_left ? y0 + w - 42.0 : y0 + 42.0
        add_bar.call(1, bar_y, split - 70.0 - 150.0, 300.0)
        add_bar.call(2, bar_y, split + 70.0 + 300.0, 600.0)
        parts << box("#{key}_panel", 'Fridge Display', [face, y0 + (w / 2.0) - 40.0, top - 170.0], [0.8, 80.0, 40.0])
        parts << box("#{key}_led", 'Fridge Display Light', [face + 0.8, y0 + (w / 2.0) - 28.0, top - 160.0], [0.4, 56.0, 20.0])
      elsif w < 1100.0
        half = w / 2.0
        add_door.call(1, 'Fridge Freezer Door', y0, half - (gap / 2.0), bottom, top - bottom)
        add_door.call(2, 'Fridge Door', y0 + half + (gap / 2.0), half - (gap / 2.0), bottom, top - bottom)
        mid_y = y0 + half
        add_bar.call(1, mid_y - 36.0, bottom + (body_h * 0.55), 700.0)
        add_bar.call(2, mid_y + 36.0, bottom + (body_h * 0.55), 700.0)
        dispenser_y = y0 + (half / 2.0)
        parts << box("#{key}_panel", 'Water Dispenser', [face, dispenser_y - 90.0, bottom + (body_h * 0.55) - 120.0], [0.8, 180.0, 330.0])
        parts << box("#{key}_led", 'Dispenser Display', [face + 0.8, dispenser_y - 40.0, bottom + (body_h * 0.55) + 120.0], [0.4, 80.0, 28.0])
        parts << box("#{key}_trim_1", 'Dispenser Recess', [face + 0.8, dispenser_y - 55.0, bottom + (body_h * 0.55) - 70.0], [0.4, 110.0, 110.0])
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
        parts << cyl("#{key}_bar_1", 'Freezer Handle', :y, [x + d + 32.0, mid_y - (length / 2.0), split - 55.0], 20.0, length)
        parts << cyl("#{key}_post_1a", 'Freezer Handle Post', :x, [sx + door_t, mid_y - (length / 2.0) + 18.0, split - 55.0], 12.0, 32.0)
        parts << cyl("#{key}_post_1b", 'Freezer Handle Post', :x, [sx + door_t, mid_y + (length / 2.0) - 18.0, split - 55.0], 12.0, 32.0)
        parts << box("#{key}_panel", 'Fridge Display', [face, mid_y - 60.0, top - 150.0], [0.8, 120.0, 40.0])
        parts << box("#{key}_led", 'Fridge Display Light', [face + 0.8, mid_y - 40.0, top - 140.0], [0.4, 80.0, 20.0])
      end
      parts
    end
  end
end
