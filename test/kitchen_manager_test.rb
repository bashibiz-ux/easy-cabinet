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
    def entities = KitchenCabinetMaster::CabinetGenerator.made.to_a
    def get_attribute(_dictionary, key, default = nil) = (@attributes ||= {}).fetch(key, default)
    def set_attribute(_dictionary, key, value) = ((@attributes ||= {})[key] = value)
    def find_entity_by_persistent_id(id) = entities.find { |entity| entity.persistent_id == id }
    def start_operation(*) = (@operations = (@operations || 0) + 1)
    def commit_operation = (@commits = (@commits || 0) + 1)
    def abort_operation = (@aborts = (@aborts || 0) + 1)
    attr_reader :operations, :commits, :aborts
  end

  def self.active_model = (@model ||= FakeModel.new)
end

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)

  Built = Struct.new(:params, :transformation) do
    def persistent_id = object_id
    def valid? = !@erased
    def erase! = (@erased = true)
    def get_attribute(_dictionary, key, default = nil) = key == 'top_z' ? 880.0 : default
    def set_attribute(dictionary, key, value) = (attributes[[dictionary, key]] = value)
    def attributes = (@attributes ||= {})
  end

  module AttributeManager
    DICTIONARY = 'KitchenCabinetMaster'
    @id = 0
    def self.next_cabinet_id(_model) = "C#{@id += 1}"
    def self.next_sequence(_model) = @id
    def self.read(instance) = instance.params
    def self.cabinet?(instance) = instance.respond_to?(:params)
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

  # The toe kick and the side panel buttons: what they were asked, with what selected, and whether they ran inside the kitchen's own operation.
  module PartManager
    class << self
      attr_reader :calls

      def reset = @calls = []
      def insert_toe_kick(raw) = record(:toe_kick, raw)
      def insert_end_panel(raw) = record(:end_panel, raw)

      # (the real one finds what shows of the side; here every side asked for is a panel)
      def place_exposed_panels(_model, target, side, raw) = (record(:end_panel, raw.merge('side' => side, 'unit' => target)); [1, 0, []])

      def record(kind, raw)
        (@calls ||= []) << { kind: kind, raw: raw, selected: Sketchup.active_model.selection.items.dup, building: KitchenManager.building? }
        { 'ok' => true, 'message' => '' }
      end
    end
  end

  module DimensionManager
    class << self
      attr_reader :asked

      def add(_model, units) = ((@asked ||= []) << units.length; units.length)
    end
  end

  module CabinetGenerator
    def self.build(_model, _entities, params, transformation)
      built = Built.new(params, transformation)
      PlacementManager.last = built
      (@made ||= []) << built
      built
    end

    def self.remove(_model, root) = root.erase!

    def self.made = @made

    def self.reset = @made = []
  end
end

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults catalog_manager kitchen_planner island_hood island_back_panel kitchen_manager].each { |f| require File.join(plugin, f) }

