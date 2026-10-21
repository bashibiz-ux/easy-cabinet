# frozen_string_literal: true

# The opening angle of a door: an L corner's doors open wide, a lift-up door stops at its limit. Run:  ruby test/door_angle_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager cabinet_layout door_animation].each { |f| require File.join(plugin, f) }

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