# frozen_string_literal: true

# Runs the plugin's REAL ToeKick, PartLayout, ValidationManager, AttributeManager
# and PartManager (the parts that decide what a toe kick is and where it goes)
# outside SketchUp. Run:  ruby test/toe_kick_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end

  # PartManager only asks the model for its materials.
  FakeModel = Struct.new(:active_entities)
  def self.active_model = @active_model ||= FakeModel.new(:model_entities)
end

module KitchenCabinetMaster
  # Every material name is "in the model" for these tests.
  module MaterialManager
    def self.available?(_model, _name) = true
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
%w[response defaults attribute_manager toe_kick cabinet_layout part_layout validation_manager
   naming_manager cabinet_generator selection_manager part_manager].each do |f|
  begin
    require File.join(plugin, f)
  rescue NameError, LoadError => e
    warn "could not load #{f}: #{e.message}"
    raise
  end
end

# A fake placed entity: attribute dictionary, transformation, parent.
class FakeEntity < Sketchup::ComponentInstance
  attr_reader :transformation, :parent, :name

  def initialize(attrs, transformation = Geom::Transformation.new, parent = nil)
    super()
    @attrs = attrs
    @transformation = transformation
    @parent = parent
    @name = attrs['part_name'] || attrs['cabinet_name'] || 'fake'
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def respond_to_missing?(*) = true
end

class FakeParent
  attr_reader :entities

  def initialize = @entities = :parent_entities
end

