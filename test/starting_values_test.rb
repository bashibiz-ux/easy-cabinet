# frozen_string_literal: true

# What a new item starts as, and that an open shelf unit lines up with the doors
# beside it.  Run:  ruby test/starting_values_test.rb

require 'json'
require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults cabinet_layout catalog_manager].each { |f| require File.join(plugin, f) }

class StartingValuesTest < Minitest::Test
  include KitchenCabinetMaster

  def test_a_toe_kick_and_the_cabinets_standing_on_it_start_at_100_mm
    assert_equal 100.0, Defaults.toe_kick_params['toe_kick_height']
    assert_equal 100.0, Defaults.params['toe_kick_height']
    %w[base tall].each do |category|
      layout = CabinetLayout.compute(Defaults.params.merge('cabinet_category' => category, 'width' => 600.0, 'depth' => 560.0,
                                                            'height' => category == 'tall' ? 2100.0 : 780.0, 'door_count' => 1))
      assert_equal 100.0, layout.base_z, "#{category} unit stands 100 mm up"
    end
  end

  def test_a_new_end_panel_goes_on_the_right
    assert_equal 'right', Defaults.end_panel_params['side']
  end

  def test_a_new_filler_is_50_mm_wide
    assert_equal 50.0, Defaults.filler_params['width']
  end

  def test_the_standard_cabinets_are_560_deep_and_780_high
    base = CatalogManager.cabinets('door_with_pull_handle', 'base')
    refute_empty base
    base.each do |cabinet|
      assert_equal 560, cabinet['defaults']['depth'], cabinet['id']
      assert_equal 780, cabinet['defaults']['height'], cabinet['id']
    end
  end

  # ---- an open shelf unit lines up with the doors beside it -----------------------

  def layout_for(doors, overrides = {})
    params = Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0,
                                   'door_count' => doors, 'toe_kick_height' => 100.0, 'shelf_count' => 2).merge(overrides)
    [CabinetLayout.compute(params), params]
  end

  def front(panel) = panel.offset[0] + panel.extent[0]

  def test_every_front_panel_of_an_open_unit_is_flush_with_the_door_of_its_neighbour
    door_front = layout_for(1).first.doors.first.then { |d| d.offset[0] + d.extent[0] }
    open, = layout_for(0)
    fronts = open.panels.reject { |p| p.role == 'back' || p.role.include?('rear') }
    refute_empty fronts
    fronts.each { |panel| assert_in_delta door_front, front(panel), 1e-9, "#{panel.role} reaches the door face" }
  end

  def test_the_open_unit_follows_a_changed_door_distance_and_thickness
    [[2.0, 18.0], [6.0, 18.0], [3.0, 25.0]].each do |distance, thick|
      extra = { 'door_distance' => distance, 'material_thickness' => thick }
      door = layout_for(1, extra).first.doors.first
      open, = layout_for(0, extra)
      assert_in_delta door.offset[0] + door.extent[0], front(open.panels.find { |p| p.role == 'left_side' }), 1e-9
    end
  end

  def test_an_open_units_footprint_is_the_same_as_a_door_units
    _l, closed = layout_for(1)
    _l, open = layout_for(0)
    assert_equal CabinetLayout.envelope(closed), CabinetLayout.envelope(open)
  end
end