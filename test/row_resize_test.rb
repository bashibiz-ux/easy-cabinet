# frozen_string_literal: true

# Making room in a row: RowResizer's real planning code, and the "settings for every
# cabinet" checks, against fake SketchUp objects.  Run:  ruby test/row_resize_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end
end

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)

  module MaterialManager
    def self.available?(_model, _name) = true
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager validation_manager catalog_manager cabinet_layout handle_manager
   selection_manager placement_manager cabinet_generator cabinet_manager].each { |f| require File.join(plugin, f) }

class Thing < Sketchup::ComponentInstance
  attr_reader :transformation, :parent, :name

  def initialize(attrs, transformation, parent)
    super()
    @attrs = attrs
    @transformation = transformation
    @parent = parent
    @name = attrs['cabinet_name'] || attrs['part_name'] || 'thing'
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
end

class Bag
  def initialize = @items = []
  def add(item) = @items << item
  def grep(klass) = @items.grep(klass)
end

class Holder
  attr_reader :entities

  def initialize(entities) = @entities = entities
end

class RowResizeTest < Minitest::Test
  include KitchenCabinetMaster

  def setup
    @bag = Bag.new
    @holder = Holder.new(@bag)
    @seq = 0
  end

  def move(y, x: 0.0, z: 0.0, turn: 0.0)
    base = Geom::Transformation.translation(Geom::Vector3d.new(x, y, z))
    return base if turn.zero?

    base * Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), nil, turn * Math::PI / 180.0)
  end

  def cabinet(y:, width: 600.0, category: 'base', **where)
    attrs = Defaults.params.merge('cabinet_id' => "CABINET_#{@seq += 1}", 'cabinet_name' => "BU#{width.to_i}",
                                  'catalog_id' => 'door_with_pull_handle', 'cabinet_type' => 'base_1door',
                                  'cabinet_category' => category, 'width' => width, 'depth' => 560.0, 'height' => 780.0,
                                  'door_count' => 1, 'drawer_count' => 0, 'toe_kick_height' => 100.0)
    item = Thing.new(attrs, move(y, **where), @holder)
    @bag.add(item)
    item
  end

  def filler(y:, width: 100.0)
    attrs = { 'part_id' => "PART_#{@seq += 1}", 'part_kind' => 'filler', 'part_name' => 'FL', 'width' => width }
    item = Thing.new(attrs, move(y), @holder)
    @bag.add(item)
    item
  end

  def plan(root, growth) = RowResizer.plan(nil, root, growth)

  # ---- finding the next item ----------------------------------------------

  def test_the_next_item_and_the_free_gap_between_are_found
    a = cabinet(y: 0.0)
    b = cabinet(y: 650.0)
    neighbour, gap = RowResizer.next_in_row(a)
    assert_same b, neighbour
    assert_in_delta 50.0, gap, 1e-6
  end

  def test_the_nearest_item_wins
    a = cabinet(y: 0.0)
    cabinet(y: 1800.0)
    near = cabinet(y: 600.0)
    assert_same near, RowResizer.next_in_row(a).first
  end

  def test_items_behind_on_another_wall_or_at_another_height_are_not_next
    a = cabinet(y: 0.0)
    cabinet(y: 600.0, z: 1400.0)          # a wall unit above
    cabinet(y: 600.0, x: 900.0)           # across the room
    cabinet(y: -700.0)                    # before it, not after
    assert_nil RowResizer.next_in_row(a)
  end

  def test_a_turned_row_is_not_next
    a = cabinet(y: 0.0)
    cabinet(y: 600.0, turn: -90.0)
    assert_nil RowResizer.next_in_row(a)
  end

  # ---- the plan --------------------------------------------------------------

  def test_growth_within_the_free_gap_needs_no_squeeze
    a = cabinet(y: 0.0)
    cabinet(y: 650.0)
    assert_equal [nil, nil], plan(a, 40.0)
  end

  def test_the_neighbour_gives_up_what_the_gap_cannot_cover
    a = cabinet(y: 0.0)
    b = cabinet(y: 650.0)
    squeeze, problem = plan(a, 100.0)
    assert_nil problem
    assert_same b, squeeze[:neighbour]
    assert_in_delta 50.0, squeeze[:need], 1e-6
    assert_in_delta 550.0, squeeze[:width], 1e-6
    assert_in_delta 550.0, squeeze[:params]['width'], 1e-6, 'the new width is what its doors and panels are rebuilt for'
  end

  def test_touching_neighbours_give_up_all_of_it
    a = cabinet(y: 0.0)
    cabinet(y: 600.0)
    squeeze, = plan(a, 100.0)
    assert_in_delta 100.0, squeeze[:need], 1e-6
    assert_in_delta 500.0, squeeze[:width], 1e-6
  end

  def test_a_filler_can_be_narrowed_too
    a = cabinet(y: 0.0)
    f = filler(y: 600.0, width: 100.0)
    squeeze, problem = plan(a, 60.0)
    assert_nil problem
    assert_same f, squeeze[:neighbour]
    assert squeeze[:filler]
    assert_in_delta 40.0, squeeze[:width], 1e-6
  end

  def test_nothing_goes_below_the_smallest_width
    a = cabinet(y: 0.0)
    cabinet(y: 600.0, width: 300.0)
    squeeze, problem = plan(a, 250.0)
    assert_nil squeeze
    assert_match(/no room/, problem)
    assert_match(/smallest is 100/, problem)
  end

  def test_a_filler_cannot_go_below_5_mm
    a = cabinet(y: 0.0)
    filler(y: 600.0, width: 100.0)
    _squeeze, problem = plan(a, 98.0)
    assert_match(/smallest is 5/, problem)
  end

  def test_a_corner_unit_is_never_narrowed
    a = cabinet(y: 0.0)
    cabinet(y: 600.0, width: 900.0, category: 'corner')
    _squeeze, problem = plan(a, 50.0)
    assert_match(/corner unit/, problem)
  end

  def test_no_neighbour_means_no_squeeze
    a = cabinet(y: 0.0)
    assert_equal [nil, nil], plan(a, 100.0)
  end

  # ---- settings for every cabinet -------------------------------------------

  def test_only_a_real_change_counts
    stored = { 'door_gap' => 1.5, 'material_thickness' => 18.0, 'base_material' => 'Oak' }
    refute CabinetManager.send(:differs?, stored, 'door_gap' => '1.5')
    refute CabinetManager.send(:differs?, stored, 'material_thickness' => '18')
    assert CabinetManager.send(:differs?, stored, 'door_gap' => '3')
    refute CabinetManager.send(:differs?, stored, 'base_material' => 'Oak')
    assert CabinetManager.send(:differs?, stored, 'base_material' => 'White')
  end

  def test_a_new_value_is_checked_by_the_same_rules_as_an_update
    stored = AttributeManager.read(cabinet(y: 0.0))
    params, errors = CabinetManager.send(:restyle_params, nil, stored, 'door_gap' => '4', 'base_material' => 'Walnut')
    assert_empty errors
    assert_equal 4.0, params['door_gap']
    assert_equal 'Walnut', params['base_material']
    assert_equal 600.0, params['width'], 'its own size is untouched'

    _none, bad = CabinetManager.send(:restyle_params, nil, stored, 'door_gap' => '40')
    refute_empty bad
    assert_equal 'door_gap', bad.first['field']
  end
end