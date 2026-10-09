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

  def item(y:, width: 600.0, depth: 580.0, top: 880.0, x: 0.0, hx: 0.0, hy: 1.0, corner: false, return_depth: nil, island_back: nil)
    { island_back: island_back, x: x, y: y, hx: hx, hy: hy, width: width, depth: depth, top: top, corner: corner, return_depth: return_depth }
  end

  def settings(overrides = {})
    Worktop::DEFAULTS.merge(overrides)
  end

  def run_of(count = 3, width: 600.0, **opts)
    Worktop.runs(Array.new(count) { |i| item(y: i * width, width: width, **opts) }).first
  end

  def test_an_islands_slab_reaches_beyond_the_back_for_seating_and_has_no_back_splash
    params = Worktop::DEFAULTS
    plain = Worktop.slab(run_of, params)
    seated = Worktop.slab(run_of(3, island_back: 300.0), params)
    assert_in_delta plain[:extent][0] + 300.0, seated[:extent][0], 0.01
    assert_in_delta(-300.0, seated[:offset][0], 0.01)
    assert_equal 0.0, plain[:offset][0]
    refute_empty Worktop.splash(run_of, plain, params)
    assert_empty Worktop.splash(run_of(3, island_back: 300.0), seated, params)
    assert_empty Worktop.splash(run_of(3, island_back: 0.0), Worktop.slab(run_of(3, island_back: 0.0), params), params), 'an island with no overhang has none either'
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

  # An L corner's worktop is as deep as the cabinets beside it and has both fronts rounded.
  def test_an_l_corner_worktop_is_as_deep_as_its_neighbour_with_rounded_fronts
    l = item(y: 600, width: 1000.0, depth: 1000.0, corner: true, return_depth: 560.0).merge(corner_style: 'l_shape', leg2_length: 1000.0, leg2_depth: 560.0)
    neighbour = item(y: 0, width: 600.0, depth: 580.0) # 560 deep with its doors: its slab reaches 580 + the front overhang
    runs = Worktop.runs([neighbour, l])
    corner = runs.find { |run| run[:corner] }
    assert_equal 580.0, corner[:neighbor_depth]
    slab = Worktop.slab(corner, settings('worktop_front' => 20.0, 'worktop_thickness' => 20.0))
    assert_equal [[0.0, 0.0], [0.0, 1000.0], [600.0, 1000.0], [600.0, 600.0], [1000.0, 600.0], [1000.0, 0.0]], slab[:points], 'both arms 580 + 20 deep'
    assert_equal [2, 3], slab[:round_edge], 'the two fronts are rounded'
    alone = Worktop.runs([l]).first
    assert_nil alone[:neighbor_depth]
    own = Worktop.slab(alone, settings('worktop_front' => 20.0))
    assert_equal 580.0, own[:points][2][0], 'with no neighbour: its own depth and the overhang'
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

  def test_a_corner_slab_is_the_shape_of_the_corner_cut_across_the_diagonal
    run = Worktop.runs([item(y: 0, width: 900.0, depth: 900.0, corner: true, return_depth: 600.0)]).first
    slab = Worktop.slab(run, settings('worktop_front' => 0.0))
    assert_equal [900.0, 900.0, 20.0], slab[:extent]
    assert_equal [[0.0, 0.0], [0.0, 900.0], [600.0, 900.0], [900.0, 600.0], [900.0, 0.0]], slab[:points], 'a pentagon: the front corner is cut'
  end

  def test_the_front_overhang_pushes_the_diagonal_out
    run = Worktop.runs([item(y: 0, width: 900.0, depth: 900.0, corner: true, return_depth: 600.0)]).first
    plain = Worktop.slab(run, settings('worktop_front' => 0.0))[:points]
    out = Worktop.slab(run, settings('worktop_front' => 20.0))[:points]
    assert_in_delta plain[2][0] + (20.0 * Math.sqrt(2)), out[2][0], 1e-9
    assert_in_delta plain[3][1] + (20.0 * Math.sqrt(2)), out[3][1], 1e-9
    assert_equal plain[0], out[0], 'the wall corners stay square'
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

  def test_the_new_actions_are_routed
    dialog = File.read(File.join(plugin_dir, 'dialog_manager.rb'))
    %w[apply_worktop remove_worktop].each { |action| assert_includes dialog, action }
    refute_includes dialog, 'create_scene', 'the 3D scene section is gone'
  end
  def plugin_dir = File.expand_path('../kitchen_cabinet_master', __dir__)

  # ---- cutting into pieces -----------------------------------------------------------

  def test_no_cutting_is_one_piece
    assert_equal [[0.0, 3000.0]], Worktop.pieces(3000.0, settings)
  end

  def test_a_longest_piece_cuts_the_run_into_equal_lengths_and_a_remainder
    assert_equal [[0.0, 1200.0], [1200.0, 2400.0], [2400.0, 3000.0]], Worktop.pieces(3000.0, settings('worktop_piece' => 1200.0))
  end

  def test_a_piece_longer_than_the_run_leaves_it_whole
    assert_equal [[0.0, 3000.0]], Worktop.pieces(3000.0, settings('worktop_piece' => 5000.0))
  end

  def test_cutting_at_listed_distances
    assert_equal [[0.0, 1500.0], [1500.0, 2200.0], [2200.0, 3000.0]], Worktop.pieces(3000.0, settings('worktop_cuts' => '1500, 2200'))
  end

  def test_listed_cuts_win_over_a_piece_length_and_out_of_range_ones_are_ignored
    assert_equal [[0.0, 1000.0], [1000.0, 3000.0]], Worktop.pieces(3000.0, settings('worktop_cuts' => '1000; 9000; 0.5', 'worktop_piece' => 500.0))
  end

  def test_the_cut_list_is_parsed
    assert_equal [1500.0, 3000.0], Worktop.parse_cuts('3000, 1500')
    assert_equal [], Worktop.parse_cuts('')
    assert_nil Worktop.parse_cuts('1500, abc')
    assert_nil Worktop.parse_cuts('-5')
  end

  def test_each_piece_is_a_slab_of_its_own_length_at_its_own_place
    run = run_of(5) # 3000 mm
    one = Worktop.slab(run, settings, from: 0.0, to: 1200.0)
    two = Worktop.slab(run, settings, from: 1200.0, to: 3000.0)
    assert_equal 1200.0, one[:extent][1]
    assert_equal 1800.0, two[:extent][1]
    assert_equal 1200.0, two[:offset][1]
  end

  def test_the_cut_list_is_validated_and_tidied
    ok = ValidationManager.validate_worktop('worktop_thickness' => '38', 'worktop_front' => '20', 'worktop_end' => '0', 'worktop_cuts' => '3000;1500')
    assert_empty ok.errors
    assert_equal '1500,3000', ok.params['worktop_cuts']
    bad = ValidationManager.validate_worktop('worktop_thickness' => '38', 'worktop_front' => '20', 'worktop_end' => '0', 'worktop_cuts' => '1500, x')
    assert_equal 'worktop_cuts', bad.errors.first['field']
  end

  # ---- the back splash -----------------------------------------------------------------

  def test_a_straight_slab_has_a_back_splash_along_its_back_edge_standing_on_it
    run = run_of(3)
    slab = Worktop.slab(run, settings)
    pieces = Worktop.splash(run, slab, settings('backsplash_height' => 120.0, 'backsplash_thickness' => 20.0))
    assert_equal 1, pieces.length
    assert_equal [20.0, 1800.0, 120.0], pieces.first[:extent]
    assert_equal [0.0, 0.0, 20.0], pieces.first[:offset], 'at the back, on top of the slab'
  end

  def test_the_back_splash_height_is_adjustable_and_zero_means_none
    run = run_of(2)
    slab = Worktop.slab(run, settings)
    assert_equal 60.0, Worktop.splash(run, slab, settings('backsplash_height' => 60.0)).first[:extent][2]
    assert_empty Worktop.splash(run, slab, settings('backsplash_height' => 0.0))
  end

  def test_a_corner_has_a_back_splash_along_each_of_its_two_walls
    run = Worktop.runs([item(y: 0, width: 900.0, depth: 900.0, corner: true, return_depth: 600.0)]).first
    slab = Worktop.slab(run, settings)
    walls = Worktop.splash(run, slab, settings)
    assert_equal 2, walls.length
    assert_equal [20.0, 900.0, 100.0], walls[0][:extent]
    assert_equal [880.0, 20.0, 100.0], walls[1][:extent], 'the second stops at the first, no overlap'
  end

  def test_a_cut_piece_gets_a_back_splash_of_its_own_length
    run = run_of(5)
    piece = Worktop.slab(run, settings, from: 0.0, to: 1200.0)
    assert_equal 1200.0, Worktop.splash(run, piece, settings).first[:extent][1]
  end

  def test_the_new_defaults
    assert_equal 100.0, Worktop::DEFAULTS['backsplash_height']
    assert_equal 0.0, Worktop::DEFAULTS['worktop_piece']
    assert_equal '', Worktop::DEFAULTS['worktop_cuts']
  end

  def test_a_back_splash_is_on_the_worktop_tag
    assert_equal 'Worktop', TagManager.for_stored('part_kind' => 'backsplash')
  end

  # ---- the rounded front edge -----------------------------------------------------------

  def test_the_worktop_front_is_rounded_by_default
    assert_equal 10.0, Worktop::DEFAULTS['worktop_round']
  end

  def test_the_layout_carries_the_radius_for_a_slab
    layout = PartLayout.worktop([600.0, 1200.0, 38.0], nil, 'Worktop', 10.0)
    assert_equal 10.0, layout.board.round
    assert_equal 0.0, PartLayout.worktop([20.0, 1200.0, 100.0], nil, 'Back Splash', 0.0).board.round
  end

  def test_the_radius_is_validated
    base = { 'worktop_thickness' => '38', 'worktop_front' => '20', 'worktop_end' => '0' }
    assert_empty ValidationManager.validate_worktop(base.merge('worktop_round' => '15')).errors
    assert_equal 15.0, ValidationManager.validate_worktop(base.merge('worktop_round' => '15')).params['worktop_round']
    assert_equal 'worktop_round', ValidationManager.validate_worktop(base.merge('worktop_round' => '500')).errors.first['field']
  end
end
