# frozen_string_literal: true

# The Ceiling Height changes the height of the lofts: CabinetManager.set_ceiling and update_one run for real, with a fake model and loft.
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

module KitchenCabinetMaster
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

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager validation_manager cabinet_layout toe_kick placement_manager].each { |f| require File.join(plugin, f) }
require File.join(plugin, 'cabinet_manager')

class FakeEntities
  def initialize(items) = @items = items
  def grep(klass) = @items.grep(klass)
end

class FakeLoft < Sketchup::ComponentInstance
  attr_reader :attrs, :transformation, :parent

  def initialize(z, parent)
    super()
    @transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z))
    @parent = parent
    base = KitchenCabinetMaster::Defaults.params.merge(
      'cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_2door', 'catalog_id' => 'kitchen_cabinets', 'width' => 600.0, 'depth' => 560.0, 'height' => 290.0,
      'toe_kick_height' => 0.0, 'door_count' => 2, 'drawer_count' => 0, 'door_opening_direction' => KitchenCabinetMaster::Defaults.direction_ids.first,
      'top_panel_style' => KitchenCabinetMaster::Defaults::TOP_PANEL_STYLES.first, 'cabinet_id' => 'CABINET_0001', 'base_z' => 0.0, 'top_z' => 290.0,
      'envelope_depth' => 580.0, 'envelope_width' => 600.0, 'envelope_top' => 290.0
    )
    @attrs = base
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

  def start_operation(*) = nil
  def commit_operation = nil
  def abort_operation = nil
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def set_attribute(_dict, key, value) = @attrs[key] = value
end

class CeilingUpdateTest < Minitest::Test
  include KitchenCabinetMaster

  def setup
    @model = FakeModel.new
    @loft = FakeLoft.new(2260.0.mm, nil)
    @model.entities = FakeEntities.new([@loft])
    Sketchup.active_model = @model
  end

  def set_ceiling(value) = CabinetManager.send(:set_ceiling, 'ceiling_height' => value)

  def test_raising_the_ceiling_makes_the_loft_taller_up_to_it
    answer = set_ceiling(2800.0)
    assert answer['ok'], answer['message']
    assert_in_delta 2800.0 - 50.0 - 2260.0, @loft.attrs['height'], 0.01, answer['message']
  end

  def test_lowering_the_ceiling_makes_it_shorter_but_never_under_the_lowest_a_loft_is_made
    set_ceiling(2800.0)
    set_ceiling(2550.0)
    assert_in_delta 240.0, @loft.attrs['height'], 0.01
    answer = set_ceiling(2300.0)
    assert answer['ok'], answer['message']
    assert_in_delta KitchenCabinetMaster::PlacementManager::LOFT_MIN_MM, @loft.attrs['height'], 0.01
    assert_includes answer['message'], 'no room'
  end

  def test_a_loft_cannot_be_typed_past_the_ceiling
    set_ceiling(2800.0)
    answer = CabinetManager.send(:update_one, @model, @loft, { 'fields_only' => true, 'fields' => { 'height' => 900.0 }, 'resize_neighbours' => false })
    assert answer['ok'], answer['message']
    assert_in_delta 490.0, @loft.attrs['height'], 0.01, 'the ceiling less the filler is the limit'
  end

  def test_the_message_says_how_tall_the_loft_is
    assert_includes set_ceiling(2900.0)['message'], '590'
  end
end
