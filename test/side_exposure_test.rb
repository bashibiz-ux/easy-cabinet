require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/side_exposure'

class SideExposureTest < Minitest::Test
  E = KitchenCabinetMaster::SideExposure
  SIDE = { depth: 580.0, base: 0.0, top: 2100.0 }.freeze

  def test_a_side_nothing_touches_shows_all_of_it
    assert_equal [[0.0, 0.0, 580.0, 2100.0]], E.uncovered(SIDE, [])
  end

  def test_a_side_wholly_covered_shows_nothing
    assert_empty E.uncovered(SIDE, [{ x0: 0.0, x1: 580.0, z0: 0.0, z1: 2100.0 }])
    assert_empty E.uncovered(SIDE, [{ x0: 0.0, x1: 600.0, z0: 0.0, z1: 2200.0 }]), 'a bigger neighbour covers it all'
  end

  def test_a_tall_cabinet_beside_a_low_one_shows_its_side_above_the_low_one
    assert_equal [[0.0, 880.0, 580.0, 2100.0]], E.uncovered(SIDE, [{ x0: 0.0, x1: 580.0, z0: 0.0, z1: 880.0 }])
  end

  def test_a_deep_cabinet_beside_a_shallow_one_shows_the_strip_in_front_of_it
    assert_equal [[320.0, 0.0, 580.0, 2100.0]], E.uncovered(SIDE, [{ x0: 0.0, x1: 320.0, z0: 0.0, z1: 2100.0 }])
  end

  def test_both_at_once_show_the_part_above_and_the_strip_in_front
    found = E.uncovered(SIDE, [{ x0: 0.0, x1: 320.0, z0: 0.0, z1: 880.0 }])
    assert_includes found, [0.0, 880.0, 320.0, 2100.0]
    assert_includes found, [320.0, 0.0, 580.0, 2100.0]
  end

  def test_a_cabinet_that_hangs_shows_its_side_below_the_one_beside_it
    side = { depth: 320.0, base: 1480.0, top: 2260.0 }
    assert_equal [[0.0, 1480.0, 320.0, 1800.0]], E.uncovered(side, [{ x0: 0.0, x1: 320.0, z0: 1800.0, z1: 2260.0 }])
  end

  def test_slivers_are_not_worth_a_panel
    assert_empty E.uncovered(SIDE, [{ x0: 0.0, x1: 570.0, z0: 0.0, z1: 2095.0 }])
  end

  # The picture: an oven tower (560 deep, 2260 high) beside base units (560 deep, 880 high) with wall units over them (320 deep, from 1480 to
  # 2260). The side of the tower shows between the base units and the wall units, and in front of the wall units.
  def test_a_tower_beside_base_and_wall_units_shows_the_side_between_them_and_in_front_of_the_wall_units
    tower = { depth: 560.0, base: 0.0, top: 2260.0 }
    base_units = { x0: 0.0, x1: 560.0, z0: 0.0, z1: 880.0 }
    wall_units = { x0: 0.0, x1: 320.0, z0: 1480.0, z1: 2260.0 }
    found = E.uncovered(tower, [base_units, wall_units])
    assert_includes found, [0.0, 880.0, 320.0, 1480.0], 'between the base units and the wall units'
    assert_includes found, [320.0, 880.0, 560.0, 2260.0], 'in front of the wall units'
    assert_equal 2, found.length
  end
def test_an_inner_side_panel_is_only_on_the_side_of_the_unit_not_down_through_the_toe_kick
  assert_equal [100.0, 2260.0], E.panel_span(inner: true, hangs: false, carcass: 100.0, top: 2260.0)
  assert_equal [100.0, 880.0], E.panel_span(inner: true, hangs: false, carcass: 100.0, top: 880.0)
end

def test_an_outer_side_panel_goes_from_the_floor_to_the_top_of_the_unit
  assert_equal [0.0, 2260.0], E.panel_span(inner: false, hangs: false, carcass: 100.0, top: 2260.0)
end

def test_a_wall_unit_never_has_a_panel_down_to_the_floor
  assert_equal [1480.0, 2260.0], E.panel_span(inner: false, hangs: true, carcass: 1480.0, top: 2260.0)
  assert_equal [1480.0, 2260.0], E.panel_span(inner: true, hangs: true, carcass: 1480.0, top: 2260.0)
end
end
