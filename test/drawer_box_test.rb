# frozen_string_literal: true

# A drawer's inner box (18 mm boards) and the handle in the middle of a drawer front. Run:  ruby test/drawer_box_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager handle_manager].each { |f| require File.join(plugin, f) }

class DrawerBoxTest < Minitest::Test
  include KitchenCabinetMaster

  def params(extra = {})
    Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0,
                          'door_count' => 0, 'drawer_count' => 2, 'toe_kick_height' => 100.0,
                          'material_thickness' => 18.0, 'back_thickness' => 6.0).merge(extra)
  end

  def test_every_drawer_has_an_inner_box_of_18_mm_boards
    layout = CabinetLayout.compute(params)
    assert_equal %w[drawer_1 drawer_2], layout.drawer_boxes.keys
    boxes = layout.drawer_boxes['drawer_1']
    assert_equal %w[left right front back bottom], boxes.map { |p| p.role.split('_box_').last }
    thin = boxes.flat_map { |p| p.extent.min }
    assert_equal [18.0], thin.uniq, 'every board is 18 mm thick'
  end

  def test_the_box_sits_behind_its_front_and_inside_the_carcass
    layout = CabinetLayout.compute(params)
    drawer = layout.drawers.first
    boxes = layout.drawer_boxes['drawer_1']
    clear = CabinetLayout.door_distance(params)
    left = boxes.find { |p| p.role.end_with?('left') }
    right = boxes.find { |p| p.role.end_with?('right') }
    front_x = 560.0 + clear # the back of the front, in cabinet X
    boxes.each do |p|
      assert_operator p.offset[0] + p.extent[0], :<=, 0.001, 'behind the front'
      assert_operator front_x + p.offset[0], :>=, 16.0 + 19.9, 'clear of the back panel'
    end
    reveal = Defaults.params['door_reveal']
    # in cabinet Y: inside the two side panels
    assert_operator reveal + left.offset[1], :>, 18.0
    assert_operator reveal + right.offset[1] + right.extent[1], :<, 600.0 - 18.0
    assert_operator left.offset[2] + left.extent[2], :<, drawer.extent[2], 'under the top of the front'
  end

  def test_a_drawer_too_small_for_a_box_gets_none
    layout = CabinetLayout.compute(params('width' => 150.0))
    assert_empty layout.drawer_boxes
  end

  def test_the_handle_of_a_drawer_front_is_in_the_middle
    layout = CabinetLayout.compute(params('drawer_count' => 1))
    drawer = layout.drawers.first
    bundle = { 'profile' => 'bar', 'section' => 10.0 }
    settings = { 'length' => 160.0, 'orientation' => 'horizontal', 'position' => 'auto', 'category' => 'base',
                 'side_offset' => 25.0, 'vertical_offset' => 25.0, 'horizontal_place' => 'edge' }
    spot = HandleManager.placement(drawer, settings, bundle)
    assert_in_delta drawer.extent[1] / 2.0, spot['u'], 1e-6, 'centred across the front'
  end
end