class KitchenManagerTest < Minitest::Test
  include KitchenCabinetMaster

  HoodSpy = []
  IslandHood.singleton_class.send(:define_method, :build) { |_model, _entities, frame, hood| HoodSpy << [frame, hood] }
  BackPanelSpy = []
  IslandBackPanel.singleton_class.send(:define_method, :build) { |_model, _entities, frame, spec| BackPanelSpy << [frame, spec] }

  def setup
    CatalogManager.user_root_override = Dir.mktmpdir('kcm') if defined?(Dir.mktmpdir)
    PlacementManager.reset
    CabinetGenerator.reset
    PartManager.reset
    WorktopManager.instance_variable_set(:@applied, nil)
    HoodSpy.clear
    BackPanelSpy.clear
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

  def test_side_panels_are_asked_for_every_side_except_the_ends_of_a_row_that_may_stand_against_a_wall
    design({ 'wall_a' => 3600 }, 'end_panel' => { 'face' => 'flat' })
    asked = PartManager.calls.select { |call| call[:kind] == :end_panel }
    refute_empty asked, 'the sides between units are looked at: a taller unit shows its side beside a lower one'
    first = made.first
    refute(asked.any? { |call| call[:raw]['unit'].equal?(first) && call[:raw]['side'] == 'left' }, 'the left end of a straight kitchen is against a wall')
    PartManager.reset
    CabinetGenerator.reset
    design({ 'wall_a' => 3600, 'open_ends' => true }, 'end_panel' => { 'face' => 'flat' })
    open = PartManager.calls.select { |call| call[:kind] == :end_panel }
    assert(open.any? { |call| call[:raw]['unit'].equal?(made.first) && call[:raw]['side'] == 'left' }, 'unless the ends are open')
  end

  def test_side_panels_on_the_island_ends_only_when_asked
    design({ 'wall_a' => 4200, 'island' => true }, 'end_panel' => {})
    island = made.last(3)
    refute(PartManager.calls.any? { |call| call[:raw]['unit'].equal?(island.first) && call[:raw]['side'] == 'left' })
    PartManager.reset
    CabinetGenerator.reset
    result = design({ 'wall_a' => 4200, 'island' => true, 'island_side_panels' => true }, 'end_panel' => {})
    island = made.last(3)
    assert(PartManager.calls.any? { |call| call[:raw]['unit'].equal?(island.first) && call[:raw]['side'] == 'left' })
    assert(PartManager.calls.any? { |call| call[:raw]['unit'].equal?(island.last) && call[:raw]['side'] == 'right' })
    assert_match(/Side panels: \d+/, result['message'])
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

  def test_an_island_hob_gets_its_hood_hung_over_the_hob_in_the_islands_frame
    design({ 'wall_a' => 4200, 'island' => true, 'island_feature' => 'hob' })
    assert_equal 1, HoodSpy.length
    frame, hood = HoodSpy.first
    assert_equal made.find { |built| built.params['cabinet_type'] == 'base_hob' }.params['width'], hood[:width]
    assert_in_delta 180.0, frame.rotation_degrees, 0.5 if frame.respond_to?(:rotation_degrees)
    design({ 'wall_a' => 4200, 'island' => true, 'island_feature' => 'hob', 'hood' => false })
    assert_equal 1, HoodSpy.length, 'no hood, none built'
  end

  def test_every_island_unit_is_marked_with_its_seating_overhang_for_the_worktop
    design({ 'wall_a' => 4200, 'island' => true, 'island_seating' => 300 })
    island = made.select { |built| built.attributes.key?(['KitchenCabinetMaster', 'island_seating']) }
    assert_operator island.length, :>=, 2
    assert(island.all? { |built| built.attributes[['KitchenCabinetMaster', 'island_seating']] == 300.0 })
    refute_equal made.length, island.length, 'the wall units are not marked'
  end

  def test_a_hood_that_cannot_be_drawn_does_not_stop_the_kitchen_and_the_reply_says_why
    IslandHood.singleton_class.send(:define_method, :build) { |*| raise 'no room' }
    result = design({ 'wall_a' => 4200, 'island' => true, 'island_feature' => 'hob' })
    assert result['ok'], result['message']
    assert_includes result['message'], 'The island hood could not be drawn: no room'
    assert_operator made.length, :>, 5, 'the kitchen is there'
  ensure
    IslandHood.singleton_class.send(:define_method, :build) { |_model, _entities, frame, hood| HoodSpy << [frame, hood] }
  end

  def test_an_island_back_panel_is_built_the_height_of_the_units_in_the_door_material
    design({ 'wall_a' => 4200, 'island' => true, 'island_back_panel' => true })
    assert_equal 1, BackPanelSpy.length
    spec = BackPanelSpy.first.last
    assert_equal 880.0, spec[:height]
    assert_equal 'White', spec[:material]
    assert_operator spec[:length], :>, 1000.0
    design({ 'wall_a' => 4200, 'island' => true })
    assert_equal 1, BackPanelSpy.length, 'not asked, not built'
  end

  def test_a_live_update_takes_the_kitchen_away_and_builds_it_again_where_it_stood
    design({ 'wall_a' => 3600 })
    first_run = made.dup
    original = first_run.first.transformation.to_a
    assert_operator first_run.length, :>, 3
    result = design({ 'wall_a' => 3000 }, 'replace' => true)
    assert result['ok'], result['message']
    assert(first_run.none?(&:valid?), 'the kitchen designed before is gone')
    rebuilt = made - first_run
    assert_operator rebuilt.length, :>, 3
    assert_equal original, rebuilt.first.transformation.to_a, 'built again at the same place'
  end

  def test_a_design_without_replace_leaves_the_earlier_kitchen_alone
    design({ 'wall_a' => 3600 })
    first_run = made.dup
    design({ 'wall_a' => 3000 })
    assert(first_run.all?(&:valid?))
  end
  def test_dimensions_are_drawn_on_the_kitchens_units_when_asked
    DimensionManager.instance_variable_set(:@asked, [])
    result = design({ 'wall_a' => 3600, 'dimensions' => true })
    assert_equal [made.length], DimensionManager.asked
    assert_match(/Dimensions: #{made.length}\./, result['message'])
    design({ 'wall_a' => 3600 })
    assert_equal 1, DimensionManager.asked.length, 'not asked, not drawn'
  end
  def test_two_bowls_reach_the_sink_unit_and_one_bowl_is_the_catalogs_own
    design({ 'wall_a' => 4800, 'sink_bowls' => 2 })
    sink = made.find { |built| built.params['cabinet_type'] == 'base_sink' }
    assert_equal 2, sink.params['sink_bowls']
    assert_equal 1200.0, sink.params['width']
    CabinetGenerator.reset
    design({ 'wall_a' => 4800 })
    assert_equal 1, made.find { |built| built.params['cabinet_type'] == 'base_sink' }.params['sink_bowls']
  end
  def test_the_unit_beside_a_tall_one_is_moved_along_by_the_panel_thickness
    design({ 'wall_a' => 4200, 'panel_thickness' => 18 })
    fridge = made.first
    after = made[1]
    gap = after.transformation.ty - (fridge.transformation.ty + fridge.params['width'])
    assert_in_delta 18.0, gap, 0.01, 'room for the panel between the fridge and the next unit'
    CabinetGenerator.reset
    PlacementManager.reset
    design({ 'wall_a' => 4200 })
    assert_in_delta 0.0, made[1].transformation.ty - (made.first.transformation.ty + made.first.params['width']), 0.01
  end
end