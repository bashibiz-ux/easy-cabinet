# frozen_string_literal: true

# The plan of a whole kitchen from a few answers (KitchenPlanner): pure maths.
# Run:  ruby test/kitchen_planner_test.rb

require 'json'
require 'minitest/autorun'

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
require File.join(plugin, 'kitchen_planner')

class KitchenPlannerTest < Minitest::Test
  include KitchenCabinetMaster

  CATALOG = JSON.parse(File.read(File.expand_path('../kitchen_cabinet_master/data/catalogs/kitchen_cabinets.json', __dir__)))
  IDS = CATALOG['categories'].to_h { |category, list| [category, list.map { |entry| entry['id'] }] }

  def plan(options = {})
    KitchenPlanner.plan(options)
  end

  def run_sum(items, run)
    items.select { |item| item.run == run }.sum(&:width).round(1)
  end

  def test_the_units_of_a_straight_kitchen_fill_the_wall_exactly
    [2700, 3000, 3300, 3600, 4200, 5100, 6000].each do |length|
      result = plan('wall_a' => length)
      assert_nil result.error, "#{length}: #{result.error}"
      assert_in_delta length, run_sum(result.base, :a), 0.5, "the base units of a #{length} mm wall"
      assert_equal [0.0] + result.base.each_cons(2).map { |a, b| (b.start - (a.start + a.width)).round(1) }.map { 0.0 }.uniq.first(0), [0.0]
      result.base.each_cons(2) { |a, b| assert_in_delta a.start + a.width, b.start, 0.5, 'each unit starts where the one before it ends' }
    end
  end

  def test_the_fridge_stands_at_the_start_and_the_sink_hob_and_hood_are_where_they_belong
    result = plan
    assert_equal :fridge, result.base.first.kind
    assert_equal 'tall', result.base.first.category
    kinds = result.base.map(&:kind)
    assert_operator kinds.index(:sink), :<, kinds.index(:hob)
    sink_at = kinds.index(:sink)
    hob_at = kinds.index(:hob)
    assert_operator hob_at - sink_at, :>=, 2, 'worktop between the sink and the hob'
    hob = result.base[hob_at]
    hood = result.wall.find { |item| item.kind == :hood }
    assert hood, 'a hood over the hob'
    assert_in_delta hob.start, hood.start, 0.01
    assert_in_delta hob.width, hood.width, 0.01
    refute_includes result.base.map(&:kind), :oven
  end

  def test_the_wall_units_fill_the_wall_between_the_tall_units_and_are_contiguous
    result = plan('wall_a' => 3600, 'oven_tower' => true)
    first = result.wall.first
    last = result.wall.last
    assert_in_delta 600.0, first.start, 0.01, 'after the fridge'
    assert_in_delta 3600.0 - 600.0, last.start + last.width, 0.5, 'before the oven housing'
    result.wall.each_cons(2) { |a, b| assert_in_delta a.start + a.width, b.start, 0.5 }
    assert_equal :oven, result.base.last.kind
  end

  def test_an_l_kitchen_has_a_corner_between_the_two_runs_and_both_walls_are_filled
    [[3600, 2800], [3200, 2400], [4200, 3000], [3000, 2000]].each do |a, b|
      result = plan('layout' => 'l', 'wall_a' => a, 'wall_b' => b)
      assert_nil result.error, "#{a} x #{b}: #{result.error}"
      assert_in_delta a, run_sum(result.base, :a), 0.5, "wall A #{a} (with the corner)"
      assert_in_delta b - 1000.0, run_sum(result.base, :b), 0.5, "wall B #{b} (less the corner)"
      corners = result.base.select { |item| item.kind == :corner }
      assert_equal 1, corners.length
      assert_equal 'base_corner_l', corners.first.type
      order = result.base.map(&:run)
      assert_equal order, order.sort_by { |run| run == :a ? 0 : 1 }, 'the units of A come before those of B'
      assert_equal :corner, result.base.select { |item| item.run == :a }.last.kind, 'the corner ends run A'
      wall_corner = result.wall.find { |item| item.kind == :corner }
      assert_equal 'wall_corner_l', wall_corner.type
      assert_in_delta a - 700.0, run_sum(result.wall.select { |item| item.run == :a && item.kind != :corner }, :a) + 600.0, 0.5, 'the wall units of A end at the wall corner'
    end
  end

  def test_the_hob_goes_on_wall_b_of_an_l_kitchen_when_there_is_room_and_the_hood_is_over_it
    result = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800)
    hob = result.base.find { |item| item.kind == :hob }
    assert_equal :b, hob.run
    hood = result.wall.find { |item| item.kind == :hood }
    assert_equal :b, hood.run
    assert_in_delta hob.start, hood.start, 0.01
    assert_equal :a, result.base.find { |item| item.kind == :sink }.run
  end

  def test_what_is_ticked_off_is_left_out
    result = plan('sink' => false, 'hob' => false, 'hood' => false, 'fridge' => 'none', 'wall_units' => false)
    assert_equal %i[fill], result.base.map(&:kind).uniq
    assert_empty result.wall
    result = plan('hood' => false)
    refute_includes result.wall.map(&:kind), :hood
  end

  def test_every_unit_is_in_the_kitchen_catalogs_and_the_widths_are_sensible
    configs = [{}, { 'layout' => 'l' }, { 'oven_tower' => true, 'fridge' => 'free' }, { 'wall_a' => 2100 }, { 'layout' => 'l', 'wall_a' => 2600, 'wall_b' => 1800 }]
    configs.each do |options|
      result = plan(options)
      next if result.error

      (result.base + result.wall).each do |item|
        assert_includes IDS[item.category], item.type, "#{item.type} is in the catalog"
        assert_operator item.width, :>=, 100.0
        assert_operator item.width, :<=, 1300.0
      end
      result.base.select { |item| item.kind == :fill }.each { |item| assert_operator item.width, :>=, 250.0 }
    end
  end

  def test_a_wall_that_is_too_short_says_so_and_a_hob_that_does_not_fit_is_left_out_with_a_note
    assert plan('wall_a' => 900).error
    assert plan('layout' => 'l', 'wall_a' => 3000, 'wall_b' => 1200).error
    result = plan('wall_a' => 1800)
    assert_nil result.error
    refute_includes result.base.map(&:kind), :hob
    assert(result.notes.any? { |note| note.include?('hob') })
    assert_in_delta 1800.0, run_sum(result.base, :a), 0.5
  end

  def test_the_answers_are_read_from_text_as_the_panel_sends_them
    options = KitchenPlanner.normalise('layout' => 'l', 'wall_a' => '3 600'.delete(' '), 'wall_b' => '2400', 'sink' => 'false', 'hob' => true, 'fridge' => 'none')
    assert_equal 'l', options['layout']
    assert_in_delta 3600.0, options['wall_a'], 0.001
    refute options['sink']
    assert options['hob']
    assert_equal 'none', options['fridge']
    assert_equal 'straight', KitchenPlanner.normalise('layout' => 'weird')['layout']
    assert_equal 'builtin', KitchenPlanner.normalise({})['fridge']
  end

  def test_the_description_names_what_was_planned
    text = KitchenPlanner.describe(plan)
    assert_includes text, 'hob'
    assert_includes text, 'sink'
    assert_includes text, 'hood'
    assert_equal 'oops', KitchenPlanner.describe(KitchenPlanner::Plan.new(error: 'oops', base: [], wall: []))
  end
end
