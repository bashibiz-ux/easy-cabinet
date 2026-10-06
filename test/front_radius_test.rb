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
end
