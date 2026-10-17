# frozen_string_literal: true

# The wall-snapping maths (SnapManager.wall_delta), which knows nothing about
# SketchUp. A cabinet's front faces along `f`; its back is at its origin. Run:
#   ruby test/wall_snap_test.rb

require 'minitest/autorun'

module Sketchup
  class EntitiesObserver; end
  class ToolsObserver; end
  class AppObserver; end
end

require_relative '../kitchen_cabinet_master/snap_manager'

class WallSnapTest < Minitest::Test
  Snap = KitchenCabinetMaster::SnapManager
  THRESHOLD = 200.0

  # A wall along Y at X = `x`, `length` long, `height` tall (its surface faces +X / -X).
  def wall_along_y(x, from: 0.0, to: 4000.0, height: 2400.0)
    { normal: [1.0, 0.0], points: [[x, from], [x, to], [x, to], [x, from]], z: [0.0, height] }
  end

  # A wall along X at Y = `y`.
  def wall_along_x(y, from: 0.0, to: 4000.0, height: 2400.0)
    { normal: [0.0, 1.0], points: [[from, y], [to, y], [to, y], [from, y]], z: [0.0, height] }
  end

  # A cabinet facing +X (front toward +X), back at `x`, spanning Y from..to.
  def facing_x(x, from: 1000.0, to: 1600.0, z: [100.0, 880.0])
    { f: [1.0, 0.0], origin: [x, from], t: [from, to], z: z }
  end

  def assert_shift(expected, actual)
    refute_nil actual, 'expected a wall snap'
    assert_in_delta expected[0], actual[0], 1e-9, 'dx'
    assert_in_delta expected[1], actual[1], 1e-9, 'dy'
  end

  def test_a_cabinet_left_short_of_the_wall_snaps_back_onto_it
    assert_shift [-60.0, 0.0], Snap.wall_delta(facing_x(60.0), [wall_along_y(0.0)], THRESHOLD)
  end

  def test_a_cabinet_pushed_into_the_wall_snaps_out_to_its_surface
    assert_shift [40.0, 0.0], Snap.wall_delta(facing_x(-40.0), [wall_along_y(0.0)], THRESHOLD)
  end

  def test_only_the_direction_the_cabinet_faces_moves
    result = Snap.wall_delta(facing_x(60.0, from: 500.0, to: 1100.0), [wall_along_y(0.0)], THRESHOLD)
    assert_in_delta 0.0, result[1], 1e-9, 'sliding along the wall is left to the user'
  end

  def test_a_wall_that_is_too_far_away_is_ignored
    assert_nil Snap.wall_delta(facing_x(350.0), [wall_along_y(0.0)], THRESHOLD)
  end

  def test_the_nearest_of_several_walls_wins
    walls = [wall_along_y(0.0), wall_along_y(150.0), wall_along_y(-100.0)]
    assert_shift [-20.0, 0.0], Snap.wall_delta(facing_x(170.0), walls, THRESHOLD)
  end

  def test_a_wall_running_the_other_way_is_not_a_back_wall
    # The cabinet faces +X; a wall along X (a side wall) is not what its back goes against.
    assert_nil Snap.wall_delta(facing_x(60.0), [wall_along_x(0.0)], THRESHOLD)
  end

  def test_a_cabinet_turned_a_quarter_turn_snaps_to_the_other_wall
    # Facing -Y (the row that turned the corner): its back is toward +Y, against a wall along X.
    turned = { f: [0.0, -1.0], origin: [900.0, 2440.0], t: [900.0, 1500.0], z: [100.0, 880.0] }
    # t = (-fy, fx) = (1, 0): its extent runs along X.
    result = Snap.wall_delta(turned, [wall_along_x(2400.0)], THRESHOLD)
    assert_shift [0.0, -40.0], result
  end

  def test_a_wall_is_ignored_when_the_cabinet_is_not_alongside_it
    # Wall only covers Y 0..800; the cabinet is at Y 1000..1600: no overlap at all.
    assert_nil Snap.wall_delta(facing_x(60.0), [wall_along_y(0.0, from: 0.0, to: 800.0)], THRESHOLD)
  end

  def test_a_short_stub_of_wall_is_not_enough
    # Only 200 of the cabinet's 600 width lies along the wall (less than half).
    stub = wall_along_y(0.0, from: 900.0, to: 1200.0)
    assert_nil Snap.wall_delta(facing_x(60.0), [stub], THRESHOLD)
  end

  def test_a_wall_that_is_not_at_the_cabinets_height_is_ignored
    low_step = wall_along_y(0.0, height: 90.0) # lower than the cabinet's base
    assert_nil Snap.wall_delta(facing_x(60.0, z: [100.0, 880.0]), [low_step], THRESHOLD)
  end

  def test_no_walls_no_snap
    assert_nil Snap.wall_delta(facing_x(60.0), [], THRESHOLD)
  end

  def test_side_and_wall_snapping_combine
    # B is dragged near A (side snap), and near a wall behind both.
    a = { min: [0.0, 0.0], max: [560.0, 600.0] }
    b = { min: [40.0, 640.0], max: [600.0, 1240.0] } # 40 short of A's side, 40 forward of A's back
    side = Snap.delta(b, [a], 200.0)
    assert_shift [-40.0, -40.0], side

    # After that shift B's back is at x = 0: the wall (also at x = 0) needs no further move.
    moved = { f: [1.0, 0.0], origin: [40.0 + side[0], 640.0 + side[1]], t: [640.0 + side[1], 1240.0 + side[1]], z: [100.0, 880.0] }
    wall = Snap.wall_delta(moved, [wall_along_y(0.0)], 200.0)
    assert_shift [0.0, 0.0], wall
  end
  # ---- a cabinet moved to another wall is turned to it ------------------------------------------

  # A cabinet 600 wide and 560 deep whose back is at `back` on the line through `origin`, looking along `f`.
  def cabinet(f, center, width: 600.0, depth: 560.0, z: [100.0, 880.0])
    t = [-f[1], f[0]]
    middle = (center[0] * t[0]) + (center[1] * t[1])
    { f: f, origin: [center[0] - (f[0] * depth / 2.0), center[1] - (f[1] * depth / 2.0)], t: [middle - (width / 2.0), middle + (width / 2.0)], z: z, center: center, depth: depth }
  end

  def degrees(radians) = radians * 180.0 / Math::PI

  def test_a_cabinet_that_looks_at_the_wall_turns_half_a_turn_to_put_its_back_on_it
    wall = wall_along_y(0.0) # the room is on the +X side
    mover = cabinet([-1.0, 0.0], [330.0, 1300.0]) # its front towards the wall (its front is at x = 50), its back away from it
    angle = Snap.wall_turn(mover, [wall], THRESHOLD)
    refute_nil angle
    assert_in_delta 180.0, degrees(angle).abs, 0.01
  end

  def test_a_cabinet_standing_across_a_wall_turns_a_quarter_to_face_the_room
    wall = wall_along_y(0.0)
    mover = cabinet([0.0, 1.0], [250.0, 1300.0], depth: 400.0) # its front looks along +Y, its side is by the wall
    angle = Snap.wall_turn(mover, [wall], 100.0)
    assert_in_delta(-90.0, degrees(angle), 0.01, 'turned clockwise from +Y to +X')
  end

  def test_a_cabinet_already_with_its_back_to_the_wall_is_left_as_it_is
    wall = wall_along_y(0.0)
    assert_nil Snap.wall_turn(cabinet([1.0, 0.0], [330.0, 1300.0]), [wall], THRESHOLD)
  end

  def test_a_wall_beside_a_cabinet_with_its_back_to_a_wall_does_not_turn_it
    wall = wall_along_y(0.0)
    assert_nil Snap.wall_turn(cabinet([1.0, 0.0], [330.0, 1300.0]), [wall, wall_along_x(1000.0)], THRESHOLD), 'it has its back to the wall: the wall beside it is left alone'
  end

  def test_a_cabinet_a_little_short_of_the_wall_with_its_back_to_it_is_snapped_not_turned
    assert_nil Snap.wall_turn(cabinet([1.0, 0.0], [380.0, 1300.0]), [wall_along_y(0.0)], THRESHOLD)
  end

  def test_the_room_is_on_the_side_of_the_cabinet_whichever_way_the_wall_faces
    wall = wall_along_y(2000.0) # the surface faces +X but the cabinet is on the -X side of it
    angle = Snap.wall_turn(cabinet([1.0, 0.0], [1700.0, 1300.0]), [wall], THRESHOLD)
    assert_in_delta 180.0, degrees(angle).abs, 0.01, 'its back must be on the wall: the front looks along -X'
  end

  def test_a_cabinet_far_from_every_wall_is_not_turned
    wall = wall_along_y(0.0)
    assert_nil Snap.wall_turn(cabinet([0.0, 1.0], [2500.0, 1300.0]), [wall], THRESHOLD)
  end

  def test_a_wall_it_is_not_beside_does_not_turn_it
    wall = wall_along_y(0.0, from: 0.0, to: 500.0)
    assert_nil Snap.wall_turn(cabinet([0.0, 1.0], [250.0, 3000.0]), [wall], THRESHOLD), 'the wall ends well before the cabinet'
  end

  def test_a_wall_of_another_height_does_not_turn_it
    wall = wall_along_y(0.0, height: 50.0)
    assert_nil Snap.wall_turn(cabinet([0.0, 1.0], [250.0, 1300.0]), [wall], THRESHOLD)
  end
end
