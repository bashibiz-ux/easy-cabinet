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
      'front_zone' => entry['zone'], 'bottom_zone' => entry['zone_bottom'], 'shelf_count' => entry['shelves'].to_s }
  end

  def each_entry
    %w[base wall tall corner].each do |category|
      CatalogManager.cabinets(CATALOG, category).each do |entry|
        (entry['widths'] || [entry['defaults']['width']]).each { |width| yield category, entry, width }
      end
    end
  end

  def test_the_catalog_is_listed
    assert_includes CatalogManager.catalogs.map { |c| c['name'] }, 'Kitchen Cabinet - Pull Handle'
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

  def test_an_oven_housing_has_drawers_below_a_niche_and_a_door_above
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_oven')
    result = ValidationManager.validate(raw_for('tall', entry, 600), door_count: 1, drawer_count: 2)
    assert_empty result.errors.map { |e| e['message'] }
    layout = CabinetLayout.compute(result.params.merge('door_count' => 1, 'drawer_count' => 2))
    door = layout.doors.first
    top_drawer = layout.drawers.last
    assert_in_delta 860.0 - Defaults.params['door_reveal'], door.extent[2], 0.05, 'the door is the top zone'
    assert_in_delta 100.0 + 2160.0 - 860.0, door.offset[2], 0.05
    assert_operator top_drawer.offset[2] + top_drawer.extent[2], :<=, 100.0 + 700.0, 'the drawers stay in the bottom zone'
    niche_height = door.offset[2] - (top_drawer.offset[2] + top_drawer.extent[2])
    assert_operator niche_height, :>, 550.0, 'about 600 mm of open niche for the oven'
    assert_includes layout.panels.map(&:role), 'oven_shelf_1'
    assert_includes layout.panels.map(&:role), 'niche_rail'
  end

  def oven_unit(set, extra = {})
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_oven')
    raw = raw_for('tall', entry, 600).merge('appliance_set' => set).merge(extra)
    result = ValidationManager.validate(raw, door_count: 1, drawer_count: 2)
    [result, CabinetLayout.compute(result.params.merge('door_count' => 1, 'drawer_count' => 2))]
  end

  def test_an_oven_housing_holds_one_oven_two_ovens_or_an_oven_and_a_microwave
    { 'oven' => 2, 'double_oven' => 4, 'oven_micro' => 4 }.each do |set, boxes|
      result, layout = oven_unit(set)
      assert_empty result.errors.map { |e| e['message'] }, set
      assert_equal boxes, layout.appliances.length, "#{set}: a body and a front for each"
    end
    _, one = oven_unit('oven')
    _, two = oven_unit('double_oven')
    assert_operator two.doors.first.extent[2], :<, one.doors.first.extent[2], 'two ovens leave a shorter door'
    micro = oven_unit('oven_micro')[1].appliances.find { |a| a.role.include?('micro') && a.role.end_with?('body') }
    assert_in_delta 380.0 - 4.0, micro.extent[2], 0.01, 'the microwave is 380 high'
  end

  def test_the_housing_follows_the_size_of_the_oven
    _, small = oven_unit('oven', 'oven_height' => '450')
    _, large = oven_unit('oven', 'oven_height' => '600')
    oven = ->(layout) { layout.appliances.find { |a| a.role.end_with?('oven_1_front') } }
    assert_equal 450.0, oven.call(small).extent[2]
    assert_equal 600.0, oven.call(large).extent[2]
    rail = ->(layout) { layout.panels.find { |p| p.role == 'niche_rail' }.offset[2] }
    assert_in_delta 150.0, rail.call(large) - rail.call(small), 0.01, 'the rail and door move up with a bigger oven'
  end

  def test_appliances_that_leave_no_room_for_the_door_are_refused
    result, = oven_unit('double_oven', 'oven_height' => '800')
    assert_includes result.errors.map { |e| e['field'] }, 'oven_height'
  end

  def test_the_appliances_start_hidden_and_the_oven_and_microwave_have_their_own_ticks
    settings = Defaults.params['visibility_settings']
    assert_equal false, settings['appliances']
    assert_equal [true, true], settings.values_at('oven', 'microwave')
  end

  def test_the_new_base_units_are_there
    ids = CatalogManager.cabinets(CATALOG, 'base').map { |e| e['id'] }
    assert_includes ids, 'base_drawer_2door'
    assert_includes ids, 'base_sink_1door'
    two = CatalogManager.cabinet(CATALOG, 'base', 'base_drawer_2door')
    assert_equal [2, 1], [two['doors'], two['drawers']]
  end
end