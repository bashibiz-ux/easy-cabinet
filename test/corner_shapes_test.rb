# frozen_string_literal: true

# L-shaped and blind corner units. Run:  ruby test/corner_shapes_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager].each { |f| require File.join(plugin, f) }

class CornerShapesTest < Minitest::Test
  include KitchenCabinetMaster

  def params(extra = {})
    Defaults.params.merge('cabinet_category' => 'base', 'corner_style' => 'l_shape', 'width' => 900.0, 'depth' => 560.0,
                          'height' => 780.0, 'door_count' => 2, 'drawer_count' => 0, 'toe_kick_height' => 100.0,
                          'material_thickness' => 18.0, 'back_thickness' => 6.0).merge(extra)
  end

  # [min_x, max_x, min_y, max_y] of a door in plan view (a turned door runs the other way).
  def plan_box(door)
    t, len, = door.extent
    x, y, = door.offset
    return [x, x + t, y, y + len] if door.rotation.to_f.zero?

    [x - len, x, y, y + t] # turned a quarter: thickness along +Y, length towards -X
  end

  def overlap?(a, b) = a[0] < b[1] && b[0] < a[1] && a[2] < b[3] && b[2] < a[3]

  def test_an_l_unit_is_a_square_that_turns_the_row_like_a_corner
    assert Defaults.corner?(params)
    assert_equal [900.0, 900.0, 880.0], CabinetLayout.envelope(params)
    refute Defaults.corner?(params('corner_style' => 'blind'))
    refute Defaults.corner?(params('corner_style' => ''))
  end

  def test_old_corner_cabinets_are_diagonal
    assert_equal 'diagonal', Defaults.corner_style('cabinet_category' => 'corner')
  end

  def test_the_l_has_two_arms_with_a_door_on_each_front
    layout = CabinetLayout.compute(params)
    roles = layout.panels.map(&:role)
    %w[left_side right_side front_return inner_front_1 inner_front_2 back bottom top shelf_1].each { |r| assert_includes roles, r } if params['shelf_count'].to_i.positive?
    %w[left_side right_side front_return inner_front_1 inner_front_2 back bottom top].each { |r| assert_includes roles, r }
    assert_equal 6, layout.panels.find { |p| p.role == 'bottom' }.points.length, 'the bottom is L-shaped'
    assert_equal 2, layout.doors.length
    one, two = layout.doors.map { |d| plan_box(d) }
    refute overlap?(one, two), 'the two doors do not run into each other'
    [one, two].each { |box| assert box.all? { |v| v >= 0.0 && v <= 900.0 }, 'inside the square' }
    assert_operator one[0], :>=, 560.0, 'door 1 is in front of the arm'
    assert_operator two[2], :>=, 560.0, 'door 2 is in front of the other arm'
  end

  def test_the_doors_hinge_at_their_outer_ends_and_swap_when_asked
    outer = CabinetLayout.compute(params).doors
    assert_equal %w[right left], outer.map(&:hinge)
    assert_in_delta 900.0 - 2.0, outer[0].pivot[1], 0.01, 'door 1 pivots at its far end'
    assert_in_delta 900.0 - 2.0, outer[1].pivot[0], 0.01, 'door 2 pivots at its far end'
    inner = CabinetLayout.compute(params('door_opening_direction' => 'right')).doors
    assert_equal %w[left right], inner.map(&:hinge)
  end

  def test_a_wall_l_unit_hangs_and_keeps_its_doors_full_height
    layout = CabinetLayout.compute(params('cabinet_category' => 'wall', 'toe_kick_height' => 0.0, 'depth' => 320.0, 'carcass_raise' => 100.0))
    assert_equal 0.0, layout.base_z
    assert_equal 680.0, layout.panels.find { |p| p.role == 'left_side' }.extent[2]
    assert_equal 780.0 - 2 * Defaults.params['door_reveal'], layout.doors.first.extent[2]
  end

  def test_a_blind_corner_has_one_door_and_a_fixed_panel_that_share_the_width
    p = params('corner_style' => 'blind', 'width' => 1000.0, 'blind_width' => 450.0, 'door_count' => 1)
    layout = CabinetLayout.compute(p)
    door = layout.doors.first
    blind = layout.panels.find { |x| x.role == 'blind_front' }
    gap = Defaults.params['door_gap']
    reveal = Defaults.params['door_reveal']
    assert_in_delta 1000.0 - 450.0 - reveal - (gap / 2.0), door.extent[1], 0.01
    assert_in_delta 450.0 - reveal - (gap / 2.0), blind.extent[1], 0.01
    assert_in_delta door.offset[1] + door.extent[1] + gap, blind.offset[1], 0.02, 'a door gap between them'
    assert_equal 'left', door.hinge
    flipped = CabinetLayout.compute(p.merge('door_opening_direction' => 'right'))
    assert_operator flipped.panels.find { |x| x.role == 'blind_front' }.offset[1], :<, flipped.doors.first.offset[1], 'blind on the left'
    assert_equal [560.0 + 2.0 + 18.0, 1000.0, 880.0], CabinetLayout.envelope(p), 'a blind corner is a straight cabinet'
  end

  def test_the_sizes_are_checked
    base = { 'catalog_id' => 'c', 'cabinet_category' => 'base', 'cabinet_type' => 'x', 'toe_kick_height' => '100', 'door_opening_direction' => 'left' }
    too_deep = ValidationManager.validate(base.merge('corner_style' => 'l_shape', 'width' => '700', 'depth' => '600', 'height' => '780'), door_count: 2)
    assert_includes too_deep.errors.map { |e| e['field'] }, 'depth'
    fine = ValidationManager.validate(base.merge('corner_style' => 'l_shape', 'width' => '900', 'depth' => '560', 'height' => '780'), door_count: 2)
    assert_empty fine.errors
    assert_equal 'l_shape', fine.params['corner_style']
    narrow_blind = ValidationManager.validate(base.merge('corner_style' => 'blind', 'blind_width' => '960', 'width' => '1000', 'depth' => '560', 'height' => '780'), door_count: 1)
    assert_includes narrow_blind.errors.map { |e| e['field'] }, 'width'
  end
end