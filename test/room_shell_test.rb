# frozen_string_literal: true

# The Room (floor, walls, roof round the kitchen): the plain geometry of RoomShell.plan and RoomShell.boxes (no SketchUp needed).
# Run:  ruby test/room_shell_test.rb

require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/room_shell'

class RoomShellTest < Minitest::Test
  RS = KitchenCabinetMaster::RoomShell

  # a cabinet whose back is on the line through `origin` and whose front faces `front`
  def item(x0, y0, x1, y1, front, origin, top: 2260.0) = { min: [x0, y0], max: [x1, y1], top: top, origin: origin, front: front }

  # three base units along x with their backs on y = 0 (fronts face +y)
  def straight
    [0, 600, 1200].map { |x| item(x, 0, x + 600, 560, [0.0, 1.0], [x, 0]) }
  end

  def test_the_wall_is_right_behind_the_backs_and_the_open_sides_are_a_distance_away
    plan = RS.plan(straight)
    assert_in_delta(-1200.0, plan[:x0], 0.01, 'an open side: the distance away')
    assert_in_delta 3000.0, plan[:x1], 0.01
    assert_in_delta 0.0, plan[:y0], 0.01, 'the backs stand against this side: the wall is right behind them'
    assert_in_delta 560.0 + 1200.0, plan[:y1], 0.01, 'the front is open'
    assert_equal({ min_x: false, max_x: false, min_y: true, max_y: false }, plan[:backs])
  end

  def test_a_u_shaped_kitchen_has_three_walls_behind_it_and_one_open_side
    items = straight + [
      item(0, 0, 560, 3000, [0.0, 1.0], [0, 0]).merge(front: [1.0, 0.0], origin: [0, 0]),     # the west row: back on x = 0, front faces +x
      item(1840, 0, 2400, 3000, [-1.0, 0.0], [2400, 0])                                          # the east row: back on x = 2400, front faces -x
    ]
    plan = RS.plan(items)
    assert_equal [true, true, true, false], plan[:backs].values_at(:min_x, :max_x, :min_y, :max_y).then { |a| [a[0], a[1], a[2], a[3]] }
    assert_in_delta 0.0, plan[:x0], 0.01
    assert_in_delta 2400.0, plan[:x1], 0.01
    assert_in_delta 3000.0 + 1200.0, plan[:y1], 0.01
  end

  def test_with_no_back_against_a_side_every_side_is_open
    island = [item(1000, 1000, 2000, 1900, [0.0, 1.0], [1500, 1450])]
    plan = RS.plan(island)
    assert_in_delta(-200.0, plan[:x0], 0.01)
    assert_in_delta 3200.0, plan[:x1], 0.01
    assert_in_delta(-200.0, plan[:y0], 0.01)
    assert_in_delta 3100.0, plan[:y1], 0.01
  end

  def test_the_room_is_as_high_as_the_highest_part_and_at_least_2600
    assert_equal 2600.0, RS.plan(straight)[:height]
    assert_equal 2900.0, RS.plan(straight + [item(0, 0, 600, 560, [0.0, 1.0], [0, 0], top: 2900.0)])[:height]
    assert_equal 3000.0, RS.plan(straight, 'room_height' => 3000.0)[:height]
  end

  def test_nothing_to_draw_round_without_a_kitchen
    assert_nil RS.plan([])
  end

  def test_the_floor_and_the_roof_are_boxes_and_the_walls_one_ring_with_the_inside_left_free
    plan = RS.plan(straight)
    boxes = RS.boxes(plan)
    assert_equal %w[Floor Roof], boxes.map { |b| b[:name] }
    floor, roof = boxes
    assert_equal [-100.0, 0.0], [floor[:from][2], floor[:to][2]]
    assert_equal [plan[:height], plan[:height] + 150.0], [roof[:from][2], roof[:to][2]]
    assert_equal [plan[:x0] - 150.0, plan[:x1] + 150.0], [floor[:from][0], floor[:to][0]], 'the floor reaches under the walls'
    ring = RS.ring(plan)
    assert_equal [plan[:x0], plan[:y0], plan[:x1], plan[:y1]], ring[:inner]
    assert_equal [plan[:x0] - 150.0, plan[:y0] - 150.0, plan[:x1] + 150.0, plan[:y1] + 150.0], ring[:outer]
    assert_equal plan[:height], ring[:height]
  end

  def test_parts_can_be_left_out
    plan = RS.plan(straight)
    assert_equal %w[Roof], RS.boxes(plan, 'floor' => false).map { |b| b[:name] }
    assert_equal %w[Floor Roof], RS.boxes(plan, 'walls' => false).map { |b| b[:name] }
    assert_nil RS.ring(plan, 'walls' => false)
  end

  # ---- the doors and windows -----------------------------------------------------------------

  def test_a_door_is_in_the_middle_of_an_open_side_standing_on_the_floor
    plan = RS.plan(straight) # inside x -1200 .. 3000, y 0 .. 1760; the backs are on the south side
    found, problem = RS.openings(plan, [{ 'kind' => 'Door', 'wall' => 'auto', 'width' => 900.0, 'height' => 2100.0 }])
    assert_nil problem
    door = found.first
    assert_equal 'north', door[:wall], 'the first open side: the south has the backs, the north is open'
    assert_in_delta(-1200.0 + ((4200.0 - 900.0) / 2.0), door[:from][0], 0.01, 'in the middle')
    assert_equal [0.0, 2100.0], [door[:from][2], door[:to][2]]
    assert_equal [plan[:y1], plan[:y1] + 150.0], [door[:from][1], door[:to][1]], 'right through the thickness of the wall'
    assert_equal [0.0, 1.0], door[:out]
  end

  def test_a_window_goes_in_the_wall_behind_the_cabinets_at_its_sill_height
    plan = RS.plan(straight)
    found, = RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'auto', 'width' => 1200.0, 'sill' => 900.0, 'height' => 1200.0, 'from' => 500.0 }])
    window = found.first
    assert_equal 'south', window[:wall]
    assert_equal [900.0, 2100.0], [window[:from][2], window[:to][2]]
    assert_in_delta(-1200.0 + 500.0, window[:from][0], 0.01)
    assert_equal [plan[:y0] - 150.0, plan[:y0]], [window[:from][1], window[:to][1]]
    assert_equal [0.0, -1.0], window[:out]
  end

  def test_a_wall_can_be_chosen_and_west_and_east_walls_are_measured_from_the_south
    plan = RS.plan(straight)
    found, = RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'east', 'width' => 1000.0, 'sill' => 900.0, 'height' => 1000.0, 'from' => 200.0 }])
    window = found.first
    assert_equal [plan[:x1], plan[:x1] + 150.0], [window[:from][0], window[:to][0]]
    assert_equal [plan[:y0] + 200.0, plan[:y0] + 1200.0], [window[:from][1], window[:to][1]]
  end

  def test_an_opening_that_does_not_fit_is_refused_with_the_reason
    plan = RS.plan(straight)
    assert_match(/past the end/, RS.openings(plan, [{ 'kind' => 'Door', 'wall' => 'north', 'width' => 900.0, 'height' => 2100.0, 'from' => 3800.0 }]).last)
    assert_match(/higher than the wall/, RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'south', 'width' => 900.0, 'sill' => 2000.0, 'height' => 1000.0 }]).last)
    assert_match(/wider/, RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'west', 'width' => 9000.0, 'sill' => 900.0, 'height' => 1000.0 }]).last)
    assert_match(/overlap/, RS.openings(plan, [{ 'kind' => 'Door', 'wall' => 'north', 'width' => 900.0, 'height' => 2100.0 }, { 'kind' => 'Window', 'wall' => 'north', 'width' => 900.0, 'sill' => 900.0, 'height' => 1000.0 }]).last)
  end

  def test_two_openings_on_a_wall_that_do_not_meet_are_fine
    plan = RS.plan(straight)
    found, problem = RS.openings(plan, [{ 'kind' => 'Door', 'wall' => 'north', 'width' => 900.0, 'height' => 2100.0, 'from' => 100.0 },
                                        { 'kind' => 'Window', 'wall' => 'north', 'width' => 900.0, 'sill' => 900.0, 'height' => 1000.0, 'from' => 2000.0 }])
    assert_nil problem
    assert_equal 2, found.length
  end
  # ---- the open sides, one distance for x and one for y ---------------------------------------

  def test_the_open_side_distance_is_one_for_x_and_one_for_y
    plan = RS.plan(straight, 'open_x' => 800.0, 'open_y' => 1500.0)
    assert_in_delta(-800.0, plan[:x0], 0.01, 'the west side is open: the distance in x')
    assert_in_delta 1800.0 + 800.0, plan[:x1], 0.01, 'the east side is open too: the same distance in x'
    assert_in_delta 0.0, plan[:y0], 0.01, 'the backs are against the south side'
    assert_in_delta 560.0 + 1500.0, plan[:y1], 0.01, 'the north side is open: the distance in y'
  end

  def test_without_x_or_y_the_old_single_distance_is_used
    plan = RS.plan(straight, 'open_distance' => 1000.0)
    assert_in_delta(-1000.0, plan[:x0], 0.01)
    assert_in_delta 560.0 + 1000.0, plan[:y1], 0.01
    assert_in_delta(-500.0, RS.plan(straight, 'open_distance' => 1000.0, 'open_x' => 500.0)[:x0], 0.01)
  end


  def test_the_back_of_an_island_is_no_wall_so_that_side_is_open_and_gets_the_distance
    items = straight + [item(2500, 1000, 3060, 2200, [1.0, 0.0], [2500, 1000]).merge(origin: [3060, 1000], front: [-1.0, 0.0], island: true)] # the back of the island is on x = 3060, the edge of the box
    plan = RS.plan(items, 'open_x' => 700.0)
    refute plan[:backs][:max_x], 'an island is not against a wall'
    assert_in_delta 3060.0 + 700.0, plan[:x1], 0.01, 'the east side is open: the distance in x'
    walls = RS.plan(items.map { |i| i.merge(island: false) }, 'open_x' => 700.0)
    assert walls[:backs][:max_x]
    assert_in_delta 3060.0, walls[:x1], 0.01, 'the same unit as a cabinet against a wall: the wall is right behind it'
  end
end
