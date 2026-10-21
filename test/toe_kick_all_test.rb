# frozen_string_literal: true

# The Toe Kick fields acting on every toe kick at once (PartManager.apply_toe_kicks),
# with the real validation, layout and naming code against fake SketchUp objects.
#   ruby test/toe_kick_all_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end
end

module EasyCabinet
  module MaterialManager
    def self.available?(_model, _name) = true
  end

  module DialogManager
    def self.push(*) = nil
  end

  # What gets rebuilt is recorded rather than built.
  module PartGenerator
    @updates = []
    class << self
      attr_reader :updates

      def update(_model, root, params, layout, _transformation = nil) = @updates << [root, params, layout]
    end
  end

  # The cabinets' side of a toe kick height change is tested elsewhere; here it is recorded.
  module CabinetManager
    @lifts = []
    class << self
      attr_reader :lifts

      def apply_all(raw)
        @lifts << raw
        Response.ok('3 cabinets updated.')
      end
    end
  end

  DATA_DIR = 'unused'
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager toe_kick cabinet_layout part_layout validation_manager
   naming_manager cabinet_generator selection_manager part_manager].each { |f| require File.join(plugin, f) }

class Kick < Sketchup::ComponentInstance
  attr_reader :transformation, :parent, :name

  def initialize(attrs, y, entities)
    super()
    @attrs = attrs
    @transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, y, 0))
    @parent = Struct.new(:entities).new(entities)
    @name = attrs['part_name']
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
end

# Something that can be lifted: its transformation can be replaced.
class Mover < Sketchup::ComponentInstance
  attr_accessor :transformation
  attr_reader :name

  def initialize(attrs, z = 0.0)
    super()
    @attrs = attrs
    @transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z))
    @name = attrs['part_name'] || attrs['cabinet_name']
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
end

class Bag
  def initialize = @items = []
  def add(item) = @items << item
  def grep(klass) = @items.grep(klass)
end

class FakeSketchModel
  attr_reader :entities, :operations

  def initialize(entities)
    @entities = entities
    @operations = []
  end

  def active_entities = @entities
  def selection = []
  def active_path = nil
  def start_operation(*args) = @operations << [:start, *args]
  def commit_operation = @operations << [:commit]
  def abort_operation = @operations << [:abort]
end

