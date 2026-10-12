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
end
