require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/island_pendants'

class IslandPendantsTest < Minitest::Test
  P = KitchenCabinetMaster::IslandPendants

  def test_lights_are_spread_evenly_one_for_about_every_800_mm
    assert_equal [450.0, 1350.0, 2250.0, 3150.0], P.positions(3600.0)
    assert_equal [450.0, 1350.0], P.positions(1800.0)
    assert_equal [500.0], P.positions(1000.0)
    assert_equal [200.0], P.positions(400.0)
  end

  def test_each_light_has_a_shade_over_the_middle_of_the_overhang_and_a_cord_to_the_ceiling
    light = P.parts({ positions: [900.0], back: 300.0, top: 2400.0 }).first
    assert_equal [-150.0, 900.0], light[:centre]
    assert_equal [1700.0, 1880.0], light[:shade]
    assert_equal [1880.0, 2400.0], light[:cord]
  end
end