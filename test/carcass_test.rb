# frozen_string_literal: true

# The carcass layout: where the back panel sits. Run:  ruby test/carcass_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults cabinet_layout validation_manager].each { |f| require File.join(plugin, f) }

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
end