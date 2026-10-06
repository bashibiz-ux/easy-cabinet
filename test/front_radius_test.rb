# frozen_string_literal: true

# The rounded front edges of doors and drawer fronts. Run:  ruby test/front_radius_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
end
module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
  module MaterialManager; end
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager front_design validation_manager panel_generator].each { |f| require File.join(plugin, f) }

class FrontRadiusTest < Minitest::Test
  include KitchenCabinetMaster

  PG = PanelGenerator

  def key(point) = point.map { |v| v.round(4) }

  def faces(r = 3.0) = PG.rounded_front_faces(18.0, 400.0, 700.0, r)

  def test_the_faces_close_up_into_a_solid
    edges = Hash.new(0)
    faces.each do |corners|
      corners.each_with_index { |p, i| edges[[key(p), key(corners[(i + 1) % corners.length])]] += 1 }
    end
    edges.each_key { |a, b| assert_equal 1, edges[[b, a]], "the edge #{a} - #{b} is shared with a face the other way round" }
    assert(edges.values.all? { |n| n == 1 })
  end

  def test_every_face_faces_outwards_and_none_collapses
    centre = [9.0, 200.0, 350.0]
    faces.each do |corners|
      normal = PG.send(:newell_normal, corners)
      mid = corners.transpose.map { |v| v.sum / corners.length }
      assert_operator (0..2).sum { |i| normal[i] * (mid[i] - centre[i]) }, :>, 0.0
      corners.each_with_index do |p, i|
        q = corners[(i + 1) % corners.length]
        refute_operator Math.sqrt(p.zip(q).sum { |a, b| (a - b)**2 }), :<, 0.01, 'two corners of a face are the same point'
      end
    end
  end

  def test_the_outer_face_is_the_flat_middle_and_the_rim_is_round
    front = faces.max_by { |c| c.sum { |p| p[0] } / c.length }
    assert_equal [18.0], front.map { |p| p[0] }.uniq
    assert_equal [3.0, 397.0], front.map { |p| p[1] }.uniq.sort
    assert_equal [3.0, 697.0], front.map { |p| p[2] }.uniq.sort
    assert_in_delta 18.0 - 3.0, faces.flatten(1).map { |p| p[0] }.select(&:positive?).min, 0.01, 'the rounding starts 3 mm behind the face'
  end

  def test_the_radius_a_front_can_have
    assert_equal 3.0, PG.front_radius(18, 400, 700, 3)
    assert_equal 0.0, PG.front_radius(18, 400, 700, 0)
    assert_equal 17.0, PG.front_radius(18, 400, 700, 40)
    assert_equal 9.0, PG.front_radius(18, 20, 700, 40), 'never more than half the width less 1 mm'
    assert_equal 0.0, PG.front_radius(18, 2, 700, 3)
  end

  def test_cuts_stay_inside_the_flat_face
    groove = [[0.0, 400.0, 347.0, 353.0, 0.0, 3.0]]
    assert_equal [[6.0, 394.0, 347.0, 353.0, 0.0, 3.0]], PG.clip_cuts(groove, 400.0, 700.0, 3.0)
    assert_equal groove, PG.clip_cuts(groove, 400.0, 700.0, 0.0)
    assert_empty PG.clip_cuts([[0.0, 2.0, 10.0, 50.0, 0.0, 3.0]], 400.0, 700.0, 3.0)
  end

  def test_the_setting_is_a_number_with_a_start_value_that_is_checked
    assert_equal 3.0, Defaults.params['front_radius']
    ok = ValidationManager.validate({ 'front_radius' => '4' })
    assert_equal 4.0, ok.params['front_radius']
    bad = ValidationManager.validate({ 'front_radius' => '30' })
    assert_includes bad.errors.map { |e| e['field'] }, 'front_radius'
  end

  def pocket(s = 3.0) = PG.rounded_pocket_faces(70.0, 330.0, 70.0, 630.0, 0.0, 6.0, 18.0, s)

  def test_a_pocket_has_a_rounded_lip_that_joins_the_face_and_closes_up
    edges = Hash.new(0)
    pocket.each { |corners| corners.each_with_index { |p, i| edges[[key(p), key(corners[(i + 1) % corners.length])]] += 1 } }
    open = edges.keys.reject { |a, b| edges.key?([b, a]) }
    assert_equal 4, open.map(&:first).uniq.length, 'only the four corners of the mouth are open: it is where the pocket joins the face'
    assert(open.all? { |a, b| a[0] == 18.0 && b[0] == 18.0 }, 'at the level of the face')
    ys = open.flatten(1).map { |p| p[1] }.uniq.sort
    assert_equal [67.0, 333.0], ys, 'the mouth is the radius wider than the wall'
  end

  def test_the_pocket_faces_face_into_the_pocket
    pocket.each do |corners|
      n = PG.send(:newell_normal, corners)
      mid = corners.transpose.map { |v| v.sum / corners.length }
      toward = [200.0 - mid[1], 350.0 - mid[2]]
      length = Math.hypot(*toward)
      assert_operator n[0] + (length < 1e-9 ? 0.0 : ((n[1] * toward[0]) + (n[2] * toward[1])) / length), :>, 0.0
      corners.each_with_index do |p, i|
        q = corners[(i + 1) % corners.length]
        refute_operator Math.sqrt(p.zip(q).sum { |a, b| (a - b)**2 }), :<, 0.01
      end
    end
    floor = pocket.min_by { |c| c.sum { |p| p[0] } }
    assert_equal [12.0], floor.map { |p| p[0] }.uniq, 'the floor is 6 mm deep'
  end

  def test_a_pocket_with_a_rounded_lip_keeps_away_from_the_edge_of_the_front
    big = [[0.0, 400.0, 100.0, 600.0, 0.0, 6.0]]
    assert_equal [[6.0, 394.0, 100.0, 600.0, 0.0, 6.0]], PG.clip_cuts(big, 400.0, 700.0, 3.0)
    groove = [[0.0, 400.0, 347.0, 353.0, 0.0, 3.0]]
    assert PG.round_lip?(big.first)
    assert PG.round_lip?(groove.first), 'a groove is rounded too'
    assert_in_delta 2.7, PG.lip_radius([0.0, 6.0, 0.0, 700.0, 0.0, 3.2], 3.0), 0.001, 'under half its width'
    assert_in_delta 1.5, PG.lip_radius([0.0, 300.0, 0.0, 300.0, 0.0, 2.0], 3.0), 0.001, 'and not deeper than the groove'
    near = [[0.0, 3.0, 0.0, 100.0, 0.0, 2.0], [3.0, 6.0, 0.0, 100.0, 0.0, 2.0]]
    assert PG.crowded?(near, 0, 1.0), 'two grooves that touch stay square'
    apart = [[0.0, 3.0, 0.0, 100.0, 0.0, 2.0], [16.0, 19.0, 0.0, 100.0, 0.0, 2.0]]
    refute PG.crowded?(apart, 0, 1.2)
    refute PG.crowded?(apart.map(&:dup), 0, 1.2), 'a cut is not crowded by itself'
    nested = [[0.0, 300.0, 0.0, 300.0, 0.0, 4.0], [20.0, 280.0, 20.0, 280.0, 4.0, 8.0]]
    refute PG.crowded?(nested, 1, 3.0), 'a step inside a recess is on another level'
  end

  def test_the_inner_corner_of_a_pocket_is_round_too
    floor_edge = pocket.flatten(1).select { |p| p[0] > 12.0 && p[0] < 15.0 && p[1] > 70.0 && p[1] < 73.0 }
    refute_empty floor_edge, 'points curve from the wall down to the floor'
    shallow = PG.rounded_pocket_faces(70.0, 330.0, 70.0, 630.0, 3.6, 3.6 + 6.0, 18.0, 3.0)
    assert_equal 18.0 - 3.6, shallow.flatten(1).map { |p| p[0] }.max, 'a step inside a recess starts at its floor'
  end

  def test_an_end_panel_has_the_outer_face_on_its_own_side
    left = PG.end_panel_frame('left', 18.0)
    right = PG.end_panel_frame('right', 18.0)
    assert_equal [10.0, 0.0, 5.0], left.map.call(18.0, 10.0, 5.0), 'the outer face of a left panel is at low Y'
    assert_equal [10.0, 18.0, 5.0], right.map.call(18.0, 10.0, 5.0), 'and of a right panel at high Y'
    assert right.flip && !left.flip
  end

  def test_a_narrow_groove_is_rounded_and_closes_up
    groove = PG.rounded_pocket_faces(100.0, 106.0, 25.0, 675.0, 0.0, 3.0, 18.0, 2.5, 6)
    edges = Hash.new(0)
    groove.each { |corners| corners.each_with_index { |p, i| edges[[key(p), key(corners[(i + 1) % corners.length])]] += 1 } }
    open = edges.keys.reject { |a, b| edges.key?([b, a]) }
    assert_equal [97.5, 108.5], open.flatten(1).map { |p| p[1] }.uniq.sort, 'the mouth is the radius wider than the groove'
    groove.each do |corners|
      corners.each_with_index do |p, i|
        q = corners[(i + 1) % corners.length]
        refute_operator Math.sqrt(p.zip(q).sum { |a, b| (a - b)**2 }), :<, 0.01
      end
    end
  end

  def test_every_design_but_the_line_frame_is_rounded_cut_by_cut
    (FrontDesign.ids - %w[flat line_frame]).each do |design|
      cuts = PG.clip_cuts(FrontDesign.cuts(design, 596.0, 716.0, 18.0), 596.0, 716.0, 3.0)
      next if cuts.empty?

      cuts.each_index do |i|
        s = PG.lip_radius(cuts[i], 3.0)
        assert_operator s, :>=, 0.3, "#{design}: cut #{i} has a lip to round"
        refute PG.crowded?(cuts, i, s), "#{design}: cut #{i} is not in the way of another"
      end
    end
  end

  def test_the_line_frame_is_one_loop
    assert_equal [[45.0, 551.0, 45.0, 671.0, 3.0, 0.0, 2.0]], FrontDesign.loops('line_frame', 596.0, 716.0, 18.0)
    assert_empty FrontDesign.loops('line_frame', 100.0, 716.0, 18.0)
    assert_empty FrontDesign.loops('shaker', 596.0, 716.0, 18.0)
  end

  def test_the_groove_round_the_line_frame_closes_up_and_faces_into_the_groove
    faces = PG.rounded_loop_faces(45.0, 551.0, 45.0, 671.0, 3.0, 0.0, 2.0, 18.0, 1.2)
    edges = Hash.new(0)
    faces.each { |corners| corners.each_with_index { |p, i| edges[[key(p), key(corners[(i + 1) % corners.length])]] += 1 } }
    open = edges.keys.reject { |a, b| edges.key?([b, a]) }
    ys = open.flatten(1).map { |p| p[1] }.uniq.sort
    assert_in_delta 43.8, ys.first, 0.001, 'the mouth is the radius outside the groove'
    assert_in_delta 552.2, ys.last, 0.001
    assert(open.all? { |a, b| a[0] == 18.0 && b[0] == 18.0 }, 'both mouths are at the level of the face')
    assert_equal 8, open.map(&:first).uniq.length, 'two loops of four corners are open: the outside of the groove and the island'
    faces.each do |corners|
      n = PG.send(:newell_normal, corners)
      assert_operator n[0], :>=, -1e-9, 'no face looks into the board'
      corners.each_with_index do |p, i|
        q = corners[(i + 1) % corners.length]
        refute_operator Math.sqrt(p.zip(q).sum { |a, b| (a - b)**2 }), :<, 0.01
      end
    end
  end
end