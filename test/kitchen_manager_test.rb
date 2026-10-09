# frozen_string_literal: true

# KitchenManager (Design Kitchen) with the SketchUp side faked: what it asks the cabinet engine to build, and where.
# Run:  ruby test/kitchen_manager_test.rb

require 'json'
require 'tmpdir'
require 'minitest/autorun'
require_relative 'geom_stub'

module Geom
  class Vector3d
    # (the real Vector3d has this setter)
    def length=(value)
      current = Math.sqrt((x * x) + (y * y) + (z * z))
      factor = current.zero? ? 0.0 : value / current
      self.x *= factor
      self.y *= factor
      self.z *= factor
    end
  end
end

module Sketchup
  class FakeSelection
    attr_reader :cleared, :items

    def initialize = @items = []
    def clear = (@cleared = true; @items = [])
    def add(item) = @items << item
  end

  class FakeModel
    attr_reader :selection

    def initialize = @selection = FakeSelection.new
    def active_entities = :entities
    def start_operation(*) = (@operations = (@operations || 0) + 1)
    def commit_operation = (@commits = (@commits || 0) + 1)
    def abort_operation = (@aborts = (@aborts || 0) + 1)
    attr_reader :operations, :commits, :aborts
  end

  def self.active_model = (@model ||= FakeModel.new)
end

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)

  Built = Struct.new(:params, :transformation)

  module AttributeManager
    @id = 0
    def self.next_cabinet_id(_model) = "C#{@id += 1}"
    def self.next_sequence(_model) = @id
    def self.read(instance) = instance.params
  end

  module NamingManager
    def self.unique_name(_entities, base) = base
    def self.base_name(params) = params['cabinet_type']
  end

  module SelectionManager
    def self.push_selection(_model = nil) = nil
  end

  module WorktopManager
    class << self
      attr_reader :applied

      def apply(values)
        @applied = values
        { 'ok' => true, 'message' => '' }
      end
    end
  end

  # A row that continues along the last unit's own Y (a corner turns it a quarter, as in the real one), wall units up on the wall.
  module PlacementManager
    class << self
      attr_accessor :last

      def reset = @last = nil

      def target_for_new(_model, params)
        transformation =
          if @last
            slot = @last.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, @last.params['width'], 0))
            params['corner_style'].to_s.empty? ? slot : slot * Geom::Transformation.translation(Geom::Vector3d.new(0, params['width'], 0)) * Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), nil, -Math::PI / 2)
          else
            Geom::Transformation.new
          end
        [:entities, transformation]
      end

      def wall_origin_z(_model, _params, _selected = nil) = 1480.0
    end
  end

  module CabinetManager
    def self.with_operation(_model, name)
      (@operations ||= []) << name
      yield
    end

    def self.operations = @operations

    def self.prepare(raw)
      cabinet = CatalogManager.cabinet(raw['catalog_id'], raw['cabinet_category'], raw['cabinet_type'])
      return [nil, { 'message' => 'no such unit' }] unless cabinet
      return [nil, { 'message' => 'does not fit' }] if raw['fail_on'] == raw['cabinet_type']

      [raw.merge('corner_style' => cabinet['corner'].to_s, 'width' => raw['width'].to_f), nil]
    end
  end

  # The toe kick and the end panel buttons: what they were asked, with what selected, and whether they ran inside the kitchen's own operation.
  module PartManager
    class << self
      attr_reader :calls

      def reset = @calls = []
      def insert_toe_kick(raw) = record(:toe_kick, raw)
      def insert_end_panel(raw) = record(:end_panel, raw)

      def record(kind, raw)
        (@calls ||= []) << { kind: kind, raw: raw, selected: Sketchup.active_model.selection.items.dup, building: KitchenManager.building? }
        { 'ok' => true, 'message' => '' }
      end
    end
  end

  module CabinetGenerator
    def self.build(_model, _entities, params, transformation)
      built = Built.new(params, transformation)
      PlacementManager.last = built
      (@made ||= []) << built
      built
    end

    def self.made = @made

    def self.reset = @made = []
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults catalog_manager kitchen_planner kitchen_manager].each { |f| require File.join(plugin, f) }

