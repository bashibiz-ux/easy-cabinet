# frozen_string_literal: true

# The tall L corner unit follows the same rules as the other cabinets. Run:  ruby test/tall_corner_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager gola_profile cabinet_layout front_design appliance_parts fixtures validation_manager catalog_manager].each { |f| require File.join(plugin, f) }

class TallCornerTest < Minitest::Test
  include EasyCabinet

  def params(category, height)
    Defaults.params.merge('cabinet_category' => category, 'corner_style' => 'l_shape', 'width' => 1000.0, 'depth' => 560.0, 'height' => height,
                          'door_count' => 2, 'drawer_count' => 0, 'toe_kick_height' => 100.0, 'material_thickness' => 18.0, 'back_thickness' => 6.0, 'shelf_count' => 4)
  end

  def test_the_tall_corner_is_in_the_catalogs_next_to_the_other_tall_units
    %w[kitchen_cabinets kitchen_cabinets_no_handle].each do |catalog|
      entry = CatalogManager.cabinet(catalog, 'tall', 'tall_corner_l')
      refute_nil entry, catalog
      assert_equal 'l_shape', entry['corner']
      assert_equal [1000, 560, 2160], entry['defaults'].values_at('width', 'depth', 'height')
    end
  end

  def test_it_turns_the_row_like_the_base_corner
    tall = params('tall', 2160.0)
    assert Defaults.corner?(tall)
    assert_equal [1000.0, 1000.0, 2260.0], CabinetLayout.envelope(tall) # (a square, standing on the toe kick)
  end

  def test_it_is_built_like_the_base_corner_but_as_high_as_a_tall_unit
    base = CabinetLayout.compute(params('base', 780.0))
    tall = CabinetLayout.compute(params('tall', 2160.0))
    assert_equal base.panels.map(&:role).reject { |r| r.start_with?('shelf') }, tall.panels.map(&:role).reject { |r| r.start_with?('shelf') }
    assert_equal 2, tall.doors.length
    assert_in_delta 100.0, tall.base_z, 0.01
    assert_in_delta 2260.0, tall.top_z, 0.01
    assert_equal 4, tall.panels.count { |p| p.role.start_with?('shelf') }
  end

  def test_it_passes_the_same_checks_as_any_cabinet
    raw = { 'catalog_id' => 'c', 'cabinet_category' => 'tall', 'cabinet_type' => 'tall_corner_l', 'corner_style' => 'l_shape', 'width' => '1000', 'depth' => '560',
            'height' => '2160', 'toe_kick_height' => '100', 'door_opening_direction' => Defaults.direction_ids.first, 'top_panel_style' => Defaults::TOP_PANEL_STYLES.first }
    assert_empty ValidationManager.validate(raw, door_count: 2, drawer_count: 0).errors
  end
end
