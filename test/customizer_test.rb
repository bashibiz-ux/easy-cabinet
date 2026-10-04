# frozen_string_literal: true

# The Customize window's data and what a change does to a cabinet's layout. Run:  ruby test/customizer_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager validation_manager cabinet_layout customizer].each { |f| require File.join(plugin, f) }

class CustomizerTest < Minitest::Test
  include KitchenCabinetMaster

  def params(extra = {})
    Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0, 'height' => 780.0, 'door_count' => 0,
                          'drawer_count' => 3, 'toe_kick_height' => 100.0, 'material_thickness' => 18.0, 'back_thickness' => 6.0).merge(extra)
  end

  def part(parts, key) = parts.find { |item| item['key'] == key }

  def test_every_board_of_a_cabinet_is_listed_with_its_size_and_place
    parts = Customizer.parts(params)
    keys = parts.map { |item| item['key'] }
    assert_equal keys.uniq, keys, 'keys are unique'
    %w[left_side right_side back bottom drawer_1 drawer_2 drawer_3 drawer_1_box_left drawer_1_box_front].each { |key| assert_includes keys, key }
    left = part(parts, 'left_side')
    assert_equal 'carcass', left['group']
    assert_equal [560.0, 18.0, 780.0], left['size']
    assert_equal [0.0, 0.0, 100.0], left['origin'], 'standing on the toe kick'
    assert_equal 'drawer_box', part(parts, 'drawer_1_box_left')['group']
    assert_equal false, left['custom']
  end

  def test_a_shaped_board_is_listed_with_its_outline
    parts = Customizer.parts(params('corner_style' => 'l_shape', 'drawer_count' => 0, 'door_count' => 2, 'width' => 900.0))
    bottom = part(parts, 'bottom')
    assert bottom['shaped']
    assert_equal 6, bottom['points'].length
    assert_equal 18.0, bottom['size'][2]
  end

  def test_a_change_resizes_and_moves_a_part_and_the_rest_keeps_following_the_cabinet
    change = { 'left_side' => { 'extent' => [nil, nil, 500.0], 'move' => [0.0, 0.0, 50.0] } }
    layout = CabinetLayout.compute(params('custom_overrides' => change))
    side = layout.panels.find { |item| item.role == 'left_side' }
    assert_equal [560.0, 18.0, 500.0], side.extent, 'only the height changed'
    assert_equal [0.0, 0.0, 50.0], side.offset
    wider = CabinetLayout.compute(params('width' => 800.0, 'custom_overrides' => change))
    assert_equal [560.0, 18.0, 500.0], wider.panels.find { |item| item.role == 'left_side' }.extent
    assert_equal 764.0, wider.panels.find { |item| item.role == 'bottom' }.extent[1], 'the others follow the new width'
    listed = part(Customizer.parts(params('custom_overrides' => change)), 'left_side')
    assert_equal [560.0, 18.0, 780.0], listed['base_size'], 'the size without the change is kept for the window'
    assert listed['custom']
    assert_equal [0.0, 0.0, 50.0], listed['move']
  end

  def test_doors_and_drawer_boxes_can_be_changed_and_a_door_takes_its_hinge_with_it
    layout = CabinetLayout.compute(params('drawer_count' => 0, 'door_count' => 1,
                                          'custom_overrides' => { 'door_1' => { 'extent' => [nil, nil, 600.0], 'move' => [0.0, 10.0, 0.0] } }))
    door = layout.doors.first
    plain = CabinetLayout.compute(params('drawer_count' => 0, 'door_count' => 1)).doors.first
    assert_equal 600.0, door.extent[2]
    assert_in_delta plain.pivot[1] + 10.0, door.pivot[1], 1e-9
    boxed = CabinetLayout.compute(params('custom_overrides' => { 'drawer_1_box_left' => { 'extent' => [300.0, nil, nil], 'move' => [0.0, 0.0, 0.0] } }))
    assert_equal 300.0, boxed.drawer_boxes['drawer_1'].find { |item| item.role.end_with?('left') }.extent[0]
  end

  def test_a_shaped_board_changes_only_its_thickness_and_place
    base = params('corner_style' => 'l_shape', 'drawer_count' => 0, 'door_count' => 2, 'width' => 900.0)
    layout = CabinetLayout.compute(base.merge('custom_overrides' => { 'bottom' => { 'extent' => [999.0, 999.0, 25.0], 'move' => [5.0, 0.0, 0.0] } }))
    bottom = layout.panels.find { |item| item.role == 'bottom' }
    plain = CabinetLayout.compute(base).panels.find { |item| item.role == 'bottom' }
    assert_equal 25.0, bottom.extent[2]
    assert_equal plain.points.first[0] + 5.0, bottom.points.first[0]
    assert_nil bottom.extent[0]
  end

  def test_changes_are_cleaned_and_can_be_added_and_taken_back
    assert_equal({}, ValidationManager.clean_overrides('nonsense'))
    assert_equal({}, ValidationManager.clean_overrides('left_side' => { 'extent' => [nil, nil, nil], 'move' => [0, 0, 0] }), 'a change that changes nothing is dropped')
    clean = ValidationManager.clean_overrides('Bad Key' => { 'move' => [1, 2, 3] }, 'left_side' => { 'extent' => ['-5', '20', nil], 'move' => ['1', 'x'] })
    assert_equal({ 'left_side' => { 'extent' => [nil, 20.0, nil], 'move' => [1.0, 0.0, 0.0] } }, clean)
    one = Customizer.with_change({}, 'back', [nil, 500, nil], [0, 0, 0])
    two = Customizer.with_change(one, 'top', [nil, nil, 25], [0, 0, 0])
    assert_equal %w[back top], two.keys
    assert_equal %w[top], Customizer.without(two, 'back').keys
  end
end
