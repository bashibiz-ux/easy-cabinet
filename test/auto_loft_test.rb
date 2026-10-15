# frozen_string_literal: true

# The Loft switch: PartManager.sync_auto_lofts with fake units (the building of a loft is faked: only who gets one, and what is taken away, is tested).
# Run:  ruby test/auto_loft_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
end

module KitchenCabinetMaster
  DATA_DIR = 'unused'
  module KitchenPlanner
    Item = Struct.new(:category, :type, :width, :kind, :run, :start, :gap_before, :extra, keyword_init: true)
  end
  module CatalogManager
    def self.cabinet(_catalog, _category, id) = { 'id' => id }
  end
  module CabinetGenerator
    class << self
      attr_reader :removed

      def remove(_model, loft)
        (@removed ||= []) << loft
        loft.entities_list.delete(loft)
      end

      def reset! = @removed = []
    end
  end
  module CabinetManager
    def self.update_quiet(_model, loft, fields) = fields.each { |key, value| loft.attrs[key] = value }
  end
  module KitchenManager
    class << self
      attr_reader :built

      def reset! = @built = []

      def build_unit(model, panel, catalog_id, item, override = nil, *_rest)
        (@built ||= []) << { type: item.type, width: item.width, panel: panel, catalog: catalog_id, override: override }
        loft = AutoLoftTest::Unit.new(override, model.entities_list, 'wall_loft_2door')
        loft.attrs['cabinet_id'] = "CABINET_90#{@built.length}"
        model.entities_list << loft
        loft
      end
    end
  end
  module AttributeManagerWrite
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager placement_manager].each { |f| require File.join(plugin, f) }

module KitchenCabinetMaster
  module AttributeManager
    def self.write(entity, params)
      params.each { |key, value| entity.attrs[key.to_s] = value }
      entity
    end
  end
  module PartManager; end
end
load File.join(plugin, 'part_manager.rb')

module KitchenCabinetMaster
  module LiveParts
    class << self
      attr_accessor :follow

      def loft_follow? = follow == true
    end
  end
end

