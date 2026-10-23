# frozen_string_literal: true

# The opening angle of a door: an L corner's doors open wide, a lift-up door stops at its limit. Run:  ruby test/door_angle_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager gola_profile cabinet_layout front_design appliance_parts fixtures door_animation].each { |f| require File.join(plugin, f) }

class DoorAngleTest < Minitest::Test
  include EasyCabinet

  def door(hinge, swing = nil)
    CabinetLayout::Door.new(role: 'door_1', name: 'Door 1', extent: [18.0, 400.0, 700.0], offset: [0.0, 0.0, 0.0],
                            hinge: hinge, pivot: [0.0, 0.0, 700.0], rotation: 0.0, swing: swing)
  end

  def test_an_ordinary_door_opens_by_the_panels_angle
    assert_equal 90.0, DoorAnimation.angle_for(door('left'), 90.0)
    assert_equal 45.0, DoorAnimation.angle_for(door('right'), 45.0)
  end

  def test_an_l_door_opens_at_least_as_wide_as_its_swing
    assert_equal 120.0, DoorAnimation.angle_for(door('left', 120.0), 90.0)
    assert_equal 150.0, DoorAnimation.angle_for(door('left', 120.0), 150.0), 'a wider panel setting still wins'
  end

  def test_a_lift_up_door_stops_at_its_limit
    assert_equal 90.0, DoorAnimation.angle_for(door('top'), 90.0)
    assert_equal DoorAnimation::LIFT_MAX_ANGLE, DoorAnimation.angle_for(door('top'), 170.0)
  end

  def test_the_floor_symbol_leaf_opens_at_the_angle_asked_and_the_arc_stops_on_it
    [45.0, 120.0].each do |angle|
      lines = DoorAnimation.indicator_segments([door('left', 150.0)], angle, 0.0) # (a door that itself opens at least 150: the symbol ignores that)
      hinge = lines.first.first
      leaves = lines.select { |from, _| from == hinge }.reject { |_, to| to[2] != hinge[2] }
      closed, opened = leaves[0][1], leaves[1][1]
      turned = Math.atan2(opened[1] - hinge[1], opened[0] - hinge[0]) - Math.atan2(closed[1] - hinge[1], closed[0] - hinge[0])
      assert_in_delta angle, turned.abs * 180.0 / Math::PI, 0.5, "the leaf is open #{angle} degrees"
      arc = lines.reject { |from, to| from == hinge || to == hinge || from[2] != to[2] }
      ends = (arc.map(&:first) + arc.map(&:last)).uniq
      radius = ->(p) { Math.hypot(p[0] - hinge[0], p[1] - hinge[1]) }
      assert ends.all? { |p| (radius.call(p) - radius.call(closed)).abs < 0.5 }, 'the arc stays on the circle of the leaf'
      assert_includes ends, opened, 'the arc ends on the open leaf'
      assert_includes ends, closed, 'and starts on the closed one'
    end
  end

  def test_the_floor_symbol_starts_at_30_degrees
    assert_equal 30.0, Defaults.params['symbol_angle']
  end

  def test_a_lift_up_door_has_no_plan_line_but_a_symbol_on_its_face
    assert_empty DoorAnimation.indicator_segments([door('top')], 90.0, 100.0)
    refute_empty DoorAnimation.indicator_segments([door('left')], 90.0, 100.0)
    lines = DoorAnimation.door_symbol_segments(door('top'))
    assert_equal 2, lines.length
    assert_equal [200.0, 200.0], lines.map { |from, _| from[1] }, 'both start at the middle of the top edge'
    assert_equal [700.0, 700.0], lines.map { |from, _| from[2] }
    assert_equal [0.0, 0.0], lines.map { |_, to| to[2] }, 'and end at the bottom corners'
  end

  # A stand-in for a door container and what is inside it.
  FakeEntity = Struct.new(:role) do
    def definition = self
    def get_attribute(_dictionary, _key) = role
  end
  FakeDoor = Struct.new(:children) do
    def definition = Struct.new(:entities).new(children)
  end

  def move(children, kind = :door)
    DoorAnimation::Move.new(door: FakeDoor.new(children), spec: door('left'), angle: 90.0, from: 0.0, to: 1.0, kind: kind)
  end

  def test_a_glass_door_takes_longer_to_open_than_any_other_and_both_are_slower_than_before
    plain = DoorAnimation.frames_for(move([FakeEntity.new('panel')]))
    glass = DoorAnimation.frames_for(move([FakeEntity.new('panel'), FakeEntity.new('door_glass')]))
    assert_equal DoorAnimation::FRAMES, plain
    assert_equal DoorAnimation::GLASS_FRAMES, glass
    assert_operator glass, :>, plain
    assert_operator plain, :>, 30, 'slower than the 30 frames of before'
    assert_equal DoorAnimation::FRAMES, DoorAnimation.frames_for(move([FakeEntity.new('door_glass')], :drawer)), 'a drawer is not a glass door'
  end
end