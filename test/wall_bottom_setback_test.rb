# frozen_string_literal: true

# The front setback of the bottom panels: one for the wall units, one of its own for the lofts.
# Run:  ruby test/wall_bottom_setback_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults validation_manager attribute_manager worktop_manager].each { |f| require File.join(plugin, f) rescue nil }
require File.join(plugin, 'wall_bottom_manager') rescue nil

class WallBottomSetbackTest < Minitest::Test
  include KitchenCabinetMaster

  def params(raw) = WallBottomManager.send(:read_params, raw).first

  def test_the_loft_has_a_setback_of_its_own
    given = params('wall_bottom_setback' => '20', 'wall_bottom_loft_setback' => '45')
    assert_equal 20.0, given['setback']
    assert_equal 45.0, given['loft_setback']
  end

  def test_an_empty_loft_setback_is_flush_with_the_front
    assert_equal 0.0, params({})['loft_setback']
    assert_equal 20.0, params({})['setback']
  end

  def test_a_panel_remembers_both
    stored = WallBottomManager.send(:params_of, 'wall_bottom_setback' => 10.0, 'wall_bottom_loft_setback' => 33.0)
    assert_equal [10.0, 33.0], [stored['setback'], stored['loft_setback']]
  end

  def test_the_loft_setback_must_be_between_0_and_500
    answer = WallBottomManager.send(:read_params, 'wall_bottom_loft_setback' => '600')
    assert_equal 'wall_bottom_loft_setback', answer.last['field']
  end
  def item(x, depth, width: 600.0, loft: false) = { x: x, y: 0.0, hx: 1.0, hy: 0.0, width: width, depth: depth, loft: loft }

  def test_a_run_of_units_of_one_depth_is_one_stretch
    run = { items: [item(0.0, 320.0), item(600.0, 320.0)], length: 1200.0 }
    assert_equal [[0.0, 1200.0]], WallBottomManager.send(:segments_of, run).map { |from, to, _| [from, to] }
  end

  def test_a_gap_between_two_units_where_a_side_panel_stands_is_left_open
    run = { items: [item(0.0, 320.0), item(618.0, 320.0)], length: 1218.0 }
    assert_equal [[0.0, 600.0], [618.0, 1218.0]], WallBottomManager.send(:segments_of, run).map { |from, to, _| [from, to] }
  end

  def test_a_change_of_depth_along_the_run_starts_a_new_stretch_with_its_own_depth
    run = { items: [item(0.0, 320.0), item(600.0, 320.0), item(1200.0, 580.0)], length: 1800.0 }
    stretches = WallBottomManager.send(:segments_of, run)
    assert_equal [[0.0, 1200.0, 320.0], [1200.0, 1800.0, 580.0]], stretches.map { |from, to, unit| [from, to, unit[:depth]] }
  end
end
