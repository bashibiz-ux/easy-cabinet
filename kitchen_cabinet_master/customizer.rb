# frozen_string_literal: true

module KitchenCabinetMaster
  # What the Customize window shows and changes: every board of a cabinet (carcass panels, doors, drawer fronts,
  # the boards of the drawer boxes, appliances) with its size and place, and the changes the user has made to them.
  #
  # A change is stored on the cabinet as `custom_overrides`: { part key => { 'extent' => [x, y, z], 'move' => [dx, dy, dz] } }.
  # `extent` holds a size only for the axes that were changed (the others are nil and keep following the cabinet's
  # own size); `move` is how far the part was moved from where it belongs. CabinetLayout.compute applies them, so
  # the cabinet in the model, the cut list and every later Update all see them. Pure maths, no SketchUp objects.
  module Customizer
    # The key of a part is its role in the layout (left_side, door_1, drawer_1_box_left ...).
    # Returns an Array of Hashes: key, name, group, origin [x, y, z] and size [x, y, z] in the cabinet's own frame
    # (X depth, Y width, Z height, millimetres, floor = 0), rot (degrees about Z at the origin), points (the outline
    # of a shaped board, else nil), base_size (the size without any change), move, custom.
    def self.parts(params)
      overrides = ValidationManager.clean_overrides(params['custom_overrides'])
      current = list(CabinetLayout.compute(params))
      base = list(CabinetLayout.compute(params.merge('custom_overrides' => {}))).to_h { |part| [part['key'], part] }
      current.each do |part|
        part['base_size'] = (base[part['key']] || part)['size']
        part['custom'] = overrides.key?(part['key'])
        part['move'] = overrides.dig(part['key'], 'move') || [0.0, 0.0, 0.0]
      end
    end

    def self.list(layout)
      z = layout.base_z
      out = []
      layout.panels.each { |item| out << board(item, 'carcass', z) }
      layout.doors.each { |item| out << front(item, 'door') }
      layout.drawers.each do |drawer|
        out << front(drawer, 'drawer')
        Array(layout.drawer_boxes && layout.drawer_boxes[drawer.role]).each { |item| out << drawer_board(item, drawer) }
      end
      layout.appliances.to_a.each { |item| out << board(item, 'appliance', z) }
      out
    end
    private_class_method :list

    def self.board(item, group, base_z)
      if item.respond_to?(:points) && item.points && !item.points.empty?
        xs = item.points.map(&:first)
        ys = item.points.map(&:last)
        return entry(item, group, [0.0, 0.0, base_z + item.offset[2]], [xs.max - xs.min, ys.max - ys.min, item.extent[2]], 0.0, item.points)
      end

      entry(item, group, [item.offset[0], item.offset[1], base_z + item.offset[2]], item.extent, 0.0, nil)
    end
    private_class_method :board

    # Doors and drawer fronts are placed in the cabinet's frame already (their offset includes the toe kick).
    def self.front(item, group)
      entry(item, group, item.offset.dup, item.extent, item.rotation.to_f, nil)
    end
    private_class_method :front

    # The boards of a drawer box are measured from the back of their drawer front.
    def self.drawer_board(item, drawer)
      entry(item, 'drawer_box', [0, 1, 2].map { |axis| drawer.offset[axis] + item.offset[axis] }, item.extent, 0.0, nil)
    end
    private_class_method :drawer_board

    def self.entry(item, group, origin, size, rotation, points)
      { 'key' => item.role, 'name' => item.name, 'group' => group, 'origin' => origin.map { |v| round1(v) },
        'size' => size.map { |v| round1(v) }, 'rot' => rotation, 'points' => points, 'shaped' => !points.nil? }
    end
    private_class_method :entry

    # `overrides` with the change to one part: `extent` and `move` as sent by the window (nil / 0 = no change).
    def self.with_change(overrides, key, extent, move)
      merged = ValidationManager.clean_overrides(overrides)
      merged[key.to_s] = { 'extent' => extent, 'move' => move }
      ValidationManager.clean_overrides(merged)
    end

    def self.without(overrides, key)
      ValidationManager.clean_overrides(overrides).reject { |name, _| name == key.to_s }
    end

    def self.round1(value)
      (value.to_f * 10).round / 10.0
    end
    private_class_method :round1
  end
end
