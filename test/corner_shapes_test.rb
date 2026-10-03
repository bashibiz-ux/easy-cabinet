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
    %w[right_side front_return back back_2 bottom top].each { |r| assert_includes roles, r }
    refute_includes roles, 'inner_front_1', 'the doors are the front; the legs have no inner panels'
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
    assert_in_delta 900.0 - Defaults.params['door_gap'], outer[0].pivot[1], 0.01, 'door 1 pivots at its far end'
    assert_in_delta 900.0 - Defaults.params['door_gap'], outer[1].pivot[0], 0.01, 'door 2 pivots at its far end'
    inner = CabinetLayout.compute(params('door_opening_direction' => 'right')).doors
    assert_equal %w[left right], inner.map(&:hinge)
  end

  def test_a_wall_l_unit_hangs_and_keeps_its_doors_full_height
    layout = CabinetLayout.compute(params('cabinet_category' => 'wall', 'toe_kick_height' => 0.0, 'depth' => 320.0, 'carcass_raise' => 100.0))
    assert_equal 0.0, layout.base_z
    assert_equal 680.0, layout.panels.find { |p| p.role == 'right_side' }.extent[2]
    assert_equal 780.0 - 2 * Defaults.params['door_gap'], layout.doors.first.extent[2]
  end

  def test_a_blind_corner_has_one_door_and_a_blind_panel_that_is_always_50_mm_wider
    gap = Defaults.params['door_gap']
    reveal = Defaults.params['door_reveal']
    [900.0, 1000.0, 1200.0].each do |width|
      layout = CabinetLayout.compute(params('corner_style' => 'blind', 'width' => width, 'door_count' => 1))
      door = layout.doors.first
      blind = layout.panels.find { |x| x.role == 'blind_front' }
      assert_in_delta door.extent[1] + 50.0, blind.extent[1], 0.02, "#{width}: the blind panel is 50 mm wider than the door"
      assert_in_delta width - (2 * reveal) - gap, door.extent[1] + blind.extent[1], 0.02, 'together they fill the width'
      assert_in_delta door.offset[1] + door.extent[1] + gap, blind.offset[1], 0.02, 'a door gap between them'
    end
  end

  def test_a_blind_corner_door_hinges_on_the_blind_side_and_swaps_with_the_direction
    left = CabinetLayout.compute(params('corner_style' => 'blind', 'door_count' => 1)) # blind on the right
    door = left.doors.first
    assert_equal 'right', door.hinge, 'the hinge is next to the blind panel'
    assert_in_delta door.offset[1] + door.extent[1], door.pivot[1], 0.01, 'its pivot is at the blind-side end'
    flipped = CabinetLayout.compute(params('corner_style' => 'blind', 'door_count' => 1, 'door_opening_direction' => 'right'))
    assert_equal 'left', flipped.doors.first.hinge
    assert_operator flipped.panels.find { |x| x.role == 'blind_front' }.offset[1], :<, flipped.doors.first.offset[1], 'blind on the left'
    assert_equal [560.0 + 2.0 + 18.0, 900.0, 880.0], CabinetLayout.envelope(params('corner_style' => 'blind')), 'a blind corner is a straight cabinet'
  end
  def test_the_two_legs_can_differ_in_length_and_depth
    p = params('width' => 1000.0, 'depth' => 560.0, 'leg2_length' => 800.0, 'leg2_depth' => 400.0)
    assert_equal [800.0, 1000.0, 880.0], CabinetLayout.envelope(p), 'x reaches leg 2''s length, y leg 1''s'
    layout = CabinetLayout.compute(p)
    bottom = layout.panels.find { |x| x.role == 'bottom' }.points
    assert_equal [800.0 - 18.0, 400.0], bottom[2], 'leg 2 ends at its side panel, the notch is leg 2''s depth'
    assert_equal [560.0, 400.0], bottom[3], 'the inside corner is at (leg 1 depth, leg 2 depth)'
    assert_equal [560.0, 1000.0 - 18.0], bottom[4]
    one, two = layout.doors.map { |d| plan_box(d) }
    refute overlap?(one, two)
    assert_in_delta 1000.0 - Defaults.params['door_gap'], one[3], 0.01, 'door A reaches leg 1''s end'
    assert_in_delta 800.0 - Defaults.params['door_gap'], two[1], 0.01, 'door B reaches leg 2''s end'
    side_one = layout.panels.find { |x| x.role == 'right_side' }
    side_two = layout.panels.find { |x| x.role == 'front_return' }
    assert_equal [560.0, 18.0], side_one.extent.first(2), 'leg 1''s end panel is as deep as leg 1'
    assert_equal [18.0, 400.0], side_two.extent.first(2), 'leg 2''s end panel is as deep as leg 2'
  end

  def test_the_sizes_are_checked
    base = { 'catalog_id' => 'c', 'cabinet_category' => 'base', 'cabinet_type' => 'x', 'toe_kick_height' => '100', 'door_opening_direction' => 'left' }
    too_deep = ValidationManager.validate(base.merge('corner_style' => 'l_shape', 'width' => '700', 'depth' => '600', 'height' => '780'), door_count: 2)
    assert_includes too_deep.errors.map { |e| e['field'] }, 'depth'
    fine = ValidationManager.validate(base.merge('corner_style' => 'l_shape', 'width' => '900', 'depth' => '560', 'height' => '780'), door_count: 2)
    assert_empty fine.errors
    assert_equal 'l_shape', fine.params['corner_style']
    narrow_blind = ValidationManager.validate(base.merge('corner_style' => 'blind', 'width' => '150', 'depth' => '560', 'height' => '780'), door_count: 1)
    assert_includes narrow_blind.errors.map { |e| e['field'] }, 'width'
  end

  # The numbers of the L-corner builder script: legs of 900 with depths 580 and a 780 high cabinet.
  def test_the_l_doors_are_the_size_of_the_script_s_shutters
    p = params('width' => 900.0, 'depth' => 580.0, 'leg2_length' => 900.0, 'leg2_depth' => 580.0, 'door_gap' => 1.5, 'door_reveal' => 2.0)
    layout = CabinetLayout.compute(p)
    one, two = layout.doors
    # Door 1 is the door of Leg 1 (Width x Depth), as the script's first shutter: Leg 1 Length - Leg 2 Depth
    # - 2 gaps - a panel - 4 mm. Door 2 is the second shutter: Leg 2 Length - Leg 1 Depth - 2 gaps.
    assert_equal [18.0, 900.0 - 580.0 - 3.0 - 18.0 - 4.0, 780.0 - 3.0], one.extent, 'shutter 1 of the script (leg 1)'
    assert_equal [18.0, 900.0 - 580.0 - 3.0, 780.0 - 3.0], two.extent, 'shutter 2 of the script (leg 2)'
    assert_in_delta 100.0 + 1.5, one.offset[2], 1e-9, 'a 1.5 mm gap under the doors'
    assert_in_delta 580.0 + 2.0, one.offset[0], 1e-9, 'a 2 mm stand-off from the carcass'
    assert_in_delta 580.0 + 1.5 + 18.0 + 4.0, one.offset[1], 1e-9, 'door 1 starts a panel and 4 mm past the notch'
    assert_in_delta 900.0 - 1.5, one.offset[1] + one.extent[1], 1e-9, 'and reaches the end of leg 1'
    assert_in_delta 580.0 + 2.0, two.offset[1], 1e-9
    assert_in_delta 900.0 - 1.5, two.offset[0], 1e-9, 'door 2 runs from the far end back towards the notch'
    assert_in_delta 580.0 + 1.5, two.offset[0] - two.extent[1], 1e-9, 'it starts a gap from leg 1'
  end

  def test_the_l_doors_open_wide_enough_to_see_inside
    layout = CabinetLayout.compute(params)
    layout.doors.each { |d| assert_equal 120.0, d.swing }
    assert_nil CabinetLayout.compute(params('corner_style' => 'diagonal', 'door_count' => 1)).doors.first.swing
  end

  def test_the_blind_panel_is_the_colour_of_the_door
    layout = CabinetLayout.compute(params('corner_style' => 'blind', 'door_count' => 1))
    assert layout.panels.find { |x| x.role == 'blind_front' }.front, 'it takes the door material'
    refute layout.panels.find { |x| x.role == 'left_side' }.front
  end

  def test_the_thin_back_runs_9_mm_into_the_groove_of_the_right_side_panel
    [6.0, 9.0].each do |back|
      layout = CabinetLayout.compute(params('width' => 1000.0, 'back_thickness' => back))
      leg1 = layout.panels.find { |x| x.role == 'back' }
      side = layout.panels.find { |x| x.role == 'right_side' }
      assert_in_delta side.offset[1] + 9.0, leg1.offset[1] + leg1.extent[1], 1e-9, "back #{back}: 9 mm into the side panel"
      assert_operator leg1.offset[1] + leg1.extent[1], :<, side.offset[1] + side.extent[1], 'and not through it'
    end
  end

  def test_the_left_back_panel_is_always_an_18_mm_panel_flush_with_the_wall
    [6.0, 9.0, 12.0, 18.0].each do |back|
      layout = CabinetLayout.compute(params('back_thickness' => back))
      left = layout.panels.find { |x| x.role == 'back_2' }
      assert_equal [900.0 - 18.0, 18.0, 780.0], left.extent, "back #{back}"
      assert_equal [0.0, 0.0, 0.0], left.offset, 'flush with the wall, not set in'
      leg1 = layout.panels.find { |x| x.role == 'back' }
      assert_equal back, leg1.extent[0], 'the other back keeps the back panel thickness'
      assert_equal 18.0, leg1.offset[1], 'and starts beside the left panel'
    end
  end
end