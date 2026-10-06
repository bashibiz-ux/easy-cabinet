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
    assert_equal [[3.0, 397.0, 347.0, 353.0, 0.0, 3.0]], PG.clip_cuts(groove, 400.0, 700.0, 3.0)
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

  def pocket(s = 3.0) = PG.rounded_pocket_faces(70.0, 330.0, 70.0, 630.0, 6.0, 18.0, s)

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
    refute PG.round_lip?(groove.first), 'a groove stays plain'
  end
end