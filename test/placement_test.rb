# frozen_string_literal: true

# Runs the plugin's REAL PlacementManager (and CabinetLayout.envelope) outside
# SketchUp, with a fake selection and fake model. Run:  ruby test/placement_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

# Just enough of the SketchUp model for PlacementManager.
module Sketchup
  class ComponentInstance; end
end

module KitchenCabinetMaster
  module AttributeManager
    DICTIONARY = 'kcm'
    def self.occupant?(instance) = instance.respond_to?(:attrs)
  end

  module SelectionManager
    class << self
      attr_accessor :selected
    end
    def self.selected_occupant(_model) = selected
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults toe_kick cabinet_layout placement_manager].each { |f| require File.join(plugin, f) }

# A placed cabinet: a ComponentInstance with a transformation and attributes.
class FakeCabinet < Sketchup::ComponentInstance
  attr_reader :transformation, :attrs, :parent

  def initialize(transformation, params, parent)
    super()
    @transformation = transformation
    @parent = parent
    env = KitchenCabinetMaster::CabinetLayout.envelope(params)
    @attrs = { 'width' => params['width'], 'envelope_depth' => env[0], 'envelope_width' => env[1], 'envelope_top' => env[2] }
  end

  def get_attribute(_dict, key) = @attrs[key]
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

class FakeModel
  attr_reader :active_entities

  def initialize(entities) = @active_entities = entities
end

class PlacementTest < Minitest::Test
  include KitchenCabinetMaster

  def setup
    @entities = FakeEntities.new
    @model = FakeModel.new(@entities)
    @parent = FakeParent.new(@entities)
    SelectionManager.selected = nil
  end

  def params(category, width, depth: 560.0)
    Defaults.params.merge('cabinet_category' => category, 'width' => width, 'depth' => depth,
                          'height' => 720.0, 'toe_kick_height' => 100.0)
  end

  # Inserts like CabinetManager.insert: place, then the new cabinet becomes the selection.
  def insert(category, width, depth: 560.0)
    p = params(category, width, depth: depth)
    _entities, transformation = PlacementManager.target_for_new(@model, p)
    cabinet = FakeCabinet.new(transformation, p, @parent)
    @entities.add(cabinet)
    SelectionManager.selected = cabinet
    cabinet
  end

  def at(cabinet, x, y) = cabinet.transformation * Geom::Point3d.new(x, y, 0)

  def assert_point(expected, actual, msg)
    assert_in_delta expected[0], actual.x, 0.01, "#{msg} (x)"
    assert_in_delta expected[1], actual.y, 0.01, "#{msg} (y)"
  end

  def test_first_corner_with_nothing_selected_goes_at_the_origin_unturned
    corner = insert('corner', 900.0)
    assert_point [0, 0], corner.transformation.origin, 'origin'
    assert_in_delta 1.0, corner.transformation.xaxis.x, 1e-9
  end

  def test_corner_after_a_cabinet_is_turned_a_quarter_turn_at_the_end_of_the_row
    base = insert('base', 600.0)
    corner = insert('corner', 900.0)

    # The base ends at Y = 600. The corner takes Y 600..1500 and its back is on the Y = 1500 wall.
    assert_point [0, 1500], corner.transformation.origin, 'corner origin'
    assert_point [0, 1500], at(corner, 0, 0), 'local back-left is the room corner'
    assert_point [900, 1500], at(corner, 0, 900), 'corner runs along +X after the turn'
    assert_point [0, 600], at(corner, 900, 0), 'front-return end meets the previous cabinet'
    assert_in_delta(-1.0, corner.transformation.xaxis.y, 1e-9, 'its front now faces -Y')
    assert_equal 600.0, base.get_attribute('kcm', 'width')
  end

  def test_the_next_cabinet_carries_on_along_the_turned_row
    insert('base', 600.0)
    corner = insert('corner', 900.0)
    next_cabinet = insert('base', 600.0)

    # Right after the corner, along the turned direction (+X), same rotation.
    assert_point [900, 1500], next_cabinet.transformation.origin, 'next cabinet origin'
    assert_in_delta(-1.0, next_cabinet.transformation.xaxis.y, 1e-9, 'shares the corner rotation')
    assert_in_delta 1.0, next_cabinet.transformation.yaxis.x, 1e-9, 'its row runs along +X'

    third = insert('base', 400.0)
    assert_point [1500, 1500], third.transformation.origin, 'and the one after that'
    refute_nil corner
  end

  def test_the_turned_row_does_not_overlap_the_first_row
    insert('base', 600.0)
    insert('corner', 900.0)
    insert('base', 600.0)

    boxes = PlacementManager.existing_boxes(@entities)
    boxes.combination(2).each do |one, two|
      refute PlacementManager.overlap?(one, two), 'two cabinets share volume'
    end
  end

  def test_gap_is_added_before_the_corner_and_after_it
    p = params('corner', 900.0).merge('placement_gap' => 10.0)
    base = FakeCabinet.new(Geom::Transformation.new, params('base', 600.0), @parent)
    @entities.add(base)
    SelectionManager.selected = base
    _e, turned = PlacementManager.target_for_new(@model, p)

    assert_in_delta 1510.0, turned.origin.y, 0.01, 'gap before the corner, then its own width'
  end

  def test_ordinary_cabinets_still_run_straight_along_y
    insert('base', 600.0)
    second = insert('base', 800.0)
    third = insert('wall', 500.0)
    assert_point [0, 600], second.transformation.origin, 'second'
    assert_point [0, 1400], third.transformation.origin, 'third'
  end

  def test_corner_footprint_is_the_square_with_no_door_overhang
    assert_equal [900.0, 900.0, 820.0], CabinetLayout.envelope(params('corner', 900.0))
  end
end
