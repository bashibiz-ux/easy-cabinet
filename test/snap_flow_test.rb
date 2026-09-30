# frozen_string_literal: true

# The whole snap, from "a cabinet was moved" to "it has been nudged and the panel
# told": SnapManager's real modified / request / settle / snap code with the real
# PlacementManager and AttributeManager, run against fake SketchUp objects.
#   ruby test/snap_flow_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class EntitiesObserver; end
  class ToolsObserver; end
  class AppObserver; end
  class ComponentInstance; end
  Layer = Struct.new(:visible?)

  class Face
    attr_reader :normal, :outer_loop

    def initialize(normal, points)
      @normal = normal
      @outer_loop = Struct.new(:vertices).new(points.map { |p| Struct.new(:position).new(p) })
    end
  end

  class Group; end

  @snap_default = true
  class << self
    attr_accessor :snap_default

    def read_default(_section, _key, default) = snap_default.nil? ? default : snap_default
    def write_default(_section, _key, value) = self.snap_default = value
  end
end

# UI timers are captured so the test decides when they "fire".
module UI
  @timers = []
  class << self
    attr_reader :timers

    def start_timer(delay, _repeat, &block)
      @timers << { delay: delay, block: block }
      @timers.length
    end

    def stop_timer(id) = @timers[id - 1] = nil
    def fire_all = @timers.compact.each { |t| t[:block].call }.tap { @timers.clear }
  end
end

module KitchenCabinetMaster
  module DialogManager
    @messages = []
    class << self
      attr_reader :messages

      def push(event, data = {}) = @messages << [event, data]
    end
  end

  module SelectionManager
    def self.suspended? = false
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout placement_manager snap_manager].each { |f| require File.join(plugin, f) }

class FakeModel
  attr_reader :entities, :operations

  def initialize(entities)
    @entities = entities
    @operations = []
  end

  def start_operation(*args) = @operations << [:start, *args]
  def commit_operation = @operations << [:commit]
  def abort_operation = @operations << [:abort]
end

class FakeEntities
  include Enumerable

  def initialize = @items = []
  def add(item) = @items << item
  def each(&block) = @items.each(&block)
  def grep(klass) = @items.grep(klass)
end

class FakeCabinet < Sketchup::ComponentInstance
  attr_accessor :transformation
  attr_reader :parent, :name, :model, :persistent_id

  @@next_id = 0

  def initialize(model, entities, y:, x: 0.0, width: 600.0, name: 'BU600')
    super()
    @persistent_id = (@@next_id += 1)
    @model = model
    @parent = Struct.new(:entities).new(entities)
    @name = name
    @transformation = Geom::Transformation.translation(Geom::Vector3d.new(x, y, 0))
    env = KitchenCabinetMaster::CabinetLayout.envelope(
      KitchenCabinetMaster::Defaults.params.merge('cabinet_category' => 'base', 'width' => width, 'depth' => 560.0,
                                                  'height' => 780.0, 'toe_kick_height' => 100.0)
    )
    @attrs = { 'cabinet_id' => "CABINET_#{@persistent_id}", 'width' => width, 'envelope_depth' => env[0],
               'envelope_width' => env[1], 'envelope_top' => env[2] }
  end

  def valid? = true
  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def transform!(shift) = @transformation = shift * @transformation
  def hidden? = false
  def layer = Sketchup::Layer.new(true)
end

