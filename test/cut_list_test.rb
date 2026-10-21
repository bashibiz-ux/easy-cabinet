# frozen_string_literal: true

# The cut list: boards grouped by name, size and material. Run:  ruby test/cut_list_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
end
module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults toe_kick cabinet_layout part_layout cut_list_manager].each { |f| require File.join(plugin, f) }

class CutListTest < Minitest::Test
  include EasyCabinet

  def cabinet(overrides = {})
    Defaults.params.merge('cabinet_id' => 'CABINET_1', 'cabinet_name' => 'BU600', 'cabinet_category' => 'base', 'width' => 600.0,
                          'depth' => 560.0, 'height' => 780.0, 'door_count' => 2, 'drawer_count' => 0, 'toe_kick_height' => 100.0,
                          'material_thickness' => 18.0, 'back_thickness' => 6.0, 'material' => 'Oak',
                          'carcass_material' => 'White').merge(overrides)
  end

  def row(rows, part) = rows.find { |r| r.part == part }

  def test_identical_boards_are_grouped_with_a_quantity
    rows = CutList.rows([cabinet, cabinet('cabinet_name' => 'BU600b')], group_all: true)
    sides = row(rows, 'Left Side Panel')
    assert_equal 2, sides.quantity
    assert_equal [780.0, 560.0, 18.0], [sides.length, sides.width, sides.thickness].map(&:to_f).then { |l, w, t| [l, w, t] }
    assert_equal 'White', sides.material
    assert_equal 'BU600 BU600b', sides.used_in.join(' ')
  end

  def test_by_default_every_cabinet_has_its_own_lines
    rows = CutList.rows([cabinet, cabinet('cabinet_name' => 'BU600b')])
    sides = rows.select { |r| r.part == 'Left Side Panel' }
    assert_equal [1, 1], sides.map(&:quantity)
    assert_equal [['BU600'], ['BU600b']], sides.map(&:used_in)
  end

  def test_doors_are_grouped_whatever_their_number_and_use_the_door_material
    door = row(CutList.rows([cabinet]), 'Door')
    assert_equal 2, door.quantity
    assert_equal 'Oak', door.material
  end

  def test_handles_are_hardware_counted_per_door
    rows = CutList.rows([cabinet('handle_id' => 'bar', 'handle_length' => 160.0)], handle_name: ->(_id) { 'Bar handle' })
    handle = row(rows, 'Handle Bar handle')
    assert_equal 2, handle.quantity
    assert_equal 160.0, handle.length
    assert_equal rows.last, handle, 'hardware is listed last'
  end

  def test_a_raised_wall_carcass_is_shorter_but_the_doors_are_not
    wall = cabinet('cabinet_category' => 'wall', 'toe_kick_height' => 0.0, 'carcass_raise' => 100.0, 'door_count' => 1)
    rows = CutList.rows([wall])
    assert_equal 680.0, row(rows, 'Left Side Panel').length
    assert_equal 780.0 - 2 * Defaults.params['door_reveal'], row(rows, 'Door').length
  end

  def test_parts_are_listed_too
    toe = { 'part_kind' => 'toe_kick', 'part_name' => 'Toe Kick 1', 'toe_kick_height' => 100.0, 'toe_kick_thickness' => 18.0,
            'toe_kick_piece_length' => 2000.0, 'toe_kick_pieces' => 1, 'toe_kick_recess' => 50.0, 'target_depth' => 560.0, 'material' => 'Oak' }
    top = { 'part_kind' => 'worktop', 'part_name' => 'Worktop 2', 'depth' => 580.0, 'width' => 1800.0, 'worktop_thickness' => 20.0, 'material' => 'Granite' }
    bottom = { 'part_kind' => 'wall_bottom', 'part_name' => 'Wall Bottom Panel 3', 'depth' => 300.0, 'width' => 2000.0,
               'wall_bottom_thickness' => 18.0, 'material' => 'Oak' }
    rows = CutList.rows([toe, top, bottom])
    assert_equal [2000.0, 100.0, 18.0], [row(rows, 'Toe Kick').length, row(rows, 'Toe Kick').width, row(rows, 'Toe Kick').thickness]
    assert_equal [1800.0, 580.0, 20.0], [row(rows, 'Worktop').length, row(rows, 'Worktop').width, row(rows, 'Worktop').thickness]
    assert_equal [2000.0, 300.0, 18.0], [row(rows, 'Wall Bottom Panel').length, row(rows, 'Wall Bottom Panel').width, row(rows, 'Wall Bottom Panel').thickness]
  end

  def test_the_csv_has_a_header_one_line_per_row_and_quotes_commas
    rows = [CutList::Row.new(part: 'Side, left', length: 780.0, width: 560.0, thickness: 18.0, material: 'White', quantity: 2, used_in: ['BU600'])]
    lines = CutList.to_csv(rows).split("\r\n")
    assert_equal CutList::HEADER.join(','), lines[0]
    assert_equal '"Side, left",780,560,18,White,2,BU600', lines[1]
  end

  def test_the_sheet_area_adds_up_per_material_and_thickness
    rows = [CutList::Row.new(part: 'A', length: 1000.0, width: 500.0, thickness: 18.0, material: 'White', quantity: 4, used_in: []),
            CutList::Row.new(part: 'Handle X', length: 160.0, width: 0.0, thickness: 0.0, material: '', quantity: 4, used_in: [])]
    assert_equal [['White', 18.0, 2.0]], CutList.areas(rows)
  end
end