class KitchenManagerTest < Minitest::Test
  include KitchenCabinetMaster

  def setup
    CatalogManager.user_root_override = Dir.mktmpdir('kcm') if defined?(Dir.mktmpdir)
    PlacementManager.reset
    CabinetGenerator.reset
    PartManager.reset
    WorktopManager.instance_variable_set(:@applied, nil)
  end

  def design(kitchen = {}, extra = {})
    KitchenManager.design({ 'kitchen' => kitchen, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets', 'base_material' => 'White' } }.merge(extra))
  end

  def made = CabinetGenerator.made

  def test_it_builds_every_unit_of_the_plan_in_one_operation_with_the_units_own_catalog_values
    before = Sketchup.active_model.operations.to_i
    result = design('wall_a' => 3600)
    assert result['ok'], result['message']
    plan = KitchenPlanner.plan('wall_a' => 3600)
    assert_equal plan.base.length + plan.wall.length, made.length
    assert_equal 1, Sketchup.active_model.operations - before, 'one Undo step'
    sink = made.find { |built| built.params['cabinet_type'] == 'base_sink' }
    assert_equal 560, sink.params['depth']
    assert_equal 780, sink.params['height']
    assert_equal 0.0, sink.params['placement_gap'], 'units touch'
    assert_match(/Kitchen designed/, result['message'])
  end

  def test_the_first_wall_unit_goes_over_the_start_of_wall_a_after_the_fridge_at_the_wall_height
    design('wall_a' => 3600)
    first_wall = made.find { |built| built.params['cabinet_category'] == 'wall' }
    first_base = made.first
    assert_in_delta first_base.transformation.ty + 600.0, first_wall.transformation.ty, 0.01, 'after the 600 mm fridge housing'
    assert_in_delta 1480.0, first_wall.transformation.tz, 0.01
  end

  def test_a_window_leaves_a_gap_in_the_wall_units
    design('wall_a' => 4200, 'windows' => [{ 'wall' => 'a', 'from' => 1800, 'width' => 1200 }])
    walls = made.select { |built| built.params['cabinet_category'] == 'wall' }
    starts = walls.map { |built| built.transformation.ty.round(1) }
    assert_includes starts, 3000.0, 'the unit after the window starts where the window ends'
    refute(starts.any? { |y| y > 1800.0 && y < 3000.0 }, 'nothing over the window')
  end

  def test_the_island_is_turned_round_and_put_by_measure
    design('wall_a' => 4200, 'island' => true)
    island = made.select { |built| built.params['cabinet_type'] == 'base_3drawer' }.last(3)
    first = island.first.transformation
    assert_in_delta(-1.0, first.xaxis.x, 1e-9, 'its fronts look at wall A')
    assert_in_delta 580.0 + 1100.0 + 580.0, first.tx, 0.01
    assert_in_delta 3000.0, first.ty, 0.5
  end

  def test_make_three_options_builds_one_kitchen_per_style_side_by_side
    result = KitchenManager.design('options' => true, 'kitchen' => { 'wall_a' => 3600 }, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets' })
    assert result['ok'], result['message']
    plans = %w[classic glass lift].map { |style| KitchenPlanner.plan('wall_a' => 3600, 'style' => style) }
    assert_equal plans.sum { |plan| plan.base.length + plan.wall.length }, made.length
    firsts = made.select { |built| built.params['cabinet_type'] == 'tall_fridge_builtin_2door' }
    assert_equal 3, firsts.length
    assert_in_delta 0.0, firsts[0].transformation.ty, 0.01
    assert_in_delta 3600.0 + 2500.0, firsts[1].transformation.ty, 0.01
    assert_in_delta 2 * (3600.0 + 2500.0), firsts[2].transformation.ty, 0.01
    assert_match(/Option 1 \(doors\)/, result['message'])
    assert_match(/Option 3 \(lift-up wall units over drawers\)/, result['message'])
    assert(made.any? { |built| built.params['glass_design'] == 'glass_wide_grid' }, 'the glass option has glass doors')
    assert(made.any? { |built| built.params['cabinet_type'] == 'wall_liftup_bifold' })
  end

  def test_the_worktop_is_added_with_the_worktop_values_of_the_panel
    result = design({ 'wall_a' => 3000 }, 'worktop' => { 'worktop_thickness' => 30 })
    assert_equal({ 'worktop_thickness' => 30 }, WorktopManager.applied)
    assert_match(/Worktop and back splash added/, result['message'])
    WorktopManager.instance_variable_set(:@applied, nil)
    design({ 'wall_a' => 3000 })
    assert_nil WorktopManager.applied, 'no worktop values: no worktop'
  end

  def test_it_says_so_when_there_is_no_catalog_or_the_model_lacks_a_unit_or_a_unit_does_not_fit
    refute KitchenManager.design('kitchen' => {}, 'cabinet' => {})['ok']
    refute KitchenManager.design('kitchen' => { 'wall_a' => 100 }, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets' })['ok'], 'a wall that is too short'
    failed = KitchenManager.design('kitchen' => { 'wall_a' => 3600 }, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets', 'fail_on' => 'base_hob' })
    refute failed['ok']
    assert_match(/does not fit/, failed['message'])
  end

  def test_toe_kicks_go_under_the_row_and_the_island_each_against_its_first_unit_inside_the_one_operation
    design({ 'wall_a' => 4200, 'island' => true }, 'toe_kick' => { 'toe_kick_height' => 100, 'toe_kick_cover_row' => false })
    calls = PartManager.calls.select { |call| call[:kind] == :toe_kick }
    assert_equal 2, calls.length
    assert_equal [made.first], calls[0][:selected], 'the first unit of the kitchen'
    assert_equal made.last(3).first, calls[1][:selected].first, 'the first unit of the island'
    assert(calls.all? { |call| call[:raw]['toe_kick_cover_row'] == true }, 'it covers the whole row')
    assert(calls.all? { |call| call[:building] }, 'inside the kitchen operation')
    refute KitchenManager.building?
    assert_match(/Toe kicks: 1\./, KitchenManager.design('kitchen' => { 'wall_a' => 3000 }, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets' }, 'toe_kick' => {})['message'])
  end

  def test_end_panels_go_on_the_open_ends_only
    design({ 'wall_a' => 3600 }, 'end_panel' => { 'face' => 'flat' })
    assert_empty PartManager.calls.select { |call| call[:kind] == :end_panel }, 'a straight kitchen stands between two walls'
    PartManager.reset
    CabinetGenerator.reset
    result = design({ 'layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'island' => true }, 'end_panel' => { 'face' => 'flat' })
    panels = PartManager.calls.select { |call| call[:kind] == :end_panel }
    assert_equal 5, panels.length, 'both ends of the island, the two ends of the base units, and the wall unit at the far end (the fridge is at the other)'
    assert(panels.all? { |call| call[:raw]['depth_auto'] && call[:raw]['height_auto'] })
    assert_equal 2, panels.count { |call| call[:raw]['side'] == 'left' }
    assert_equal 3, panels.count { |call| call[:raw]['side'] == 'right' }
    assert_match(/End panels: 5/, result['message'])
    assert_empty Sketchup.active_model.selection.items, 'nothing is left selected'
  end

  def test_a_part_that_cannot_be_made_is_reported_and_does_not_stop_the_kitchen
    PartManager.singleton_class.send(:define_method, :record) do |kind, raw|
      (@calls ||= []) << { kind: kind, raw: raw, selected: [], building: true }
      { 'ok' => false, 'message' => 'something is in the way' }
    end
    result = design({ 'wall_a' => 3600 }, 'toe_kick' => {})
    assert result['ok']
    assert_match(/A toe kick was not added: something is in the way/, result['message'])
  ensure
    PartManager.singleton_class.send(:define_method, :record) do |kind, raw|
      (@calls ||= []) << { kind: kind, raw: raw, selected: Sketchup.active_model.selection.items.dup, building: KitchenManager.building? }
      { 'ok' => true, 'message' => '' }
    end
  end

  def test_the_dishwasher_space_is_built_next_to_the_sink
    design('wall_a' => 3600)
    types = made.select { |built| built.params['cabinet_category'] == 'base' }.map { |built| built.params['cabinet_type'] }
    assert_equal types.index('base_sink') + 1, types.index('base_dishwasher')
    dish = made.find { |built| built.params['cabinet_type'] == 'base_dishwasher' }
    assert_equal 600.0, dish.params['width']
    design({ 'wall_a' => 3600, 'dishwasher' => false })
    refute(made.last(8).any? { |built| built.params['cabinet_type'] == 'base_dishwasher' })
  end

  def test_a_mirrored_kitchen_is_built_from_the_other_end_and_the_wall_units_start_after_the_oven_housing
    design('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'oven_tower' => true, 'mirror' => true)
    assert_equal 'tall_oven', made.first.params['cabinet_type']
    walls = made.select { |built| built.params['cabinet_category'] == 'wall' }
    assert_in_delta made.first.transformation.ty + 600.0, walls.first.transformation.ty, 0.01
    assert_equal 'tall_fridge_builtin_2door', made.select { |built| built.params['cabinet_category'] == 'tall' }.last.params['cabinet_type']
  end

  def test_an_island_with_the_hob_is_built_with_the_hob_unit_in_the_island_and_none_on_the_wall
    design('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob')
    hobs = made.select { |built| built.params['cabinet_type'] == 'base_hob' }
    assert_equal 1, hobs.length
    assert_in_delta(-1.0, hobs.first.transformation.xaxis.x, 1e-9, 'it stands in the island, turned towards wall A')
    refute(made.any? { |built| built.params['cabinet_type'] == 'wall_hood' }, 'no hood on the wall')
    assert_equal 1, made.count { |built| built.params['cabinet_type'] == 'base_sink' }
  end
end
