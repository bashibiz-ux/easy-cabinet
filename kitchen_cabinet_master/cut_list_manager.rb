# frozen_string_literal: true

module KitchenCabinetMaster
  # The cut list: every board of every cabinet and part in the model, grouped by name, size and
  # material with a quantity, and a CSV export of it. Sizes are millimetres, written
  # longest first (length >= width >= thickness).
  #
  # CutList.rows is pure (it works from the stored parameters, so it can be tested without
  # SketchUp); CutListManager reads the model and writes the file.
  module CutList
    Row = Struct.new(:part, :length, :width, :thickness, :material, :quantity, :used_in, keyword_init: true)

    HEADER = ['Part', 'Length (mm)', 'Width (mm)', 'Thickness (mm)', 'Material', 'Quantity', 'Cabinet'].freeze

    # records - Array of stored-parameter Hashes (one per cabinet / part in the model).
    # handle_name - lambda taking a handle id and returning its name (or nil).
    # group_all: false keeps every cabinet's boards on lines of their own; true adds identical
    # boards of different cabinets together.
    def self.rows(records, handle_name: ->(_id) { nil }, group_all: false)
      found = {}
      records.each do |stored|
        boards_of(stored, handle_name).each do |board|
          key = [board[:part], board[:size], board[:material], (group_all ? nil : board[:owner])]
          row = (found[key] ||= Row.new(part: board[:part], length: board[:size][0], width: board[:size][1],
                                         thickness: board[:size][2], material: board[:material], quantity: 0, used_in: []))
          row.quantity += board[:quantity] || 1
          row.used_in << board[:owner] unless board[:owner].to_s.empty? || row.used_in.include?(board[:owner])
        end
      end
      found.values.sort_by { |row| [group_all ? '' : natural(row.used_in.first), row.part.start_with?('Handle') ? 1 : 0, row.material.to_s, -row.length, row.part] }
    end

    # BU600 2 sorts before BU600 10.
    def self.natural(text)
      text.to_s.gsub(/\d+/) { |digits| digits.rjust(8, '0') }
    end

    # Total sheet area per material and thickness in square metres: [[material, thickness, m2], ...].
    def self.areas(rows)
      sums = Hash.new(0.0)
      rows.each do |row|
        next if row.part.start_with?('Handle') || row.width.to_f.zero?

        sums[[row.material, row.thickness]] += row.length * row.width * row.quantity / 1_000_000.0
      end
      sums.map { |(material, thickness), area| [material, thickness, area.round(3)] }.sort_by { |item| [item[0].to_s, item[1]] }
    end

    def self.to_csv(rows)
      lines = [HEADER] + rows.map do |row|
        [row.part, number(row.length), number(row.width), number(row.thickness), row.material, row.quantity, row.used_in.join(' ')]
      end
      lines.map { |fields| fields.map { |field| quote(field) }.join(',') }.join("\r\n") + "\r\n"
    end

    def self.quote(field)
      text = field.to_s
      text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
    end
    private_class_method :quote
    def self.number(value)
      value.to_f.zero? ? '' : format('%.1f', value.to_f).sub(/\.0\z/, '')
    end
    private_class_method :number

    # ---- what one stored record is made of ---------------------------------------

    def self.boards_of(stored, handle_name)
      kind = stored['part_kind'].to_s
      return cabinet_boards(stored, handle_name) if kind.empty? && stored['cabinet_id']

      case kind
      when 'filler', 'end_panel' then part_board(stored, kind == 'filler' ? 'Filler' : 'Side Panel')
      when 'toe_kick' then toe_kick_boards(stored)
      when 'worktop' then [board('Worktop', [stored['depth'], stored['width'], stored['worktop_thickness']], stored['material'], stored['part_name'])]
      when 'backsplash'
        [board('Back Splash', [stored['backsplash_thickness'], stored['width'], stored['backsplash_height']], stored['material'], stored['part_name'])]
      when 'wall_bottom'
        [board('Wall Bottom Panel', [stored['depth'], stored['width'], stored['wall_bottom_thickness']], stored['material'], stored['part_name'])]
      else []
      end
    end
    private_class_method :boards_of

    def self.cabinet_boards(stored, handle_name)
      layout = CabinetLayout.compute(stored)
      door = stored['material'].to_s.empty? ? fallback_door_material(stored) : stored['material'].to_s
      carcass = stored['carcass_material'].to_s.empty? ? door : stored['carcass_material'].to_s
      owner = stored['cabinet_name'] || stored['cabinet_id']

      out = layout.panels.map do |panel|
        shaped = panel.points && !panel.points.empty?
        board(panel.name + (shaped ? ' (shaped)' : ''), panel.extent, panel.front ? door : carcass, owner) # a front panel is cut from the door material
      end
      fronts = layout.doors + layout.drawers
      fronts.each { |item| out << board(item.name, item.extent, door, owner) }
      (layout.drawer_boxes || {}).each_value { |panels| panels.each { |p| out << board(p.name, p.extent, carcass, owner) } }

      id = stored['handle_id'].to_s
      handled = fronts.count { |item| item.handle != false }
      if !id.empty? && handled.positive?
        name = handle_name.call(id) || id
        out << { part: "Handle #{name}", size: [stored['handle_length'].to_f, 0.0, 0.0], material: '', owner: owner, quantity: handled }
      end
      out
    end
    private_class_method :cabinet_boards

    def self.part_board(stored, label)
      material = stored['material'].to_s
      material = stored['target_door_material'].to_s if material.empty? || material.start_with?('__')
      layout = label == 'Filler' ? PartLayout.filler(stored) : PartLayout.end_panel(stored)
      [board(label, layout.board.extent, material, stored['part_name'])]
    end
    private_class_method :part_board

    def self.toe_kick_boards(stored)
      material = stored['material'].to_s
      ToeKick.pieces(stored).map { |piece| board('Toe Kick', piece.extent, material, stored['part_name']) }
    end
    private_class_method :toe_kick_boards

    def self.fallback_door_material(stored)
      category = stored['cabinet_category'].to_s
      category = 'base' if category == 'corner'
      own = stored["#{category}_material"].to_s
      own.empty? ? Defaults::DEFAULT_MATERIAL : own
    end
    private_class_method :fallback_door_material

    # One line: the name without its number ("Door 2" is a "Door"), the three sizes longest first.
    def self.board(name, extent, material, owner)
      size = extent.map { |v| ((v.to_f * 10).round / 10.0) }.sort.reverse
      { part: name.to_s.sub(/\s+\d+\z/, ''), size: size, material: material.to_s, owner: owner.to_s, quantity: 1 }
    end
    private_class_method :board
  end

  # Reads the model for the cut list, and saves the CSV.
  module CutListManager
    def self.perform(action, raw)
      case action
      when 'get_cut_list' then get_cut_list(raw)
      when 'export_cut_list' then export(raw)
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    def self.get_cut_list(raw = {})
      rows = current_rows(group_all?(raw))
      return Response.ok('There is nothing in the model yet.', { 'rows' => [], 'areas' => [] }) if rows.empty?

      scope = selected_only? ? ' (the selected items only)' : ''
      Response.ok("#{rows.sum(&:quantity)} pieces in #{rows.length} lines#{scope}.", { 'rows' => rows.map { |row| row_hash(row) },
                                                                                 'areas' => CutList.areas(rows).map { |m, t, a| { 'material' => m, 'thickness' => t, 'area' => a } } })
    end

    def self.export(raw)
      rows = current_rows(group_all?(raw))
      return Response.fail('There is nothing in the model to list yet.') if rows.empty?

      folder = begin
        File.dirname(Sketchup.active_model.path.to_s)
      rescue StandardError
        nil
      end
      folder = Dir.home unless folder && Dir.exist?(folder)
      path = UI.savepanel('Save the cut list', folder, 'cut_list.csv')
      return Response.ok('The export was cancelled.') unless path

      path += '.csv' unless File.extname(path).casecmp('.csv').zero?
      File.write(path, "﻿#{CutList.to_csv(rows)}", mode: 'wb', encoding: 'UTF-8')
      Response.ok("Cut list saved: #{path}", { 'path' => path })
    rescue StandardError => e
      Response.fail("The cut list could not be saved (#{e.message}).")
    end

    def self.group_all?(raw)
      raw.is_a?(Hash) && [true, 'true', 1, '1'].include?(raw['group'])
    end
    private_class_method :group_all?

    # With cabinets or parts selected in the model the list is of those; with nothing selected it is of everything.
    def self.selected_only?
      Sketchup.active_model.selection.grep(Sketchup::ComponentInstance).any? { |item| AttributeManager.cabinet?(item) || AttributeManager.part?(item) }
    end
    private_class_method :selected_only?

    def self.current_rows(group_all = false)
      model = Sketchup.active_model
      items = model.entities.grep(Sketchup::ComponentInstance)
      items = items.select { |item| model.selection.include?(item) } if selected_only?
      records = items.filter_map do |item|
        stored = AttributeManager.read(item)
        stored if stored && !AttributeManager.custom_model?(item) && (AttributeManager.cabinet?(item) || AttributeManager.part?(item))
      end
      CutList.rows(records, handle_name: ->(id) { CatalogManager.handle_bundle(id)&.fetch('name', nil) }, group_all: group_all)
    end
    private_class_method :current_rows

    def self.row_hash(row)
      { 'part' => row.part, 'length' => row.length, 'width' => row.width, 'thickness' => row.thickness,
        'material' => row.material, 'quantity' => row.quantity, 'used_in' => row.used_in.join(' ') }
    end
    private_class_method :row_hash
  end
end
