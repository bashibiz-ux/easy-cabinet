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
  def test_shapes_turn_a_profile_round_the_cord_and_the_cord_starts_at_the_top_of_the_shade
    P::SHAPES.each do |shape|
      light = P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: shape }).first
      outline = P.profile(shape)
      assert_equal 1700.0, outline.first[1], shape
      assert_equal outline.last[1], light[:cord][0], shape
      assert_equal outline.last[1], light[:shade][1], shape
    end
    assert_equal [[150.0, 1700.0], [150.0, 1880.0]], P.profile('drum')
    assert_equal [150.0, 50.0], P.profile('cone').map(&:first)
    assert_equal [0.0, 0.0], P.profile('globe').values_at(0, -1).map(&:first)
    assert_equal P.profile('drum'), P.profile('nonsense'), 'an unknown shape is a drum'
  end
  def test_sizes_scale_the_shade_but_keep_its_underside_where_it_is
    small = P.profile('drum', 'small')
    large = P.profile('drum', 'large')
    assert_equal [[112.5, 1700.0], [112.5, 1835.0]], small
    assert_equal [[210.0, 1700.0], [210.0, 1952.0]], large
    assert_equal P.profile('drum'), P.profile('drum', 'enormous'), 'an unknown size is the usual one'
    light = P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum', size: 'large' }).first
    assert_equal 1952.0, light[:cord][0]
  end
end