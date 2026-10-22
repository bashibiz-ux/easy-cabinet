require 'minitest/autorun'
require_relative '../easy_cabinet/dimensioning'

class DimensioningTest < Minitest::Test
  D = EasyCabinet::Dimensioning

  def unit(y:, width: 600.0, **opts)
    { x: 0.0, y: y, z: 0.0, hx: 0.0, hy: 1.0, fx: 1.0, fy: 0.0, width: width, depth: 580.0, base_z: 0.0, top: 880.0, tall: false }.merge(opts)
  end

  # The kinds of line (a row along Y, its fronts looking along +X): a width is drawn 120 mm in front, a run 320 mm in front, a depth 150 mm to the left or right.
  def widths(lines) = lines.select { |line| line[:offset] == [120.0, 0.0, 0.0] }
  def runs(lines) = lines.select { |line| line[:offset] == [320.0, 0.0, 0.0] }
  def depths(lines) = lines.select { |line| line[:from][2] == line[:to][2] && line[:offset][1].abs == 150.0 }
  def heights(lines) = lines.select { |line| line[:from][2] != line[:to][2] }

  def test_every_unit_gets_its_width_along_its_front
    lines = widths(D.lines([unit(y: 0.0)]))
    assert_equal 1, lines.length
    assert_equal [580.0, 0.0, 0.0], lines.first[:from]
    assert_equal [580.0, 600.0, 0.0], lines.first[:to]
    assert_equal [120.0, 0.0, 0.0], lines.first[:offset], 'out in front of the units'
  end

  def test_a_run_of_units_gets_its_whole_length_as_well
    lines = D.lines([unit(y: 0.0), unit(y: 600.0, width: 900.0), unit(y: 1500.0, width: 300.0)])
    assert_equal 3, widths(lines).length
    whole = runs(lines).first
    assert_equal [580.0, 0.0, 0.0], whole[:from]
    assert_equal [580.0, 1800.0, 0.0], whole[:to]
    assert_equal [320.0, 0.0, 0.0], whole[:offset]
  end

  def test_units_with_a_gap_are_two_runs
    lines = D.lines([unit(y: 0.0), unit(y: 600.0), unit(y: 2000.0), unit(y: 2600.0)])
    assert_equal 4, widths(lines).length
    assert_equal 2, runs(lines).length
  end

  def test_wall_units_are_a_run_of_their_own_at_their_own_height
    lines = D.lines([unit(y: 0.0), unit(y: 600.0), unit(y: 0.0, base_z: 1480.0, top: 2260.0, depth: 320.0), unit(y: 600.0, base_z: 1480.0, top: 2260.0, depth: 320.0)])
    whole = runs(lines)
    assert_equal 2, whole.length
    assert_equal [1480.0], whole.map { |line| line[:from][2] } - [0.0]
  end

  def test_a_tall_unit_gets_its_height_up_its_front_edge
    lines = D.lines([unit(y: 0.0, top: 2260.0, tall: true)])
    height = heights(lines).first
    assert_equal [580.0, 0.0, 0.0], height[:from]
    assert_equal [580.0, 0.0, 2260.0], height[:to]
    assert_equal 1, heights(lines).length, 'one height: a tall unit has its own, not the one of a base run'
  end

  def test_a_turned_row_follows_its_own_direction
    # a row along X, its fronts looking along +Y
    lines = D.lines([{ x: 0.0, y: 0.0, z: 0.0, hx: 1.0, hy: 0.0, fx: 0.0, fy: 1.0, width: 600.0, depth: 580.0, base_z: 0.0, top: 880.0, tall: false }])
    first = lines.find { |line| line[:offset] == [0.0, 120.0, 0.0] }
    assert_equal [0.0, 580.0, 0.0], first[:from]
    assert_equal [600.0, 580.0, 0.0], first[:to]
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
  end

  # ---- the plan: depths ------------------------------------------------------------------------------------------

  def test_a_run_gets_its_depth_on_its_left_end
    lines = depths(D.lines([unit(y: 0.0), unit(y: 600.0)]))
    assert_equal 1, lines.length, 'the units are equally deep: one depth'
    assert_equal [0.0, 0.0, 0.0], lines.first[:from], 'from the back of the first unit'
    assert_equal [580.0, 0.0, 0.0], lines.first[:to], 'to its front'
    assert_equal [0.0, -150.0, 0.0], lines.first[:offset], 'to the left of the run'
  end

  def test_a_unit_at_the_far_end_with_another_depth_gets_its_own_on_the_right
    lines = depths(D.lines([unit(y: 0.0), unit(y: 600.0, depth: 400.0)]))
    assert_equal 2, lines.length
    right = lines.find { |line| line[:offset][1] == 150.0 }
    assert_equal [0.0, 1200.0, 0.0], right[:from]
    assert_equal [400.0, 1200.0, 0.0], right[:to]
  end

  def test_a_wall_run_has_its_depth_at_the_height_of_its_underside
    lines = depths(D.lines([unit(y: 0.0, base_z: 1480.0, top: 2260.0, depth: 320.0, wall: true)]))
    assert_equal [1480.0], lines.map { |line| line[:from][2] }.uniq
    assert_equal [320.0, 0.0, 1480.0], lines.first[:to]
  end

  # ---- the elevation: heights ------------------------------------------------------------------------------------

  def test_a_base_run_gets_the_height_of_its_toe_kick_and_its_whole_height
    lines = heights(D.lines([unit(y: 0.0, base_z: 100.0, top: 880.0, wall: false), unit(y: 600.0, base_z: 100.0, top: 880.0, wall: false)]))
    assert_equal 2, lines.length
    toe = lines.find { |line| line[:to][2] == 100.0 }
    assert_equal [0.0, 0.0], [toe[:from][2], toe[:from][1]]
    whole = lines.find { |line| line[:to][2] == 880.0 }
    assert_equal 0.0, whole[:from][2]
    assert_equal [0.0, -300.0, 0.0], whole[:offset], 'outside the toe kick'
  end

  def test_a_wall_run_gets_how_high_it_hangs_and_how_tall_its_units_are
    lines = heights(D.lines([unit(y: 0.0, base_z: 1480.0, top: 2260.0, depth: 320.0, wall: true)]))
    assert_equal 2, lines.length
    assert_equal [0.0, 1480.0], lines.first.values_at(:from, :to).map { |p| p[2] }
    assert_equal [1480.0, 2260.0], lines.last.values_at(:from, :to).map { |p| p[2] }
  end

  def test_base_and_wall_units_over_one_another_are_two_runs_when_they_are_marked
    items = [unit(y: 0.0, base_z: 100.0, top: 880.0, wall: false), unit(y: 600.0, base_z: 100.0, top: 880.0, wall: false),
             unit(y: 0.0, base_z: 1480.0, top: 2260.0, depth: 320.0, wall: true), unit(y: 600.0, base_z: 1480.0, top: 2260.0, depth: 320.0, wall: true)]
    assert_equal 2, runs(D.lines(items)).length
  end
end
