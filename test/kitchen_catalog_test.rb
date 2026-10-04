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
      'front_zone' => entry['zone'], 'bottom_zone' => entry['zone_bottom'], 'door_stacked' => entry['stacked'] == true,
      'appliance_set' => entry['appliances'].to_s, 'shelf_count' => entry['shelves'].to_s,
      'fridge' => !!entry['fridge'], 'freestanding' => entry['freestanding'] == true, 'fridge_height' => entry['fridge'], 'top_front' => entry['top_front'], 'drawer_pattern' => entry['pattern'].to_s }
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
      lift = entry['fridge'] ? 1 : 0 # a built-in fridge has a lift-up door over its doors
      assert_equal entry['doors'].to_i + lift, layout.doors.length, "#{entry['id']} doors" if entry['corner'].to_s != 'l_shape' && category != 'corner'
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
    reveal = Defaults.params['door_reveal']
    assert_in_delta 857.0, door.extent[2], 0.05, 'the door takes what the oven leaves (595 mm oven)'
    rail = layout.panels.find { |p| p.role == 'niche_rail' }
    assert_in_delta rail.offset[2] + reveal, door.offset[2] - 100.0, 0.05, 'the door covers the rail, a reveal short of its lower edge'
    assert_in_delta 2160.0 - reveal, door.offset[2] - 100.0 + door.extent[2], 0.05
    shelf = layout.panels.find { |p| p.role == 'oven_shelf_1' }
    assert_in_delta 700.0, shelf.offset[2] + shelf.extent[2], 0.05, 'the drawers end at the top of the first shelf'
    assert_in_delta 700.0 - reveal, top_drawer.offset[2] - 100.0 + top_drawer.extent[2], 0.05, 'and cover its edge, a reveal short of the top'
    [shelf, rail].each { |p| assert_in_delta 560.0, p.offset[0] + p.extent[0], 0.05, "#{p.role} is flush with the carcass front" }
    assert_operator top_drawer.offset[2] + top_drawer.extent[2], :<=, 100.0 + 700.0, 'the drawers stay in the bottom zone'
    niche_height = door.offset[2] - (top_drawer.offset[2] + top_drawer.extent[2])
    assert_operator niche_height, :>, 550.0, 'about 600 mm of open niche for the oven'
    oven = layout.appliances.find { |a| a.role.end_with?('oven_1_frame') }
    assert_in_delta 700.0, oven.offset[2], 0.01, 'the oven stands on the first shelf'
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
    { 'oven' => 1, 'double_oven' => 2, 'oven_micro' => 2 }.each do |set, count|
      result, layout = oven_unit(set)
      assert_empty result.errors.map { |e| e['message'] }, set
      assert_equal count, layout.appliances.count { |a| a.role.end_with?('_body') }, "#{set}: a body for each"
      assert_equal count, layout.appliances.count { |a| a.role.end_with?('_frame') }, "#{set}: a front for each"
      assert layout.appliances.any? { |a| a.role.end_with?('_handle') }, 'with a handle'
      assert layout.appliances.any? { |a| a.role.end_with?('_glass') }, 'and a window'
    end
    _, one = oven_unit('oven')
    _, two = oven_unit('double_oven')
    assert_operator two.doors.first.extent[2], :<, one.doors.first.extent[2], 'two ovens leave a shorter door'
    micro = oven_unit('oven_micro')[1].appliances.find { |a| a.role.include?('micro') && a.role.end_with?('body') }
    assert_in_delta 380.0 - 4.0, micro.extent[2], 0.01, 'the microwave is 380 high'
  end

  def test_with_two_ovens_or_an_oven_and_a_microwave_the_top_door_lifts_up
    _, one = oven_unit('oven')
    assert_equal %w[left], one.doors.map(&:hinge), 'one oven: an ordinary door'
    %w[double_oven oven_micro].each do |set|
      _, layout = oven_unit(set)
      door = layout.doors.first
      assert_equal 'top', door.hinge, "#{set}: the door over the appliances lifts up"
      assert_in_delta door.offset[2] + door.extent[2], door.pivot[2], 0.01, 'hinged on its top edge'
    end
    _, mixed = lower_unit('door', 1, 'appliance_set' => 'double_oven')
    assert_equal %w[left top], mixed.doors.map(&:hinge), 'the lower door stays an ordinary door'
  end

  def test_the_housing_follows_the_size_of_the_oven
    _, small = oven_unit('oven', 'oven_height' => '450')
    _, large = oven_unit('oven', 'oven_height' => '600')
    oven = ->(layout) { layout.appliances.find { |a| a.role.end_with?('oven_1_frame') } }
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

  def unit(category, id, width = nil, extra = {})
    entry = CatalogManager.cabinet(CATALOG, category, id)
    raw = raw_for(category, entry, width || entry['defaults']['width']).merge(extra)
    result = ValidationManager.validate(raw, door_count: entry['doors'].to_i, drawer_count: entry['drawers'].to_i)
    layout = CabinetLayout.compute(result.params.merge('door_count' => entry['doors'].to_i, 'drawer_count' => entry['drawers'].to_i))
    [result, layout]
  end

  def test_the_diagonal_corner_units_are_in_the_base_and_wall_lists
    assert_includes CatalogManager.cabinets(CATALOG, 'base').map { |e| e['id'] }, 'base_corner_diagonal'
    assert_includes CatalogManager.cabinets(CATALOG, 'wall').map { |e| e['id'] }, 'wall_corner_diagonal'
    assert_empty CatalogManager.cabinets(CATALOG, 'corner'), 'no separate Corner list'
    refute_includes CatalogManager.catalogs.find { |c| c['id'] == CATALOG }['features'], 'corner'
    _, base = unit('base', 'base_corner_diagonal')
    assert_equal 1, base.doors.length
    assert_equal 45.0, base.doors.first.rotation, 'a diagonal door'
    _, wall = unit('wall', 'wall_corner_diagonal')
    assert_equal 0.0, wall.base_z, 'the wall one hangs'
    assert_equal 45.0, wall.doors.first.rotation
  end

  def test_a_fridge_housing_has_a_panel_where_the_door_closes_in_two_widths_and_an_adjustable_door
    assert_equal [600, 900], CatalogManager.cabinet(CATALOG, 'tall', 'tall_fridge')['widths']
    result, layout = unit('tall', 'tall_fridge', 900)
    assert_empty result.errors
    door = layout.doors.first
    rail = layout.panels.find { |p| p.role == 'door_rail' }
    assert rail, 'a panel under the door'
    reveal = Defaults.params['door_reveal']
    assert_in_delta 2160.0 - 500.0 - reveal, rail.offset[2], 0.01
    assert_in_delta door.offset[2] - 100.0, rail.offset[2] + reveal, 0.01, 'the door covers it, a reveal short of its lower edge'
    assert_in_delta 560.0, rail.offset[0] + rail.extent[0], 0.01, 'flush with the carcass front'
    _, taller = unit('tall', 'tall_fridge', 600, 'front_zone' => 800)
    assert_in_delta 800.0 - Defaults.params['door_reveal'], taller.doors.first.extent[2], 0.01, 'the door height can be adjusted'
  end

  def test_the_built_in_fridge_has_a_door_of_adjustable_height_and_a_lift_up_door_over_it
    reveal = Defaults.params['door_reveal']
    gap = Defaults.params['door_gap']
    result, one = unit('tall', 'tall_fridge_builtin_1door')
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal 2, one.doors.length, 'the fridge door and the lift-up door'
    door, lift = one.doors
    assert_in_delta 1780.0, door.extent[2], 0.01, 'the fridge door is 1780 high, as entered'
    assert_equal 'top', lift.hinge, 'the upper door lifts up'
    assert_in_delta 2160.0 - reveal, lift.offset[2] - 100.0 + lift.extent[2], 0.01, 'it covers the top'
    assert_in_delta door.offset[2] + door.extent[2] + gap, lift.offset[2], 0.01, 'a door gap above the fridge door'
    assert_in_delta lift.offset[2] + lift.extent[2], lift.pivot[2], 0.01, 'hinged on its top edge'
    shelf = one.panels.find { |p| p.role == 'fridge_shelf' }
    assert_in_delta 1780.0 + (2 * reveal), shelf.offset[2] + shelf.extent[2], 0.01, 'the shelf under the lift-up door'
    assert_in_delta 560.0, shelf.offset[0] + shelf.extent[0], 0.01, 'flush with the carcass front'

    _, taller = unit('tall', 'tall_fridge_builtin_1door', 600, 'fridge_height' => 1900)
    assert_in_delta 1900.0, taller.doors.first.extent[2], 0.01, 'the fridge door height can be adjusted'
    # no lift-up door: only a shelf over the fridge, and the door carries on to the top
    result, plain = unit('tall', 'tall_fridge_builtin_1door', 600, 'fridge_lift' => false)
    assert_empty result.errors
    assert_equal 1, plain.doors.length
    assert_in_delta 2160.0 - (2 * reveal), plain.doors.first.extent[2], 0.01, 'the door reaches the top'
    shelf_off = plain.panels.find { |p| p.role == 'fridge_shelf' }
    assert_in_delta 1780.0 + (2 * reveal), shelf_off.offset[2] + shelf_off.extent[2], 0.01, 'with the shelf where the fridge ends'
    refuse, = unit('tall', 'tall_fridge_builtin_1door', 600, 'fridge_height' => 2100)
    assert_includes refuse.errors.map { |e| e['field'] }, 'fridge_height', 'a 56 mm lift-up door is refused'
    assert_empty unit('tall', 'tall_fridge_builtin_1door', 600, 'fridge_height' => 2100, 'fridge_lift' => false)[0].errors
  end

  def test_the_two_door_fridge_has_stacked_doors_and_a_lift_up_door
    reveal = Defaults.params['door_reveal']
    result, two = unit('tall', 'tall_fridge_builtin_2door')
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal 3, two.doors.length
    bottom, top, lift = two.doors
    assert_equal bottom.extent[1], top.extent[1], 'both are full width'
    assert_in_delta 1100.0, top.extent[2], 0.01, 'the top door is 1100 high'
    assert_operator bottom.offset[2] + bottom.extent[2], :<, top.offset[2], 'the doors do not touch'
    assert_equal bottom.hinge, top.hinge, 'hinged on the same side'
    assert_equal 'top', lift.hinge
    assert_in_delta 675.0, bottom.extent[2], 0.01, 'the bottom door is as entered'
    assert_equal %w[top bottom], [bottom.grip, top.grip], 'both handles next to the gap between the doors'
    _, shorter = unit('tall', 'tall_fridge_builtin_2door', 600, 'front_zone' => 500)
    assert_in_delta 500.0, shorter.doors[1].extent[2], 0.01, 'the top door height can be adjusted'
    _, lower = unit('tall', 'tall_fridge_builtin_2door', 600, 'fridge_height' => 500)
    assert_in_delta 500.0, lower.doors[0].extent[2], 0.01, 'the bottom door height can be adjusted'
    assert_in_delta 2160.0 - reveal, lower.doors[2].offset[2] - 100.0 + lower.doors[2].extent[2], 0.01, 'and the lift-up door covers the rest'
    _, no_lift = unit('tall', 'tall_fridge_builtin_2door', 600, 'fridge_lift' => false)
    assert_equal 2, no_lift.doors.length
    assert_in_delta 2160.0 - reveal, no_lift.doors[1].offset[2] - 100.0 + no_lift.doors[1].extent[2], 0.01, 'without it the top door carries on to the top'
    assert_in_delta 675.0, no_lift.doors[0].extent[2], 0.01
    assert no_lift.panels.find { |p| p.role == 'fridge_shelf' }, 'and a shelf stands over the fridge'
  end

  def test_the_fridge_is_drawn_behind_the_doors
    result, layout = unit('tall', 'tall_fridge_builtin_2door')
    assert_empty result.errors
    roles = layout.appliances.map(&:role)
    assert_includes roles, 'appliance_fridge_1_body'
    assert_equal %w[appliance_fridge_1_plate_1 appliance_fridge_1_plate_2], roles.grep(/plate/), 'a front for each door'
    body = layout.appliances.find { |a| a.role.end_with?('body') }
    shelf = layout.panels.find { |p| p.role == 'fridge_shelf' }
    assert_operator body.offset[2] + body.extent[2], :<=, shelf.offset[2], 'it stands under the shelf'
    assert_operator body.offset[2], :>=, 18.0, 'on the bottom panel'
    _, single = unit('tall', 'tall_fridge_builtin_1door')
    assert_equal ['appliance_fridge_1_plate_1'], single.appliances.map(&:role).grep(/plate/)
    assert_equal true, Defaults.params['visibility_settings']['fridge'], 'the fridge has its own tick'
  end

  # The lower part of an oven housing: drawers, a door, or a small drawer over a door.
  def lower_unit(mode, count = 2, extra = {})
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_oven')
    doors = mode == 'drawers' ? 1 : 2
    drawers = { 'drawers' => count, 'door' => 0, 'drawer_door' => 1 }[mode]
    raw = raw_for('tall', entry, 600).merge('lower_mode' => mode, 'lower_drawers' => count).merge(extra)
    result = ValidationManager.validate(raw, door_count: doors, drawer_count: drawers)
    [result, CabinetLayout.compute(result.params.merge('door_count' => doors, 'drawer_count' => drawers))]
  end

  def test_the_lower_part_of_the_oven_housing_is_drawers_a_door_or_a_small_drawer_over_a_door
    reveal = Defaults.params['door_reveal']
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_oven')
    assert entry['lower']
    result, drawers = lower_unit('drawers', 3)
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal [3, 1], [drawers.drawers.length, drawers.doors.length]
    result, door = lower_unit('door')
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal [0, 2], [door.drawers.length, door.doors.length]
    lower, upper = door.doors
    assert_in_delta 700.0 - (2 * reveal), lower.extent[2], 0.01, 'one door under the first shelf'
    assert_in_delta 700.0 - reveal, lower.offset[2] - 100.0 + lower.extent[2], 0.01, 'covering its edge, a reveal short of the top'
    assert_operator upper.offset[2], :>, 700.0, 'the other door is above the appliances'
    assert door.panels.find { |p| p.role == 'oven_shelf_1' }
    result, mixed = lower_unit('drawer_door', 1, 'small_drawer' => 200)
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal [1, 2], [mixed.drawers.length, mixed.doors.length]
    small = mixed.drawers.first
    assert_in_delta 200.0, small.extent[2], 0.01, 'the small drawer is as entered'
    assert_in_delta 700.0 - reveal, small.offset[2] - 100.0 + small.extent[2], 0.01
    assert_operator mixed.doors.first.offset[2] + mixed.doors.first.extent[2], :<, small.offset[2], 'the door is under the drawer'
    assert mixed.panels.find { |p| p.role == 'lower_rail' }
    refuse, = lower_unit('drawer_door', 1, 'small_drawer' => 650)
    assert_includes refuse.errors.map { |e| e['field'] }, 'small_drawer'
  end

  def test_a_freestanding_fridge_is_only_the_appliance
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_fridge_free')
    assert_equal [600, 700, 900], entry['widths']
    result, layout = unit('tall', 'tall_fridge_free')
    assert_empty result.errors.map { |e| e['message'] }
    assert_empty layout.panels
    assert_empty layout.doors
    assert_equal 0.0, layout.base_z, 'it stands on the floor'
    assert_equal 1850.0, layout.top_z
    roles = layout.appliances.map(&:role)
    assert_includes roles, 'appliance_fridge_1_free_body'
    assert_equal 2, roles.grep(/plate/).length
    assert_equal 2, roles.grep(/handle/).length
    assert_equal [0.0, 1850.0, 1850.0], [layout.appliances.map { |a| a.offset[2] }.min, layout.appliances.map { |a| a.offset[2] + a.extent[2] }.max, layout.top_z]
  end

  def test_three_drawers_small_small_big
    entry = CatalogManager.cabinet(CATALOG, 'base', 'base_3drawer_graded')
    assert entry, 'the unit is in the catalog'
    result, layout = unit('base', 'base_3drawer_graded')
    assert_empty result.errors.map { |e| e['message'] }
    bottom, middle, top = layout.drawers.map { |d| d.extent[2] }
    assert_in_delta middle, top, 0.01, 'the two small drawers are equal'
    assert_in_delta 2.0 * top, bottom, 0.02, 'the big one at the bottom is twice as high'
    assert_in_delta 780.0 - (2 * Defaults.params['door_reveal']) - (2 * Defaults.params['door_gap']), bottom + middle + top, 0.02, 'together they fill the front'
    assert_equal 3, layout.drawer_boxes.length, 'each has an inner box'
  end

  def test_a_base_unit_with_a_built_in_oven_has_a_drawer_below_and_no_door
    assert_equal [600, 900], CatalogManager.cabinet(CATALOG, 'base', 'base_oven')['widths']
    [600, 900].each do |width|
      result, layout = unit('base', 'base_oven', width)
      assert_empty result.errors.map { |e| e['message'] }, width.to_s
      assert_empty layout.doors
      assert_equal 1, layout.drawers.length
      assert_equal 1, layout.appliances.count { |a| a.role.end_with?('_body') }, 'one oven'
      front = layout.appliances.find { |a| a.role.end_with?('frame') }
      assert layout.appliances.all? { |a| a.offset[2] + a.extent[2] <= 780.0 - 40.0 }, 'it fits under the panel over it'
      assert_in_delta width - 8.0, front.extent[1], 0.01, "the oven is as wide as the unit (#{width})"
      top = layout.panels.find { |p| p.role == 'top_front' }
      assert top.front, 'the panel over the oven is the door colour'
      assert_in_delta 40.0 - Defaults.params['door_reveal'], top.extent[2], 0.01
      assert_in_delta 780.0 - Defaults.params['door_reveal'], top.offset[2] + top.extent[2], 0.01
    end
    # the drawer and the panel over the oven can be adjusted
    _, deeper = unit('base', 'base_oven', 600, 'bottom_zone' => 160, 'top_front' => 20)
    assert_in_delta 160.0 - (2 * Defaults.params['door_reveal']), deeper.drawers.first.extent[2], 0.01, 'the drawer height'
    assert_in_delta 20.0 - Defaults.params['door_reveal'], deeper.panels.find { |p| p.role == 'top_front' }.extent[2], 0.01, 'the top panel height'
    too_big, = unit('base', 'base_oven', 600, 'bottom_zone' => 200)
    assert_includes too_big.errors.map { |e| e['field'] }, 'oven_height', 'a taller drawer pushes the oven into the panel over it'
    result, = unit('base', 'base_oven', 600, 'appliance_set' => 'double_oven')
    assert_includes result.errors.map { |e| e['field'] }, 'oven_height', 'two ovens do not fit in a base unit'
    assert_equal ['oven'], CatalogManager.cabinet(CATALOG, 'base', 'base_oven')['appliance_sets']
  end

  def test_tall_handles_have_their_own_tick_that_starts_on
    assert_equal false, Defaults.params['hide_tall_handles']
  end
end