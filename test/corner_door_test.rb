# frozen_string_literal: true

# Runs the plugin's REAL CabinetLayout and DoorAnimation code outside SketchUp,
# using a tiny stand-in for the few Geom classes they touch (Z-axis rotations and
# translations only). Run:  ruby test/corner_door_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  module AttributeManager; DICTIONARY = 'kcm'; end
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults toe_kick cabinet_layout door_animation validation_manager].each { |f| require File.join(plugin, f) }

class CornerDoorTest < Minitest::Test
  include EasyCabinet

  WIDTH = 900.0
  RETURN_DEPTH = 600.0
  THICK = 18.0

  def params(direction)
    p = Defaults.params
    p.merge!('cabinet_category' => 'corner', 'width' => WIDTH, 'depth' => RETURN_DEPTH,
             'height' => 720.0, 'door_count' => 1, 'door_opening_direction' => direction,
             'shelf_count' => 0)
    p
  end

  def door(direction) = CabinetLayout.compute(params(direction)).doors.first

  # World XY of a point given in the door's own local frame, at opening fraction f.
  def world(door, local, fraction)
    t = DoorAnimation.transformation(door, 90.0, fraction)
    t.apply(*local)
  end

  def near(expected, actual, msg, delta = 0.5)
    assert_in_delta expected[0], actual[0], delta, "#{msg} (x)"
    assert_in_delta expected[1], actual[1], delta, "#{msg} (y)"
  end

  def test_closed_door_spans_the_opening_between_the_two_panels
    inner = WIDTH - THICK
    a = [RETURN_DEPTH, inner]
    b = [inner, RETURN_DEPTH]

    %w[left right].each do |direction|
      d = door(direction)
      _thick, length, = d.extent
      near(b, world(d, [0, 0], 0), "#{direction}: low end sits at B", 3.0)
      near(a, world(d, [0, length], 0), "#{direction}: high end sits at A", 3.0)
    end
  end

  def test_door_stays_inside_the_square_footprint_when_closed
    %w[left right].each do |direction|
      d = door(direction)
      _t, length, = d.extent
      [[0, 0], [0, length], [d.extent[0], 0], [d.extent[0], length]].each do |pt|
        x, y = world(d, pt, 0)
        assert_operator x, :<=, WIDTH + 5, "#{direction}: x #{x} beyond the cabinet"
        assert_operator y, :<=, WIDTH + 5, "#{direction}: y #{y} beyond the cabinet"
      end
    end
  end

  def test_hinge_end_does_not_move_and_free_end_swings_outward
    d = door('left')
    _t, length, = d.extent
    hinge_before = world(d, [d.extent[0], 0], 0)
    free_before = world(d, [d.extent[0], length], 0)

    [0.25, 0.5, 1.0].each do |f|
      near(hinge_before, world(d, [d.extent[0], 0], f), "left hinge stays put at #{f}", 0.01)
    end
    fx, fy = world(d, [d.extent[0], length], 1.0)
    # Outward = away from the back-left wall corner, so x + y must grow.
    assert_operator fx + fy, :>, free_before.sum + 100, 'left: free edge swings outward'

    r = door('right')
    rhinge = world(r, [r.extent[0], length], 0)
    near(rhinge, world(r, [r.extent[0], length], 1.0), 'right hinge stays put', 0.01)
    rx, ry = world(r, [r.extent[0], 0], 1.0)
    rfree = world(r, [r.extent[0], 0], 0)
    assert_operator rx + ry, :>, rfree.sum + 100, 'right: free edge swings outward'
  end

  def test_free_end_never_swings_through_the_carcass
    inner = WIDTH - THICK
    %w[left right].each do |direction|
      d = door(direction)
      _t, length, = d.extent
      free_local = direction == 'left' ? [d.extent[0], length] : [d.extent[0], 0]
      (0..18).each do |i|
        x, y = world(d, free_local, i / 18.0)
        inside = x < inner && y < inner && (x + y) < (RETURN_DEPTH + inner) - 1
        refute inside, "#{direction}: free edge inside the carcass at step #{i} (#{x.round(1)}, #{y.round(1)})"
      end
    end
  end

  def test_plan_indicator_starts_and_ends_on_the_door
    %w[left right].each do |direction|
      d = door(direction)
      segs = DoorAnimation.indicator_segments([d], 90.0, 100.0)
      # second segment: hinge -> closed free edge. Compare with the real door's free-end midpoint.
      closed_free = segs[1][1]
      _t, length, = d.extent
      free_local = direction == 'left' ? [d.extent[0] / 2.0, length] : [d.extent[0] / 2.0, 0]
      near(world(d, free_local, 0), closed_free, "#{direction}: indicator free point matches door", 2.0)
      open_free = segs[2][1]
      near(world(d, free_local, 1.0), open_free, "#{direction}: indicator open point matches door", 2.0)
    end
  end

  def test_door_symbol_lines_start_at_the_hinge_and_reach_the_free_edge_at_every_opening
    %w[left right].each do |direction|
      d = door(direction)
      thick, length, height = d.extent
      lines = DoorAnimation.door_symbol_segments(d)
      assert_equal 2, lines.length

      apex = lines[0][0]
      assert_equal apex, lines[1][0], 'both lines start at the same point'
      assert_in_delta height / 2.0, apex[2], 1e-6, 'apex halfway up'
      assert_operator apex[0], :>, thick, 'lines sit in front of the door face'

      hinge_local = direction == 'left' ? 0.0 : length
      assert_in_delta hinge_local, apex[1], 1e-6, "#{direction}: apex on the hinge side"
      assert_equal [0.0, height], lines.map { |l| l[1][2] }.sort, 'ends reach the top and bottom'
      lines.each { |l| assert_in_delta length - hinge_local, l[1][1], 1e-6, 'ends on the free edge' }

      # In the door's own frame, so the world position follows the swing: at any
      # opening the hinge-side apex stays over the pivot (within the face standoff).
      pivot = d.pivot
      [0.0, 0.5, 1.0].each do |f|
        x, y = DoorAnimation.transformation(d, 90.0, f).apply(apex[0], apex[1])
        assert_operator Math.hypot(x - pivot[0], y - pivot[1]), :<, 3.0, "#{direction}: apex stays at the hinge (#{f})"
      end
    end
  end

  def test_both_opening_direction_symbols_are_independent_and_start_unticked
    defaults = Defaults.params
    assert_equal false, defaults['show_opening_direction'], 'the symbol on the floor starts off'
    assert_equal false, defaults['show_door_symbol'], 'the dashed lines on the door start off'
    refute defaults.key?('door_symbol'), 'the old symbol-style choice is gone'

    # Both are always built (visibility only flips a flag), so both exist for any door.
    refute_empty DoorAnimation.indicator_segments([door('left')], 90.0, 100.0)
    refute_empty DoorAnimation.door_symbol_segments(door('left'))
  end

  def test_the_two_symbols_are_switched_by_their_own_settings
    checked = ValidationManager.validate(
      { 'catalog_id' => 'x', 'cabinet_category' => 'base', 'cabinet_type' => 'y', 'width' => '600', 'depth' => '560',
        'height' => '780', 'door_opening_direction' => 'left', 'toe_kick_height' => '100',
        'show_opening_direction' => false, 'show_door_symbol' => true }
    )
    assert_equal false, checked.params['show_opening_direction']
    assert_equal true, checked.params['show_door_symbol']

    flipped = ValidationManager.validate(
      { 'catalog_id' => 'x', 'cabinet_category' => 'base', 'cabinet_type' => 'y', 'width' => '600', 'depth' => '560',
        'height' => '780', 'door_opening_direction' => 'left', 'toe_kick_height' => '100',
        'show_opening_direction' => true, 'show_door_symbol' => false }
    )
    assert_equal true, flipped.params['show_opening_direction']
    assert_equal false, flipped.params['show_door_symbol']
  end

  def test_first_cabinet_needs_no_material_choice_and_defaults_to_plain_white
    result = ValidationManager.validate(
      { 'catalog_id' => 'x', 'cabinet_category' => 'base', 'cabinet_type' => 'y', 'width' => '600', 'depth' => '560',
        'height' => '780', 'door_opening_direction' => 'left', 'toe_kick_height' => '100',
        'base_material' => '', 'wall_material' => '', 'tall_material' => '' }
    )
    assert_empty result.errors.map { |e| e['field'] } & %w[base_material wall_material tall_material]
    assert_equal Defaults::DEFAULT_MATERIAL, result.params['base_material']
    assert_equal Defaults::DEFAULT_MATERIAL, result.params['wall_material']
  end

  def test_ordinary_door_is_unchanged
    p = Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0,
                              'height' => 780.0, 'door_count' => 1, 'door_opening_direction' => 'left')
    d = CabinetLayout.compute(p).doors.first
    assert_equal(-1.0 * Math::PI / 2, DoorAnimation.swing_radians('left', d.rotation, 90.0, 1.0))
    assert_equal(Math::PI / 2, DoorAnimation.swing_radians('right', d.rotation, 90.0, 1.0))
  end
