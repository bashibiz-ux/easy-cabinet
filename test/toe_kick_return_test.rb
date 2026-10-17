# frozen_string_literal: true

# The toe kick turns round the end of a row under a side panel that stands only on the cabinet (no floor under it). Real ToeKick maths, no SketchUp.
# Run:  ruby test/toe_kick_return_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[defaults toe_kick cabinet_layout].each { |f| require File.join(plugin, f) }

class ToeKickReturnTest < Minitest::Test
  TK = KitchenCabinetMaster::ToeKick

  def params(extra = {})
    { 'toe_kick_height' => 100.0, 'toe_kick_thickness' => 18.0, 'toe_kick_piece_length' => 2000.0, 'toe_kick_pieces' => 1, 'toe_kick_recess' => 50.0,
      'target_depth' => 600.0, 'toe_kick_total' => 1218.0, 'toe_kick_turns' => '' }.merge(extra)
  end

  # a side panel standing only on the cabinet (it starts 100 mm up) one thickness (18) before the start of a row 1200 mm long, and one after its end
  def high_panels = [{ y: -18.0, thickness: 18.0, base: 100.0, category: 'base' }, { y: 1200.0, thickness: 18.0, base: 100.0, category: 'base' }]

  def test_a_panel_that_stands_only_on_the_cabinet_gets_a_return_under_it
    assert_equal [true, true], TK.panel_returns(high_panels, 1200.0)
  end

  def test_a_panel_that_reaches_the_floor_needs_none_and_neither_does_a_wall_unit_panel
    floor = [{ y: -18.0, thickness: 18.0, base: 0.0, category: 'base' }, { y: 1200.0, thickness: 18.0, base: 0.0, category: 'base' }]
    assert_equal [false, false], TK.panel_returns(floor, 1200.0)
    hung = [{ y: -18.0, thickness: 18.0, base: 1480.0, category: 'wall' }]
    assert_equal [false, false], TK.panel_returns(hung, 1200.0)
  end

  def test_only_the_end_with_such_a_panel_gets_one_and_a_far_panel_none
    assert_equal [true, false], TK.panel_returns([high_panels.first], 1200.0)
    assert_equal [false, true], TK.panel_returns([high_panels.last], 1200.0)
    far = [{ y: -400.0, thickness: 18.0, base: 100.0, category: 'base' }]
    assert_equal [false, false], TK.panel_returns(far, 1200.0), 'a panel far from the end is not the end panel of this row'
  end

  def test_the_pieces_have_no_returns_unless_asked
    pieces = TK.pieces(params)
    assert_equal ['toe_kick_1'], pieces.map(&:role)
  end

  def test_the_returns_run_from_the_front_piece_back_to_the_carcass_flush_with_the_ends
    pieces = TK.pieces(params('toe_kick_return_start' => true, 'toe_kick_return_end' => true))
    assert_equal %w[toe_kick_1 toe_kick_return_start toe_kick_return_end], pieces.map(&:role)
    front, start, finish = pieces
    depth_to_front_piece = 600.0 - 50.0 - 18.0 # where the front piece starts (its back face)
    assert_equal [depth_to_front_piece, 18.0, 100.0], start.extent, 'from the back of the carcass to the front piece, one thickness wide'
    assert_equal [0.0, 0.0, 0.0], start.offset
    assert_equal [depth_to_front_piece, 1218.0 - 18.0, 0.0], [finish.extent[0], finish.offset[1], finish.offset[2]], 'the second one stands at the far end'
    assert_equal front.offset[0], start.extent[0], 'they meet the front piece without overlapping it'
    assert_equal [0.0, 0.0], [finish.offset[0], start.offset[1]]
  end

  def test_only_the_asked_end_gets_one
    assert_equal %w[toe_kick_1 toe_kick_return_end], TK.pieces(params('toe_kick_return_end' => true)).map(&:role)
    assert_equal %w[toe_kick_1 toe_kick_return_start], TK.pieces(params('toe_kick_return_start' => true)).map(&:role)
  end

  def test_a_row_that_turns_corners_has_no_returns
    turned = params('toe_kick_turns' => [[1000.0, -90.0]], 'toe_kick_return_start' => true)
    assert(TK.pieces(turned).none? { |piece| piece.role.include?('return') })
  end

  def test_the_returns_are_boards_of_the_cut_list_like_the_other_pieces
    pieces = TK.pieces(params('toe_kick_return_start' => true))
    assert_equal ['Toe Kick 1', 'Toe Kick Return 1'], pieces.map(&:name)
  end
end
