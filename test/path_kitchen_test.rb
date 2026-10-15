# frozen_string_literal: true

# Runs the plugin's REAL PathKitchen geometry (no SketchUp needed).
# Run:  ruby test/path_kitchen_test.rb

require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/path_kitchen'

class PathKitchenTest < Minitest::Test
  PK = KitchenCabinetMaster::PathKitchen

  def rectangle(width = 4000.0, depth = 3000.0)
    pts = [[0, 0], [width, 0], [width, depth], [0, depth]]
    pts.each_with_index.map { |p, i| [p, pts[(i + 1) % 4]] }
  end

  def test_edges_that_join_make_one_chain_and_a_split_wall_is_one_wall
    chains = PK.chains([[[0, 0], [1000, 0]], [[1000, 0], [3000, 0]], [[3000, 0], [3000, 2000]]])
    assert_equal 1, chains.length
    assert_equal [[0, 0], [3000, 0], [3000, 2000]], chains.first[:points]
    refute chains.first[:closed]
  end

  def test_separate_edges_are_separate_chains
    assert_equal 2, PK.chains([[[0, 0], [3000, 0]], [[5000, 0], [8000, 0]]]).length
  end

  def test_a_closed_rectangle_with_the_room_inside_is_a_u_and_a_straight
    laid = PK.layout(rectangle, eye: nil)
    assert_equal %w[u straight], laid[:pieces].map { |p| p[:layout] }
    u, straight = laid[:pieces]
    assert_equal 3, u[:lengths].length
    # the last wall of the loop stops short of the corner the first piece starts in, and starts short of the corner before it
    assert_in_delta 3000.0 - (2 * PK::CLEAR), straight[:lengths].first, 0.2
  end

  def test_the_room_is_inside_whichever_way_the_rectangle_was_drawn
    clockwise = rectangle.reverse.map(&:reverse)
    [rectangle, clockwise].each do |segments|
      pieces = PK.layout(segments)[:pieces]
      first = pieces.first
      # the first wall runs with the room on its right: the row's out direction (right of dir) points into the rectangle
      out = [first[:dir][1], -first[:dir][0]]
      probe = [first[:origin][0] + (out[0] * 100) + (first[:dir][0] * 100), first[:origin][1] + (out[1] * 100) + (first[:dir][1] * 100)]
      assert probe[0].between?(0, 4000) && probe[1].between?(0, 3000), "room inside, got #{probe.inspect}"
    end
  end

  def test_an_open_l_is_an_l_on_the_side_the_eye_is_on
    segments = [[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]]]
    inside = PK.layout(segments, eye: [1000, 1000])[:pieces]
    assert_equal ['l'], inside.map { |p| p[:layout] }
    assert_equal [2400.0, 3000.0], inside.first[:lengths]
    # seen from the other side the same edges turn the wrong way for an inner corner: two straight runs
    outside = PK.layout(segments, eye: [-500, -500])[:pieces]
    assert_equal %w[straight straight], outside.map { |p| p[:layout] }
  end

  def test_flip_puts_the_units_on_the_other_side
    segments = [[[0, 0], [3000, 0]]]
    a = PK.layout(segments, eye: [1000, 500])[:pieces].first
    b = PK.layout(segments, eye: [1000, 500], flip: true)[:pieces].first
    refute_equal a[:dir], b[:dir]
  end

  def test_a_u_is_three_walls
    segments = [[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]], [[3000, 2400], [0, 2400]]]
    pieces = PK.layout(segments, eye: [1500, 1200])[:pieces]
    assert_equal ['u'], pieces.map { |p| p[:layout] }
    assert_equal [3000.0, 2400.0, 3000.0], pieces.first[:lengths]
  end
  # ---- the floor plan: the best fit ------------------------------------------------------

  def test_the_floor_plan_best_fit_is_one_u_on_the_three_longest_walls_in_a_row
    pieces = PK.layout(rectangle, fit: 'auto')[:pieces]
    assert_equal ['u'], pieces.map { |p| p[:layout] }
    assert_equal [4000.0, 3000.0, 4000.0], pieces.first[:lengths]
  end

  def test_an_l_or_one_wall_can_be_asked_for
    assert_equal [[4000.0, 3000.0]], PK.layout(rectangle, fit: 'l')[:pieces].map { |p| p[:lengths] }
    assert_equal [[4000.0]], PK.layout(rectangle, fit: 'straight')[:pieces].map { |p| p[:lengths] }
  end

  def test_walls_that_are_too_short_for_a_u_give_an_l_then_a_straight
    narrow = rectangle(4000.0, 1500.0)
    assert_equal ['straight'], PK.layout(narrow, fit: 'auto')[:pieces].map { |p| p[:layout] }, 'only the 4000 walls are long enough, and they are not next to one another'
    assert_equal [[4000.0]], PK.layout(narrow, fit: 'u')[:pieces].map { |p| p[:lengths] }, 'a U that does not fit gives what does'
  end

  def test_every_wall_keeps_the_old_way
    assert_equal %w[u straight], PK.layout(rectangle, fit: 'all')[:pieces].map { |p| p[:layout] }
  end

  def test_the_units_stand_inside_the_room_with_the_best_fit_too
    piece = PK.layout(rectangle, fit: 'straight')[:pieces].first
    centre = [2000.0, 1500.0] # the room is on the right of the way the row runs
    assert_operator PK.cross(piece[:dir], PK.vec(piece[:origin], centre)), :<, 0
    assert_in_delta 1.0, Math.hypot(*piece[:dir]), 1e-9
  end
end
