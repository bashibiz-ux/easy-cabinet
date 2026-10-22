# frozen_string_literal: true

module EasyCabinet
  # The pictures of the cabinet gallery (Cabinets and Extras): for every cabinet of a category of a catalog, the boxes its layout is made of at its standard size
  # (see html/gallery.js, which draws them as a front view or a 3D view). Pure maths, no SketchUp calls.
  #
  # A shape: { 'w', 'd', 'h', 'parts' => [{ 'k' => 'body' | 'door' | 'drawer' | 'toe' | 'appl', 'o' => [x, y, z], 'e' => [dx, dy, dz], 'r' => degrees (optional), 'p' => [[x, y], ...] (optional) }] }
  module CabinetGallery

    # => { cabinet id => shape } for every cabinet of the category.
    def self.shapes(catalog_id, category)
      CatalogManager.cabinets(catalog_id, category).each_with_object({}) do |entry, out|
        out[entry['id']] = shape(catalog_id, category, entry)
      end
    end

    def self.shape(catalog_id, category, entry)
      layout, params = layout_of(catalog_id, category, entry)
      return fallback(entry) unless layout

      from_layout(layout, params, mode_of(catalog_id))
    end

    # How the fronts of a catalog open: 'handle' (a handle on each front), 'gola' (a Gola profile along the fronts, no handles) or 'none' (no handle: a finger gap).
    def self.mode_of(catalog_id)
      catalog = CatalogManager.catalogs.find { |item| item['id'] == catalog_id } || {}
      if catalog['gola'] == true then 'gola' elsif catalog['finger_pull'] == true then 'none' else 'handle' end
    end

    # The boxes of a layout (see `shape`), also for the ghost that follows the cursor when a cabinet is placed (see PlaceTool).
    def self.from_layout(layout, params, mode = 'handle')
      parts = []
      lift = layout.base_z.to_f
      # (the boards and appliances are measured from the bottom of the carcass, the doors and drawers from the floor: the boards are lifted to the floor level)
      lifted = lambda do |box|
        next box unless box

        moved = box.merge('o' => [box['o'][0], box['o'][1], (box['o'][2] + lift).round(1)])
        moved['tp'] = box['tp'].map { |x, y, z| [x, y, (z + lift).round(1)] } if box['tp']
        moved
      end
      layout.panels.to_a.each { |panel| parts << lifted.call(part(panel.front || panel.role.to_s.include?('dishwasher_front') ? 'door' : 'body', panel)) }
      layout.appliances.to_a.each { |item| appliance_parts(item).each { |box| parts << lifted.call(box) } }
      if params['dishwasher'] == true # (the dishwasher stands behind its front: a steel box in the space)
        parts << { 'k' => 'appl', 'c' => '#a3abb4', 's' => true, 'o' => [10.0, 7.0, lift], 'e' => [[params['depth'].to_f - 40.0, 100.0].max, params['width'].to_f - 14.0, params['height'].to_f - 40.0] }
      end
      layout.drawers.to_a.each { |front| parts << part('drawer', front) }
      layout.doors.to_a.each { |door| parts << part('door', door) }
      (layout.drawers.to_a + layout.doors.to_a).each { |front| parts.concat(gola_parts(front)) } if mode == 'gola'
      parts.compact!
      if lift.positive? # the plinth under a unit that stands on the floor
        depth = params['depth'].to_f
        parts << { 'k' => 'toe', 'o' => [60.0, 0.0, 0.0], 'e' => [[depth - 90.0, 20.0].max, params['width'].to_f, lift] }
      end
      { 'w' => params['width'].to_f, 'd' => params['depth'].to_f, 'h' => params['height'].to_f, 'lift' => lift, 'cat' => params['cabinet_category'].to_s, 'mode' => mode, 'parts' => parts }
    end

    MIN_DETAIL_MM = 9.0 # an appliance part smaller than this (a figure of a display, a button, a letter) is left out of a picture

    # The boxes (and outlines) an appliance part is drawn as, in its own colour: [{ 'k' => 'appl', 'c' => '#rrggbb', 's' => true when it shines (steel, glass), 'o', 'e', ... }].
    # A round bar is a box or a disc, a sink deck is boxes round its openings, a sink bowl is a floor and four walls, a bent pipe is straight bars.
    def self.appliance_parts(item)
      _name, color, look = AppliancePieces.finish(item.role)
      look = {} unless look.is_a?(Hash)
      base = { 'k' => 'appl', 'c' => color, 's' => look['metalness'].to_f >= 1.0 || look['roughness'].to_f < 0.1 }
      extent = item.extent
      offset = item.offset
      return [] if extent.nil? || offset.nil?

      round = ->(list) { list.map { |v| v.to_f.round(1) } }
      box = ->(o, e, extra = {}) { base.merge('o' => round.call(o), 'e' => round.call(e)).merge(extra) }
      case item.shape.to_s
      when 'deck' then deck_boxes(offset, extent, item.path, box)
      when 'bowl' then bowl_boxes(offset, extent, item.path.first.to_f, box)
      when 'tube' then tube_boxes(offset, item.path, item.round.to_f, box)
      when 'plate_x' then []
      when 'cyl_z'
        centre = [offset[0].to_f + (extent[0].to_f / 2.0), offset[1].to_f + (extent[1].to_f / 2.0)]
        radius = extent[0].to_f / 2.0
        outline = (0...14).map { |i| [(centre[0] + (radius * Math.cos(i * 2.0 * Math::PI / 14.0))).round(1), (centre[1] + (radius * Math.sin(i * 2.0 * Math::PI / 14.0))).round(1)] }
        [base.merge('o' => [0.0, 0.0, offset[2].to_f.round(1)], 'e' => [0.0, 0.0, extent[2].to_f.round(1)], 'p' => outline)]
      when 'cyl_x' then extent.max < MIN_DETAIL_MM ? [] : [box.call(offset, extent, 'ax' => 'x')]
      when 'cyl_y' then extent.max < MIN_DETAIL_MM ? [] : [box.call(offset, extent)]
      else
        if item.points && !item.points.empty? # (a flame ring: an outline)
          [base.merge('o' => [0.0, 0.0, offset[2].to_f.round(1)], 'e' => [0.0, 0.0, extent[2].to_f.round(1)], 'p' => item.points.map { |x, y| [x.to_f.round(1), y.to_f.round(1)] })]
        elsif extent.max.to_f < MIN_DETAIL_MM
          []
        else
          [box.call(offset, extent)]
        end
      end
    end
    private_class_method :appliance_parts

    # A slab with rectangular openings ([x0, x1, y0, y1, radius] in the slab's own frame) as the boxes round the openings.
    def self.deck_boxes(offset, extent, holes, box)
      dx, dy, dz = extent.map(&:to_f)
      out = []
      add = ->(x0, x1, y0, y1) { out << box.call([offset[0] + x0, offset[1] + y0, offset[2]], [x1 - x0, y1 - y0, dz]) if x1 - x0 > 0.5 && y1 - y0 > 0.5 }
      cursor = 0.0
      Array(holes).sort_by { |hole| hole[2] }.each do |x0, x1, y0, y1, _radius|
        add.call(0.0, dx, cursor, y0)
        add.call(0.0, x0, y0, y1)
        add.call(x1, dx, y0, y1)
        cursor = y1
      end
      add.call(0.0, dx, cursor, dy)
      out
    end
    private_class_method :deck_boxes

    # A hollow bowl: its floor and four walls `wall` mm thick.
    def self.bowl_boxes(offset, extent, wall, box)
      dx, dy, dz = extent.map(&:to_f)
      w = [wall, 1.0].max
      at = ->(x, y, z) { [offset[0] + x, offset[1] + y, offset[2] + z] }
      [box.call(at.call(0, 0, 0), [dx, dy, w], 'c' => '#8d959e'), box.call(at.call(0, 0, 0), [w, dy, dz]), box.call(at.call(dx - w, 0, 0), [w, dy, dz]),
       box.call(at.call(0, 0, 0), [dx, w, dz]), box.call(at.call(0, dy - w, 0), [dx, w, dz])]
    end
    private_class_method :bowl_boxes

    # A bent pipe (a swan neck): one part that keeps its path ('tp', in the cabinet's frame), drawn as a round pipe `td` mm thick. Its box is the riser (the tap's column).
    def self.tube_boxes(offset, path, diameter, box)
      return [] if path.nil? || path.length < 2

      d = [diameter, 14.0].max # (a thin pipe would vanish in a small picture)
      points = path.map { |x, y, z| [(offset[0] + x).round(1), (offset[1] + y).round(1), (offset[2] + z).round(1)] }
      top = points.map { |p| p[2] }.max
      first = points.first
      [box.call([first[0] - (d / 2.0), first[1] - (d / 2.0), first[2]], [d, d, [top - first[2], 1.0].max], 'tp' => points, 'td' => d.round(1))]
    end
    private_class_method :tube_boxes

    # The Gola profile along the top of a front (a bar in the gap over it, set into the carcass front).
    def self.gola_parts(front)
      spot = front.respond_to?(:gola) ? front.gola : nil
      return [] unless spot && spot['horizontal'] && spot['length'].to_f.positive?

      centre = front.offset[1].to_f + spot['u'].to_f
      [{ 'k' => 'gola', 'o' => [(front.offset[0].to_f + front.extent[0].to_f - 24.0).round(1), (centre - (spot['length'].to_f / 2.0)).round(1), (front.offset[2].to_f + front.extent[2].to_f).round(1)],
         'e' => [24.0, spot['length'].to_f.round(1), 28.0] }]
    end
    private_class_method :gola_parts

    # The layout of a cabinet at its standard size, built the way the panel builds it; nil when the parameters are refused.
    def self.layout_of(catalog_id, category, entry)
      defaults = entry['defaults'] || {}
      raw = { 'catalog_id' => catalog_id, 'cabinet_category' => category, 'cabinet_type' => entry['id'], 'width' => defaults['width'].to_s,
              'depth' => defaults['depth'].to_s, 'height' => defaults['height'].to_s, 'toe_kick_height' => '100', 'door_opening_direction' => 'left',
              'corner_style' => entry['corner'].to_s, 'blind_width' => entry['blind'], 'front_zone' => entry['zone'], 'bottom_zone' => entry['zone_bottom'],
              'door_stacked' => entry['stacked'] == true, 'appliance_set' => entry['appliances'].to_s, 'shelf_count' => entry['shelves'].to_s,
              'sink' => entry['sink'] == true, 'sink_bowls' => entry['sink_bowls'], 'sink_tray' => entry['sink_tray'], 'hob' => entry['hob'] == true,
              'hood' => entry['hood'] == true, 'fridge' => !!entry['fridge'], 'freestanding' => entry['freestanding'] == true, 'fridge_height' => entry['fridge'],
              'top_front' => entry['top_front'], 'drawer_pattern' => entry['pattern'].to_s, 'free_housing' => entry['free_housing'] == true,
              'housing_lift' => entry['lift'], 'pullout' => entry['pullout'] == true, 'finger_pull' => mode_of(catalog_id) == 'none', 'gola_system' => (mode_of(catalog_id) == 'gola' ? 'b' : ''), 'gola_system_drawer' => (mode_of(catalog_id) == 'gola' ? 'c' : ''), 'dishwasher' => entry['dishwasher'] == true, 'dishwasher_handle' => true,
              'lift_door' => entry['lift_door'] == true, 'bifold' => entry['bifold'] == true, 'door_split' => entry['split'] == true, 'lower_mode' => entry['lower'].to_s }
      doors = entry['doors'].to_i
      drawers = entry['drawers'].to_i
      result = ValidationManager.validate(raw, door_count: doors, drawer_count: drawers)
      return nil unless result.errors.empty?

      params = result.params.merge('door_count' => doors, 'drawer_count' => drawers)
      [CabinetLayout.compute(params), params]
    rescue StandardError => e
      warn "[Easy Cabinet] No picture for #{entry['id']}: #{e.message}"
      nil
    end
    private_class_method :layout_of

    # One box of a layout: a plain box, a door or drawer front (turned about Z at its offset), or a board with an outline.
    def self.part(kind, item)
      extent = item.extent
      offset = item.offset
      return nil if extent.nil? || offset.nil?

      out = { 'k' => kind, 'o' => offset.map { |v| v.to_f.round(1) }, 'e' => extent.map { |v| v.to_f.round(1) } }
      points = item.respond_to?(:points) ? item.points : nil
      out['p'] = points.map { |x, y| [x.to_f.round(1), y.to_f.round(1)] } if points && !points.empty?
      rotation = item.respond_to?(:rotation) ? item.rotation.to_f : 0.0
      out['r'] = rotation.round(2) unless rotation.zero?
      out['g'] = item.hinge.to_s if item.respond_to?(:hinge) && item.hinge # (where a door is hinged: its handle is on the other side)
      out
    end
    private_class_method :part

    # A box with its doors side by side, when the layout cannot be made.
    def self.fallback(entry)
      defaults = entry['defaults'] || {}
      width = defaults['width'].to_f
      depth = defaults['depth'].to_f
      height = defaults['height'].to_f
      count = [entry['doors'].to_i, 1].max
      parts = [{ 'k' => 'body', 'o' => [0.0, 0.0, 0.0], 'e' => [depth, width, height] }]
      count.times do |i|
        parts << { 'k' => 'door', 'o' => [depth, (width / count) * i, 0.0], 'e' => [18.0, (width / count) - 3.0, height] }
      end
      { 'w' => width, 'd' => depth, 'h' => height, 'parts' => parts }
    end
    private_class_method :fallback
  end
end
