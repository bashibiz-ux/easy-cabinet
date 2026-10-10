require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/dimensioning'

class DimensioningTest < Minitest::Test
  D = KitchenCabinetMaster::Dimensioning

  def unit(y:, width: 600.0, **opts)
    { x: 0.0, y: y, z: 0.0, hx: 0.0, hy: 1.0, fx: 1.0, fy: 0.0, width: width, depth: 580.0, base_z: 0.0, top: 880.0, tall: false }.merge(opts)
  end

  def test_every_unit_gets_its_width_along_its_front
    lines = D.lines([unit(y: 0.0)])
    assert_equal 1, lines.length
    assert_equal [580.0, 0.0, 0.0], lines.first[:from]
    assert_equal [580.0, 600.0, 0.0], lines.first[:to]
    assert_equal [120.0, 0.0, 0.0], lines.first[:offset], 'out in front of the units'
  end

  def test_a_run_of_units_gets_its_whole_length_as_well
    lines = D.lines([unit(y: 0.0), unit(y: 600.0, width: 900.0), unit(y: 1500.0, width: 300.0)])
    assert_equal 4, lines.length
    whole = lines.last
    assert_equal [580.0, 0.0, 0.0], whole[:from]
    assert_equal [580.0, 1800.0, 0.0], whole[:to]
    assert_equal [320.0, 0.0, 0.0], whole[:offset]
  end

  def test_units_with_a_gap_are_two_runs
    lines = D.lines([unit(y: 0.0), unit(y: 600.0), unit(y: 2000.0), unit(y: 2600.0)])
    assert_equal 4 + 2, lines.length
  end

  def test_wall_units_are_a_run_of_their_own_at_their_own_height
    lines = D.lines([unit(y: 0.0), unit(y: 600.0), unit(y: 0.0, base_z: 1480.0, top: 2260.0, depth: 320.0), unit(y: 600.0, base_z: 1480.0, top: 2260.0, depth: 320.0)])
    whole = lines.select { |line| line[:offset] == [320.0, 0.0, 0.0] }
    assert_equal 2, whole.length
    assert_equal [1480.0], whole.map { |line| line[:from][2] } - [0.0]
  end

  def test_a_tall_unit_gets_its_height_up_its_front_edge
    lines = D.lines([unit(y: 0.0, top: 2260.0, tall: true)])
    height = lines.last
    assert_equal [580.0, 0.0, 0.0], height[:from]
    assert_equal [580.0, 0.0, 2260.0], height[:to]
  end

  def test_a_turned_row_follows_its_own_direction
    # a row along X, its fronts looking along +Y
    lines = D.lines([{ x: 0.0, y: 0.0, z: 0.0, hx: 1.0, hy: 0.0, fx: 0.0, fy: 1.0, width: 600.0, depth: 580.0, base_z: 0.0, top: 880.0, tall: false }])
    assert_equal [0.0, 580.0, 0.0], lines.first[:from]
    assert_equal [600.0, 580.0, 0.0], lines.first[:to]
    assert_equal [0.0, 120.0, 0.0], lines.first[:offset]
  end

def test_an_island_gets_its_length_on_the_back_and_its_depth_with_the_overhang
  island = [unit(y: 0.0, island: true, overhang: 300.0), unit(y: 600.0, island: true, overhang: 300.0)]
  lines = D.lines(island)
  assert_equal 5, lines.length, 'two widths, the run in front, the run on the back, the depth'
  back = lines.find { |line| line[:offset] == [-320.0, 0.0, 0.0] }
  assert_equal [-300.0, 0.0, 0.0], back[:from]
  assert_equal [-300.0, 1200.0, 0.0], back[:to]
  depth = lines.last
  assert_equal [-300.0, 0.0, 0.0], depth[:from]
  assert_equal [580.0, 0.0, 0.0], depth[:to], '300 mm of overhang and 580 mm of units'
  assert_equal [0.0, -300.0, 0.0], depth[:offset], 'out beyond the end of the island'
  assert_equal 3, D.lines([unit(y: 0.0), unit(y: 600.0)]).length, 'a plain run is not touched: two widths and the run'
end
end
