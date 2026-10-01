# frozen_string_literal: true

# The worktop runs, the tags and the 3D scene's viewpoint: the real planning code,
# with fake SketchUp objects.  Run:  ruby test/worktop_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
  class SelectionObserver; end
  class AppObserver; end
end

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout part_layout validation_manager tag_manager worktop_manager].each { |f| require File.join(plugin, f) }

class WorktopTest < Minitest::Test
  include KitchenCabinetMaster

  def item(y:, width: 600.0, depth: 580.0, top: 880.0, x: 0.0, hx: 0.0, hy: 1.0, corner: false)
    { x: x, y: y, hx: hx, hy: hy, width: width, depth: depth, top: top, corner: corner }
  end

  def settings(overrides = {})
    Worktop::DEFAULTS.merge(overrides)
  end

  # ---- runs -------------------------------------------------------------------

  def test_units_in_a_line_get_one_worktop
    runs = Worktop.runs([item(y: 0), item(y: 600), item(y: 1200)])
    assert_equal 1, runs.length
    assert_in_delta 1800.0, runs.first[:length], 1e-9
    assert_in_delta 0.0, runs.first[:along], 1e-9
    assert_equal 580.0, runs.first[:depth]
  end

  def test_the_order_they_were_inserted_in_does_not_matter
    runs = Worktop.runs([item(y: 1200), item(y: 0), item(y: 600)])
    assert_equal 1, runs.length
    assert_equal 0.0, runs.first[:items].first[:y]
  end

  def test_a_real_gap_starts_another_worktop
    runs = Worktop.runs([item(y: 0), item(y: 600), item(y: 1800)]) # 600 mm hole after the second
    assert_equal [2, 1], runs.map { |r| r[:items].length }.sort.reverse
  end

  def test_a_small_gap_is_still_one_worktop
    assert_equal 1, Worktop.runs([item(y: 0), item(y: 700)]).length # 100 mm
  end

  def test_the_deepest_unit_sets_the_depth
    runs = Worktop.runs([item(y: 0, depth: 580.0), item(y: 600, depth: 620.0)])
    assert_equal 620.0, runs.first[:depth]
  end

  def test_units_at_another_height_or_on_another_wall_are_separate
    runs = Worktop.runs([item(y: 0), item(y: 600, top: 1000.0), item(y: 0, x: 3000.0)])
    assert_equal 3, runs.length
  end

  def test_a_row_that_turns_is_not_one_slab
    runs = Worktop.runs([item(y: 0), item(y: 600, hx: 1.0, hy: 0.0, x: 600.0)])
    assert_equal 2, runs.length
  end

  def test_a_corner_unit_has_a_square_worktop_of_its_own
    runs = Worktop.runs([item(y: 0), item(y: 600, width: 900.0, depth: 900.0, corner: true)])
    corner = runs.find { |r| r[:corner] }
    assert corner
    assert_equal 900.0, corner[:length]
    assert_equal 900.0, corner[:depth]
    assert_equal 2, runs.length
  end

  def test_nothing_in_means_no_worktop
    assert_empty Worktop.runs([])
  end

  # ---- the slab ----------------------------------------------------------------

  def test_the_slab_reaches_past_the_doors_by_the_front_overhang
    run = Worktop.runs([item(y: 0), item(y: 600)]).first
    slab = Worktop.slab(run, settings('worktop_front' => 20.0, 'worktop_end' => 0.0, 'worktop_thickness' => 38.0))
    assert_equal [600.0, 1200.0, 38.0], slab[:extent]
    assert_equal [0.0, 0.0, 0.0], slab[:offset]
  end

  def test_an_end_overhang_widens_it_at_both_ends
    run = Worktop.runs([item(y: 0)]).first
    slab = Worktop.slab(run, settings('worktop_end' => 10.0))
    assert_equal 620.0, slab[:extent][1]
    assert_equal(-10.0, slab[:offset][1], 'it starts before the first unit')
  end

  def test_a_corner_slab_is_exactly_its_square
    run = Worktop.runs([item(y: 0, width: 900.0, depth: 900.0, corner: true)]).first
    assert_equal [900.0, 900.0, 38.0], Worktop.slab(run, settings)[:extent]
  end

  def test_the_slab_layout_is_one_board_of_that_size
    layout = PartLayout.worktop([600.0, 1200.0, 38.0])
    assert_equal [600.0, 1200.0, 38.0], layout.board.extent
    assert_equal 38.0, layout.top_z
  end

  def test_worktop_settings_are_validated
    ok = ValidationManager.validate_worktop('worktop_thickness' => '40', 'worktop_front' => '15', 'worktop_end' => '0', 'material' => 'Oak')
    assert_empty ok.errors
    assert_equal 40.0, ok.params['worktop_thickness']
    assert_equal 'Oak', ok.params['material']
    assert_equal 'worktop_thickness', ValidationManager.validate_worktop('worktop_thickness' => '2', 'worktop_front' => '15', 'worktop_end' => '0').errors.first['field']
    assert_equal 3, ValidationManager.validate_worktop({}).errors.length
  end

  # ---- tags ---------------------------------------------------------------------

  def test_each_kind_of_item_has_its_own_tag
    assert_equal 'Base Unit', TagManager.for_category('base')
    assert_equal 'Base Unit', TagManager.for_category('corner')
    assert_equal 'Wall Unit', TagManager.for_category('wall')
    assert_equal 'Tall Unit', TagManager.for_category('tall')
    assert_equal 'Toe Kick', TagManager.for_stored('part_kind' => 'toe_kick')
    assert_equal 'Worktop', TagManager.for_stored('part_kind' => 'worktop')
    assert_equal 'Tall Unit', TagManager.for_stored('cabinet_id' => 'C1', 'cabinet_category' => 'tall')
    assert_nil TagManager.for_stored('part_kind' => 'filler'), 'a filler is not tagged'
    assert_nil TagManager.for_stored(nil)
  end

  def test_the_five_tags_are_the_ones_asked_for
    assert_equal ['Base Unit', 'Worktop', 'Wall Unit', 'Tall Unit', 'Toe Kick'], TagManager::ALL
  end

  # ---- the scene ------------------------------------------------------------------

  def test_the_scene_looks_from_the_front_right_and_above_at_the_middle
    eye, target = SceneManager.viewpoint([2000.0, 1500.0, 1000.0], [4000.0, 600.0, 2200.0])
    assert_equal [2000.0, 1500.0, 1000.0], target
    assert_operator eye[0], :>, 2000.0, 'in front (the doors face +X)'
    assert_operator eye[1], :<, 1500.0, 'to the right'
    assert_operator eye[2], :>, 1000.0, 'above'
  end

  def test_the_scene_stands_back_far_enough_for_a_big_kitchen
    near, = SceneManager.viewpoint([0.0, 0.0, 0.0], [600.0, 600.0, 900.0])
    far, = SceneManager.viewpoint([0.0, 0.0, 0.0], [6000.0, 3000.0, 2200.0])
    assert_operator Math.sqrt(far.sum { |v| v * v }), :>, Math.sqrt(near.sum { |v| v * v })
    assert_operator Math.sqrt(near.sum { |v| v * v }), :>=, 2500.0 - 1e-6, 'never closer than 2.5 m'
  end

  def test_the_new_actions_are_routed
    dialog = File.read(File.join(plugin_dir, 'dialog_manager.rb'))
    WorktopManager::ACTIONS.each { |action| assert_includes dialog, action }
  end

  def plugin_dir = File.expand_path('../kitchen_cabinet_master', __dir__)
end