# frozen_string_literal: true

# The carcass layout: where the back panel sits. Run:  ruby test/carcass_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager cabinet_manager].each { |f| require File.join(plugin, f) }

class CarcassTest < Minitest::Test
  include KitchenCabinetMaster

  def params(overrides = {})
    Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0,
                          'door_count' => 1, 'toe_kick_height' => 100.0, 'material_thickness' => 18.0,
                          'back_thickness' => 6.0).merge(overrides)
  end

  def back_of(overrides = {})
    CabinetLayout.compute(params(overrides)).panels.find { |p| p.role == 'back' }
  end

  def test_a_thin_back_is_set_in_from_the_rear_edge
    back = back_of('back_thickness' => 6.0)
    assert_equal 10.0, back.offset[0]
    assert_equal 6.0, back.extent[0]
  end

  def test_an_18_mm_back_is_flush_with_the_rear_edge_of_the_sides
    back = back_of('back_thickness' => 18.0)
    assert_equal 0.0, back.offset[0], 'its rear face is level with the sides'
    assert_equal 18.0, back.extent[0]
  end

  def test_every_other_size_keeps_the_recess
    [6.0, 9.0, 12.0, 17.9].each { |t| assert_equal 10.0, back_of('back_thickness' => t).offset[0], "#{t} mm" }
  end

  def test_the_corner_unit_follows_the_same_rule
    assert_equal 0.0, back_of('cabinet_category' => 'corner', 'back_thickness' => 18.0).offset[0]
    assert_equal 10.0, back_of('cabinet_category' => 'corner', 'back_thickness' => 9.0).offset[0]
  end

  def test_the_inside_starts_where_the_back_ends
    thick = CabinetLayout.compute(params('back_thickness' => 18.0)).panels.find { |p| p.role == 'bottom' }
    assert_equal 18.0, thick.offset[0], 'the bottom starts at the front face of a flush 18 mm back'
    thin = CabinetLayout.compute(params('back_thickness' => 6.0)).panels.find { |p| p.role == 'bottom' }
    assert_equal 16.0, thin.offset[0]
  end

  def test_the_recess_rule
    assert_equal 0.0, Defaults.back_recess(18)
    assert_equal 0.0, Defaults.back_recess(20)
    assert_equal 10.0, Defaults.back_recess(12)
  end

  # ---- the groove for a set-in back ---------------------------------------

  def test_a_6_mm_back_reaches_9_mm_into_a_groove_in_each_side
    back = back_of('back_thickness' => 6.0) # 18 mm sides, 600 wide
    assert_equal 564.0 + 18.0, back.extent[1], 'the 564 mm gap between the sides plus 9 mm into each'
    assert_equal 9.0, back.offset[1], 'it starts 9 mm inside the left side (18 mm thick)'
    assert_equal 600.0 - 9.0, back.offset[1] + back.extent[1], 'and ends 9 mm inside the right side'
  end

  def test_a_flush_18_mm_back_just_fits_between_the_sides
    back = back_of('back_thickness' => 18.0)
    assert_equal 564.0, back.extent[1]
    assert_equal 18.0, back.offset[1]
  end

  def test_the_groove_never_goes_deeper_than_half_a_thin_side
    back = back_of('material_thickness' => 12.0, 'back_thickness' => 6.0)
    assert_equal 6.0, back.offset[1], 'a 12 mm side is grooved 6 mm at most'
  end

  def test_the_corner_back_has_its_groove_too
    back = back_of('cabinet_category' => 'corner', 'back_thickness' => 6.0)
    assert_equal 9.0, back.offset[1]
  end

  # ---- rotating ------------------------------------------------------------

  class Spun
    def initialize(transformation, attrs) = (@transformation = transformation; @attrs = attrs)
    attr_reader :transformation
    def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  end

  def test_a_quarter_turn_swings_the_cabinet_about_the_middle_of_its_footprint
    cabinet = Spun.new(Geom::Transformation.new, 'envelope_depth' => 580.0, 'envelope_width' => 600.0)
    turn = CabinetManager.send(:rotation_of, cabinet, 90)
    middle = Geom::Point3d.new(290.0, 300.0, 0)
    moved = turn * middle
    assert_in_delta 290.0, moved.x, 1e-6, 'the middle stays where it is'
    assert_in_delta 300.0, moved.y, 1e-6
    corner = turn * Geom::Point3d.new(0, 0, 0)
    assert_in_delta 590.0, corner.x, 1e-6, 'the rear-left corner swings to the front-left, anticlockwise'
    assert_in_delta 10.0, corner.y, 1e-6
  end

  def test_turning_back_undoes_it
    cabinet = Spun.new(Geom::Transformation.new, 'envelope_depth' => 580.0, 'envelope_width' => 600.0)
    there = CabinetManager.send(:rotation_of, cabinet, 37)
    back = CabinetManager.send(:rotation_of, cabinet, -37)
    point = (there * back) * Geom::Point3d.new(100, 200, 0)
    assert_in_delta 100.0, point.x, 1e-6
    assert_in_delta 200.0, point.y, 1e-6
  end
end
