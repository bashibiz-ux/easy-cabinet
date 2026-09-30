# frozen_string_literal: true

# The snapping maths (SnapManager.delta), which knows nothing about SketchUp.
# Boxes are { min: [x, y], max: [x, y] } in millimetres. Run:  ruby test/snap_test.rb

require 'minitest/autorun'

module Sketchup
  class EntitiesObserver; end
  class ToolsObserver; end
  class AppObserver; end
end

require_relative '../kitchen_cabinet_master/snap_manager'

class SnapTest < Minitest::Test
  Snap = KitchenCabinetMaster::SnapManager
  THRESHOLD = 150.0

  def box(x, y, depth, width) = { min: [x, y], max: [x + depth, y + width] }

  def snap(moved, others) = Snap.delta(moved, others, THRESHOLD)

  def assert_shift(expected, actual)
    refute_nil actual, 'expected a snap'
    assert_in_delta expected[0], actual[0], 1e-9, 'dx'
    assert_in_delta expected[1], actual[1], 1e-9, 'dy'
  end

  # A 600 x 560 cabinet fixed at the origin (X = depth, Y = width).
  def fixed = box(0, 0, 560, 600)

  def test_a_cabinet_left_a_little_short_snaps_against_the_next_ones_side
    moved = box(0, 640, 560, 600) # 40 mm clear of the fixed cabinet's right side (Y = 600)
    assert_shift [0.0, -40.0], snap(moved, [fixed])
  end

  def test_a_cabinet_pushed_into_the_next_one_snaps_back_out
    moved = box(0, 570, 560, 600) # overlaps it by 30 mm
    assert_shift [0.0, 30.0], snap(moved, [fixed])
  end

  def test_the_left_side_snaps_too
    moved = box(0, -650, 560, 600) # its right side (Y = -50) is 50 mm short of the fixed cabinet's left side (Y = 0)
    assert_shift [0.0, 50.0], snap(moved, [fixed])
  end

  def test_backs_line_up_when_they_are_close
    moved = box(30, 640, 560, 600) # 30 mm forward of the row's back line
    assert_shift [-30.0, -40.0], snap(moved, [fixed])
  end

  def test_a_different_depth_lines_up_by_the_nearest_edge
    tall = box(0, 640, 300, 600) # shallower, backs level already
    assert_shift [0.0, -40.0], snap(tall, [fixed])

    front_flush = box(260, 640, 300, 600) # its front (X = 560) already level, so it lines up front to front
    assert_shift [0.0, -40.0], snap(front_flush, [fixed])
  end

  def test_nothing_snaps_when_too_far_away
    assert_nil snap(box(0, 800, 560, 600), [fixed]) # 200 mm gap
  end

  def test_it_snaps_to_the_nearest_of_several_neighbours
    left = box(0, 0, 560, 600)
    right = box(0, 1000, 560, 600)
    moved = box(0, 640, 560, 340) # 40 mm from `left`, 20 mm from `right` (its right edge is at 980)
    assert_shift [0.0, 20.0], snap(moved, [left, right])
  end

  def test_a_cabinet_in_another_part_of_the_room_does_not_snap
    far_across = box(1200, 0, 560, 600) # 640 mm in front of the fixed cabinet: too far
    assert_nil snap(far_across, [fixed])
  end

  def test_front_to_back_snap_for_a_turned_row
    # A cabinet from the turned leg, 40 mm short of the fixed one's front face (X = 560).
    moved = box(600, 0, 560, 600)
    assert_shift [-40.0, 0.0], snap(moved, [fixed])
  end

  def test_already_touching_needs_no_move
    result = snap(box(0, 600, 560, 600), [fixed])
    assert_shift [0.0, 0.0], result
  end

  def test_no_neighbours_means_no_snap
    assert_nil snap(box(0, 0, 560, 600), [])
  end

  # ---- three axes ---------------------------------------------------------

  def box3(x, y, z, depth, width, height) = { min: [x, y, z], max: [x + depth, y + width, z + height] }

  def test_a_cabinet_lowered_onto_another_snaps_onto_its_top
    below = box3(0, 0, 0, 560, 600, 880)
    moved = box3(0, 0, 1000, 560, 600, 720) # 120 mm above its top
    result = Snap.delta(moved, [below], 300.0)
    assert_equal [0.0, 0.0, -120.0], result
  end

  def test_a_cabinet_beside_another_lines_up_its_height_too
    fixed3 = box3(0, 0, 0, 560, 600, 880)
    moved = box3(0, 640, 60, 560, 600, 880) # 40 mm clear on Y, 60 mm too high
    result = Snap.delta(moved, [fixed3], 300.0)
    assert_equal [0.0, -40.0, -60.0], result
  end

  def test_the_height_snap_reaches_300_mm
    fixed3 = box3(0, 0, 0, 560, 600, 880)
    near = box3(0, 640, 280, 560, 600, 880)
    far = box3(0, 640, 320, 560, 600, 880)
    assert_in_delta(-280.0, Snap.delta(near, [fixed3], 300.0)[2], 1e-9)
    assert_in_delta 0.0, Snap.delta(far, [fixed3], 300.0)[2], 1e-9, 'beyond 300 mm the height is left'
  end

  def test_the_floor_snap
    assert_equal(-120.0, Snap.floor_delta(120.0, 0.0, false, 300.0))
    assert_nil Snap.floor_delta(0.0, 0.0, false, 300.0), 'already on it'
    assert_nil Snap.floor_delta(120.0, 0.0, true, 300.0), 'a wall unit hangs'
    assert_nil Snap.floor_delta(120.0, -30.0, false, 300.0), 'a neighbour already set the height'
    assert_nil Snap.floor_delta(500.0, 0.0, false, 300.0), 'too far'
  end
end
