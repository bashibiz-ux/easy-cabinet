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

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)

  module MaterialManager
    def self.available?(_model, _name) = true
  end
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager validation_manager catalog_manager gola_profile cabinet_layout front_design appliance_parts fixtures handle_manager
   selection_manager placement_manager cabinet_generator cabinet_manager part_layout part_generator part_manager].each { |f| require File.join(plugin, f) }

class Thing < Sketchup::ComponentInstance
  attr_accessor :transformation
  attr_reader :parent, :name

  def initialize(attrs, transformation, parent)
    super()
    @attrs = attrs
    @transformation = transformation
    @parent = parent
    @name = attrs['cabinet_name'] || attrs['part_name'] || 'thing'
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def set_attribute(_dict, key, value) = @attrs[key] = value
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
  include EasyCabinet

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
                                  'catalog_id' => 'kitchen_cabinets', 'cabinet_type' => 'base_1door',
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

  # A side panel against the `side` end of `target`, `thickness` thick, standing at `y`.
  def side_panel(target, side, y:, thickness: 18.0)
    attrs = { 'part_id' => "PART_#{@seq += 1}", 'part_kind' => 'end_panel', 'part_name' => 'SP', 'target_id' => target.get_attribute(nil, 'cabinet_id'),
              'side' => side, 'thickness' => thickness, 'target_width' => target.get_attribute(nil, 'width') }
    item = Thing.new(attrs, move(y, x: 5.0, z: 0.0), @holder)
    @bag.add(item)
    item
  end

  def plan(root, growth) = RowResizer.plan(nil, root, growth)

  # ---- side panels ------------------------------------------------------------

  def test_the_side_panels_of_a_cabinet_are_found
    a = cabinet(y: 0.0)
    b = cabinet(y: 700.0)
    right = side_panel(a, 'right', y: 600.0)
    side_panel(b, 'left', y: 682.0)
    assert_equal [right], AttributeManager.end_panels_of(a)
  end

  def test_the_room_a_side_panel_takes_between_two_units_is_not_free
    a = cabinet(y: 0.0)
    b = cabinet(y: 618.0)
    side_panel(a, 'right', y: 600.0) # the panel stands between them, against the first unit
    squeeze, problem = plan(a, 300.0)
    assert_nil problem
    assert_in_delta 300.0, squeeze[:need], 1e-6, 'the neighbour gives all of it: the 18 mm of the panel are not free space'
    assert_same b, squeeze[:neighbour]
  end

  def test_a_side_panel_against_the_neighbour_is_not_free_room_either
    a = cabinet(y: 0.0)
    b = cabinet(y: 650.0)
    side_panel(b, 'left', y: 632.0)
    squeeze, = plan(a, 100.0)
    assert_in_delta 100.0 - 32.0, squeeze[:need], 1e-6, 'only the 32 mm left of the 50 mm gap are free'
  end

  def test_a_unit_with_a_side_panel_and_nothing_after_it_grows_and_its_panel_slides_with_it
    oven = cabinet(y: 0.0, width: 600.0)
    right = side_panel(oven, 'right', y: 600.0)
    left = side_panel(oven, 'left', y: -18.0)
    assert_equal [nil, nil], plan(oven, 300.0), 'nothing to squeeze: the panel is not a neighbour'
    before = oven.transformation
    PartManager.follow_target(nil, oven, before, 600.0, 900.0)
    assert_in_delta 900.0, right.transformation.origin.y, 1e-6, 'the right panel stays against the unit'
    assert_in_delta(-18.0, left.transformation.origin.y, 1e-6, 'the left panel stays where it is')
    assert_equal 900.0, right.get_attribute(nil, 'target_width'), 'so a later change of the panel puts it at the right place'
    assert_in_delta 5.0, right.transformation.origin.x, 1e-6, 'it keeps its place from the back'
  end

  def test_the_panels_of_a_unit_that_moved_and_got_narrower_follow_it
    b = cabinet(y: 650.0, width: 600.0)
    right = side_panel(b, 'right', y: 1250.0)
    left = side_panel(b, 'left', y: 632.0)
    before = b.transformation
    b.transformation = move(700.0) # the squeeze: 50 mm further along, 50 mm narrower
    PartManager.follow_target(nil, b, before, 600.0, 550.0)
    assert_in_delta 1250.0, right.transformation.origin.y, 1e-6, 'its far end stays where it was'
    assert_in_delta 682.0, left.transformation.origin.y, 1e-6, 'its start moved along with it'
  end
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