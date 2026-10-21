# frozen_string_literal: true

# Where a new wall unit goes, how a shrunk cabinet's neighbour follows it, and the
# starting colours. Run:  ruby test/wall_height_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end
end

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)

  module MaterialManager
    def self.available?(_model, _name) = true
  end
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager validation_manager catalog_manager gola_profile cabinet_layout front_design appliance_parts fixtures handle_manager
   selection_manager placement_manager cabinet_generator cabinet_manager].each { |f| require File.join(plugin, f) }

class Unit < Sketchup::ComponentInstance
  attr_reader :transformation, :parent, :name

  def initialize(attrs, transformation, parent)
    super()
    @attrs = attrs
    @transformation = transformation
    @parent = parent
    @name = attrs['cabinet_name'] || 'unit'
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
end

class Entities
  def initialize = @items = []
  def add(item) = @items << item
  def grep(klass) = @items.grep(klass)
end

Holder = Struct.new(:entities)
Model = Struct.new(:active_entities) do
  def selection = []
  def active_path = nil
end

class WallHeightTest < Minitest::Test
  include EasyCabinet

  def setup
    @entities = Entities.new
    @model = Model.new(@entities)
    @holder = Holder.new(@entities)
    @seq = 0
  end

  # A placed unit: `z` is where its origin stands; its own top is `top_z`.
  def place(category, z: 0.0, y: 0.0, top_z:, width: 600.0)
    attrs = Defaults.params.merge('cabinet_id' => "CABINET_#{@seq += 1}", 'sequence' => @seq, 'cabinet_category' => category,
                                  'cabinet_name' => category, 'width' => width, 'top_z' => top_z, 'height' => 720.0)
    unit = Unit.new(attrs, Geom::Transformation.translation(Geom::Vector3d.new(0, y, z)), @holder)
    @entities.add(unit)
    unit
  end

  def wall_z(selected = nil) = PlacementManager.wall_origin_z(@model, { 'height' => 720.0 }, selected)

  def test_a_wall_unit_goes_600_mm_above_the_base_unit
    base = place('base', top_z: 880.0)
    assert_in_delta 1480.0, wall_z(base), 1e-9
  end

  def test_with_a_tall_unit_the_wall_unit_top_lines_up_with_it
    place('base', top_z: 880.0)
    place('tall', top_z: 2200.0, y: 700.0)
    assert_in_delta 2200.0 - 720.0, wall_z, 1e-9, 'the wall unit hangs from the tall unit top'
  end

  def test_a_taller_wall_unit_starts_lower_to_keep_its_top
    place('tall', top_z: 2200.0)
    short = PlacementManager.wall_origin_z(@model, { 'height' => 720.0 })
    tall = PlacementManager.wall_origin_z(@model, { 'height' => 900.0 })
    assert_in_delta 180.0, short - tall, 1e-9
  end

  def test_the_next_wall_unit_in_a_row_lines_up_its_top_with_the_one_before
    place('base', top_z: 880.0)
    wall = place('wall', z: 1480.0, top_z: 720.0, y: 0.0)
    assert_in_delta 1480.0, wall_z(wall), 1e-9
    assert_in_delta 1480.0 + 720.0 - 600.0, PlacementManager.wall_origin_z(@model, { 'height' => 600.0 }, wall), 1e-9
  end

  def test_the_most_recent_tall_unit_wins
    place('tall', top_z: 2100.0)
    place('tall', top_z: 2200.0, y: 700.0)
    assert_in_delta 2200.0 - 720.0, wall_z, 1e-9
  end

  def test_with_nothing_in_the_model_it_hangs_over_a_standard_base_unit
    assert_in_delta 1480.0, wall_z, 1e-9
  end

  def test_a_new_wall_unit_is_lifted_to_that_height_whatever_the_row_height
    base = place('base', top_z: 880.0)
    transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 600, 0))
    lift = PlacementManager.wall_origin_z(@model, { 'height' => 720.0 }, base)
    raised = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift - transformation.origin.z)) * transformation
    assert_in_delta 1480.0, raised.origin.z, 1e-9
    assert_in_delta 600.0, raised.origin.y, 1e-9
  end

  # ---- a shrunk cabinet's neighbour follows it back ---------------------------------

  def row_item(y:, width: 600.0, category: 'base')
    attrs = Defaults.params.merge('cabinet_id' => "CABINET_#{@seq += 1}", 'cabinet_name' => "BU#{width.to_i}", 'catalog_id' => 'x',
                                  'cabinet_type' => 'y', 'cabinet_category' => category, 'width' => width, 'depth' => 560.0,
                                  'height' => 780.0, 'door_count' => 1, 'drawer_count' => 0, 'toe_kick_height' => 100.0)
    unit = Unit.new(attrs, Geom::Transformation.translation(Geom::Vector3d.new(0, y, 0)), @holder)
    @entities.add(unit)
    unit
  end

  def test_the_neighbour_grows_by_what_the_cabinet_gave_up
    first = row_item(y: 0.0)
    second = row_item(y: 600.0)
    plan, problem = RowResizer.plan(nil, first, -100.0)
    assert_nil problem
    assert_same second, plan[:neighbour]
    assert_in_delta(-100.0, plan[:need], 1e-9, 'its start moves back by 100')
    assert_in_delta 700.0, plan[:width], 1e-9
    assert_in_delta 700.0, plan[:params]['width'], 1e-9
  end

  def test_a_corner_unit_neighbour_is_left_alone_when_the_cabinet_shrinks
    first = row_item(y: 0.0)
    row_item(y: 600.0, width: 900.0, category: 'corner')
    assert_equal [nil, nil], RowResizer.plan(nil, first, -100.0)
  end

  def test_a_neighbour_that_would_get_too_wide_is_left_alone
    first = row_item(y: 0.0)
    row_item(y: 600.0, width: 2950.0)
    assert_equal [nil, nil], RowResizer.plan(nil, first, -100.0)
  end

  def test_shrinking_with_no_neighbour_changes_nothing
    first = row_item(y: 0.0)
    assert_equal [nil, nil], RowResizer.plan(nil, first, -100.0)
  end

  # ---- starting values ------------------------------------------------------------

  def test_the_carcass_starts_light_grey_not_the_door_material
    assert_equal Defaults::DEFAULT_CARCASS_MATERIAL, Defaults.params['carcass_material']
    assert_equal Defaults::DEFAULT_CARCASS_MATERIAL, CabinetGenerator.carcass_material(Defaults.params.merge('base_material' => 'Oak'), 'Oak')
  end

  def test_a_tall_unit_stands_100_mm_up_on_its_toe_kick
    layout = CabinetLayout.compute(Defaults.params.merge('cabinet_category' => 'tall', 'width' => 600.0, 'depth' => 560.0,
                                                          'height' => 2100.0, 'door_count' => 1))
    assert_equal 100.0, layout.base_z
    assert_equal 2200.0, layout.top_z
  end

  # ---- tall, base and corner units always start on the floor ----------------------

  def new_unit_z(category, follows)
    params = Defaults.params.merge('cabinet_category' => category, 'width' => 600.0, 'depth' => 560.0, 'height' => 2100.0,
                                   'toe_kick_height' => 100.0, 'material_thickness' => 18.0)
    _entities, transformation = PlacementManager.target_for_new(@model, params)
    assert follows
    transformation.origin.z
  end

  def test_a_tall_unit_after_a_wall_unit_still_starts_on_the_floor
    wall = place('wall', z: 1480.0, top_z: 720.0)
    assert_equal 0.0, new_unit_z('tall', wall)
  end

  def test_a_base_unit_after_a_wall_unit_starts_on_the_floor_too
    wall = place('wall', z: 1480.0, top_z: 720.0)
    assert_equal 0.0, new_unit_z('base', wall)
  end

  def test_the_new_unit_goes_beside_the_wall_unit_but_at_floor_level
    place('wall', z: 1480.0, top_z: 720.0, y: 0.0)
    _entities, transformation = PlacementManager.target_for_new(
      @model, Defaults.params.merge('cabinet_category' => 'tall', 'width' => 600.0, 'depth' => 560.0, 'height' => 2100.0,
                                    'toe_kick_height' => 100.0, 'material_thickness' => 18.0)
    )
    assert_equal 0.0, transformation.origin.z
    assert_in_delta 600.0, transformation.origin.y, 1e-9, 'still next to it along the row'
  end
end
