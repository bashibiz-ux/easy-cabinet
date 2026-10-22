# frozen_string_literal: true

module EasyCabinet
  # The pictures of the cabinet gallery (Cabinets and Extras): for every cabinet of a category of a catalog, the boxes its layout is made of at its standard size
  # (see html/gallery.js, which draws them as a front view or a 3D view). Pure maths, no SketchUp calls.
  #
  # A shape: { 'w', 'd', 'h', 'parts' => [{ 'k' => 'body' | 'door' | 'drawer' | 'toe' | 'appl', 'o' => [x, y, z], 'e' => [dx, dy, dz], 'r' => degrees (optional), 'p' => [[x, y], ...] (optional) }] }
  module CabinetGallery
    MIN_APPLIANCE_MM = [120.0, 80.0].freeze # an appliance part smaller than this (knobs, buttons, letters) is left out of a picture

    # => { cabinet id => shape } for every cabinet of the category.
    def self.shapes(catalog_id, category)
      CatalogManager.cabinets(catalog_id, category).each_with_object({}) do |entry, out|
        out[entry['id']] = shape(catalog_id, category, entry)
      end
    end

    def self.shape(catalog_id, category, entry)
      layout, params = layout_of(catalog_id, category, entry)
      return fallback(entry) unless layout

      from_layout(layout, params)
    end

    # The boxes of a layout (see `shape`), also for the ghost that follows the cursor when a cabinet is placed (see PlaceTool).
    def self.from_layout(layout, params)
      parts = []
      layout.panels.to_a.each { |panel| parts << part(panel.front || panel.role.to_s.include?('dishwasher_front') ? 'door' : 'body', panel) }
      layout.appliances.to_a.each do |item|
        next unless item.shape.nil? && item.points.nil? && item.extent[1].to_f >= MIN_APPLIANCE_MM[0] && item.extent[2].to_f >= MIN_APPLIANCE_MM[1]

        parts << part('appl', item)
      end
      layout.drawers.to_a.each { |front| parts << part('drawer', front) }
      layout.doors.to_a.each { |door| parts << part('door', door) }
      parts.compact!
      lift = layout.base_z.to_f
      if lift.positive? # the plinth under a unit that stands on the floor
        depth = params['depth'].to_f
        parts << { 'k' => 'toe', 'o' => [60.0, 0.0, 0.0], 'e' => [[depth - 90.0, 20.0].max, params['width'].to_f, lift] }
      end
      { 'w' => params['width'].to_f, 'd' => params['depth'].to_f, 'h' => params['height'].to_f, 'lift' => lift, 'cat' => params['cabinet_category'].to_s, 'parts' => parts }
    end

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
              'housing_lift' => entry['lift'], 'pullout' => entry['pullout'] == true, 'finger_pull' => false, 'dishwasher' => entry['dishwasher'] == true, 'dishwasher_handle' => true,
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
