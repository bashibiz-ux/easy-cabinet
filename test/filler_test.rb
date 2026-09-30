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
  def set_attribute(_dict, key, value) = @attrs[key] = value
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

  def test_a_filler_takes_the_cabinets_door_material_and_has_none_of_its_own
    stored = AttributeManager.read(cabinet) # door material 'Oak'
    door = PartManager.send(:door_material_of, stored)
    assert_equal 'Oak', door

    params, failure = PartManager.send(:prepare_filler, { 'width' => '50', 'thickness' => '18', 'height' => '780', 'material' => 'Walnut' }, door)
    assert_nil failure
    assert_equal 'Oak', params['material'], 'a material sent from the panel is ignored: it follows the door'

    assert_equal 'White', PartManager.send(:door_material_of, { 'cabinet_category' => 'base' }), 'nothing recorded: plain white'
    corner = { 'cabinet_category' => 'corner', 'base_material' => 'Walnut', 'material' => '' }
    assert_equal 'Walnut', PartManager.send(:door_material_of, corner), 'a corner uses the Base Unit door material'
  end

  # ---- end panel material: "same as door", following unless changed by hand ---------------------

  def test_an_end_panel_starts_as_same_as_door_material_and_uses_the_door_colour
    assert_equal '__door__', Defaults.end_panel_params['material']

    params, failure = PartManager.send(:prepare_end_panel, { 'side' => 'left', 'thickness' => '18', 'material' => '__door__' }, 'Oak', 'Grey')
    assert_nil failure
    assert_equal 'Oak', params['material'], 'resolved to the door colour'
    assert_equal '__door__', params['material_choice'], 'but remembered as "follow the door"'

    blank, = PartManager.send(:prepare_end_panel, { 'side' => 'left', 'thickness' => '18', 'material' => '' }, 'Oak', 'Grey')
    assert_equal '__door__', blank['material_choice'], 'blank means same as door'
    assert_equal 'Oak', blank['material']
  end

  def test_an_end_panel_with_a_material_picked_by_hand_keeps_it
    params, = PartManager.send(:prepare_end_panel, { 'side' => 'right', 'thickness' => '18', 'material' => 'Walnut' }, 'Oak', 'Grey')
    assert_equal 'Walnut', params['material']
    assert_equal 'Walnut', params['material_choice']
  end

  # ---- following the cabinet's door material after it changes ---------------------------------------

  # A part standing in the model, with a definition whose instances can be recoloured.
  class FakePiece < Sketchup::ComponentInstance
    attr_accessor :painted
  end

  class FakeDefinition
    attr_reader :pieces

    def initialize(count) = @pieces = Array.new(count) { FakePiece.new }
    def entities = self
    def grep(_klass) = @pieces
  end

  class FakePart < FakeThing
    attr_reader :definition

    def initialize(attrs, parent, pieces = 1)
      super(attrs, Geom::Transformation.new, parent)
      @definition = FakeDefinition.new(pieces)
    end
  end

  def part(kind, attrs, pieces = 1)
    p = FakePart.new({ 'part_id' => "PART_#{@entities.grep(FakeThing).length}", 'part_kind' => kind }.merge(attrs), @parent, pieces)
    @entities.add(p)
    p
  end

  # MaterialManager.apply records the colour on the piece so the test can read it back.
  module ::KitchenCabinetMaster::MaterialManager
    def self.apply(entity, name, _model = nil, _color = nil)
      entity.painted = name
      true
    end

    def self.follows_another_part?(name) = ['__door__', '__carcass__', '__cabinet__'].include?(name)
  end

  def repaint(cabinet_stored)
    cab = cabinet
    cab.attrs.merge!(cabinet_stored)
    cab
  end

  def test_when_the_door_material_changes_the_filler_and_followers_change_with_it
    cab = cabinet(base_material: 'Walnut', material: 'Walnut') # the cabinet was just updated to Walnut
    id = cab.attrs['cabinet_id']
    filler = part('filler', 'target_id' => id, 'material' => 'Oak')
    following_panel = part('end_panel', 'target_id' => id, 'material' => 'Oak', 'material_choice' => '__door__')
    own_panel = part('end_panel', 'target_id' => id, 'material' => 'Grey', 'material_choice' => 'Grey')
    following_kick = part('toe_kick', 'target_id' => id, 'material' => 'Oak', 'toe_kick_material' => '__door__', 'target_door_material' => 'Oak', 'width' => 600.0)
    own_kick = part('toe_kick', 'target_id' => id, 'material' => 'PVC Black', 'toe_kick_material' => 'PVC Black')
    stranger = part('filler', 'target_id' => 'CABINET_9999', 'material' => 'Oak')

    PartManager.follow_door(Sketchup.active_model, cab)

    assert_equal 'Walnut', filler.attrs['material']
    assert_equal ['Walnut'], filler.definition.pieces.map(&:painted).uniq, 'the filler board is recoloured'
    assert_equal 'Walnut', following_panel.attrs['material']
    assert_equal 'Walnut', following_kick.attrs['material']
    assert_equal 'Grey', own_panel.attrs['material'], 'a hand-picked end panel material stays'
    assert_nil own_panel.definition.pieces.first.painted
    assert_equal 'PVC Black', own_kick.attrs['material'], 'a hand-picked toe kick material stays'
    assert_equal 'Oak', stranger.attrs['material'], 'other cabinets\' parts are left alone'
    assert_equal 'Walnut', following_kick.attrs['target_door_material'], 'and a later Update keeps following'
  end

  def test_things_attached_to_a_filler_follow_the_cabinet_too
    cab = cabinet(base_material: 'Walnut', material: 'Walnut')
    filler = part('filler', 'target_id' => cab.attrs['cabinet_id'], 'material' => 'Oak')
    beside_filler = part('end_panel', 'target_id' => filler.attrs['part_id'], 'material' => 'Oak', 'material_choice' => '__door__')

    PartManager.follow_door(Sketchup.active_model, cab)
    assert_equal 'Walnut', beside_filler.attrs['material']
  end

  def test_a_toe_kick_records_the_cabinet_it_goes_with
    cab = cabinet
    t = PartManager.send(:toe_kick_target, { 'depth' => '560' }, cab)
    assert_equal cab.attrs['cabinet_id'], t['target_id']
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
    assert_equal %w[height thickness width], d.keys.sort, 'no position, gap, height-off-floor or material'
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