class AutoLoftTest < Minitest::Test
  include KitchenCabinetMaster

  class Unit < Sketchup::ComponentInstance
    attr_reader :attrs, :transformation, :entities_list

    def initialize(transformation, list, type = '')
      super()
      @transformation = transformation
      @entities_list = list
      @attrs = { 'cabinet_type' => type, 'corner_style' => '', 'sequence' => list.length + 1 }
    end

    def name = @attrs['cabinet_id'].to_s
    def attribute_dictionary(_name, _create = false) = @attrs
    def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  end

  class Model
    attr_reader :entities_list

    def initialize
      @entities_list = []
      @attrs = {}
    end

    def active_entities = Entities.new(@entities_list)
    def entities = Entities.new(@entities_list)
    def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
    def set_attribute(_dict, key, value) = @attrs[key] = value
  end

  class Entities
    def initialize(list) = @list = list
    def grep(klass) = @list.grep(klass)
  end

  def unit(model, id, category, width, z: 0.0, top: 2260.0)
    t = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z))
    item = Unit.new(t, model.entities_list)
    item.attrs.merge!('cabinet_id' => id, 'cabinet_category' => category, 'width' => width, 'depth' => 560.0, 'top_z' => top - z, 'catalog_id' => 'kitchen_cabinets')
    model.entities_list << item
    item
  end

  def setup
    CabinetGenerator.reset!
    KitchenManager.reset!
    @model = Model.new
    @tall = unit(@model, 'CABINET_0001', 'tall', 600.0)
    @wall = unit(@model, 'CABINET_0002', 'wall', 900.0, z: 1480.0)
  end

  def sync(values, skip = []) = PartManager.send(:sync_auto_lofts, @model, values, skip)

  def test_every_wall_and_tall_unit_gets_a_loft_as_wide_as_it_of_the_right_kind
    sync({})
    assert_equal [['wall_loft_1door', 600.0], ['wall_loft_2door', 900.0]], KitchenManager.built.map { |b| [b[:type], b[:width]] }
    lofts = PlacementManager.lofts(@model)
    assert_equal %w[CABINET_0001 CABINET_0002], lofts.map { |l| l.attrs['loft_over'] }.sort
    assert(lofts.all? { |l| l.attrs['auto_loft'] == true })
  end

  def test_they_stand_at_the_top_of_the_highest_unit
    sync({})
    KitchenManager.built.each { |b| assert_in_delta 2260.0, b[:override].origin.z.to_mm, 0.01 }
  end

  def test_the_height_of_the_settings_is_given_to_them
    sync('height' => '320')
    assert_equal [320.0, 320.0], PlacementManager.lofts(@model).map { |l| l.attrs['height'] }
  end

  def test_a_unit_that_has_a_loft_gets_no_second_one_and_a_deleted_one_stays_away
    sync({})
    KitchenManager.reset!
    sync({})
    assert_empty KitchenManager.built, 'nothing is made twice'
    PartManager.send(:sync_auto_lofts, @model, nil, [])
    assert_empty PlacementManager.lofts(@model), 'with the switch off they are taken away'
    KitchenManager.reset!
    sync({}, ['CABINET_0002'])
    assert_equal [600.0], KitchenManager.built.map { |b| b[:width] }, 'the unit whose loft was deleted gets none'
  end

  def test_a_loft_you_inserted_yourself_is_never_taken_away_and_counts_as_the_loft_of_its_unit
    mine = Unit.new(@tall.transformation, @model.entities_list, 'wall_loft_2door')
    mine.attrs.merge!('cabinet_id' => 'CABINET_0050', 'loft_over' => 'CABINET_0001', 'sequence' => 50)
    @model.entities_list << mine
    sync({})
    assert_equal [900.0], KitchenManager.built.map { |b| b[:width] }, 'only the wall unit gets one'
    PartManager.send(:sync_auto_lofts, @model, nil, [])
    assert_includes @model.entities_list, mine
  end

  def test_a_loft_whose_unit_is_gone_is_taken_away
    sync({})
    @model.entities_list.delete(@wall)
    sync({})
    assert_equal ['CABINET_0001'], PlacementManager.lofts(@model).map { |l| l.attrs['loft_over'] }
  end
  def test_the_lofts_follow_the_loft_handles_tick_of_the_visibility
    @model.set_attribute('KitchenCabinetMaster', 'hide_loft_handles', true)
    sync({})
    assert(KitchenManager.built.all? { |b| b[:panel]['hide_loft_handles'] == true })
    KitchenManager.reset!
    @model.entities_list.clear
    @tall = unit(@model, 'CABINET_0001', 'tall', 600.0)
    @model.set_attribute('KitchenCabinetMaster', 'hide_loft_handles', false)
    sync({})
    assert(KitchenManager.built.none? { |b| b[:panel]['hide_loft_handles'] == true })
  end
  def lofts_over_units
    @tall.attrs['depth'] = 600.0
    sync({})
    PlacementManager.lofts(@model)
  end

  def test_with_the_follow_switch_a_loft_takes_the_width_and_depth_of_its_unit
    lofts = lofts_over_units
    @wall.attrs['width'] = 800.0
    @tall.attrs['depth'] = 640.0
    LiveParts.follow = true
    PartManager.send(:align_lofts, @model)
    over = ->(id) { lofts.find { |l| l.attrs['loft_over'] == id } }
    assert_equal [800.0, 560.0], [over.call('CABINET_0002').attrs['width'], over.call('CABINET_0002').attrs['depth']]
    assert_equal 640.0, over.call('CABINET_0001').attrs['depth'], 'the loft over the tall unit is as deep as the tall unit, not as the deepest unit'
  ensure
    LiveParts.follow = false
  end

  def test_without_it_the_lofts_share_the_deepest_depth
    lofts = lofts_over_units
    @tall.attrs['depth'] = 640.0
    PartManager.send(:align_lofts, @model)
    assert_equal [640.0], lofts.map { |l| l.attrs['depth'] }.uniq
  end
end
