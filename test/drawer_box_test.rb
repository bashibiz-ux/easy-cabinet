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
    assert_equal %w[left right bottom back front], boxes.map { |p| p.role.split('_box_').last }
    thin = boxes.flat_map { |p| p.extent.min }
    assert_equal [18.0], thin.uniq, 'every board is 18 mm thick'
  end

  def test_the_boards_are_as_thick_as_the_panel_thickness
    layout = CabinetLayout.compute(params('material_thickness' => 12.0))
    boxes = layout.drawer_boxes['drawer_1']
    assert_equal [12.0], boxes.map { |p| p.extent.min }.uniq
    front = boxes.find { |p| p.role.end_with?('front') }
    assert_in_delta(-12.0, front.offset[0], 1e-9, 'the inner front is right behind the drawer front')
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

  # The numbers of the drawer script (drawer unit.rb): a 600 x 580 x 780 cabinet with three drawers.
  def test_the_boxes_match_the_drawer_script
    p = params('drawer_count' => 3, 'depth' => 580.0, 'door_reveal' => 1.5, 'door_gap' => 1.5)
    layout = CabinetLayout.compute(p)
    clear = CabinetLayout.door_distance(p)
    base = 100.0
    expected_heights = [171.5, 188.0, 170.0] # the script's side heights for the bottom, middle and top drawer
    layout.drawers.each_with_index do |drawer, i|
      boxes = layout.drawer_boxes[drawer.role]
      left = boxes.find { |b| b.role.end_with?('left') }
      right = boxes.find { |b| b.role.end_with?('right') }
      bottom = boxes.find { |b| b.role.end_with?('bottom') }
      back = boxes.find { |b| b.role.end_with?('back') }
      assert_equal 536.0, left.extent[0], 'from the front to 46 mm off the wall'
      assert_in_delta 46.0, 580.0 + clear + left.offset[0], 1e-6, 'its back is 46 mm from the wall'
      assert_in_delta 31.0, 1.5 + left.offset[1], 1e-6, 'left side 31 mm in (13 mm clear of the carcass side)'
      assert_in_delta 551.0, 1.5 + right.offset[1], 1e-6, 'right side ends 13 mm clear of the right panel'
      assert_in_delta 502.0, bottom.extent[1], 1e-6, 'the bottom runs between the sides'
      assert_equal 18.0, bottom.extent[2]
      assert_in_delta expected_heights[i], left.extent[2], 1e-6, "drawer #{i + 1} side height"
      front_z = drawer.offset[2] - base
      first_bottom = 38.0 # 20 mm above the carcass bottom panel
      assert_in_delta(i.zero? ? first_bottom : front_z + 20.0, front_z + left.offset[2], 1e-6, "drawer #{i + 1} bottom")
      assert_in_delta expected_heights[i] - 18.0, back.extent[2], 1e-6, 'the back stands on the bottom'
      assert_equal [18.0, 502.0], back.extent.first(2)
      front = boxes.find { |b| b.role.end_with?('front') }
      assert_equal [18.0, 502.0, expected_heights[i] - 18.0], front.extent, 'the inner front is as tall as the back'
    end
  end
end