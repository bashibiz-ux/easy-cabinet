# frozen_string_literal: true

# Runs the plugin's REAL KitchenPlanner and CatalogManager: the 25 variations of the Auto Kitchen.
# Run:  ruby test/kitchen_variation_test.rb

require 'json'
require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
%w[response defaults catalog_manager island_hood kitchen_planner].each { |file| require_relative "../kitchen_cabinet_master/#{file}" }

class KitchenVariationTest < Minitest::Test
  include KitchenCabinetMaster

  LAYOUTS = [
    { 'layout' => 'straight', 'wall_a' => 4800.0 },
    { 'layout' => 'l', 'wall_a' => 4200.0, 'wall_b' => 3600.0 },
    { 'layout' => 'u', 'wall_a' => 4200.0, 'wall_b' => 3000.0, 'wall_c' => 3600.0 }
  ].freeze

  def test_there_are_25_variations_with_their_own_names
    list = KitchenPlanner.variations
    assert_equal 25, list.length
    assert_equal list.length, list.map { |v| v['id'] }.uniq.length
    assert_equal list.length, list.map { |v| v['name'] }.uniq.length
  end

  def test_the_first_variation_starts_with_storage_then_a_freestanding_fridge_then_the_oven
    plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4800.0, 'variation' => 'v01')
    assert_nil plan.error
    assert_equal %w[tall_2door tall_fridge_housing_free tall_oven], plan.base.first(3).map(&:type)
  end

  def test_the_second_variation_is_built_in_fridge_then_freezer_then_oven
    plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4800.0, 'variation' => 'v02')
    assert_equal %w[tall_fridge_builtin_2door tall_fridge_builtin_1door tall_oven], plan.base.first(3).map(&:type)
  end

  def test_every_variation_plans_on_every_layout_with_units_the_catalog_has_and_walls_that_add_up
    KitchenPlanner.variations.each do |variation|
      LAYOUTS.each do |layout|
        plan = KitchenPlanner.plan(layout.merge('variation' => variation['id']))
        assert_nil plan.error, "#{variation['id']} #{layout['layout']}: #{plan.error}"
        (plan.base + plan.wall).each do |item|
          refute_nil CatalogManager.cabinet('kitchen_cabinets', item.category, item.type), "#{variation['id']}: no #{item.category} #{item.type}"
        end
        lengths = { a: layout['wall_a'], b: layout['wall_b'], c: layout['wall_c'] }
        plan.base.group_by(&:run).each do |run, items|
          # (a corner unit stands in the run it ends and takes the first 1000 mm of the next wall)
          expected = run == :a ? lengths[run] : lengths[run] - KitchenPlanner::CORNER_BASE
          assert_in_delta expected, items.sum(&:width), 2.0, "#{variation['id']} #{layout['layout']} run #{run}"
        end
      end
    end
  end

  def test_the_variations_are_not_all_the_same_kitchen
    kitchens = KitchenPlanner.variations.map do |variation|
      plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4800.0, 'variation' => variation['id'])
      (plan.base + plan.wall).map { |item| [item.type, item.width] }
    end
    assert_equal kitchens.length, kitchens.uniq.length
  end

  def test_without_a_variation_the_fridge_and_oven_answers_decide
    plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4800.0, 'fridge' => 'free', 'oven_tower' => true)
    assert_equal 'tall_fridge_housing_free', plan.base.first.type
    assert_equal 'tall_oven', plan.base.last.type
  end
end
