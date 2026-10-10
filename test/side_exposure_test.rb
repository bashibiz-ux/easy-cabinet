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
    assert_includes found, [0.0, 880.0, 580.0, 2100.0]
    assert_includes found, [320.0, 0.0, 580.0, 880.0]
  end

  def test_a_cabinet_that_hangs_shows_its_side_below_the_one_beside_it
    side = { depth: 320.0, base: 1480.0, top: 2260.0 }
    assert_equal [[0.0, 1480.0, 320.0, 1800.0]], E.uncovered(side, [{ x0: 0.0, x1: 320.0, z0: 1800.0, z1: 2260.0 }])
  end

  def test_slivers_are_not_worth_a_panel
    assert_empty E.uncovered(SIDE, [{ x0: 0.0, x1: 570.0, z0: 0.0, z1: 2095.0 }])
  end
end