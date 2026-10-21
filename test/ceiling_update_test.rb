# frozen_string_literal: true

# A tall unit's height and the lofts over it, and Reset Unit Sizes: CabinetManager.update_one and reset_unit_sizes run for real, with a fake model and units.
# Run:  ruby test/ceiling_update_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end

  def self.active_model = @model
  def self.active_model=(model)
    @model = model
  end
end

module EasyCabinet
  DATA_DIR = 'unused'
  module HandleManager
    MODEL_KEYS = [].freeze
    def self.method_missing(*) = nil
    def self.respond_to_missing?(*) = true
  end
  module SelectionManager
    def self.suspend = yield
    def self.push_selection(*) = nil
    def self.selected_cabinet(*) = nil
  end
  module CabinetGenerator
    def self.update(_model, root, params)
      root.attrs['height'] = params['height']
      root.attrs['top_z'] = params['height'] + root.attrs['base_z'].to_f
      @updated = (@updated || 0) + 1
      root
    end

    def self.updated = @updated.to_i
    def self.door_material(_params) = 'White'
    def self.carcass_material(_params, door) = door
  end
  module PartManager
    def self.ceiling_filler_height(_model) = 50.0
    def self.follow_door(*) = nil
    def self.align_lofts(*) = nil
    def self.method_missing(*) = nil
    def self.respond_to_missing?(*) = true
  end
  module MaterialManager
    def self.available?(*) = true
  end
  module CatalogManager
    def self.handle_bundle(*) = nil
    def self.cabinet(_catalog, category, _type) = { 'defaults' => { 'width' => 600.0, 'depth' => 560.0, 'height' => category == 'loft' ? 290.0 : 2160.0 } }
    def self.method_missing(*) = nil
    def self.respond_to_missing?(*) = true
  end
  module NamingManager
    def self.for_update(_root, _params) = 'LU600'
  end
  module WorktopManager
    def self.refresh(*) = nil
  end
  module WallBottomManager
    def self.refresh(*) = nil
  end
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager validation_manager cabinet_layout toe_kick placement_manager].each { |f| require File.join(plugin, f) }
require File.join(plugin, 'cabinet_manager')

class FakeEntities
  def initialize(items) = @items = items
  def grep(klass) = @items.grep(klass)
end

class FakeLoft < Sketchup::ComponentInstance
  attr_reader :attrs, :transformation, :parent

  def initialize(z, parent, kind = :loft)
    super()
    @transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z))
    @parent = parent
    base = EasyCabinet::Defaults.params.merge(
      'cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_2door', 'catalog_id' => 'kitchen_cabinets', 'width' => 600.0, 'depth' => 560.0, 'height' => 290.0,
      'toe_kick_height' => 0.0, 'door_count' => 2, 'drawer_count' => 0, 'door_opening_direction' => EasyCabinet::Defaults.direction_ids.first,
      'top_panel_style' => EasyCabinet::Defaults::TOP_PANEL_STYLES.first, 'cabinet_id' => 'CABINET_0001', 'base_z' => 0.0, 'top_z' => 290.0,
      'envelope_depth' => 580.0, 'envelope_width' => 600.0, 'envelope_top' => 290.0
    )
    @attrs = kind == :wall ? base.merge('cabinet_type' => 'wall_2door', 'cabinet_id' => 'CABINET_0003', 'height' => 780.0, 'top_z' => 780.0, 'envelope_top' => 780.0, 'sequence' => 3) : kind == :tall ? base.merge('cabinet_category' => 'tall', 'cabinet_type' => 'tall_1door', 'cabinet_id' => 'CABINET_0002', 'door_count' => 1, 'height' => 2160.0, 'toe_kick_height' => 100.0, 'base_z' => 100.0, 'top_z' => 2260.0, 'envelope_top' => 2260.0, 'sequence' => 1) : base.merge('sequence' => 2)
  end

  def name = 'LU600'
  def valid? = true
  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def set_attribute(_dict, key, value) = @attrs[key] = value
  def transformation=(value)
    @transformation = value
  end
end

