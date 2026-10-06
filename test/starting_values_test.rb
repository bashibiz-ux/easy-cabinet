# frozen_string_literal: true

# What a new item starts as, and that an open shelf unit lines up with the doors
# beside it.  Run:  ruby test/starting_values_test.rb

require 'json'
require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout catalog_manager handle_manager].each { |f| require File.join(plugin, f) }

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
    base = CatalogManager.cabinets('kitchen_cabinets', 'base')
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

  # ---- where the handle goes ------------------------------------------------------

  BAR = { 'profile' => 'bar', 'lengths' => [160], 'section' => 10, 'projection' => 30 }.freeze

  def handle_spot(category, height, position: 'auto')
    params = Defaults.params.merge('cabinet_category' => category, 'width' => 600.0, 'depth' => 560.0, 'height' => height,
                                   'door_count' => 1, 'toe_kick_height' => category == 'wall' ? 0.0 : 100.0,
                                   'handle_length' => 160.0, 'handle_orientation' => 'vertical', 'handle_position' => position,
                                   'handle_side_offset' => 35.0, 'handle_vertical_offset' => 80.0)
    door = CabinetLayout.compute(params).doors.first
    spot = HandleManager.placement(door, HandleManager.settings(params, BAR), BAR)
    [spot, door]
  end

  def test_a_base_unit_handle_is_near_the_top_of_its_door
    spot, door = handle_spot('base', 780.0)
    assert_in_delta door.extent[2] - 80.0 - 80.0, spot['v'], 1e-9, '80 mm below the top edge to the top of the handle'
  end

  def test_a_wall_unit_handle_is_near_the_bottom_of_its_door
    spot, = handle_spot('wall', 720.0)
    assert_in_delta 80.0 + 80.0, spot['v'], 1e-9
  end

  def test_a_tall_unit_handle_is_at_hand_height
    spot, door = handle_spot('tall', 2100.0)
    height_from_floor = door.offset[2] + spot['v']
    assert_in_delta 1050.0, height_from_floor, 1e-9, 'about a metre up, not at the top of the door'
  end

  def test_a_handle_position_chosen_by_hand_is_kept
    spot, door = handle_spot('wall', 720.0, position: 'top')
    assert_in_delta door.extent[2] - 80.0 - 80.0, spot['v'], 1e-9
    centred, door2 = handle_spot('tall', 2100.0, position: 'center')
    assert_in_delta door2.extent[2] / 2.0, centred['v'], 1e-9
  end

  def test_a_cabinet_stored_without_a_position_gets_the_unit_type_placement
    spot, door = handle_spot('base', 780.0, position: '')
    assert_in_delta door.extent[2] - 160.0, spot['v'], 1e-9
  end

  def test_the_panel_offers_by_unit_type_first
    assert_equal 'auto', Defaults::HANDLE_POSITIONS.first['id']
    assert_equal 'auto', Defaults::HANDLE_DEFAULTS['position']
  end

  def test_the_handle_offsets_start_at_25_mm
    assert_equal 25.0, Defaults::HANDLE_DEFAULTS['side_offset']
    assert_equal 25.0, Defaults::HANDLE_DEFAULTS['vertical_offset']
  end

  # ---- the top of an open unit ------------------------------------------------------

  def test_an_open_unit_has_one_full_top_panel_and_a_closed_base_unit_two_rails
    open, = layout_for(0)
    assert_includes open.panels.map(&:role), 'top'
    refute(open.panels.any? { |p| p.role.include?('rail') })
    closed, = layout_for(1)
    assert(closed.panels.any? { |p| p.role.include?('rail') })
    refute_includes closed.panels.map(&:role), 'top'
  end

  def test_a_unit_with_drawers_is_not_treated_as_open
    drawers, = layout_for(0, 'drawer_count' => 3)
    assert(drawers.panels.any? { |p| p.role.include?('rail') }, 'a front means rails, like a door unit')
    assert_in_delta 560.0, drawers.panels.find { |p| p.role == 'left_side' }.then { |p| front(p) }, 1e-9, 'its sides stop at the drawer fronts'
  end

  # ---- one position, and a horizontal handle in the middle of the door ------------------

  def test_by_unit_type_is_the_only_position_offered
    assert_equal ['auto'], Defaults::HANDLE_POSITIONS.map { |p| p['id'] }
  end

  def test_a_cabinet_that_still_has_an_old_position_keeps_working
    %w[top center bottom left right custom].each { |old| assert_includes Defaults.handle_position_ids, old }
  end

  def test_a_horizontal_handle_can_be_centred_across_the_door_at_the_top
    params = Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0,
                                   'door_count' => 1, 'toe_kick_height' => 100.0, 'handle_length' => 160.0,
                                   'handle_orientation' => 'horizontal', 'handle_position' => 'auto',
                                   'handle_side_offset' => 25.0, 'handle_vertical_offset' => 25.0)
    door = CabinetLayout.compute(params).doors.first
    edge = HandleManager.placement(door, HandleManager.settings(params.merge('handle_horizontal_place' => 'edge'), BAR), BAR)
    middle = HandleManager.placement(door, HandleManager.settings(params.merge('handle_horizontal_place' => 'middle'), BAR), BAR)
    assert_in_delta door.extent[2] - 25.0 - 5.0, edge['v'], 1e-9, 'at the edge: near the top, as before'
    assert_in_delta door.extent[1] - 25.0 - 80.0, edge['u'], 1e-9
    assert_in_delta door.extent[1] / 2.0, middle['u'], 1e-9, 'centred across the door'
    assert_in_delta edge['v'], middle['v'], 1e-9, 'still at the top of the door, the same height as at the edge'
    assert_in_delta door.extent[2] - 25.0 - 5.0, middle['v'], 1e-9, 'the bottom offset below the top edge'
    assert middle['horizontal']
  end

  def test_the_middle_choice_does_nothing_to_a_vertical_handle
    params = Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0,
                                   'door_count' => 1, 'toe_kick_height' => 100.0, 'handle_length' => 160.0,
                                   'handle_orientation' => 'vertical', 'handle_position' => 'auto',
                                   'handle_side_offset' => 25.0, 'handle_vertical_offset' => 25.0)
    door = CabinetLayout.compute(params).doors.first
    plain = HandleManager.placement(door, HandleManager.settings(params, BAR), BAR)
    asked = HandleManager.placement(door, HandleManager.settings(params.merge('handle_horizontal_place' => 'middle'), BAR), BAR)
    assert_equal plain, asked
  end

  def test_the_horizontal_places_are_validated_and_listed
    assert_equal %w[edge middle], Defaults::HANDLE_HORIZONTAL_PLACES.map { |p| p['id'] }
    assert_equal 'middle', Defaults::HANDLE_DEFAULTS['horizontal_place']
  end
end