class ToeKickAllTest < Minitest::Test
  include EasyCabinet

  def setup
    @bag = Bag.new
    @model = FakeSketchModel.new(@bag)
    Sketchup.instance_variable_set(:@active_model, @model)
    Sketchup.define_singleton_method(:active_model) { @active_model }
    PartGenerator.updates.clear
    CabinetManager.lifts.clear
    @count = 0
  end

  def kick(y:, length: 600.0, pieces: 1, **extra)
    attrs = { 'part_id' => "PART_#{@count += 1}", 'part_kind' => 'toe_kick', 'part_name' => "TK#{@count}",
              'toe_kick_height' => 100.0, 'toe_kick_thickness' => 18.0, 'toe_kick_piece_length' => length,
              'toe_kick_pieces' => pieces, 'toe_kick_recess' => 50.0, 'toe_kick_material' => '__door__',
              'target_depth' => 560.0, 'target_door_material' => 'White', 'target_carcass_material' => 'White' }.merge(extra)
    item = Kick.new(attrs, y, @bag)
    @bag.add(item)
    item
  end

  def apply(raw) = PartManager.send(:apply_toe_kicks, raw)

  def test_a_changed_value_goes_to_every_toe_kick_in_one_undo_step
    a = kick(y: 0.0)
    b = kick(y: 1000.0)
    result = apply('toe_kick_height' => '150')
    assert result['ok'], result['message']
    assert_equal [a, b], PartGenerator.updates.map(&:first)
    assert_equal [150.0, 150.0], PartGenerator.updates.map { |_r, params, _l| params['toe_kick_height'] }
    assert_equal 1, @model.operations.count { |op| op.first == :start }, 'one Undo step'
    assert_match(/2 toe kicks updated/, result['message'])
  end

  def test_each_toe_kick_keeps_its_own_other_values
    kick(y: 0.0, length: 600.0, pieces: 2)
    kick(y: 5000.0, length: 900.0, pieces: 1)
    apply('toe_kick_recess' => '30')
    lengths = PartGenerator.updates.map { |_r, params, _l| [params['toe_kick_piece_length'], params['toe_kick_pieces'], params['toe_kick_recess']] }
    assert_equal [[600.0, 2, 30.0], [900.0, 1, 30.0]], lengths
  end

  def test_only_the_fields_that_were_sent_change
    kick(y: 0.0)
    apply('toe_kick_thickness' => '25', 'toe_kick_height' => '')
    params = PartGenerator.updates.first[1]
    assert_equal 25.0, params['toe_kick_thickness']
    assert_equal 100.0, params['toe_kick_height'], 'a blank field leaves the toe kick as it is'
  end

  def test_nothing_is_rebuilt_when_nothing_changes
    kick(y: 0.0)
    result = apply('toe_kick_height' => '100')
    assert result['ok']
    assert_empty PartGenerator.updates
    assert_match(/already/, result['message'])
  end

  def test_a_value_the_rules_refuse_changes_nothing
    kick(y: 0.0)
    result = apply('toe_kick_height' => '9000')
    refute result['ok']
    assert_empty PartGenerator.updates
  end

  def test_two_runs_that_would_end_up_on_top_of_each_other_are_not_both_lengthened
    first = kick(y: 0.0, length: 1000.0)
    kick(y: 1100.0, length: 1000.0)
    result = apply('toe_kick_piece_length' => '1500') # the first would reach 1500, the second starts at 1100
    assert_equal [first], PartGenerator.updates.map(&:first)
    assert_match(/on top of/, result['message'])
  end

  def test_with_no_toe_kicks_it_says_so
    result = apply('toe_kick_height' => '120')
    assert result['ok']
    assert_match(/No toe kicks/, result['message'])
  end

  def test_a_higher_toe_kick_lifts_the_cabinets_too
    kick(y: 0.0)
    result = apply('toe_kick_height' => '150')
    assert_equal [{ 'toe_kick_height' => '150' }], CabinetManager.lifts
    assert_match(/3 cabinets updated/, result['message'])
  end

  def test_other_toe_kick_fields_leave_the_cabinets_alone
    kick(y: 0.0)
    apply('toe_kick_recess' => '30')
    assert_empty CabinetManager.lifts
  end

  def test_the_cabinets_are_lifted_even_when_the_toe_kicks_already_have_that_height
    kick(y: 0.0)
    apply('toe_kick_height' => '100')
    assert_equal 1, CabinetManager.lifts.length
  end

  def test_nothing_is_lifted_when_the_toe_kick_change_is_refused
    kick(y: 0.0)
    apply('toe_kick_height' => '9000')
    assert_empty CabinetManager.lifts
  end

  # ---- what goes up when the toe kick goes up ------------------------------------------

  def mover(attrs, z = 0.0)
    item = Mover.new(attrs, z)
    @bag.add(item)
    item
  end

  def lift(from, to) = PartManager.lift_attached(@model, from, to)

  def test_wall_units_move_up_with_the_toe_kick_and_base_units_stay_put
    wall = mover({ 'cabinet_id' => 'C1', 'cabinet_category' => 'wall', 'cabinet_name' => 'WU' }, 1480.0)
    base = mover({ 'cabinet_id' => 'C2', 'cabinet_category' => 'base', 'cabinet_name' => 'BU' }, 0.0)
    lift(100.0, 150.0)
    assert_in_delta 1530.0, wall.transformation.origin.z, 1e-9
    assert_in_delta 0.0, base.transformation.origin.z, 1e-9, 'a base unit is rebuilt higher instead'
  end

  def test_what_hangs_beside_a_wall_unit_moves_too
    filler = mover({ 'part_id' => 'P1', 'part_kind' => 'filler', 'part_name' => 'FL', 'target_category' => 'wall', 'width' => 50.0 }, 1480.0)
    panel = mover({ 'part_id' => 'P2', 'part_kind' => 'end_panel', 'part_name' => 'EP', 'target_base_z' => 1480.0, 'height' => 720.0 }, 1480.0)
    lift(100.0, 130.0)
    assert_in_delta 1510.0, filler.transformation.origin.z, 1e-9
    assert_in_delta 1510.0, panel.transformation.origin.z, 1e-9
    assert_empty PartGenerator.updates, 'nothing needed rebuilding'
  end

  def test_floor_standing_fillers_and_end_panels_are_rebuilt_not_moved
    filler = mover({ 'part_id' => 'P1', 'part_kind' => 'filler', 'part_name' => 'FL', 'target_category' => 'base', 'target_base_z' => 100.0,
                     'width' => 50.0, 'thickness' => 18.0, 'height' => 780.0, 'target_flush_x' => 580.0 })
    panel = mover({ 'part_id' => 'P2', 'part_kind' => 'end_panel', 'part_name' => 'EP', 'target_base_z' => 0.0, 'depth' => 580.0,
                    'thickness' => 18.0, 'height' => 880.0 })
    lift(100.0, 150.0)
    assert_in_delta 0.0, filler.transformation.origin.z, 1e-9
    by_item = PartGenerator.updates.to_h { |root, params, _layout| [root, params] }
    assert_equal 150.0, by_item[filler]['target_base_z']
    assert_equal 930.0, by_item[panel]['height'], 'it grows to the cabinets new top'
  end

  def test_lowering_the_toe_kick_brings_the_wall_units_down
    wall = mover({ 'cabinet_id' => 'C1', 'cabinet_category' => 'wall', 'cabinet_name' => 'WU' }, 1530.0)
    lift(150.0, 100.0)
    assert_in_delta 1480.0, wall.transformation.origin.z, 1e-9
  end

  def test_no_change_moves_nothing
    wall = mover({ 'cabinet_id' => 'C1', 'cabinet_category' => 'wall', 'cabinet_name' => 'WU' }, 1480.0)
    lift(100.0, 100.0)
    assert_in_delta 1480.0, wall.transformation.origin.z, 1e-9
  end
end
