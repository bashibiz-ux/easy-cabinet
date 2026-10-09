require 'minitest/autorun'
require_relative 'geom_stub'
module Sketchup; end
module KitchenCabinetMaster; module AttributeManager; end; end
require_relative '../kitchen_cabinet_master/panel_generator'

class DistinctCornersTest < Minitest::Test
  P = KitchenCabinetMaster::PanelGenerator

  def test_a_repeated_corner_is_dropped_whether_it_is_next_to_the_other_or_wraps_round
    assert_equal [[0, 0], [1, 0], [1, 1]], P.distinct_corners([[0, 0], [1, 0], [1, 0], [1, 1]])
    assert_equal [[0, 0], [1, 0], [1, 1]], P.distinct_corners([[0, 0], [1, 0], [1, 1], [0, 0]])
    assert_equal [[0, 0, 0], [1, 0, 0], [1, 1, 0]], P.distinct_corners([[0, 0, 0], [1, 0, 0], [1, 1, 0]])
  end

  def test_a_rounding_as_thick_as_the_slab_no_longer_leaves_a_face_with_a_repeated_point
    pts = [[0.0, 0.0], [0.0, 1000.0], [600.0, 1000.0], [600.0, 600.0], [1000.0, 600.0], [1000.0, 0.0]]
    P.rounded_polygon_faces(pts, 20.0, 20.0, 2).each do |face|
      corners = P.distinct_corners(face)
      assert_equal corners.map { |c| c.map { |v| v.round(3) } }.uniq.length, corners.length
    end
  end
  def test_corners_closer_than_sketchup_tells_apart_are_one_corner
    corners = [[0.0, 0.0, 20.0], [0.0, 0.0, 19.9786], [10.0, 0.0, 19.0], [10.0, 5.0, 19.0]]
    assert_equal [[0.0, 0.0, 20.0], [10.0, 0.0, 19.0], [10.0, 5.0, 19.0]], P.distinct_corners(corners)
  end

  def test_every_face_of_a_rounded_l_slab_has_corners_sketchup_can_tell_apart
    [[10.0, 20.0], [5.0, 20.0], [10.0, 30.0]].each do |r, t|
      pts = [[0.0, 0.0], [0.0, 1000.0], [600.0, 1000.0], [600.0, 600.0], [1000.0, 600.0], [1000.0, 0.0]]
      P.rounded_polygon_faces(pts, t, r, [2, 3]).each do |face|
        c = P.distinct_corners(face)
        c.combination(2).each do |p, q|
          assert_operator Math.sqrt(p.zip(q).sum { |u, v| (u - v)**2 }), :>=, 0.0254, "r=#{r} t=#{t}"
        end
      end
    end
  end
end