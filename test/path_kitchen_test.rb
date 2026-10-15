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
  # ---- Insert on Path ---------------------------------------------------------------------

  def test_as_many_whole_cabinets_as_fit_stand_along_a_wall_from_its_start
    laid = PK.placements([[[0, 0], [2500, 0]]], 600.0, 560.0, eye: [1000, -3000])
    assert_equal 4, laid[:places].length
    assert_equal [0.0, 600.0, 1200.0, 1800.0], laid[:places].map { |p| p['x'].round(1) }
    assert_equal [0.0, -1.0], [laid[:places].first['out_x'], laid[:places].first['out_y']], 'the front faces the side the eye is on'
  end

  def test_the_other_side_of_the_path
    laid = PK.placements([[[0, 0], [1300, 0]]], 600.0, 560.0, eye: [500, -3000], flip: true)
    assert_equal [0.0, 1.0], [laid[:places].first['out_x'], laid[:places].first['out_y']]
  end

  def test_the_wall_after_an_inner_corner_starts_a_cabinet_depth_from_it
    segments = [[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]]]
    places = PK.placements(segments, 600.0, 560.0, eye: [1500, 1000])[:places]
    along_y0 = places.select { |p| p['y'].abs < 0.01 } # (the path runs from the far wall: the wall at y = 0 is the second one)
    assert_in_delta 3000.0 - 560.0, along_y0.map { |p| p['x'] }.max, 0.01
  end

  def test_a_closed_room_stops_the_last_wall_a_depth_short_of_the_first
    places = PK.placements(rectangle(3000.0, 3000.0), 600.0, 560.0)[:places]
    refute_empty places
    assert_equal places.length, places.map { |p| [p['x'].round(1), p['y'].round(1)] }.uniq.length, 'no two cabinets in one place'
  end

  def test_a_wall_too_short_gives_nothing_and_a_note
    laid = PK.placements([[[0, 0], [400, 0]]], 600.0, 560.0)
    assert_empty laid[:places]
    refute_empty laid[:notes]
  end
  def test_a_corner_unit_goes_into_an_inner_corner_and_the_walls_make_room_for_it
    segments = [[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]]]
    places = PK.placements(segments, 600.0, 560.0, eye: [1500, 1000], corner: 1000.0)[:places]
    corners = places.select { |p| p['corner'] }
    assert_equal 1, corners.length
    assert_in_delta 3000.0, corners.first['x'], 0.01
    assert_in_delta 0.0, corners.first['y'], 0.01, 'its origin is the corner of the walls'
    assert_equal [0.0, 1.0], [corners.first['out_x'], corners.first['out_y']], 'its depth runs back along the first wall (which came down along x = 3000), its width along the second'
    straight = places.reject { |p| p['corner'] || p['filler'] }
    assert_equal 2, straight.count { |p| p['x'].round == 3000 }, 'the first wall has 1400 mm left for the straight cabinets'
    assert_equal 3, straight.count { |p| p['y'].round.zero? }, 'the second wall starts 1000 mm from the corner'
    assert_in_delta 2000.0, straight.select { |p| p['y'].round.zero? }.map { |p| p['x'] }.max, 0.01
  end

  def test_a_closed_room_has_a_corner_unit_in_every_corner
    places = PK.placements(rectangle(4000.0, 3000.0), 600.0, 560.0, corner: 1000.0)[:places]
    assert_equal 4, places.count { |p| p['corner'] }
  end

  def test_no_corner_unit_for_a_single_wall_or_without_a_corner_width
    assert_equal 0, PK.placements([[[0, 0], [3000, 0]]], 600.0, 560.0, corner: 1000.0)[:places].count { |p| p['corner'] }
    assert_equal 0, PK.placements([[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]]], 600.0, 560.0, eye: [1500, 1000])[:places].count { |p| p['corner'] }
  end
  def test_what_is_left_of_a_wall_before_a_corner_is_a_filler_after_the_last_cabinet
    segments = [[[0, 0], [3000, 0]], [[3000, 0], [3000, 2400]]]
    places = PK.placements(segments, 600.0, 560.0, eye: [1500, 1000], corner: 1000.0)[:places]
    fillers = places.select { |p| p['filler'] }
    assert_equal [200.0], fillers.map { |p| p['filler'] }, 'the first wall: 2400 - 1000 for the corner = 1400, two cabinets of 600 leave 200'
    assert_in_delta 1200.0, (fillers.first['y'] - 2400.0).abs, 0.01, 'it starts where the second cabinet ends'
  end

  def test_no_filler_where_the_cabinets_fill_the_wall_or_at_the_end_of_the_path
    assert_empty PK.placements([[[0, 0], [3000, 0]]], 600.0, 560.0, eye: [1500, -3000])[:places].select { |p| p['filler'] }
  end
end
