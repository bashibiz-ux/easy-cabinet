# frozen_string_literal: true

# The scenes for a drawing in LayOut (LayoutScenes.scenes: what is looked at, from where, and what is hidden). Run:  ruby test/layout_scenes_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  module RoomShell; end
  module Response; end
  module AttributeManager; end
end
require File.expand_path('../easy_cabinet/layout_scenes', __dir__)

class LayoutScenesTest < Minitest::Test
  LS = EasyCabinet::LayoutScenes
  BOX = { x0: 0.0, y0: 0.0, x1: 4000.0, y1: 3000.0 }.freeze

  def named(list, name) = list.find { |scene| scene[:name] == name }

  def test_there_is_a_plan_and_an_elevation_of_each_wall_asked_for
    list = LS.scenes(BOX, 2500.0, %w[south west])
    assert_equal ['Plan', 'Elevation South', 'Elevation West'], list.map { |s| s[:name] }
    assert_equal 4, LS.scenes(BOX, 2500.0).count { |s| s[:name].start_with?('Elevation') }, 'without a choice: all four walls'
  end

  def test_the_plan_looks_down_on_the_middle_of_the_room_with_the_roof_hidden
    plan = named(LS.scenes(BOX, 2500.0), 'Plan')
    assert_equal [2000.0, 1500.0, 0.0], plan[:target]
    assert_equal [2000.0, 1500.0], plan[:eye][0, 2]
    assert_operator plan[:eye][2], :>, 2500.0
    assert_equal [0.0, 1.0, 0.0], plan[:up]
    assert_equal ['Roof'], plan[:hide]
    assert_operator plan[:height], :>=, 3000.0, 'the whole depth of the room is in the view'
  end

  def test_an_elevation_looks_straight_at_its_wall_from_outside_the_room_on_the_other_side
    south = named(LS.scenes(BOX, 2500.0), 'Elevation South')
    assert_equal [2000.0, 0.0, 1250.0], south[:target], 'the middle of the wall, half way up'
    assert_in_delta 2000.0, south[:eye][0], 0.01
    assert_operator south[:eye][1], :>, 3000.0, 'beyond the north wall (which is hidden): it looks towards -Y at the south wall'
    assert_equal [0.0, 0.0, 1.0], south[:up]
    assert_equal %w[Roof Walls], south[:hide]
    east = named(LS.scenes(BOX, 2500.0), 'Elevation East')
    assert_equal [4000.0, 1500.0, 1250.0], east[:target]
    assert_operator east[:eye][0], :<, 0.0, 'west of the room, looking towards +X'
  end

  def test_the_view_holds_the_whole_wall
    scene = named(LS.scenes(BOX, 2500.0), 'Elevation North')
    assert_operator scene[:height], :>=, 2500.0 + 600.0, 'its height and a margin'
    assert_operator scene[:height] * LS::ASPECT, :>=, 4000.0, 'its length too'
  end

  def test_the_walls_the_cabinets_stand_against
    assert_equal %w[south west], LS.walls_with_backs(min_y: true, max_y: false, min_x: true, max_x: false)
    assert_empty LS.walls_with_backs(nil)
    assert_empty LS.walls_with_backs(min_y: false, max_y: false, min_x: false, max_x: false)
  end
end
