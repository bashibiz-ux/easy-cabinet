# frozen_string_literal: true

# Runs the plugin's REAL filler and end panel logic (PartLayout, PartManager's
# placement and material rules, PartGenerator's stored footprint, validation)
# outside SketchUp. Run:  ruby test/filler_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end
  FakeModel = Struct.new(:active_entities)
  def self.active_model = @active_model ||= FakeModel.new(:model_entities)
end

module KitchenCabinetMaster
  DATA_DIR = 'unused'

  module MaterialManager
    def self.available?(_model, _name) = true
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager toe_kick cabinet_layout part_layout validation_manager naming_manager
   placement_manager cabinet_generator selection_manager part_generator part_manager].each { |f| require File.join(plugin, f) }

class FakeThing < Sketchup::ComponentInstance
  attr_reader :transformation, :attrs, :parent, :name

  def initialize(attrs, transformation, parent)
    super()
    @attrs = attrs
    @transformation = transformation
    @parent = parent
    @name = attrs['cabinet_name'] || attrs['part_name'] || 'fake'
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
end

class FakeEntities
  def initialize = @items = []
  def add(item) = @items << item
  def grep(klass) = @items.grep(klass)
end

class FakeParent
  attr_reader :entities

  def initialize(entities) = @entities = entities
end

