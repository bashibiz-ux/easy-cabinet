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
    attr_reader :cleared

    def clear = @cleared = true
  end

  class FakeModel
    attr_reader :selection

    def initialize = @selection = FakeSelection.new
    def active_entities = :entities
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
    WorktopManager.instance_variable_set(:@applied, nil)
  end

  def design(kitchen = {}, extra = {})
    KitchenManager.design({ 'kitchen' => kitchen, 'cabinet' => { 'catalog_id' => 'kitchen_cabinets', 'base_material' => 'White' } }.merge(extra))
  end

  def made = CabinetGenerator.made

  def test_it_builds_every_unit_of_the_plan_in_one_operation_with_the_units_own_catalog_values
    result = design('wall_a' => 3600)
    assert result['ok'], result['message']
    plan = KitchenPlanner.plan('wall_a' => 3600)
    assert_equal plan.base.length + plan.wall.length, made.length
    assert_equal ['Design Kitchen'], CabinetManager.operations.last(1)
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
end