class FakeModel
  attr_reader :entities

  def initialize
    @attrs = {}
    @entities = nil
  end

  def entities=(value)
    @entities = value
  end

  def active_entities = @entities
  def selection = []
  def active_path = nil

  def start_operation(*) = nil
  def commit_operation = nil
  def abort_operation = nil
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def set_attribute(_dict, key, value) = @attrs[key] = value
end

class CeilingUpdateTest < Minitest::Test
  include EasyCabinet

  def setup
    @model = FakeModel.new
    @loft = FakeLoft.new(2260.0.mm, nil)
    @model.entities = FakeEntities.new([@loft])
    Sketchup.active_model = @model
  end

  def with_tall
    @tall = FakeLoft.new(0.0, nil, :tall)
    @model.entities = FakeEntities.new([@tall, @loft])
    parent = Struct.new(:entities).new(@model.entities)
    [@tall, @loft].each { |item| item.instance_variable_set(:@parent, parent) }
  end

  def test_a_tall_unit_can_grow_into_the_place_of_the_loft_above_it
    with_tall
    answer = CabinetManager.send(:update_one, @model, @tall, { 'fields_only' => true, 'fields' => { 'height' => 2260.0 }, 'resize_neighbours' => false })
    assert answer['ok'], answer['message']
    assert_in_delta 2260.0, @tall.attrs['height'], 0.01
  end

  def test_a_tall_unit_cannot_grow_so_much_that_the_loft_is_left_lower_than_the_lowest_it_is_made
    with_tall
    answer = CabinetManager.send(:update_one, @model, @tall, { 'fields_only' => true, 'fields' => { 'height' => 2360.0 }, 'resize_neighbours' => false })
    refute answer['ok']
    assert_includes answer['message'], 'taller at most'
    assert_includes answer['message'], '140'
    assert_in_delta 2160.0, @tall.attrs['height'], 0.01, 'nothing was changed'
  end

  def test_a_tall_unit_can_get_shorter
    with_tall
    answer = CabinetManager.send(:update_one, @model, @tall, { 'fields_only' => true, 'fields' => { 'height' => 2000.0 }, 'resize_neighbours' => false })
    assert answer['ok'], answer['message']
  end
  def test_a_loft_is_not_cut_at_any_ceiling_whatever_height_is_typed
    answer = CabinetManager.send(:update_one, @model, @loft, { 'fields_only' => true, 'fields' => { 'height' => 900.0 }, 'resize_neighbours' => false })
    assert answer['ok'], answer['message']
    assert_in_delta 900.0, @loft.attrs['height'], 0.01
  end

  def test_reset_unit_sizes_puts_the_units_in_the_model_back_to_the_standard_size_of_their_entry
    @loft.attrs['height'] = 500.0
    @loft.attrs['top_z'] = 500.0
    answer = CabinetManager.send(:reset_unit_sizes, 'resize_neighbours' => false)
    assert answer['ok'], answer['message']
    assert_in_delta 290.0, @loft.attrs['height'], 0.01, 'a loft goes back to 290 mm'
    assert_includes answer['message'], '1 unit'
    assert_in_delta 0.0, @model.get_attribute('kcm', 'loft_depth', 0.0), 0.01
  end
  def test_a_wall_unit_level_with_the_tall_unit_goes_up_with_it_when_the_tall_unit_grows
    @tall = FakeLoft.new(0.0, nil, :tall)
    @wall = FakeLoft.new(1480.0.mm, nil, :wall)
    @model.entities = FakeEntities.new([@tall, @wall])
    parent = Struct.new(:entities).new(@model.entities)
    [@tall, @wall].each { |item| item.instance_variable_set(:@parent, parent) }
    answer = CabinetManager.send(:update_one, @model, @tall, { 'fields_only' => true, 'fields' => { 'height' => 2500.0 }, 'resize_neighbours' => false })
    assert answer['ok'], answer['message']
    assert_in_delta 1480.0 + 340.0, @wall.transformation.origin.z.to_mm, 0.01, 'the wall unit rose by what the tall unit grew'
  end
end
