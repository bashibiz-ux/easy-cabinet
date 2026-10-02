# frozen_string_literal: true

# Every cabinet of the "Kitchen Cabinets" catalog must pass the panel's checks and lay out in every width it offers.
# Run:  ruby test/kitchen_catalog_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager catalog_manager].each { |f| require File.join(plugin, f) }

class KitchenCatalogTest < Minitest::Test
  include KitchenCabinetMaster

  CATALOG = 'kitchen_cabinets'

  def raw_for(category, entry, width)
    { 'catalog_id' => CATALOG, 'cabinet_category' => category, 'cabinet_type' => entry['id'], 'width' => width.to_s,
      'depth' => entry['defaults']['depth'].to_s, 'height' => entry['defaults']['height'].to_s, 'toe_kick_height' => '100',
      'door_opening_direction' => 'left', 'corner_style' => entry['corner'].to_s, 'blind_width' => entry['blind'],
      'front_zone' => entry['zone'], 'shelf_count' => entry['shelves'].to_s }
  end

  def each_entry
    %w[base wall tall corner].each do |category|
      CatalogManager.cabinets(CATALOG, category).each do |entry|
        (entry['widths'] || [entry['defaults']['width']]).each { |width| yield category, entry, width }
      end
    end
  end

  def test_the_catalog_is_listed
    assert_includes CatalogManager.catalogs.map { |c| c['name'] }, 'Kitchen Cabinets'
    assert_empty CatalogManager.warnings
  end

  def test_every_cabinet_in_every_width_passes_the_checks_and_lays_out
    count = 0
    each_entry do |category, entry, width|
      result = ValidationManager.validate(raw_for(category, entry, width), door_count: entry['doors'].to_i, drawer_count: entry['drawers'].to_i)
      assert_empty result.errors, "#{entry['id']} at #{width}: #{result.errors.map { |e| e['message'] }.join(' / ')}"
      params = result.params.merge('door_count' => entry['doors'].to_i, 'drawer_count' => entry['drawers'].to_i)
      layout = CabinetLayout.compute(params)
      assert_equal entry['doors'].to_i, layout.doors.length, "#{entry['id']} doors" if entry['corner'].to_s != 'l_shape' && category != 'corner'
      assert_equal entry['drawers'].to_i, layout.drawers.length, "#{entry['id']} drawers"
      layout.panels.each { |p| assert(p.extent.compact.all? { |v| v.positive? }, "#{entry['id']} #{p.role} has a size") }
      (layout.doors + layout.drawers).each { |d| assert(d.extent.all?(&:positive?), "#{entry['id']} #{d.role} has a size") }
      count += 1
    end
    assert_operator count, :>, 40
  end

  def test_the_cabinets_the_user_asked_for_are_there
    ids = lambda { |category| CatalogManager.cabinets(CATALOG, category).map { |e| e['id'] } }
    assert_includes ids.call('base'), 'base_corner_l'
    assert_includes ids.call('base'), 'base_corner_blind'
    assert_includes ids.call('wall'), 'wall_corner_l'
    assert_includes ids.call('wall'), 'wall_corner_blind'
    assert_equal [700, 800, 900, 1000, 1200], CatalogManager.cabinet(CATALOG, 'base', 'base_2door')['widths']
    assert_equal [300, 600, 800], CatalogManager.cabinet(CATALOG, 'base', 'base_open')['widths']
  end

  def test_a_drawer_over_a_door_has_both_and_a_rail_between
    entry = CatalogManager.cabinet(CATALOG, 'base', 'base_drawer_door')
    result = ValidationManager.validate(raw_for('base', entry, 600), door_count: 1, drawer_count: 1)
    layout = CabinetLayout.compute(result.params.merge('door_count' => 1, 'drawer_count' => 1))
    door = layout.doors.first
    drawer = layout.drawers.first
    assert_operator door.offset[2] + door.extent[2], :<, drawer.offset[2], 'the drawer is above the door'
    assert_in_delta 780.0 - Defaults.params['door_reveal'], drawer.offset[2] - 100.0 + drawer.extent[2], 0.05, 'the drawer reaches the top'
    assert_includes layout.panels.map(&:role), 'drawer_rail'
  end

  def test_a_fridge_housing_has_a_door_only_at_the_top
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_fridge')
    result = ValidationManager.validate(raw_for('tall', entry, 600), door_count: 1, drawer_count: 0)
    door = CabinetLayout.compute(result.params.merge('door_count' => 1, 'drawer_count' => 0)).doors.first
    assert_in_delta 500.0 - Defaults.params['door_reveal'], door.extent[2], 0.05
    assert_in_delta 100.0 + 2160.0 - 500.0, door.offset[2], 0.05
  end
end