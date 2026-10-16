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

  def test_the_boxes_are_a_floor_four_walls_and_a_roof_with_the_inside_left_free
    plan = RS.plan(straight)
    boxes = RS.boxes(plan)
    assert_equal %w[Floor Walls Walls Walls Walls Roof], boxes.map { |b| b[:name] }
    floor = boxes.first
    roof = boxes.last
    assert_equal [-100.0, 0.0], [floor[:from][2], floor[:to][2]]
    assert_equal [plan[:height], plan[:height] + 150.0], [roof[:from][2], roof[:to][2]]
    walls = boxes.select { |b| b[:name] == 'Walls' }
    assert(walls.all? { |w| w[:from][2] == 0.0 && w[:to][2] == plan[:height] })
    walls.each do |w| # no wall comes into the inside of the room
      overlap_x = [w[:to][0], plan[:x1]].min - [w[:from][0], plan[:x0]].max
      overlap_y = [w[:to][1], plan[:y1]].min - [w[:from][1], plan[:y0]].max
      refute overlap_x > 0.01 && overlap_y > 0.01, 'a wall inside the room'
    end
    assert_equal [plan[:x0] - 150.0, plan[:x1] + 150.0], [floor[:from][0], floor[:to][0]], 'the floor reaches under the walls'
  end

  def test_parts_can_be_left_out
    plan = RS.plan(straight)
    assert_equal %w[Walls Walls Walls Walls], RS.boxes(plan, 'floor' => false, 'roof' => false).map { |b| b[:name] }
    assert_equal %w[Floor Roof], RS.boxes(plan, 'walls' => false).map { |b| b[:name] }
  end
end