class SnapFlowTest < Minitest::Test
  Snap = KitchenCabinetMaster::SnapManager
  V = Geom::Vector3d
  P = Geom::Point3d

  def setup
    @entities = FakeEntities.new
    @model = FakeModel.new(@entities)
    Snap.instance_variable_set(:@known, {})
    Snap.instance_variable_set(:@dirty, {})
    Snap.instance_variable_set(:@busy, false)
    Sketchup.snap_default = true
    UI.timers.clear
    KitchenCabinetMaster::DialogManager.messages.clear
  end

  def cabinet(**opts)
    c = FakeCabinet.new(@model, @entities, **opts)
    @entities.add(c)
    c
  end

  # A wall along Y at X = 0, 4 m long, 2.4 m tall.
  def add_back_wall
    @entities.add(Sketchup::Face.new(V.new(1, 0, 0), [P.new(0, 0, 0), P.new(0, 4000, 0), P.new(0, 4000, 2400), P.new(0, 0, 2400)]))
  end

  # The user moves a cabinet (the Move tool changes its transformation), then the
  # plugin hears about it, then the timer fires.
  def move_and_settle(entity, dx: 0.0, dy: 0.0)
    Snap.remember(entity)
    entity.transform!(Geom::Transformation.translation(V.new(dx, dy, 0)))
    Snap.modified(entity)
    UI.fire_all
  end

  def origin(entity) = [entity.transformation.origin.x, entity.transformation.origin.y]

  def assert_origin(expected, entity)
    x, y = origin(entity)
    assert_in_delta expected[0], x, 1e-6, 'x'
    assert_in_delta expected[1], y, 1e-6, 'y'
  end

  def test_a_moved_cabinet_snaps_its_side_against_the_neighbour
    cabinet(y: 0.0)                          # A: Y 0..600
    b = cabinet(y: 1200.0, name: 'BU600')    # B, then dragged to 40 mm clear of A
    move_and_settle(b, dy: -560.0)
    assert_origin [0.0, 600.0], b
    assert_equal [['snap', { 'message' => 'BU600 snapped to the next cabinet.' }]], KitchenCabinetMaster::DialogManager.messages
  end

  def test_the_snap_is_one_transparent_operation_so_undo_takes_back_both
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    move_and_settle(b, dy: -560.0)
    assert_equal [[:start, 'Snap Cabinet', true, false, true], [:commit]], @model.operations
  end

  def test_the_back_snaps_onto_the_wall
    add_back_wall
    b = cabinet(y: 1000.0, x: 0.0)
    move_and_settle(b, dx: 80.0)             # dragged 80 mm off the wall
    assert_origin [0.0, 1000.0], b
    assert_equal 'BU600 snapped to the wall.', KitchenCabinetMaster::DialogManager.messages.last[1]['message']
  end

  def test_sides_and_wall_together
    add_back_wall
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    move_and_settle(b, dx: 60.0, dy: -560.0) # 60 forward of the wall, 40 short of the neighbour
    assert_origin [0.0, 600.0], b
    assert_equal 'BU600 snapped to the next cabinet.', KitchenCabinetMaster::DialogManager.messages.last[1]['message'],
                 'the back was already level with the neighbour, which is on the wall'
  end

  def test_a_cabinet_far_from_everything_is_left_where_it_was_put
    cabinet(y: 0.0)
    b = cabinet(y: 3000.0)
    move_and_settle(b, dy: -300.0)           # still ~2 m from A
    assert_origin [0.0, 2700.0], b
    assert_empty KitchenCabinetMaster::DialogManager.messages
    assert_empty @model.operations
  end

  def test_nothing_happens_when_snapping_is_switched_off
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    Sketchup.snap_default = false
    move_and_settle(b, dy: -560.0)
    assert_origin [0.0, 640.0], b
    assert_empty @model.operations
  end

  def test_a_change_that_did_not_move_the_cabinet_is_ignored
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    Snap.remember(b)
    Snap.modified(b) # e.g. an attribute write: same transformation
    assert_empty UI.timers.compact, 'nothing was scheduled'
  end

  def test_the_snap_is_handed_to_a_timer_not_done_inside_the_callback
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    Snap.remember(b)
    b.transform!(Geom::Transformation.translation(V.new(0, -560, 0)))
    Snap.modified(b)
    assert_origin [0.0, 640.0], b   # not moved yet
    assert_equal 1, UI.timers.compact.length
    UI.fire_all
    assert_origin [0.0, 600.0], b   # moved once the timer fires
  end

  def test_a_cabinet_turned_off_the_grid_is_not_snapped
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    Snap.remember(b)
    b.transformation = Geom::Transformation.rotation(P.new(0, 0, 0), V.new(0, 0, 1), 0.3) * b.transformation
    Snap.modified(b)
    UI.fire_all
    assert_empty @model.operations
  end

  def test_a_failure_is_reported_not_swallowed
    cabinet(y: 0.0)
    b = cabinet(y: 1200.0)
    Snap.remember(b)
    b.transform!(Geom::Transformation.translation(V.new(0, -560, 0))) # the user's own move works ...
    Snap.modified(b)
    b.define_singleton_method(:transform!) { |_t| raise 'boom' }      # ... the snap's does not
    UI.fire_all
    assert_match(/Could not snap BU600: boom/, KitchenCabinetMaster::DialogManager.messages.last[1]['message'])
    assert_includes @model.operations, [:abort]
  end
end
