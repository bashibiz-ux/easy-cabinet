# frozen_string_literal: true

# The plain panel (Category = Panel): validation, layout and name. Run:  ruby test/panel_part_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager front_design toe_kick part_layout naming_manager].each do |file|
  path = File.join(plugin, "#{file}.rb")
  require path if File.exist?(path)
end

class PanelPartTest < Minitest::Test
  include KitchenCabinetMaster

  def raw(extra = {})
    { 'orientation' => 'vertical', 'width' => '1000', 'length' => '1000', 'thickness' => '18', 'material' => '__door__' }.merge(extra)
  end

  def test_a_valid_panel_is_a_panel_part
    result = ValidationManager.validate_panel(raw)
    assert_empty result.errors
    assert_equal 'panel', result.params['part_kind']
    assert_equal 1000.0, result.params['width']
  end

  def test_the_orientation_and_the_sizes_are_checked
    assert_equal ['orientation'], ValidationManager.validate_panel(raw('orientation' => 'sideways')).errors.map { |e| e['field'] }
    assert_includes ValidationManager.validate_panel(raw('width' => '5')).errors.map { |e| e['field'] }, 'width'
    assert_includes ValidationManager.validate_panel(raw('thickness' => '')).errors.map { |e| e['field'] }, 'thickness'
  end

  def test_a_vertical_panel_stands_and_a_horizontal_one_lies
    vertical = PartLayout.panel(ValidationManager.validate_panel(raw).params)
    assert_equal [18.0, 1000.0, 1000.0], vertical.board.extent
    assert_in_delta 1000.0, vertical.top_z, 0.01
    horizontal = PartLayout.panel(ValidationManager.validate_panel(raw('orientation' => 'horizontal')).params)
    assert_equal [1000.0, 1000.0, 18.0], horizontal.board.extent
    assert_in_delta 18.0, horizontal.top_z, 0.01
  end

  def test_the_panel_has_a_name_of_its_sizes
    assert_equal 'VP1000x1000', NamingManager.panel_name('orientation' => 'vertical', 'width' => 1000.0, 'length' => 1000.0)
    assert_equal 'HP1200x600', NamingManager.panel_name('orientation' => 'horizontal', 'width' => 1200.0, 'length' => 600.0)
  end

  def test_the_layout_of_a_stored_panel_is_found_again
    params = ValidationManager.validate_panel(raw).params
    assert_equal [18.0, 1000.0, 1000.0], PartLayout.layout_for(params).board.extent
  end
end
