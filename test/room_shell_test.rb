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
  # ---- the frames ---------------------------------------------------------------------------------

  def test_a_door_has_a_jamb_each_side_and_a_head_and_its_leaf_stands_on_the_floor
    plan = RS.plan(straight)
    cut = RS.openings(plan, [{ 'kind' => 'Door', 'wall' => 'north', 'width' => 900.0, 'height' => 2100.0, 'from' => 1000.0 }]).first.first
    parts = RS.frame_parts(cut)
    assert_equal 3, parts[:frame].length
    left, right, head = parts[:frame]
    assert_equal [cut[:from][0], cut[:from][0] + 50.0], [left[:from][0], left[:to][0]]
    assert_equal [cut[:to][0] - 50.0, cut[:to][0]], [right[:from][0], right[:to][0]]
    assert_equal [2050.0, 2100.0], [head[:from][2], head[:to][2]]
    assert_equal [cut[:from][1], cut[:to][1]], [left[:from][1], left[:to][1]], 'the frame goes through the whole thickness of the wall'
    leaf = parts[:infill]
    assert_equal 0.0, leaf[:from][2], 'the leaf stands on the floor'
    assert_equal 2050.0, leaf[:to][2]
    assert_in_delta 40.0, leaf[:to][1] - leaf[:from][1], 0.01
    assert_in_delta((cut[:from][1] + cut[:to][1]) / 2.0, (leaf[:from][1] + leaf[:to][1]) / 2.0, 0.01, 'in the middle of the wall')
  end

  def test_a_window_has_a_frame_all_round_and_its_glass_inside_it
    plan = RS.plan(straight)
    cut = RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'east', 'width' => 1000.0, 'sill' => 900.0, 'height' => 1200.0, 'from' => 300.0 }]).first.first
    parts = RS.frame_parts(cut)
    assert_equal 4, parts[:frame].length
    sill = parts[:frame].last
    assert_equal [900.0, 950.0], [sill[:from][2], sill[:to][2]]
    glass = parts[:infill]
    assert_equal [950.0, 2050.0], [glass[:from][2], glass[:to][2]]
    assert_equal [cut[:from][1] + 50.0, cut[:to][1] - 50.0], [glass[:from][1], glass[:to][1]], 'a west or east wall runs along y'
    assert_in_delta 10.0, glass[:to][0] - glass[:from][0], 0.01
  end

  def test_a_frame_never_takes_more_than_a_quarter_of_a_narrow_opening
    plan = RS.plan(straight)
    cut = RS.openings(plan, [{ 'kind' => 'Window', 'wall' => 'north', 'width' => 200.0, 'sill' => 900.0, 'height' => 300.0 }]).first.first
    left = RS.frame_parts(cut)[:frame].first
    assert_in_delta 50.0, left[:to][0] - left[:from][0], 0.01
    narrow = RS.frame_parts(cut, 400.0)[:frame].first
    assert_in_delta 50.0, narrow[:to][0] - narrow[:from][0], 0.01
  end

  # ---- parts are no backs --------------------------------------------------------------------------

  def test_a_part_whose_back_is_on_the_edge_of_the_box_is_no_wall_behind_it
    island_worktop = item(2500, 1000, 3060, 2200, [1.0, 0.0], [3060, 1000]).merge(front: [-1.0, 0.0], cabinet: false)
    plan = RS.plan(straight + [island_worktop], 'open_x' => 700.0)
    refute plan[:backs][:max_x]
    assert_in_delta 3060.0 + 700.0, plan[:x1], 0.01
    cabinet = island_worktop.merge(cabinet: true)
    assert RS.plan(straight + [cabinet])[:backs][:max_x], 'the same thing as a cabinet is a back against a wall'
  end
  # ---- realistic doors and windows ------------------------------------------------------------------

  def overlap(a, b)
    (0..2).map { |i| [[a[:to][i], b[:to][i]].min - [a[:from][i], b[:from][i]].max, 0.0].max }.reduce(:*)
  end

  def no_overlaps_in(parts)
    parts.each do |name, boxes|
      boxes.combination(2).each { |a, b| assert_operator overlap(a, b), :<, 1e-6, "two boxes of #{name} run into one another" }
      boxes.each { |box| assert(box[:from].zip(box[:to]).all? { |lo, hi| hi - lo > 0.001 }, "a box of #{name} has no size") }
    end
  end

  def door_cut(wall = 'north', from = 1000.0)
    RS.openings(RS.plan(straight), [{ 'kind' => 'Door', 'wall' => wall, 'width' => 900.0, 'height' => 2100.0, 'from' => from }]).first.first
  end

  def window_cut(wall = 'south', width = 1200.0)
    RS.openings(RS.plan(straight), [{ 'kind' => 'Window', 'wall' => wall, 'width' => width, 'sill' => 900.0, 'height' => 1200.0, 'from' => 300.0 }]).first.first
  end

  def test_a_door_is_a_frame_with_trim_a_panelled_leaf_and_a_handle_and_nothing_overlaps
    parts = RS.door_parts(door_cut)
    assert_equal %w[Frame Handle Hinge Leaf], parts.keys.sort
    assert_equal 4 + 12 + 3, parts['Frame'].length, 'two jambs, a head and a threshold; casing and bead (three boards each) on both faces; three stop strips'
    assert_equal 3, parts['Hinge'].length
    leaf = parts['Leaf']
    assert_equal 1 + 8, leaf.length, 'the leaf, and four raised panels (two by two) on each face'
    assert_equal 4, parts['Handle'].length, 'a rose and a lever on each face'
    no_overlaps_in(parts)
  end

  def test_the_door_leaf_is_inside_the_frame_and_off_the_floor_a_little_and_the_handle_is_at_hand_height
    cut = door_cut
    parts = RS.door_parts(cut)
    leaf = parts['Leaf'].first
    assert_operator leaf[:from][0], :>, cut[:from][0] + 50.0, 'inside the jambs'
    assert_operator leaf[:to][0], :<, cut[:to][0] - 50.0
    assert_in_delta 10.0, leaf[:from][2], 0.01, 'a little clear of the floor'
    assert_operator leaf[:to][2], :<, cut[:to][2] - 50.0, 'under the head'
    zs = parts['Handle'].map { |b| (b[:from][2] + b[:to][2]) / 2.0 }
    assert(zs.all? { |z| (z - 1000.0).abs < 1.0 }, 'about a metre up')
  end

  def test_a_window_has_a_frame_sashes_glass_a_handle_and_two_sills_and_nothing_overlaps
    parts = RS.window_parts(window_cut)
    assert_equal %w[Bar Frame Glass Handle Sash], parts.keys.sort
    assert_equal 4 + 6, parts['Frame'].length, 'the frame, and casing and bead on the room face'
    assert_equal 2 * 4, parts['Sash'].length, 'a wide window has two sashes, four sticks each'
    assert_equal 2 * 2, parts['Glass'].length, 'each sash has two panes, side by side'
    assert_equal 2, parts['Bar'].length, 'and a bar between them'
    no_overlaps_in(parts)
    assert_equal 1 * 4, RS.window_parts(window_cut('south', 700.0))['Sash'].length, 'a narrow one has one sash'
  end

  def test_each_sash_is_hinged_at_its_outer_edge_and_turns_into_the_room
    cut = window_cut
    first, second = RS.window_sashes(cut)
    assert_operator first[:hinge][0], :<, second[:hinge][0]
    assert_equal(-first[:turn], second[:turn], 'they turn opposite ways')
    assert_in_delta cut[:from][0] + 60.0 + 2.0, first[:hinge][0], 0.01
    assert_equal 1, RS.window_sashes(window_cut('south', 700.0)).length
  end

  def test_a_leaf_opening_swings_into_the_room_whichever_wall_it_is_in
    plan = RS.plan(straight)
    %w[south north west east].each do |wall|
      cut = RS.openings(plan, [{ 'kind' => 'Door', 'wall' => wall, 'width' => 900.0, 'height' => 2100.0, 'from' => 200.0 }]).first.first
      swing = RS.door_swing(cut)
      along = cut[:out][0].zero? ? [1.0, 0.0] : [0.0, 1.0]
      a = swing[:angle] * Math::PI / 180.0
      turned = [(along[0] * Math.cos(a)) - (along[1] * Math.sin(a)), (along[0] * Math.sin(a)) + (along[1] * Math.cos(a))]
      assert_operator((turned[0] * cut[:out][0]) + (turned[1] * cut[:out][1]), :<, -0.99, "on the #{wall} wall the open leaf points into the room")
    end
  end

  def test_whether_a_door_is_open_is_kept_in_its_spec
    cut = RS.openings(RS.plan(straight), [{ 'kind' => 'Door', 'wall' => 'north', 'width' => 900.0, 'height' => 2100.0, 'from' => 1000.0, 'open' => true }]).first.first
    assert_equal true, cut[:spec]['open']
    assert_equal false, door_cut[:spec]['open']
  end

  def test_a_window_has_no_sill_boards_below_its_frame
    cut = window_cut
    lowest = RS.window_parts(cut).values.flatten.map { |b| b[:from][2] }.min
    assert_in_delta cut[:from][2], lowest, 0.01, 'nothing hangs below the frame'
  end

  def test_the_parts_of_a_window_on_a_west_or_east_wall_run_along_y
    cut = window_cut('east', 1000.0)
    sash = RS.window_parts(cut)['Sash']
    assert(sash.all? { |b| b[:from][1] >= cut[:from][1] && b[:to][1] <= cut[:to][1] }, 'the sashes are inside the opening along y')
    glass = RS.window_parts(cut)['Glass'].first
    assert_in_delta 6.0, glass[:to][0] - glass[:from][0], 0.01, 'thin across the wall, which is x here'
  end

  # ---- moving a door or a window ---------------------------------------------------------------------

  def test_a_moved_door_goes_to_the_nearest_wall_and_its_place_follows
    plan = RS.plan(straight) # inside x -1200 .. 3000, y 0 .. 1760
    spec = { 'kind' => 'Door', 'wall' => 'north', 'from' => 1000.0, 'width' => 900.0, 'sill' => 0.0, 'height' => 2100.0 }
    moved = RS.relocate(plan, spec, 2800.0, 1000.0, 0.0) # the middle is now near the east wall
    assert_equal 'east', moved['wall']
    assert_in_delta 1000.0 - 450.0, moved['from'], 0.01, 'its middle is 1000 along the east wall (from the south end)'
    assert_equal 0.0, moved['sill']
  end

  def test_it_stays_on_the_wall_whatever_the_distance_and_is_kept_inside_its_ends
    plan = RS.plan(straight)
    spec = { 'kind' => 'Window', 'wall' => 'south', 'from' => 300.0, 'width' => 1200.0, 'sill' => 900.0, 'height' => 1200.0 }
    near_south = RS.relocate(plan, spec, 0.0, 30.0, 1100.0)
    assert_equal 'south', near_south['wall']
    assert_in_delta 1200.0 - 600.0, near_south['from'], 0.01, 'its middle is at x = 0, which is 1200 from the west end'
    assert_equal 1100.0, near_south['sill'], 'a window can be moved up and down'
    far = RS.relocate(plan, spec, 2900.0, 20.0, 900.0)
    assert_in_delta 4200.0 - 1200.0, far['from'], 0.01, 'it is kept inside the end of the wall'
    assert_equal 0.0, RS.relocate(plan, spec, -1190.0, 20.0, -500.0)['sill'], 'and not under the floor'
    assert_equal [1760.0 - 1200.0, 1760.0 - 1200.0], [RS.relocate(plan, spec, 2990.0, 5000.0, 900.0)['from']] * 2
  end

  def test_the_moved_opening_is_cut_where_the_door_now_is
    plan = RS.plan(straight)
    spec = { 'kind' => 'Door', 'wall' => 'north', 'from' => 1000.0, 'width' => 900.0, 'sill' => 0.0, 'height' => 2100.0 }
    moved = RS.relocate(plan, spec, 2800.0, 1000.0, 0.0)
    cut = RS.openings(plan, [moved]).first.first
    assert_equal [plan[:x1], plan[:x1] + 150.0], [cut[:from][0], cut[:to][0]]
    assert_equal [plan[:y0] + 550.0, plan[:y0] + 1450.0], [cut[:from][1], cut[:to][1]]
    assert_equal [1.0, 0.0], cut[:out], 'the opening is parallel to the east wall: it runs along y'
  end
  # ---- copies of a door or window ------------------------------------------------------------------

  def test_a_door_that_is_where_it_was_drawn_is_left_alone
    moved, copies = RS.classify_openings([[0, [100.0, 200.0, 0.0], [100.0, 200.0, 0.0]], [1, [900.0, 5.0, 900.0], [900.0, 5.0, 900.0]]])
    assert_empty moved
    assert_empty copies
  end

  def test_a_door_that_was_moved_is_moved
    moved, copies = RS.classify_openings([[0, [500.0, 200.0, 0.0], [100.0, 200.0, 0.0]]])
    assert_equal({ 0 => [500.0, 200.0, 0.0] }, moved)
    assert_empty copies
  end

  def test_a_pasted_copy_is_a_new_opening_and_the_original_stays
    home = [100.0, 200.0, 0.0]
    moved, copies = RS.classify_openings([[0, home, home], [0, [2000.0, 300.0, 0.0], home]])
    assert_empty moved, 'the original is where it was drawn'
    assert_equal [[0, [2000.0, 300.0, 0.0]]], copies
    moved, copies = RS.classify_openings([[0, [2000.0, 300.0, 0.0], home], [0, home, home]]) # the order in the model does not matter
    assert_empty moved
    assert_equal [[0, [2000.0, 300.0, 0.0]]], copies
  end

  def test_several_copies_are_several_openings
    home = [100.0, 200.0, 0.0]
    _, copies = RS.classify_openings([[0, home, home], [0, [800.0, 300.0, 0.0], home], [0, [1600.0, 300.0, 0.0], home]])
    assert_equal 2, copies.length
  end

  def test_when_none_is_at_home_the_first_is_the_original_that_was_moved_and_the_rest_are_copies
    home = [100.0, 200.0, 0.0]
    moved, copies = RS.classify_openings([[0, [800.0, 300.0, 0.0], home], [0, [1600.0, 300.0, 0.0], home]])
    assert_equal({ 0 => [800.0, 300.0, 0.0] }, moved)
    assert_equal [[0, [1600.0, 300.0, 0.0]]], copies
  end

  def test_a_window_and_a_door_are_told_apart_by_their_index
    moved, copies = RS.classify_openings([[0, [1.0, 1.0, 0.0], [1.0, 1.0, 0.0]], [1, [9.0, 9.0, 900.0], [5.0, 5.0, 900.0]], [1, [5.0, 5.0, 900.0], [5.0, 5.0, 900.0]]])
    assert_empty moved
    assert_equal [[1, [9.0, 9.0, 900.0]]], copies
  end

  def test_a_copy_of_a_window_on_another_wall_is_a_window_of_the_same_size_square_to_that_wall
    plan = RS.plan(straight)
    spec = { 'kind' => 'Window', 'wall' => 'south', 'from' => 300.0, 'width' => 1200.0, 'sill' => 900.0, 'height' => 1200.0 }
    copy = RS.relocate(plan, spec.dup, 2995.0, 900.0, 900.0) # pasted by the east wall
    assert_equal 'east', copy['wall']
    assert_equal [1200.0, 1200.0, 900.0], [copy['width'], copy['height'], copy['sill']], 'as big as the first'
    cuts, problem = RS.openings(plan, [spec, copy])
    assert_nil problem
    assert_equal [[0.0, -1.0], [1.0, 0.0]], cuts.map { |c| c[:out] }, 'each is cut square to its own wall: the first through the south, the copy through the east'
  end
  # ---- a door or window that is deleted ---------------------------------------------------------------

  def test_an_opening_whose_group_is_gone_is_found
    entries = [[0, [1.0, 1.0, 0.0], [1.0, 1.0, 0.0]], [2, [9.0, 9.0, 900.0], [9.0, 9.0, 900.0]]]
    assert_equal [1], RS.missing_openings(3, entries), 'three were drawn, the second is gone'
    assert_empty RS.missing_openings(2, [[0, [0, 0, 0], [0, 0, 0]], [1, [0, 0, 0], [0, 0, 0]]])
    assert_equal [0, 1], RS.missing_openings(2, []), 'all gone: the walls are closed'
  end

  def test_a_copy_does_not_hide_that_the_original_is_gone
    home = [100.0, 200.0, 0.0]
    entries = [[1, [500.0, 300.0, 0.0], home]]
    assert_equal [0], RS.missing_openings(2, entries)
  end

  def test_without_the_closed_opening_the_wall_has_no_cut
    plan = RS.plan(straight)
    spec = { 'kind' => 'Door', 'wall' => 'north', 'from' => 1000.0, 'width' => 900.0, 'sill' => 0.0, 'height' => 2100.0 }
    assert_equal 1, RS.openings(plan, [spec]).first.length
    assert_empty RS.openings(plan, []).first, 'no door: nothing is cut'
  end
  # ---- boxes put together as one solid -------------------------------------------------------

  def box(x0, x1, y0, y1, z0, z1) = { from: [x0, y0, z0], to: [x1, y1, z1] }

  def area(square)
    xs, ys, zs = square.transpose.map { |v| v.max - v.min }
    [xs, ys, zs].reject(&:zero?).inject(:*)
  end

  def edge_uses(squares)
    uses = Hash.new(0)
    squares.each { |s| s.each_with_index { |p, i| uses[[p, s[(i + 1) % 4]].sort] += 1 } }
    uses
  end

  def test_two_boxes_that_touch_have_no_face_where_they_touch
    squares = RS.shell_squares([box(0, 10, 0, 10, 0, 10), box(10, 20, 0, 10, 0, 10)])
    assert_in_delta 2 * 6 * 100.0 - 2 * 100.0, squares.sum { |s| area(s) }, 1e-6, 'the two outsides less the faces that meet'
    assert(squares.none? { |s| s.all? { |p| p[0] == 10 } }, 'nothing left at x = 10')
  end

  def test_a_box_inside_another_adds_nothing
    squares = RS.shell_squares([box(0, 10, 0, 10, 0, 10), box(2, 4, 2, 4, 2, 4)])
    assert_in_delta 600.0, squares.sum { |s| area(s) }, 1e-6
  end

  def test_the_frame_of_a_door_and_of_a_window_and_the_leaf_are_closed_solids
    [RS.door_parts(door_cut)['Frame'], RS.door_parts(door_cut)['Leaf'], RS.window_parts(window_cut)['Frame'], RS.window_sashes(window_cut).first[:sash]].each do |boxes|
      uses = edge_uses(RS.shell_squares(boxes))
      assert_equal [2], uses.values.uniq, ('every edge belongs to two faces ' + uses.select { |_, n| n == 4 }.keys.first(3).inspect)
    end
  end
end