def plain(category, adjust)
  Defaults.params.merge('cabinet_category' => category, 'width' => 800.0, 'depth' => 580.0, 'height' => 720.0, 'door_count' => 2, 'shelf_count' => 0,
                        'door_height_adjust' => adjust, 'toe_kick_height' => category == 'wall' ? 0.0 : 100.0)
end

def test_the_door_height_adjustment_moves_the_top_edge_of_a_base_door_and_the_bottom_edge_of_a_wall_door
  base = CabinetLayout.compute(plain('base', 0.0)).doors.first
  taller = CabinetLayout.compute(plain('base', 25.0)).doors.first
  assert_in_delta base.extent[2] + 25.0, taller.extent[2], 0.01
  assert_in_delta base.offset[2], taller.offset[2], 0.01, 'a base door keeps its bottom edge'
  wall = CabinetLayout.compute(plain('wall', 0.0)).doors.first
  shorter = CabinetLayout.compute(plain('wall', -30.0)).doors.first
  assert_in_delta wall.extent[2] - 30.0, shorter.extent[2], 0.01
  assert_in_delta wall.offset[2] + wall.extent[2], shorter.offset[2] + shorter.extent[2], 0.01, 'a wall door keeps its top edge'
  assert_in_delta wall.offset[2] + 30.0, shorter.offset[2], 0.01
end
end