class FillerTest < Minitest::Test
  include KitchenCabinetMaster

  def setup
    @entities = FakeEntities.new
    @parent = FakeParent.new(@entities)
  end

  # A placed 600 x 560 base cabinet standing 100 mm off the floor, 18 mm panels.
  def cabinet(y: 0.0, width: 600.0, sequence: 1, **extra)
    params = Defaults.params.merge('cabinet_category' => 'base', 'width' => width, 'depth' => 560.0, 'height' => 780.0,
                                   'door_count' => 1, 'toe_kick_height' => 100.0)
    layout = CabinetLayout.compute(params)
    env = CabinetLayout.envelope(params)
    attrs = params.merge('cabinet_id' => "CABINET_#{sequence}", 'cabinet_name' => "BU#{width.to_i}", 'sequence' => sequence,
                         'material' => 'Oak', 'base_z' => layout.base_z, 'top_z' => layout.top_z,
                         'envelope_depth' => env[0], 'envelope_width' => env[1], 'envelope_top' => env[2])
                  .merge(extra.transform_keys(&:to_s))
    move = Geom::Transformation.translation(Geom::Vector3d.new(0, y, 0))
    thing = FakeThing.new(attrs, move, @parent)
    @entities.add(thing)
    thing
  end

  def filler_params(target, overrides = {})
    { 'width' => 100.0, 'thickness' => 18.0, 'height' => 780.0, 'material' => 'Oak' }
      .merge(overrides)
      .merge(PartManager.send(:filler_target, target, AttributeManager.read(target)))
  end

  # ---- geometry -----------------------------------------------------------------

  def test_the_target_is_read_from_the_cabinet_once
    t = PartManager.send(:filler_target, cabinet, AttributeManager.read(cabinet))
    assert_equal 560.0, t['target_depth']
    assert_equal 100.0, t['target_base_z'], 'stands as high off the floor as the cabinet'
    assert_equal 600.0, t['target_width']
    # door front = carcass depth + door clearance (2) + door thickness (18)
    assert_in_delta 580.0, t['target_flush_x'], 1e-9
  end

  def test_the_filler_is_flush_with_the_door_at_the_cabinets_height_off_the_floor
    params = filler_params(cabinet)
    board = PartLayout.filler(params).board

    assert_equal [18.0, 100.0, 780.0], board.extent, 'thickness x width x height'
    assert_in_delta 580.0, board.offset[0] + board.extent[0], 1e-9, 'front face level with the door front'
    assert_in_delta 562.0, board.offset[0], 1e-9
    assert_equal 100.0, board.offset[2], 'same base height as the cabinet'
    assert_equal 880.0, PartLayout.filler(params).top_z
  end

  def test_thickness_is_what_sets_how_far_back_it_reaches
    board = PartLayout.filler(filler_params(cabinet, 'thickness' => 30.0)).board
    assert_in_delta 580.0, board.offset[0] + board.extent[0], 1e-9, 'front stays flush'
    assert_in_delta 550.0, board.offset[0], 1e-9
  end

  def test_a_wall_unit_filler_hangs_at_the_wall_units_height
    wall = cabinet(cabinet_category: 'wall', base_z: 0.0, top_z: 720.0)
    assert_equal 0.0, filler_params(wall)['target_base_z']
  end

  def test_the_corner_units_filler_is_flush_with_the_square
    corner = cabinet(cabinet_category: 'corner', width: 900.0, depth: 600.0)
    assert_equal 900.0, PartManager.send(:filler_target, corner, AttributeManager.read(corner))['target_flush_x']
  end

  def test_the_stored_footprint_reaches_from_the_origin_to_the_front_face
    params = filler_params(cabinet)
    attrs = PartGenerator.send(:attributes_for, params, PartLayout.filler(params))
    assert_in_delta 580.0, attrs['envelope_depth'], 1e-9
    assert_equal 100.0, attrs['envelope_width']
    assert_equal 880.0, attrs['envelope_top']
    assert_equal 100.0, attrs['width'], 'the width a following cabinet is placed after'
  end

  # ---- which side ------------------------------------------------------------------

  def side_of(target, params)
    _t, side, problem = PartManager.send(:filler_placement, target, params)
    [side, problem]
  end

  def test_a_lone_cabinet_gets_its_filler_on_the_right
    target = cabinet
    side, problem = side_of(target, filler_params(target))
    assert_equal 'right', side
    assert_nil problem
  end

  def test_the_filler_goes_on_the_free_side
    left = cabinet(y: 0.0, sequence: 1)
    middle = cabinet(y: 600.0, sequence: 2)
    # `left` has a cabinet on its right, so the wall side is its left ...
    assert_equal ['left', nil], side_of(left, filler_params(left))
    # ... and `middle` has one on its left, so the right.
    assert_equal ['right', nil], side_of(middle, filler_params(middle))
  end

  def test_the_right_side_position_touches_the_cabinet
    target = cabinet
    params = filler_params(target)
    transformation, side, = PartManager.send(:filler_placement, target, params)
    assert_equal 'right', side
    assert_in_delta 600.0, transformation.origin.y, 1e-9, 'starts where the cabinet ends'
  end

  def test_the_left_side_position_ends_where_the_cabinet_starts
    left = cabinet(y: 0.0, sequence: 1)
    cabinet(y: 600.0, sequence: 2)
    transformation, side, = PartManager.send(:filler_placement, left, filler_params(left, 'width' => 75.0))
    assert_equal 'left', side
    assert_in_delta(-75.0, transformation.origin.y, 1e-9, 'its right edge touches the cabinet')
  end

  def test_no_room_on_either_side_is_reported
    middle = cabinet(y: 600.0, sequence: 2)
    cabinet(y: 0.0, sequence: 1)
    cabinet(y: 1200.0, sequence: 3)
    side, problem = side_of(middle, filler_params(middle))
    assert_nil side
    assert_match(/Both sides/, problem)
  end

  # ---- cabinet lookup and material -------------------------------------------------------

  def test_with_no_selection_it_goes_against_the_last_cabinet_inserted
    first = cabinet(y: 3000.0, sequence: 1)
    last = cabinet(y: 0.0, sequence: 2)
    filler = FakeThing.new({ 'part_id' => 'PART_1', 'part_kind' => 'filler', 'sequence' => 3 },
                           Geom::Transformation.new, @parent)
    @entities.add(filler)

    found = PlacementManager.last_cabinet(Sketchup::FakeModel.new(@entities))
    assert_same last, found, 'a filler is never taken as the cabinet'
    refute_same first, found
  end

  def test_a_blank_material_follows_the_cabinets_door
    stored = AttributeManager.read(cabinet)
    filled = PartManager.send(:with_default_material, { 'material' => '', 'width' => '50' }, stored)
    assert_equal 'Oak', filled['material']

    chosen = PartManager.send(:with_default_material, { 'material' => 'Walnut' }, stored)
    assert_equal 'Walnut', chosen['material'], 'an entered material is kept'

    assert_equal 'White', PartManager.send(:with_default_material, {}, { 'cabinet_category' => 'base' })['material'],
                 'nothing to follow: plain white'
  end

  # ---- validation ---------------------------------------------------------------------------

  def test_filler_validation
    ok = ValidationManager.validate_filler('width' => '50', 'thickness' => '18', 'height' => '780', 'material' => 'Oak')
    assert_empty ok.errors
    assert_equal 50.0, ok.params['width']
    assert_equal 18.0, ok.params['thickness']

    bad = ->(overrides) { ValidationManager.validate_filler({ 'width' => '50', 'thickness' => '18', 'height' => '780' }.merge(overrides)).errors.map { |e| e['field'] } }
    assert_includes bad.call('width' => '2'), 'width'
    assert_includes bad.call('width' => ''), 'width'
    assert_includes bad.call('thickness' => '1'), 'thickness'
    assert_includes bad.call('height' => 'tall'), 'height'
    assert_empty bad.call('width' => '5'), 'a narrow gap filler is fine'
  end

  def test_filler_defaults_match_the_request
    d = Defaults.filler_params
    assert_equal 18.0, d['thickness'], 'initial thickness 18 mm'
    assert_equal %w[height material thickness width], d.keys.sort, 'no position, gap or height-off-floor'
  end

  # ---- end panel target ----------------------------------------------------------------------

  def test_an_end_panel_against_a_filler_reaches_the_door_front
    target = cabinet
    params = filler_params(target)
    filler = FakeThing.new(params.merge('part_id' => 'PART_1', 'part_kind' => 'filler', 'material' => 'Oak',
                                        'envelope_top' => 880.0), Geom::Transformation.new, @parent)
    stored = AttributeManager.read(filler)
    depth = stored['target_flush_x'].to_f
    assert_in_delta 580.0, depth, 1e-9
    assert_equal 880.0, stored['envelope_top']
  end
end
