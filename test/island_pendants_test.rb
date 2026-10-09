require 'json'
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
  def test_the_spacing_sets_how_many_lights_an_island_gets
    assert_equal 6, P.positions(3600.0, 600.0).length
    assert_equal 3, P.positions(3600.0, 1200.0).length
    assert_equal [600.0, 1800.0, 3000.0], P.positions(3600.0, 1200.0)
    assert_equal P.positions(3600.0), P.positions(3600.0, 800.0)
    assert_equal [900.0], P.positions(1800.0, 1200.0)
  end
  def test_the_height_moves_the_whole_shade_and_its_cord_start
    low = P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum', height: 'low' }).first
    high = P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum', height: 'high' }).first
    assert_equal [1600.0, 1780.0], low[:shade]
    assert_equal [1800.0, 1980.0], high[:shade]
    assert_equal 1980.0, high[:cord][0]
    assert_equal P.profile('dome'), P.profile('dome', 'medium', 'sky-high'), 'an unknown height is the usual one'
  end
  def test_a_shade_with_a_wall_has_an_inside_and_a_single_skin_does_not
    drum = P.profile('drum')
    assert_nil P.inner_profile(drum, 0.0)
    assert_equal [[144.0, 1700.0], [144.0, 1874.0]], P.inner_profile(drum, 6.0), 'an open shade keeps its opening and is lower inside at the top'
    cone = P.inner_profile(P.profile('cone'), 12.0)
    assert_equal [138.0, 38.0], cone.map(&:first)
    globe = P.inner_profile(P.profile('globe'), 12.0)
    assert_equal [0.0, 0.0], globe.values_at(0, -1).map(&:first)
    assert_operator globe.map(&:first).max, :<, 120.0, 'a smaller ball inside'
    light = P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum', thickness: 'thick' }).first
    assert_equal [[138.0, 1700.0], [138.0, 1868.0]], light[:inner]
    assert_nil P.parts({ positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum', thickness: 'weird' }).first[:inner]
  end
  def test_the_glows_are_materials_of_the_extension
    assert_nil P::GLOWS['none']
    assert_equal 'Warm White', P::GLOWS['warm']
    names = JSON.parse(File.read(File.expand_path('../kitchen_cabinet_master/data/materials.json', __dir__))).values.flatten.grep(Hash).map { |m| m['name'] }
    P::GLOWS.values.compact.each { |name| assert_includes names, name }
  end
  def test_a_cord_length_decides_where_the_shade_hangs_but_not_below_the_lowest_allowed
    base = { positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum' }
    short = P.parts(base.merge(cord: 'short')).first
    assert_equal [1720.0, 1900.0], short[:shade]
    assert_equal [1900.0, 2400.0], short[:cord]
    long = P.parts(base.merge(cord: 'long')).first
    assert_equal 1400.0, long[:shade][0], 'a long cord stops where the shade is 500 mm over the worktop'
    assert_equal P.parts(base).first[:shade], P.parts(base.merge(cord: 'auto')).first[:shade]
    assert_equal P.parts(base).first[:shade], P.parts(base.merge(cord: 'weird')).first[:shade]
  end
  def test_the_cord_thickness_is_the_width_across_the_cord
    base = { positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum' }
    assert_equal 8.0, P.parts(base).first[:cord_width]
    assert_equal 4.0, P.parts(base.merge(cord_width: 'thin')).first[:cord_width]
    assert_equal 16.0, P.parts(base.merge(cord_width: 'thick')).first[:cord_width]
    assert_equal 8.0, P.parts(base.merge(cord_width: 'rope')).first[:cord_width]
  end
  def test_a_plate_sits_on_the_ceiling_where_the_cord_ends
    base = { positions: [900.0], back: 300.0, top: 2400.0, shape: 'drum' }
    assert_nil P.parts(base).first[:cap]
    round = P.parts(base.merge(cap: 'round')).first[:cap]
    assert_equal({ shape: :round, half: 50.0, z: [2380.0, 2400.0] }, round)
    assert_equal({ shape: :square, half: 50.0, z: [2380.0, 2400.0] }, P.parts(base.merge(cap: 'square')).first[:cap])
    assert_equal 80.0, P.parts(base.merge(cap: 'wide')).first[:cap][:half]
    assert_nil P.parts(base.merge(cap: 'star')).first[:cap]
    assert_nil P.parts(base.merge(cap: 'round', top: 1700.0)).first[:cap], 'no cord, no plate'
  end
end