# frozen_string_literal: true

# Runs the plugin's REAL KitchenPlanner: the island parallel to wall A, B or C.
# Run:  ruby test/island_wall_test.rb

require 'minitest/autorun'

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)
end
%w[response defaults catalog_manager island_hood kitchen_planner].each { |file| require_relative "../easy_cabinet/#{file}" }

class IslandWallTest < Minitest::Test
  include EasyCabinet

  ROOM = { 'layout' => 'u', 'wall_a' => 5200.0, 'wall_b' => 5200.0, 'wall_c' => 5200.0, 'island' => true, 'island_length' => 1800.0 }.freeze

  def island(extra)
    KitchenPlanner.plan(ROOM.merge(extra)).island
  end

  def test_the_island_is_on_the_wall_that_was_asked_for
    %w[a b c].each do |wall|
      plan = island('island_wall' => wall)
      refute_nil plan, "island on #{wall}"
      assert_equal wall.to_sym, plan.wall
    end
  end

  def test_wall_b_and_wall_c_have_their_own_frames
    assert_equal [0.0, 0.0, 0.0], island('island_wall' => 'a').frame
    assert_equal [0.0, 5200.0, -90.0], island('island_wall' => 'b').frame
    assert_equal [5200.0, 5200.0, 180.0], island('island_wall' => 'c').frame
  end

  def test_the_island_stays_between_the_walls_that_meet_its_wall
    plan = island('island_wall' => 'b', 'island_length' => 9000.0)
    reach = KitchenPlanner::FRONT_DEPTH + plan.aisle
    assert_operator plan.length, :<=, 5200.0 - (2 * reach) + 0.1 # wall A and wall C meet wall B at its ends
    assert_operator plan.y, :>=, plan.length
    assert_operator plan.y, :<=, 5200.0 - reach + 0.1
  end

  def test_an_l_island_on_wall_b_keeps_clear_of_wall_a_only
    plan = KitchenPlanner.plan('layout' => 'l', 'wall_a' => 4200.0, 'wall_b' => 4200.0, 'island' => true, 'island_wall' => 'b', 'island_length' => 1800.0).island
    refute_nil plan
    reach = KitchenPlanner::FRONT_DEPTH + plan.aisle
    assert_operator plan.y - plan.length, :>=, reach - 0.1
  end

  def test_a_wall_the_layout_does_not_have_falls_back_to_wall_a_with_a_note
    plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4800.0, 'island' => true, 'island_wall' => 'c')
    assert_equal :a, plan.island.wall
    assert plan.notes.any? { |note| note.include?('no wall C') }
  end
end
