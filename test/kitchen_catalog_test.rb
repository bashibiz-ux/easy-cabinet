# frozen_string_literal: true

# Every cabinet of the "Kitchen Cabinets" catalog must pass the panel's checks and lay out in every width it offers.
# Run:  ruby test/kitchen_catalog_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager catalog_manager handle_manager].each { |f| require File.join(plugin, f) }

class KitchenCatalogTest < Minitest::Test
  include KitchenCabinetMaster

  CATALOG = 'kitchen_cabinets'

  def raw_for(category, entry, width)
    { 'catalog_id' => CATALOG, 'cabinet_category' => category, 'cabinet_type' => entry['id'], 'width' => width.to_s,
      'depth' => entry['defaults']['depth'].to_s, 'height' => entry['defaults']['height'].to_s, 'toe_kick_height' => '100',
      'door_opening_direction' => 'left', 'corner_style' => entry['corner'].to_s, 'blind_width' => entry['blind'],
      'front_zone' => entry['zone'], 'bottom_zone' => entry['zone_bottom'], 'door_stacked' => entry['stacked'] == true,
      'appliance_set' => entry['appliances'].to_s, 'shelf_count' => entry['shelves'].to_s,
      'sink' => entry['sink'] == true, 'sink_bowls' => entry['sink_bowls'], 'sink_tray' => entry['sink_tray'], 'hob' => entry['hob'] == true, 'hood' => entry['hood'] == true,
      'fridge' => !!entry['fridge'], 'freestanding' => entry['freestanding'] == true, 'fridge_height' => entry['fridge'], 'top_front' => entry['top_front'], 'drawer_pattern' => entry['pattern'].to_s,
      'free_housing' => entry['free_housing'] == true, 'housing_lift' => entry['lift'], 'pullout' => entry['pullout'] == true, 'finger_pull' => false }
  end

  def each_entry
    %w[base wall tall corner].each do |category|
      CatalogManager.cabinets(CATALOG, category).each do |entry|
        (entry['widths'] || [entry['defaults']['width']]).each { |width| yield category, entry, width }
      end
    end
  end

  def test_the_catalog_is_listed
    assert_includes CatalogManager.catalogs.map { |c| c['name'] }, 'Kitchen Cabinet - with handle'
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

  def test_a_built_in_fridge_unit_has_no_fridge_drawn_inside
    ['tall_fridge_builtin_1door', 'tall_fridge_builtin_2door'].each do |id|
      result, layout = unit('tall', id)
      assert_empty result.errors, id
      assert_empty layout.appliances, "#{id}: only the housing, no fridge inside"
      assert layout.doors.length >= 1 && layout.panels.find { |pan| pan.role == 'fridge_shelf' }, 'the doors and the shelf are still there'
    end
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


  def test_a_tall_unit_has_one_full_door_or_two_split_doors_with_the_lower_one_adjustable
    reveal = Defaults.params['door_reveal']
    gap = Defaults.params['door_gap']
    _, full = unit('tall', 'tall_1door', 600)
    assert_equal 1, full.doors.length
    result, split = unit('tall', 'tall_1door', 600, 'door_split' => true)
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal 2, split.doors.length
    lower, upper = split.doors
    assert_in_delta 1000.0, lower.extent[2], 0.01, 'the lower door is 1000 high to start'
    assert_in_delta 2160.0 - (2 * reveal) - gap - 1000.0, upper.extent[2], 0.01, 'the upper one takes the rest'
    assert_equal %w[top bottom], [lower.grip, upper.grip], 'handles next to the gap'
    assert_in_delta 2160.0 - reveal, upper.offset[2] - 100.0 + upper.extent[2], 0.01
    _, other = unit('tall', 'tall_1door', 600, 'door_split' => true, 'split_height' => 800)
    assert_in_delta 800.0, other.doors.first.extent[2], 0.01, 'adjustable'
    _, pair = unit('tall', 'tall_2door', 900, 'door_split' => true)
    assert_equal 4, pair.doors.length, 'two columns of two'
    assert_equal pair.doors[0].extent[2], pair.doors[1].extent[2]
    refute_equal pair.doors[0].hinge, pair.doors[1].hinge, 'the columns open apart'
    too_tall, = unit('tall', 'tall_1door', 600, 'door_split' => true, 'split_height' => 2140)
    assert_includes too_tall.errors.map { |e| e['field'] }, 'split_height'
  end

  def test_each_drawer_can_have_its_own_height
    reveal = Defaults.params['door_reveal']
    gap = Defaults.params['door_gap']
    _, auto = unit('base', 'base_3drawer', 600)
    _, typed = unit('base', 'base_3drawer', 600, 'drawer_heights' => '300,,')
    bottom, middle, top = typed.drawers.map { |d| d.extent[2] }
    assert_in_delta 300.0, top, 0.01, 'the first one typed is the top drawer'
    assert_in_delta middle, bottom, 0.01, 'the others share what is left'
    assert_in_delta 780.0 - (2 * reveal) - (2 * gap), bottom + middle + top, 0.02, 'together they still fill the front'
    assert_operator top, :>, auto.drawers.last.extent[2]
    _, low = unit('base', 'base_3drawer', 600, 'drawer_heights' => ',150,')
    assert_in_delta 150.0, low.drawers[1].extent[2], 0.01
    assert_equal 3, typed.drawer_boxes.length, 'each drawer keeps its box'
    refuse, = unit('base', 'base_3drawer', 600, 'drawer_heights' => '700,,')
    assert_includes refuse.errors.map { |e| e['field'] }, 'drawer_heights'
  end

  def test_the_sink_cabinets_have_a_sink_with_an_opening_in_the_worktop
    result, layout = unit('base', 'base_sink', 900)
    assert_empty result.errors.map { |e| e['message'] }
    roles = layout.appliances.map(&:role)
    %w[appliance_sink_1_bowl_1_floor appliance_sink_1_rim_1 appliance_sink_1_tap_body appliance_sink_1_tray].each { |role| assert_includes roles, role }
    assert_equal 1, roles.grep(/bowl_\d_floor/).length, 'one bowl and a drainer to start'
    floor = layout.appliances.find { |a| a.role.end_with?('bowl_1_floor') }
    rim = layout.appliances.find { |a| a.role.end_with?('rim_1') }
    assert_in_delta 780.0 + 20.0 - 180.0, floor.offset[2], 0.01, 'the bowl hangs from the top of the worktop'
    assert_in_delta 780.0 + 20.0, rim.offset[2], 0.01, 'the rim lies on it'
    params = result.params.merge('door_count' => 2, 'drawer_count' => 0)
    cuts = Fixtures.cutouts(params)
    assert_equal 1, cuts.length
    x0, x1, y0, y1 = cuts.first
    assert_operator x0, :>, 10.0
    assert_operator x1, :<, 560.0
    assert_operator y0, :>, 18.0
    assert_operator y1, :<, 900.0 - 18.0
    assert_in_delta 420.0, x1 - x0, 0.01, 'the opening is the size of the sink'

    # two bowls, no drainer; and mirrored: the drainer on the other side
    two, = unit('base', 'base_sink', 1200, 'sink_bowls' => 2, 'sink_tray' => false)
    assert_empty two.errors
    two_layout = unit('base', 'base_sink', 1200, 'sink_bowls' => 2, 'sink_tray' => false)[1]
    assert_equal 2, two_layout.appliances.map(&:role).grep(/bowl_\d_floor/).length
    refute two_layout.appliances.map(&:role).include?('appliance_sink_1_tray')
    plain = unit('base', 'base_sink', 1200, 'sink_bowls' => 1, 'sink_tray' => true)[0].params.merge('door_count' => 2)
    dims = CabinetLayout.send(:dimensions, plain)
    flat = Fixtures.sink_plan(plain, dims)
    flipped = Fixtures.sink_plan(plain.merge('sink_mirror' => true), dims)
    assert flat[:fits] && flipped[:fits]
    centre = ->(rect) { (rect[2] + rect[3]) / 2.0 }
    assert_operator centre.call(flat[:tray]), :>, centre.call(flat[:bowls].first), 'the drainer is on the right'
    assert_operator centre.call(flipped[:tray]), :<, centre.call(flipped[:bowls].first), 'mirrored it is on the left'
    assert_equal flat[:rect], flipped[:rect], 'the opening is the same either way'
    assert_equal 420.0, flat[:depth], 'it is not turned: the bowls keep their depth'
    # a sink that does not fit is refused
    narrow, = unit('base', 'base_sink_1door', 400, 'sink_bowls' => 2)
    assert_includes narrow.errors.map { |e| e['field'] }, 'sink_bowls'
    fine, = unit('base', 'base_sink_1door', 400)
    assert_empty fine.errors.map { |e| e['message'] }
  end

  def test_the_hob_unit_has_a_hob_and_an_opening
    [600, 900].each do |width|
      result, layout = unit('base', 'base_hob', width)
      assert_empty result.errors.map { |e| e['message'] }
      glass = layout.appliances.find { |a| a.role == 'appliance_hob_1_glass' }
      assert glass, 'the hob'
      assert_in_delta [width - 20.0, 860.0].min, glass.extent[1], 0.01, 'as wide as the unit allows (860 at most)'
      assert_equal width >= 700 ? 5 : 4, layout.appliances.count { |a| a.role =~ /hob_1_zone_\d\z/ }, 'cooking zones'
      assert layout.appliances.any? { |a| a.shape == 'cyl_z' }, 'drawn round'
      cut = Fixtures.cutouts(result.params.merge('door_count' => 0, 'drawer_count' => 2)).first
      assert_in_delta glass.extent[1] - 20.0, cut[3] - cut[2], 0.01, 'the opening is a little smaller than the glass'
    end
    assert_equal true, Defaults.params['visibility_settings'].values_at('sink', 'hob', 'hood').all?
  end

  def test_the_hood_cabinet_has_a_hood_under_it
    result, layout = unit('wall', 'wall_hood', 600)
    assert_empty result.errors.map { |e| e['message'] }
    hood = layout.appliances.select { |a| a.role.start_with?('appliance_hood_1') }
    assert_operator hood.length, :>=, 8, 'visor, glass front, buttons, filter ribs and lights'
    assert hood.all? { |a| a.offset[2] < 0.0 }, 'below the cabinet'
    assert_equal 780.0, layout.top_z, 'the hood cabinet is a full standard wall unit'
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
    assert_equal [600, 900], CatalogManager.cabinet(CATALOG, 'base', 'base_oven_hob')['widths']
    [600, 900].each do |width|
      result, layout = unit('base', 'base_oven_hob', width)
      assert_empty result.errors.map { |e| e['message'] }, width.to_s
      assert_empty layout.doors
      assert_equal 1, layout.drawers.length
      assert_equal 1, layout.appliances.count { |a| a.role.end_with?('_body') }, 'one oven'
      front = layout.appliances.find { |a| a.role.end_with?('oven_1_frame') }
      assert layout.appliances.select { |a| a.role.start_with?('appliance_oven_') }.all? { |a| a.offset[2] + a.extent[2] <= 780.0 - 40.0 }, 'it fits under the panel over it'
      assert_in_delta width - 8.0, front.extent[1], 0.01, "the oven is as wide as the unit (#{width})"
      top = layout.panels.find { |p| p.role == 'top_front' }
      assert top.front, 'the panel over the oven is the door colour'
      assert_in_delta 40.0 - Defaults.params['door_reveal'], top.extent[2], 0.01
      assert_in_delta 780.0 - Defaults.params['door_reveal'], top.offset[2] + top.extent[2], 0.01
    end
    # the drawer and the panel over the oven can be adjusted
    _, deeper = unit('base', 'base_oven_hob', 600, 'bottom_zone' => 160, 'top_front' => 20)
    assert_in_delta 160.0 - (2 * Defaults.params['door_reveal']), deeper.drawers.first.extent[2], 0.01, 'the drawer height'
    assert_in_delta 20.0 - Defaults.params['door_reveal'], deeper.panels.find { |p| p.role == 'top_front' }.extent[2], 0.01, 'the top panel height'
    too_big, = unit('base', 'base_oven_hob', 600, 'bottom_zone' => 200)
    assert_includes too_big.errors.map { |e| e['field'] }, 'oven_height', 'a taller drawer pushes the oven into the panel over it'
    result, = unit('base', 'base_oven_hob', 600, 'appliance_set' => 'double_oven')
    assert_includes result.errors.map { |e| e['field'] }, 'oven_height', 'two ovens do not fit in a base unit'
    assert_equal ['oven'], CatalogManager.cabinet(CATALOG, 'base', 'base_oven_hob')['appliance_sets']
  end

  def test_tall_handles_have_their_own_tick_that_starts_on
    assert_equal false, Defaults.params['hide_tall_handles']
  end
  def test_a_freestanding_fridge_housing_has_door_coloured_side_panels_and_a_lift_up_cabinet_over_the_fridge
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_fridge_housing_free')
    assert_equal [600, 900, 1000, 1200], entry['widths']
    [600, 900, 1000, 1200].each do |width|
      result, layout = unit('tall', 'tall_fridge_housing_free', width)
      assert_empty result.errors.map { |e| e['message'] }, width.to_s
      sides = layout.panels.select { |p| p.role.end_with?('_side') }
      assert_equal 2, sides.length
      assert sides.all?(&:front), 'the side panels are in the door material'
      assert sides.all? { |p| p.extent[0] == 650.0 && p.extent[2] == 2260.0 }, 'as deep as the cabinet and as high as a tall unit on its toe kick (100 + 2160)'
      door = layout.doors.first
      assert_equal 'top', door.hinge, 'a lift-up door'
      assert_equal 1, layout.doors.length
      inside = (sides[0].offset[1] + sides[0].extent[1]) <= door.offset[1] && (door.offset[1] + door.extent[1]) <= sides[1].offset[1]
      assert inside, 'the door is between the panels'
      assert_in_delta door.offset[2] + door.extent[2], door.pivot[2], 0.01, 'hinged on its top edge'
      assert_operator door.offset[2] + door.extent[2], :<=, 2260.0
      fridge = layout.appliances.select { |a| a.role.include?('_housed_') }
      assert layout.panels.map(&:role).include?('lift_left') && layout.panels.map(&:role).include?('lift_bottom'), 'the cabinet over the fridge has its own carcass'
      plates_front = fridge.select { |a| a.role =~ /_plate_\d\z/ }.map { |a| a.offset[0] + a.extent[0] }.max
      assert_in_delta 650.0, plates_front, 0.01, 'the fridge doors are flush with the front of the panels'
      assert_in_delta 650.0, door.offset[0] + door.extent[0], 0.01, 'and so is the door of the cabinet over it'
      assert_operator fridge.length, :>, 5, 'a fridge stands between the panels'
      assert fridge.all? { |a| a.offset[1] >= sides[0].extent[1] - 0.01 && a.offset[1] + a.extent[1] <= sides[1].offset[1] + 0.01 }, 'inside the panels'
      assert_operator fridge.map { |a| a.offset[2] + a.extent[2] }.max, :<=, door.offset[2], 'under the lift-up cabinet'
    end
    _, tall = unit('tall', 'tall_fridge_housing_free', 900, 'housing_lift' => 500)
    _, std = unit('tall', 'tall_fridge_housing_free', 900)
    assert_in_delta 140.0, tall.doors.first.extent[2] - std.doors.first.extent[2], 0.01, 'the height of the lift-up cabinet is adjustable'
    refuse, = unit('tall', 'tall_fridge_housing_free', 900, 'housing_lift' => 1800)
    assert_includes refuse.errors.map { |e| e['field'] }, 'housing_lift'
    assert_equal 360, entry['lift'], 'the lift-up cabinet starts as high as our short wall unit'
    # the fridge is drawn by width: fridge over freezer, side by side, French doors
    plates = ->(w) { unit('tall', 'tall_fridge_housing_free', w)[1].appliances.count { |a| a.role =~ /_plate_\d\z/ } }
    assert_equal [2, 2, 2, 3], [600, 900, 1000, 1200].map { |w| plates.call(w) }
  end

  def test_lift_up_doors_and_drawers_always_get_a_horizontal_handle
    bundle = { 'profile' => 'bar' }
    settings = { 'length' => 160.0, 'orientation' => 'vertical', 'position' => 'auto', 'horizontal_place' => 'middle', 'category' => 'tall',
                 'side_offset' => 40.0, 'vertical_offset' => 40.0, 'custom_x' => 0.0, 'custom_z' => 0.0 }
    checked = 0
    each_entry do |category, entry, width|
      _, layout = unit(category, entry['id'], width)
      (layout.doors + layout.drawers).each do |door|
        next unless %w[top center].include?(door.hinge)
        next if entry['pullout'] # a pull-out has a vertical handle (see below)

        spot = HandleManager.placement(door, settings.merge('category' => category), bundle)
        assert spot['horizontal'], "#{entry['id']} #{width} #{door.role}: a lift-up door or a drawer has a horizontal handle"
        checked += 1
      end
    end
    assert_operator checked, :>, 30
  end

  def test_the_appliances_are_drawn_with_round_parts_and_a_finish_for_each
    _, layout = oven_unit('oven_micro')
    shapes = layout.appliances.map(&:shape).compact.uniq
    assert_equal ['cyl_x', 'cyl_y', 'cyl_z'].sort, (shapes + ['cyl_z']).uniq.sort, 'knobs, handle bars'
    roles = layout.appliances.map(&:role)
    %w[glass window panel display seal handle].each { |suffix| assert roles.any? { |r| r.end_with?("oven_1_#{suffix}") }, "the oven has a #{suffix}" }
    finish = ->(role) { AppliancePieces.finish(role)[0] }
    assert_equal 'Appliance - Graphite Glass', finish.call('appliance_oven_1_glass')
    assert_equal 'Appliance - Inox', finish.call('appliance_oven_1_handle')
    assert_equal 'Appliance - Polished Chrome', finish.call('appliance_sink_1_tap_spout')
    assert_equal 'Appliance - Sink Inox', finish.call('appliance_sink_1_bowl_1_floor')
    assert_equal 'Appliance - Gloss White', finish.call('appliance_fridge_1_body')
    assert_equal 'Appliance - Silver Ring', finish.call('appliance_hob_1_zone_1')
    assert_equal 'Appliance - LED Glow', finish.call('appliance_oven_1_display')
    assert_equal 'Appliance - Graphite Plastic', finish.call('appliance_oven_1_cap_1')
    assert AppliancePieces::APPLIANCE_FINISHES.values.none? { |_, color, _| color[1, 6].scan(/../).map { |h| h.to_i(16) }.max < 0x30 }, 'no finish is pure black'
    sink = unit('base', 'base_sink', 900)[1].appliances
    neck = sink.find { |a| a.shape == 'tube' }
    assert neck && neck.path.length > 10 && neck.round == 24.0, 'the tap has a swan neck: one bent pipe'
    assert_equal 'Appliance - Polished Chrome', AppliancePieces.finish(neck.role)[0]
    assert AppliancePieces::APPLIANCE_FINISHES.values.all? { |_, color, look| color =~ /\A#\h{6}\z/ && look['roughness'] }, 'every finish has a colour and a roughness'
  end
  def test_every_appliance_is_under_show_appliances_with_a_tick_of_its_own
    ticks = { 'appliance_oven_1_frame' => 'oven', 'appliance_micro_1_glass' => 'microwave', 'appliance_hob_1_glass' => 'hob', 'appliance_hood_1_frame' => 'hood',
              'appliance_fridge_1_free_plate_1' => 'free_fridge', 'appliance_fridge_1_housed_plate_2' => 'free_fridge',
              'appliance_sink_1_tray' => 'sink' }
    ticks.each { |role, tick| tick ? assert_equal(tick, AppliancePieces.tick_for(role), role) : assert_nil(AppliancePieces.tick_for(role), role) }
    assert_equal true, Defaults.params['visibility_settings']['free_fridge'], 'the freestanding fridge has its own tick'
    _, housing = unit('tall', 'tall_fridge_housing_free', 900)
    assert housing.appliances.all? { |a| AppliancePieces.tick_for(a.role) == 'free_fridge' }, 'the fridge of a housing follows the freestanding fridge tick'
    assert_equal 2260.0, CatalogManager.cabinet(CATALOG, 'tall', 'tall_fridge_housing_free')['defaults']['height']
  end
  def test_the_tall_list_has_a_pull_out_and_no_pantry_fridge_housing_or_freestanding_fridge
    ids = CatalogManager.cabinets(CATALOG, 'tall').map { |e| e['id'] }
    %w[tall_pantry tall_fridge tall_fridge_free].each { |id| refute_includes ids, id }
    assert_includes ids, 'tall_pullout'
    entry = CatalogManager.cabinet(CATALOG, 'tall', 'tall_pullout')
    assert_equal [150, 200, 300, 400, 450, 600], entry['widths']
    result, layout = unit('tall', 'tall_pullout', 300, 'drawer_number' => 1)
    assert_empty result.errors.map { |e| e['message'] }
    assert_equal 1, layout.drawers.length
    assert_in_delta 2160.0 - (2 * Defaults.params['door_reveal']), layout.drawers.first.extent[2], 0.01, 'one pull-out front over the full height'
    assert_empty layout.drawer_boxes, 'and nothing inside it'
    _, base = unit('base', 'base_pullout', 200)
    assert_equal 1, base.drawers.length
    assert_empty base.drawer_boxes, 'the narrow base pull-out has no inner parts either'
    _, ordinary = unit('base', 'base_2drawer', 600)
    assert_equal 2, ordinary.drawer_boxes.length, 'ordinary drawers keep their boxes'
  end

  def test_the_built_in_oven_cabinet_comes_with_a_hob_too
    ids = CatalogManager.cabinets(CATALOG, 'base').map { |e| e['id'] }
    refute_includes ids, 'base_oven', 'the plain built-in oven cabinet is no longer in the list'
    assert_includes ids, 'base_oven_hob'
    [600, 900].each do |width|
      result, layout = unit('base', 'base_oven_hob', width)
      assert_empty result.errors.map { |e| e['message'] }, width.to_s
      roles = layout.appliances.map(&:role)
      assert roles.any? { |r| r.start_with?('appliance_oven_1_') }, 'the oven'
      assert_includes roles, 'appliance_hob_1_glass'
      cut = Fixtures.cutouts(result.params.merge('door_count' => 0, 'drawer_count' => 1))
      assert_equal 1, cut.length, 'an opening for the hob in the worktop'
    end
  end
  def test_the_displays_of_the_appliances_show_numbers
    _, oven = oven_unit('oven_micro')
    %w[oven micro].each do |kind|
      display = oven.appliances.find { |a| a.role == "appliance_#{kind}_1_display" }
      figures = oven.appliances.select { |a| a.role =~ /appliance_#{kind}_1_digit_\d+\z/ }
      assert_operator figures.length, :>=, 12, "#{kind}: the clock reads 12:30 / 0:30"
      assert figures.all? { |f| f.offset[1] >= display.offset[1] - 0.01 && f.offset[1] + f.extent[1] <= display.offset[1] + display.extent[1] + 0.01 }, "#{kind}: the figures lie on the display"
      assert figures.all? { |f| f.offset[2] >= display.offset[2] - 0.01 && f.offset[2] + f.extent[2] <= display.offset[2] + display.extent[2] + 0.01 }, "#{kind}: and inside its height"
      assert figures.all? { |f| f.offset[0] >= display.offset[0] + display.extent[0] - 0.01 }, "#{kind}: standing on its face"
    end
    _, hob = unit('base', 'base_hob', 600)
    led = hob.appliances.find { |a| a.role == 'appliance_hob_1_led_1' }
    marks = hob.appliances.select { |a| a.role =~ /appliance_hob_1_digit_/ }
    assert_operator marks.length, :>=, 8, 'the hob shows P9'
    assert marks.all? { |m| m.offset[0] >= led.offset[0] - 0.01 && m.offset[0] + m.extent[0] <= led.offset[0] + led.extent[0] + 0.01 }, 'on its display'
    _, house = unit('tall', 'tall_fridge_housing_free', 900)
    assert house.appliances.any? { |a| a.role =~ /housed_digit_/ }, 'a freestanding fridge shows its temperature'
    assert_equal 'Appliance - Graphite Trim', AppliancePieces.finish('appliance_oven_1_digit_4')[0]
    assert_equal '12:30'.length, 5
  end
  def test_a_knob_is_a_smooth_turned_shape_with_a_rose_a_neck_and_a_domed_head
    [[28.0, 28.0], [32.0, 28.0], [38.0, 28.0], [30.0, 40.0]].each do |diameter, projection|
      profile = HandleManager.knob_profile(diameter, projection)
      assert_equal [0.0, 0.0], profile.first, 'starts in the middle of its base on the door'
      assert_equal [0.0, projection], profile.last, 'ends in the middle of its top'
      assert_in_delta diameter / 2.0, profile.map(&:first).max, 0.01, 'the head is as wide as the knob'
      neck = profile.map(&:first).each_cons(3).count { |a, b, c| b < a && b < c }
      assert_operator neck, :>=, 0
      assert_operator profile.map(&:first)[profile.index { |r, _| r > 0 } || 1], :>, 0
      assert profile.each_cons(2).all? { |(_, z0), (_, z1)| z1 >= z0 - 1e-9 }, 'it never doubles back towards the door'
      assert_operator profile.length, :>=, 20, 'a curved outline, not a cylinder'
      faces = HandleManager.knob_faces(diameter, projection)
      assert_operator faces.length, :>, 48 * 15, 'drawn with many faces'
      assert faces.all? { |f| f.length >= 3 }, 'no collapsed face'
      centre = ->(f) { f.transpose.map { |v| v.sum / v.length } }
      outward = faces.all? do |f|
        c = centre.call(f)
        normal = HandleManager.send(:newell, f)
        radial = [0.0, c[1], c[2]]
        flat = (c[1]**2 + c[2]**2) < 1e-6
        flat ? normal[0].abs > 0 : HandleManager.send(:dot, normal, radial) >= -1e-9 || normal[0].abs > Math.hypot(normal[1], normal[2])
      end
      assert outward, 'every face points out of the knob'
      xs = faces.flatten(1).map(&:first)
      assert_in_delta projection, xs.max, 0.01
      assert_in_delta 0.0, xs.min, 0.01, 'it stands on the door face'
      assert_operator faces.flatten(1).map { |p| Math.hypot(p[1], p[2]) }.max, :<=, (diameter / 2.0) + 0.01
    end
  end
  def test_a_bar_handle_is_a_smooth_round_grip_with_domed_ends_on_two_round_posts
    [[96.0, 10.0, 30.0], [160.0, 10.0, 30.0], [320.0, 12.0, 35.0], [128.0, 10.0, 10.0]].each do |length, section, projection|
      faces = HandleManager.bar_faces(length, section, projection)
      assert_operator faces.length, :>, 48 * 8, 'many faces'
      assert faces.all? { |f| f.length >= 3 }
      points = faces.flatten(1)
      assert_in_delta projection, points.map(&:first).max, 0.01, 'the grip is as far from the door as the projection says'
      assert_in_delta length / 2.0, points.map { |p| p[2] }.max, 0.01
      assert_in_delta(-length / 2.0, points.map { |p| p[2] }.min, 0.01)
      d = [section, projection].min
      assert_operator points.map { |p| p[1].abs }.max, :<=, (d * 0.6) + 0.01, 'no wider than the grip and its roses'
      posts = projection > d
      assert_operator points.map(&:first).min, :<, 0.01, 'posts reach the door, or the grip rests on it'
      assert_operator(faces.length, :>, 48 * 30, 'with posts') if posts
      faces_out = faces.all? do |f|
        normal = HandleManager.send(:newell, f)
        c = f.transpose.map { |v| v.sum / v.length }
        grip_axis = [projection - (d / 2.0), 0.0, c[2]]
        radial = [c[0] - grip_axis[0], c[1], 0.0]
        near_grip = (radial[0]**2 + radial[1]**2) <= ((d / 2.0) + 0.01)**2 && c[0] > projection - d - 0.01
        next true unless near_grip && c[2].abs < (length / 2.0) - (d * 1.3) # the straight part of the grip, clear of the posts

        HandleManager.send(:dot, normal, radial) > 0
      end
      assert faces_out, 'faces of the grip point out of it'
    end
  end
  def test_the_handle_of_a_tall_pull_out_is_at_the_same_height_as_on_the_other_tall_units
    bundle = { 'profile' => 'bar' }
    settings = { 'length' => 160.0, 'orientation' => 'vertical', 'position' => 'auto', 'horizontal_place' => 'middle', 'category' => 'tall',
                 'side_offset' => 40.0, 'vertical_offset' => 40.0, 'custom_x' => 0.0, 'custom_z' => 0.0 }
    _, pull = unit('tall', 'tall_pullout', 300)
    _, doors = unit('tall', 'tall_1door', 450)
    out = HandleManager.placement(pull.drawers.first, settings.merge('pullout' => true), bundle)
    door = HandleManager.placement(doors.doors.first, settings, bundle)
    floor_height = ->(item, spot) { item.offset[2] + spot['v'] }
    assert_in_delta floor_height.call(doors.doors.first, door), floor_height.call(pull.drawers.first, out), 0.01, 'the same height off the floor'
    assert_in_delta Defaults::TALL_HANDLE_HEIGHT, floor_height.call(pull.drawers.first, out), 0.01
    assert_equal false, out['horizontal'], 'and it is vertical'
    _, four = unit('tall', 'tall_4drawer', 600)
    top = HandleManager.placement(four.drawers.last, settings, bundle)
    assert_operator top['v'], :>, four.drawers.last.extent[2] / 2.0, 'the small drawers of a tall unit keep their handle at the top'
  end
  def test_the_model_without_handle_shortens_the_top_fronts_and_closes_the_gap_with_a_panel_that_follows
    reveal = Defaults.params['door_reveal']
    _, plain = unit('base', 'base_2door', 900)
    result, pull = unit('base', 'base_2door', 900, 'finger_pull' => true)
    assert_empty result.errors.map { |e| e['message'] }
    panel = pull.panels.find { |p| p.role == 'finger_panel' }
    assert panel, 'a panel over the doors'
    assert panel.front, 'in the door material'
    assert_in_delta 900.0, panel.extent[1], 0.01, 'from the outside of one side panel of the carcass to the other'
    assert_in_delta 0.0, panel.offset[1], 0.01
    assert_equal plain.doors.map { |d| d.extent[2] - 35.0 }, pull.doors.map { |d| d.extent[2] }, 'the doors are 35 mm shorter'
    assert_equal plain.doors.map { |d| d.offset[2] }, pull.doors.map { |d| d.offset[2] }, 'from where they started'
    assert_equal plain.doors.map { |d| d.offset[0] }, pull.doors.map { |d| d.offset[0] }, 'and not moved in or out'
    rail = pull.panels.find { |p| p.role == 'top_front_rail' }
    assert_in_delta plain.panels.find { |p| p.role == 'top_front_rail' }.offset[0] - 18.0, rail.offset[0], 0.01, 'the top front rail steps back by the thickness of the panel'
    assert_in_delta panel.offset[0], rail.offset[0] + rail.extent[0], 0.01, 'to just behind it'
    door_top = pull.doors.first.offset[2] + pull.doors.first.extent[2] - 100.0 # above the carcass bottom
    assert_in_delta door_top - 10.0, panel.offset[2], 0.01, 'the panel reaches 10 mm down behind the top of the doors'
    assert_in_delta 780.0, panel.offset[2] + panel.extent[2], 0.01, 'and up to the top of the carcass sides'
    side = pull.panels.find { |p| p.role == 'left_side' }
    assert_in_delta side.offset[0] + side.extent[0], panel.offset[0] + panel.extent[0], 0.01, 'its front is flush with the front of the side panels'
    assert_in_delta side.offset[2] + side.extent[2], panel.offset[2] + panel.extent[2], 0.01, 'and it starts at their top'
    refute plain.panels.any? { |p| p.role == 'finger_panel' }
    # the door height reduction is adjustable and the panel follows it
    _, deeper = unit('base', 'base_2door', 900, 'finger_pull' => true, 'finger_gap' => 60)
    assert_in_delta pull.doors.first.extent[2] - 25.0, deeper.doors.first.extent[2], 0.01, 'doors 60 mm shorter'
    deeper_panel = deeper.panels.find { |p| p.role == 'finger_panel' }
    assert_in_delta panel.offset[2] - 25.0, deeper_panel.offset[2], 0.01, 'the panel is taller by the same amount'
    assert_in_delta 780.0, deeper_panel.offset[2] + deeper_panel.extent[2], 0.01
    refuse, = unit('base', 'base_2door', 900, 'finger_pull' => true, 'finger_gap' => 300)
    assert_includes refuse.errors.map { |e| e['field'] }, 'finger_gap'
    # drawers: only the top one
    _, drawers = unit('base', 'base_3drawer', 600, 'finger_pull' => true)
    _, ordinary = unit('base', 'base_3drawer', 600)
    assert_in_delta ordinary.drawers.last.extent[2] - 35.0, drawers.drawers.last.extent[2], 0.01, 'the top drawer front is lower'
    assert_in_delta ordinary.drawers.first.extent[2], drawers.drawers.first.extent[2], 0.01, 'the others are as they were'
    assert_equal drawers.drawers.length, drawers.drawer_boxes.length, 'every drawer keeps its box'
    # not on wall units, tall units or corner shapes
    [['wall', 'wall_2door'], ['tall', 'tall_2door'], ['base', 'base_corner_l'], ['base', 'base_corner_diagonal']].each do |category, id|
      _, other = unit(category, id, nil, 'finger_pull' => true)
      refute other.panels.any? { |p| p.role == 'finger_panel' }, id
    end
  end

  def test_no_face_of_a_handle_has_two_points_closer_than_sketchup_accepts
    faces = []
    [28.0, 32.0, 38.0].each { |d| faces << HandleManager.knob_faces(d, 28.0) }
    Dir[File.join(KitchenCabinetMaster::DATA_DIR, 'handles', '*.json')].each do |file|
      bundle = JSON.parse(File.read(file, encoding: 'UTF-8'))
      next unless bundle['profile'] == 'bar'

      bundle['lengths'].each { |length| faces << HandleManager.bar_faces(length.to_f, (bundle['section'] || 10).to_f, (bundle['projection'] || 30).to_f) }
    end
    assert_operator faces.length, :>=, 9
    faces.flatten(1).each do |face|
      face.combination(2).each do |a, b|
        distance = Math.sqrt(a.zip(b).sum { |u, v| (u - v)**2 })
        assert_operator distance, :>, 0.0255, 'SketchUp raises "Duplicate points in array" for points closer than 0.001 inch'
      end
    end
  end

  def test_the_top_drawer_front_has_its_own_reduction_and_the_panel_follows_it
    _, plain = unit('base', 'base_3drawer', 600)
    _, same = unit('base', 'base_3drawer', 600, 'finger_pull' => true)
    result, own = unit('base', 'base_3drawer', 600, 'finger_pull' => true, 'finger_gap_drawer' => 50)
    assert_empty result.errors.map { |e| e['message'] }
    assert_in_delta plain.drawers.last.extent[2] - 35.0, same.drawers.last.extent[2], 0.01, 'both start at 35 mm'
    assert_in_delta plain.drawers.last.extent[2] - 50.0, own.drawers.last.extent[2], 0.01, 'the drawer front is 50 mm lower'
    assert_in_delta plain.drawers.first.extent[2], own.drawers.first.extent[2], 0.01, 'the other drawers are as they were'
    panel = own.panels.find { |p| p.role == 'finger_panel' }
    same_panel = same.panels.find { |p| p.role == 'finger_panel' }
    assert_in_delta same_panel.offset[2] - 15.0, panel.offset[2], 0.01, 'the panel reaches 15 mm lower'
    assert_in_delta 780.0, panel.offset[2] + panel.extent[2], 0.01
    # a door and a drawer: each has its own value
    _, both = unit('base', 'base_drawer_door', 600, 'finger_pull' => true, 'finger_gap' => 40, 'finger_gap_drawer' => 60)
    _, normal = unit('base', 'base_drawer_door', 600)
    assert_in_delta normal.drawers.first.extent[2] - 60.0, both.drawers.first.extent[2], 0.01
    assert_in_delta normal.doors.first.extent[2], both.doors.first.extent[2], 0.01, 'a lower door is not changed'
    refuse, = unit('base', 'base_3drawer', 600, 'finger_pull' => true, 'finger_gap_drawer' => 300)
    assert_includes refuse.errors.map { |e| e['field'] }, 'finger_gap_drawer'
    # a door unit is not affected by the drawer value
    _, doors = unit('base', 'base_2door', 900, 'finger_pull' => true, 'finger_gap_drawer' => 80)
    _, doors_plain = unit('base', 'base_2door', 900)
    assert_in_delta doors_plain.doors.first.extent[2] - 35.0, doors.doors.first.extent[2], 0.01
  end

  def test_every_front_can_have_its_finger_gap_when_asked
    _, plain = unit('base', 'base_3drawer', 600)
    _, top_only = unit('base', 'base_3drawer', 600, 'finger_pull' => true)
    assert_equal 1, top_only.panels.count { |p| p.role.start_with?('finger_panel') }, 'as it was: only the top one'
    assert_in_delta plain.drawers.first.extent[2], top_only.drawers.first.extent[2], 0.01

    result, all = unit('base', 'base_3drawer', 600, 'finger_pull' => true, 'finger_all' => true)
    assert_empty result.errors.map { |e| e['message'] }
    all.drawers.each_with_index do |drawer, i|
      assert_in_delta plain.drawers[i].extent[2] - 35.0, drawer.extent[2], 0.01, "drawer #{i + 1} is 35 mm lower"
      assert_in_delta plain.drawers[i].offset[2], drawer.offset[2], 0.01, 'and starts where it did'
    end
    finger = all.panels.select { |p| p.role.start_with?('finger_panel') }
    assert_equal 3, finger.length, 'a panel over each drawer'
    assert_equal 3, finger.map(&:role).uniq.length
    top, middle, bottom = finger.sort_by { |p| -p.offset[2] }
    assert_in_delta 780.0, top.offset[2] + top.extent[2], 0.01, 'the top one goes up to the top of the sides'
    [middle, bottom].each do |panel|
      assert panel.front
      assert_in_delta 600.0, panel.extent[1], 0.01, 'from side to side'
      assert_in_delta 542.0, panel.offset[0], 0.01, 'flush with the front of the sides'
    end
    drawer = plain.drawers[1]
    ended = drawer.offset[2] + drawer.extent[2] - 100.0 # where the middle drawer front ended above the carcass bottom
    assert_in_delta ended, middle.offset[2] + middle.extent[2], 0.01, 'a lower panel goes up to where its front ended'
    assert_in_delta ended - 35.0 - 10.0, middle.offset[2], 0.01, 'and 10 mm down behind the shortened front'
    # a drawer over a door: the door has its gap too, and a door unit with two doors beside each other has one panel
    _, both = unit('base', 'base_drawer_door', 600, 'finger_pull' => true, 'finger_all' => true)
    _, normal = unit('base', 'base_drawer_door', 600)
    assert_in_delta normal.doors.first.extent[2] - 35.0, both.doors.first.extent[2], 0.01
    assert_equal 2, both.panels.count { |p| p.role.start_with?('finger_panel') }
    _, pair = unit('base', 'base_2door', 900, 'finger_pull' => true, 'finger_all' => true)
    assert_equal 1, pair.panels.count { |p| p.role.start_with?('finger_panel') }
    # fronts that are too small keep their height
    _, tiny = unit('base', 'base_3drawer', 600, 'finger_pull' => true, 'finger_all' => true, 'finger_gap' => 100, 'finger_gap_drawer' => 100, 'height' => '500')
    tiny.drawers.each { |d| assert_operator d.extent[2], :>=, 60.0 }
  end
end