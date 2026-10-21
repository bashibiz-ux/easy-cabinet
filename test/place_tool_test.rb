# frozen_string_literal: true

# Insert at Point: which way the cabinet faces at a click (the plain arithmetic of PlaceTool), and where PlacementManager puts it.
# Run:  ruby test/place_tool_test.rb

require 'minitest/autorun'
require_relative '../easy_cabinet/place_tool'

class PlaceToolTest < Minitest::Test
  Tool = EasyCabinet::PlaceTool

  def test_with_no_edge_the_front_faces_along_x
    assert_equal [1.0, 0.0], Tool.frame(nil, nil)
  end

  def test_on_an_edge_the_front_faces_the_side_the_eye_is_on
    assert_equal [0.0, -1.0], Tool.frame([1.0, 0.0], [0.0, -500.0])
    assert_equal [0.0, 1.0], Tool.frame([1.0, 0.0], [0.0, 500.0])
  end

  def test_a_diagonal_edge_gives_a_front_at_a_right_angle_to_it
    out = Tool.frame([1.0, 1.0], [-1.0, 1.0])
    assert_in_delta 0.0, (out[0] * 1.0) + (out[1] * 1.0), 1e-9
    assert_in_delta 1.0, Math.hypot(*out), 1e-9
  end

  def test_the_arrow_keys_turn_it_a_quarter_each_way
    assert_equal [0.0, 1.0], Tool.frame(nil, nil, 1)
    assert_equal [-1.0, 0.0], Tool.frame(nil, nil, 2)
    assert_equal [0.0, -1.0], Tool.frame(nil, nil, -1)
  end
end