class ToeKickTest < Minitest::Test
  include KitchenCabinetMaster

  def params(overrides = {})
    { 'toe_kick_height' => 100.0, 'toe_kick_thickness' => 18.0, 'toe_kick_piece_length' => 600.0,
      'toe_kick_pieces' => 3, 'toe_kick_recess' => 50.0, 'target_depth' => 560.0 }.merge(overrides)
  end

  def raw(overrides = {})
    { 'toe_kick_height' => '100', 'toe_kick_thickness' => '18', 'toe_kick_piece_length' => '600',
      'toe_kick_pieces' => '3', 'toe_kick_recess' => '50', 'toe_kick_material' => '__door__', 'depth' => '560' }.merge(overrides)
  end

  # ---- geometry -----------------------------------------------------------

  def test_pieces_are_laid_end_to_end_one_after_another
    pieces = ToeKick.pieces(params)

    assert_equal 3, pieces.length
    assert_equal [0.0, 600.0, 1200.0], pieces.map { |p| p.offset[1] }
    assert_equal [600.0] * 3, pieces.map { |p| p.extent[1] }
    assert_equal %w[toe_kick_1 toe_kick_2 toe_kick_3], pieces.map(&:role)
    assert_equal 1800.0, ToeKick.total_length(params)
  end

  def test_each_piece_is_thickness_by_height_and_on_the_floor
    pieces = ToeKick.pieces(params('toe_kick_thickness' => 22.0, 'toe_kick_height' => 150.0))
    pieces.each do |piece|
      assert_equal [22.0, 600.0, 150.0], piece.extent
      assert_equal 0.0, piece.offset[2], 'stands on the floor'
    end
  end

  def test_recess_sets_the_front_face_back_from_the_carcass_front
    # carcass 560 deep, recess 50, 18 thick: the piece spans X 492..510, its front face at 510 = 560 - 50.
    piece = ToeKick.pieces(params).first
    assert_in_delta 492.0, piece.offset[0], 1e-9
    assert_in_delta 560.0 - 50.0, piece.offset[0] + piece.extent[0], 1e-9

    deeper = ToeKick.pieces(params('toe_kick_recess' => 80.0)).first
    assert_in_delta 462.0, deeper.offset[0], 1e-9, 'a bigger recess moves it back'

    none = ToeKick.pieces(params('toe_kick_recess' => 0.0)).first
    assert_in_delta 542.0, none.offset[0], 1e-9, 'no recess: flush with the carcass front'
  end

  def test_custom_length_and_count
    pieces = ToeKick.pieces(params('toe_kick_piece_length' => 743.5, 'toe_kick_pieces' => 2))
    assert_equal [0.0, 743.5], pieces.map { |p| p.offset[1] }
    assert_in_delta 1487.0, ToeKick.total_length(params('toe_kick_piece_length' => 743.5, 'toe_kick_pieces' => 2)), 1e-9
  end

  def test_no_pieces_without_a_height_length_or_count
    assert_empty ToeKick.pieces(params('toe_kick_height' => 0.0))
    assert_empty ToeKick.pieces(params('toe_kick_pieces' => 0))
    assert_empty ToeKick.pieces(params('toe_kick_piece_length' => 0.0))
  end

  # ---- the cabinet no longer carries one -----------------------------------------

  def test_a_cabinet_has_no_toe_kick_but_still_stands_on_the_toe_kick_height
    cabinet = Defaults.params.merge('cabinet_category' => 'base', 'width' => 600.0, 'depth' => 560.0,
                                    'height' => 780.0, 'door_count' => 1, 'toe_kick_height' => 100.0)
    layout = CabinetLayout.compute(cabinet)
    assert_empty layout.toe_kick, 'the toe kick is a separate entity'
    assert_equal 100.0, layout.base_z
    assert_equal 880.0, layout.top_z
  end

  def test_a_filler_has_no_toe_kick
    filler = Defaults.filler_params.merge('target_base_z' => 100.0, 'target_flush_x' => 580.0)
    layout = PartLayout.filler(filler)
    assert_empty layout.toe_kick
    assert_equal 100.0, layout.base_z, 'stands as high off the floor as the cabinet it goes beside'
  end

  def test_the_toe_kick_layout_is_pieces_only
    layout = PartLayout.toe_kick(params)
    assert_nil layout.board
    assert_equal 3, layout.toe_kick.length
    assert_equal 100.0, layout.top_z
  end

  # ---- validation ------------------------------------------------------------------

  def test_valid_values_pass_and_are_converted
    result = ValidationManager.validate_toe_kick(raw)
    assert_empty result.errors
    assert_equal 3, result.params['toe_kick_pieces']
    assert_equal 600.0, result.params['toe_kick_piece_length']
    assert_equal 50.0, result.params['toe_kick_recess']
    assert_equal 'toe_kick', result.params['part_kind']
  end

  def test_bad_values_are_reported_by_field
    fields = lambda do |overrides|
      ValidationManager.validate_toe_kick(raw(overrides)).errors.map { |e| e['field'] }
    end

    assert_includes fields.call('toe_kick_pieces' => '0'), 'toe_kick_pieces'
    assert_includes fields.call('toe_kick_pieces' => '2.5'), 'toe_kick_pieces'
    assert_includes fields.call('toe_kick_pieces' => ''), 'toe_kick_pieces'
    assert_includes fields.call('toe_kick_piece_length' => ''), 'toe_kick_piece_length'
    assert_includes fields.call('toe_kick_piece_length' => 'abc'), 'toe_kick_piece_length'
    assert_includes fields.call('toe_kick_recess' => '-5'), 'toe_kick_recess'
    assert_includes fields.call('toe_kick_thickness' => '1'), 'toe_kick_thickness'
    assert_includes fields.call('toe_kick_height' => '0'), 'toe_kick_height'
    assert_empty fields.call('toe_kick_recess' => '0'), 'zero recess is allowed'
  end

  # ---- what counts as an occupant ---------------------------------------------------

  def test_a_toe_kick_never_blocks_a_cabinet
    toe_kick = FakeEntity.new('part_id' => 'PART_0001', 'part_kind' => 'toe_kick')
    filler = FakeEntity.new('part_id' => 'PART_0002', 'part_kind' => 'filler')
    cabinet = FakeEntity.new('cabinet_id' => 'CABINET_0001')

    refute AttributeManager.occupant?(toe_kick)
    assert AttributeManager.part?(toe_kick), 'but it is still a part, so it can be selected and edited'
    assert AttributeManager.occupant?(filler)
    assert AttributeManager.occupant?(cabinet)
  end

  # ---- what it is placed against ---------------------------------------------------

  def target(anchor, overrides = {})
    PartManager.send(:toe_kick_target, { 'depth' => '560' }.merge(overrides), anchor)
  end

  def test_with_nothing_selected_it_uses_the_panels_depth_and_the_default_material
    t = target(nil, 'depth' => '620')
    assert_equal 620.0, t['target_depth']
    assert_equal Defaults::DEFAULT_MATERIAL, t['target_door_material'], 'nothing selected: plain white'

    assert_equal Defaults::DEFAULT_TOE_KICK_DEPTH, target(nil, 'depth' => '')['target_depth']
  end

  def test_against_a_cabinet_it_takes_the_cabinets_depth_and_colours
    cabinet = FakeEntity.new('cabinet_id' => 'CABINET_0001', 'cabinet_category' => 'base', 'depth' => 580.0,
                             'width' => 800.0, 'material' => 'Oak', 'carcass_material' => 'Grey')
    t = target(cabinet)
    assert_equal 580.0, t['target_depth']
    assert_equal 'Oak', t['target_door_material']
    assert_equal 'Grey', t['target_carcass_material']
  end

  def test_against_a_corner_unit_it_uses_the_square_not_the_return_depth
    corner = FakeEntity.new('cabinet_id' => 'CABINET_0002', 'cabinet_category' => 'corner', 'depth' => 600.0,
                            'width' => 900.0, 'material' => 'Oak')
    assert_equal 900.0, target(corner)['target_depth']
  end

  # ---- the "door material \"\" was not found" errors -----------------------------------

  def test_a_corner_unit_uses_whatever_the_base_unit_door_material_is
    refute Defaults.params.key?('corner_material'), 'a corner has no material setting of its own'

    corner = Defaults.params.merge('cabinet_category' => 'corner')
    assert_equal Defaults::DEFAULT_MATERIAL, CabinetGenerator.door_material(corner), 'the initial colour is the same plain white'
    assert_equal 'Oak', CabinetGenerator.door_material(corner.merge('base_material' => 'Oak')), 'the Base Unit choice applies'
    assert_equal 'Oak', CabinetGenerator.door_material(corner.merge('base_material' => 'Oak', 'wall_material' => 'Walnut')),
                 'not the wall or tall choice'
    assert_equal 'Oak', CabinetGenerator.door_material(corner.merge('base_material' => 'Oak', 'corner_material' => 'Walnut')),
                 'a leftover corner setting from an older cabinet is ignored'
    assert_equal Defaults::DEFAULT_MATERIAL, CabinetGenerator.door_material(corner.merge('base_material' => '')), 'blank falls back, never ""'
    assert_equal 'Grey', CabinetGenerator.door_material(corner.merge('cabinet_material' => 'Grey')), 'an override still wins'

    tall = Defaults.params.merge('cabinet_category' => 'tall', 'base_material' => 'Oak', 'tall_material' => 'Walnut')
    assert_equal 'Walnut', CabinetGenerator.door_material(tall), 'other categories keep their own'
  end

  def test_a_corner_can_be_validated_without_choosing_a_material
    raw = { 'catalog_id' => 'x', 'cabinet_category' => 'corner', 'cabinet_type' => 'y', 'width' => '900', 'depth' => '600',
            'height' => '720', 'door_opening_direction' => 'left', 'toe_kick_height' => '100', 'base_material' => '' }
    result = ValidationManager.validate(raw)
    assert_empty(result.errors.select { |e| e['field'].to_s.end_with?('material') })
    assert_equal Defaults::DEFAULT_MATERIAL, CabinetGenerator.door_material(result.params)

    chosen = ValidationManager.validate(raw.merge('base_material' => 'Walnut'))
    assert_equal 'Walnut', CabinetGenerator.door_material(chosen.params), 'the corner door follows the Base Unit choice'
  end

  def test_a_toe_kick_follows_the_door_material_and_never_ends_up_blank
    assert_equal 'Oak', ToeKick.material_name({ 'toe_kick_material' => '__door__' }, 'Oak', 'Grey')
    assert_equal 'Grey', ToeKick.material_name({ 'toe_kick_material' => '__carcass__' }, 'Oak', 'Grey')
    assert_equal 'PVC Black', ToeKick.material_name({ 'toe_kick_material' => 'PVC Black' }, 'Oak', 'Grey')
    assert_equal Defaults::DEFAULT_MATERIAL, ToeKick.material_name({ 'toe_kick_material' => '__door__' }, '', ''), 'nothing to follow: white'
    assert_equal Defaults::DEFAULT_MATERIAL, ToeKick.material_name({ 'toe_kick_material' => '__door__' }, nil, nil)
  end

  def test_a_toe_kick_against_an_old_cabinet_with_no_recorded_material_still_works
    old_corner = FakeEntity.new('cabinet_id' => 'CABINET_0003', 'cabinet_category' => 'corner', 'depth' => 600.0,
                                'width' => 900.0, 'material' => '', 'corner_material' => '')
    t = target(old_corner)
    assert_equal Defaults::DEFAULT_MATERIAL, t['target_door_material']
    assert_equal Defaults::DEFAULT_MATERIAL, t['target_carcass_material']

    fits = PartManager.send(:toe_kick_fit_errors, Sketchup.active_model, params.merge(t))
    assert_empty fits, 'no "door material was not found" error'
  end

  def test_a_second_toe_kick_carries_on_with_the_first_ones_target
    first = FakeEntity.new('part_id' => 'PART_0001', 'part_kind' => 'toe_kick', 'target_depth' => 575.0,
                           'target_door_material' => 'Oak', 'target_carcass_material' => 'Grey')
    t = target(first, 'depth' => '999')
    assert_equal 575.0, t['target_depth'], 'the run keeps one line, whatever the panel says'
    assert_equal 'Oak', t['target_door_material']
  end

  def test_placement_against_a_cabinet_starts_at_its_origin
    cabinet_move = Geom::Transformation.translation(Geom::Vector3d.new(1000, 2000, 0))
    cabinet = FakeEntity.new({ 'cabinet_id' => 'CABINET_0001' }, cabinet_move, FakeParent.new)
    entities, transformation = PartManager.send(:toe_kick_placement, Sketchup.active_model, cabinet)

    assert_equal :parent_entities, entities
    assert_in_delta 1000.0, transformation.origin.x, 1e-9
    assert_in_delta 2000.0, transformation.origin.y, 1e-9
  end

  def test_placement_after_a_toe_kick_starts_where_it_ends_even_when_turned
    turn = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), -Math::PI / 2)
    place = Geom::Transformation.translation(Geom::Vector3d.new(0, 1500, 0)) * turn
    first = FakeEntity.new({ 'part_id' => 'PART_0001', 'part_kind' => 'toe_kick', 'width' => 1800.0 }, place, FakeParent.new)

    _entities, next_start = PartManager.send(:toe_kick_placement, Sketchup.active_model, first)

    # The run heads along the first one's own Y axis, which the turn points along +X.
    assert_in_delta 1800.0, next_start.origin.x, 1e-6
    assert_in_delta 1500.0, next_start.origin.y, 1e-6
  end

  def test_placement_with_nothing_selected_is_the_origin_of_the_model
    entities, transformation = PartManager.send(:toe_kick_placement, Sketchup.active_model, nil)
    assert_equal :model_entities, entities
    assert_in_delta 0.0, transformation.origin.x
  end

  def test_names_say_the_length_and_count
    assert_equal 'TK600x3', NamingManager.toe_kick_name(params)
    assert_equal 'TK743.5x2', NamingManager.toe_kick_name(params('toe_kick_piece_length' => 743.5, 'toe_kick_pieces' => 2))
  end

  def test_recess_that_leaves_no_room_is_rejected
    too_much = params('toe_kick_recess' => 550.0, 'target_depth' => 560.0)
    problems = PartManager.send(:toe_kick_fit_errors, Sketchup.active_model, too_much)
    assert_equal ['toe_kick_recess'], problems.map { |e| e['field'] }

    assert_empty PartManager.send(:toe_kick_fit_errors, Sketchup.active_model, params('target_door_material' => 'Oak'))
  end

  # ---- following a row round a corner -------------------------------------

  # A (600 wide, 560 deep) -> corner (900 square, turned -90) -> B (600 wide, 560 deep)
  def row
    anchor = { x: 0.0, y: 0.0, angle: 0.0, width: 600.0, depth: 560.0, corner: false }
    items = [
      { x: 0.0, y: 1500.0, angle: -90.0, width: 900.0, depth: 900.0, corner: true },
      { x: 900.0, y: 1500.0, angle: -90.0, width: 600.0, depth: 560.0, corner: false }
    ]
    [anchor, items]
  end

  def test_turns_are_found_where_the_row_turns_a_corner
    turns = ToeKick.turns_from(*row, 50.0)
    assert_equal [[990.0, -90.0]], turns
  end

  def test_a_straight_row_has_no_turns
    anchor = { x: 0.0, y: 0.0, angle: 0.0, width: 600.0, depth: 560.0, corner: false }
    next_one = { x: 0.0, y: 600.0, angle: 0.0, width: 800.0, depth: 560.0, corner: false }
    assert_empty ToeKick.turns_from(anchor, [next_one], 50.0)
  end

  def test_a_cabinet_that_does_not_join_on_stops_the_path
    anchor, items = row
    items[0][:y] = 5000.0
    assert_empty ToeKick.turns_from(anchor, items, 50.0)
  end

  def test_pieces_turn_the_corner_with_the_row
    pieces = ToeKick.pieces(params('toe_kick_pieces' => 4, 'toe_kick_turns' => [[990.0, -90.0]]))
    assert_equal 4, pieces.length
    assert_equal [600.0, 390.0, 600.0, 600.0], pieces.map { |p| p.extent[1] }
    assert_equal [0.0, 0.0, -90.0, -90.0], pieces.map { |p| p.rotation.to_f }
    assert_equal [492.0, 600.0], pieces[1].offset.first(2)
    assert_equal [492.0, 1008.0], pieces[2].offset.first(2)
    assert_equal [1092.0, 1008.0], pieces[3].offset.first(2)
  end

  def test_turns_can_be_stored_as_json_text
    text = JSON.generate([[990.0, -90.0]])
    assert_equal [[990.0, -90.0]], ToeKick.turns_of('toe_kick_turns' => text)
    assert_empty ToeKick.turns_of('toe_kick_turns' => '')
  end

  def test_a_toe_kick_over_a_whole_row_is_cut_into_pieces_of_the_chosen_length
    pieces = ToeKick.pieces(params('toe_kick_piece_length' => 2000.0, 'toe_kick_pieces' => 1, 'toe_kick_total' => 5200.0))
    assert_equal [2000.0, 2000.0, 1200.0], pieces.map { |p| p.extent[1] }, 'the last piece takes what is left'
    assert_equal [0.0, 2000.0, 4000.0], pieces.map { |p| p.offset[1] }
    assert_equal 5200.0, ToeKick.total_length(params('toe_kick_total' => 5200.0))
  end

  def test_the_length_of_a_row_is_its_widths_added_up
    anchor = { x: 0.0, y: 0.0, width: 600.0 }
    items = [{ x: 0.0, y: 600.0, width: 800.0, angle: 0.0 }, { x: 0.0, y: 1400.0, width: 400.0, angle: 0.0 },
             { x: 0.0, y: 5000.0, width: 600.0, angle: 0.0 }] # the last one is not joined on
    assert_equal 1800.0, ToeKick.run_length(anchor, items)
  end
  def test_a_room_left_between_two_units_for_a_side_panel_is_plinth_too
    anchor = { x: 0.0, y: 0.0, width: 600.0 }
    items = [{ x: 0.0, y: 618.0, width: 800.0, angle: 0.0 }, { x: 0.0, y: 1418.0, width: 400.0, angle: 0.0 }]
    assert_equal 1818.0, ToeKick.run_length(anchor, items), 'the 18 mm between the first two units counts'
  end

  def test_a_toe_kick_stops_at_the_inner_face_of_a_side_panel_and_never_runs_into_it
    touching = [{ y: -18.0, thickness: 18.0, base: 0.0 }, { y: 1800.0, thickness: 18.0, base: 0.0 }]
    assert_equal [0.0, 0.0], ToeKick.panel_reach(touching, 1800.0), 'the panels touch the ends of the row: nothing to add'
  end

  def test_a_toe_kick_reaches_a_side_panel_that_stands_a_little_way_off
    apart = [{ y: -36.0, thickness: 18.0, base: 0.0 }, { y: 1818.0, thickness: 18.0, base: 0.0 }]
    assert_equal [18.0, 18.0], ToeKick.panel_reach(apart, 1800.0), 'to the inner faces, which are 18 mm away'
    assert_equal [18.0, 0.0], ToeKick.panel_reach(apart.first(1), 1800.0)
  end

  def test_a_panel_that_does_not_reach_the_floor_or_is_somewhere_else_does_not_make_the_toe_kick_longer
    floating = { y: -18.0, thickness: 18.0, base: 100.0 }
    elsewhere = { y: 900.0, thickness: 18.0, base: 0.0 }
    assert_equal [0.0, 0.0], ToeKick.panel_reach([floating, elsewhere], 1800.0)
  end
end