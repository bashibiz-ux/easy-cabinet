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

module EasyCabinet
  module SelectionManager
    class << self
      attr_accessor :selected
    end
    def self.selected_occupant(_model) = selected
  end
end

plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults toe_kick gola_profile cabinet_layout front_design appliance_parts fixtures attribute_manager validation_manager placement_manager naming_manager].each do |f|
  require File.join(plugin, f)
end

# A placed cabinet: a ComponentInstance with a transformation and attributes.
class FakeCabinet < Sketchup::ComponentInstance
  attr_reader :transformation, :attrs, :parent

  def initialize(transformation, params, parent, sequence = 0)
    super()
    @transformation = transformation
    @parent = parent
    env = EasyCabinet::CabinetLayout.envelope(params)
    @attrs = { 'cabinet_id' => "CABINET_#{sequence}", 'sequence' => sequence, 'width' => params['width'],
               'cabinet_category' => params['cabinet_category'], 'cabinet_type' => params['cabinet_type'].to_s, 'depth' => params['depth'], 'top_z' => env[2],
               'envelope_depth' => env[0], 'envelope_width' => env[1], 'envelope_top' => env[2],
               'corner_style' => params['corner_style'].to_s, 'door_opening_direction' => params['door_opening_direction'].to_s }
  end

  def attribute_dictionary(_name, _create = false) = @attrs
  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
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

  def initialize(entities)
    @active_entities = entities
    @attrs = {}
  end

  def get_attribute(_dict, key, default = nil) = @attrs.fetch(key, default)
  def set_attribute(_dict, key, value) = @attrs[key] = value
end

class PlacementTest < Minitest::Test
  include EasyCabinet

  def setup
    @entities = FakeEntities.new
    @model = FakeModel.new(@entities)
    @parent = FakeParent.new(@entities)
    @sequence = 0
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
    cabinet = FakeCabinet.new(transformation, p, @parent, @sequence += 1)
    @entities.add(cabinet)
    SelectionManager.selected = cabinet
    cabinet
  end

  # The user clicks away, so nothing is selected any more.
  def deselect = SelectionManager.selected = nil

  def at(cabinet, x, y) = cabinet.transformation * Geom::Point3d.new(x, y, 0)

  def assert_point(expected, actual, msg)
    assert_in_delta expected[0], actual.x, 0.01, "#{msg} (x)"
    assert_in_delta expected[1], actual.y, 0.01, "#{msg} (y)"
  end

  def insert_params(p)
    _entities, transformation = PlacementManager.target_for_new(@model, p)
    cabinet = FakeCabinet.new(transformation, p, @parent, @sequence += 1)
    @entities.add(cabinet)
    SelectionManager.selected = cabinet
    cabinet
  end

  # A cabinet after a blind corner is turned towards the blind side and 50 mm beyond the blind panel's face.
  def test_a_cabinet_after_a_blind_corner_turns_towards_the_blind_side_and_stands_50_mm_off_the_panel
    blind = insert_params(params('base', 1000.0).merge('corner_style' => 'blind', 'door_opening_direction' => 'left'))
    front = blind.get_attribute('kcm', 'envelope_depth') # 560 + door distance + door thickness
    nxt = insert('base', 600.0)
    assert_point [front + 50.0, 1000.0], nxt.transformation.origin, 'blind on the right: it starts 50 mm past the front of the corner unit'
    assert_in_delta(-1.0, nxt.transformation.xaxis.y, 1e-9, 'its front faces back along the row')
    assert_in_delta 1.0, nxt.transformation.yaxis.x, 1e-9, 'and its row runs out along the next wall'
  end

  def test_a_cabinet_after_a_blind_corner_with_the_blind_part_on_the_left_turns_the_other_way
    blind = insert_params(params('base', 1000.0).merge('corner_style' => 'blind', 'door_opening_direction' => 'right'))
    front = blind.get_attribute('kcm', 'envelope_depth')
    nxt = insert('base', 600.0)
    assert_point [front + 50.0 + 600.0, 0.0], nxt.transformation.origin, 'its width runs back towards the corner unit'
    assert_in_delta 1.0, nxt.transformation.xaxis.y, 1e-9, 'its front faces along the row'
    assert_in_delta(-1.0, nxt.transformation.yaxis.x, 1e-9)
    assert_point [front + 50.0, 600.0 * 0], at(nxt, 0, 600.0), 'the near end of it is 50 mm past the panel'
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

  def test_with_nothing_selected_the_next_cabinet_goes_after_the_last_one
    insert('base', 600.0)
    insert('base', 800.0)
    deselect

    third = insert('base', 400.0)
    assert_point [0, 1400], third.transformation.origin, 'straight after the second cabinet, not back at the origin'
  end

  # A cabinet dropped in the model at Y = `y` with the given insertion number.
  def place(width, y, sequence)
    p = params('base', width)
    move = Geom::Transformation.translation(Geom::Vector3d.new(0, y, 0))
    cabinet = FakeCabinet.new(move, p, @parent, sequence)
    @entities.add(cabinet)
    cabinet
  end

  def test_the_last_cabinet_is_the_most_recently_inserted_not_the_furthest_along
    far = place(600.0, 3000.0, 1) # inserted first, but sits furthest along
    near = place(600.0, 0.0, 2)   # inserted last, back near the start

    assert_same near, PlacementManager.last_occupant(@model)
    _e, transformation = PlacementManager.target_for_new(@model, params('base', 500.0))
    assert_point [0, 600], transformation.origin, 'after the last INSERTED cabinet'
    refute_same far, PlacementManager.last_occupant(@model)
  end

  def test_a_selection_still_wins_over_the_last_cabinet
    first = place(600.0, 0.0, 1)
    place(600.0, 3000.0, 2) # the last one inserted
    SelectionManager.selected = first

    _e, transformation = PlacementManager.target_for_new(@model, params('base', 500.0))
    assert_point [0, 600], transformation.origin, 'after the selected cabinet, not the last one'
  end

  def test_an_end_panel_or_toe_kick_is_never_taken_as_the_last_cabinet
    cabinet = place(600.0, 0.0, 1)
    panel = FakeCabinet.new(Geom::Transformation.new, params('base', 18.0), @parent, 9)
    panel.attrs.delete('cabinet_id')
    panel.attrs['part_id'] = 'PART_0009'
    panel.attrs['part_kind'] = 'end_panel'
    @entities.add(panel)

    assert_same cabinet, PlacementManager.last_occupant(@model)
  end

  def test_a_corner_with_nothing_selected_turns_after_the_last_cabinet
    insert('base', 600.0)
    deselect
    corner = insert('corner', 900.0)
    assert_point [0, 1500], corner.transformation.origin, 'turned at the end of the row'
    assert_in_delta(-1.0, corner.transformation.xaxis.y, 1e-9)
  end

  def test_the_first_cabinet_still_goes_at_the_origin
    assert_nil PlacementManager.last_occupant(@model)
    first = insert('base', 600.0)
    assert_point [0, 0], first.transformation.origin, 'origin'
  end

  def test_same_sized_cabinets_share_one_name
    a = NamingManager.unique_name(@entities, NamingManager.base_name(params('base', 600.0).merge('name_code' => '')))
    b = NamingManager.unique_name(@entities, NamingManager.base_name(params('base', 600.0).merge('name_code' => '')))
    assert_equal 'BU600', a
    assert_equal a, b, 'no #2 suffix'
    assert_equal 'BU800', NamingManager.base_name(params('base', 800.0).merge('name_code' => ''))
    assert_equal 'WU600', NamingManager.base_name(params('wall', 600.0).merge('name_code' => ''))
    assert_equal 'BU600', NamingManager.for_update_base(nil, 'BU600')
  end

  def test_ordinary_cabinets_run_straight_along_y_and_a_wall_unit_goes_above_the_selected_one
    insert('base', 600.0)
    second = insert('base', 800.0)
    third = insert('wall', 500.0)
    assert_point [0, 600], second.transformation.origin, 'second'
    assert_point [0, 600], third.transformation.origin, 'a wall unit goes above the selected base unit'
  end

  def test_corner_footprint_is_the_square_with_no_door_overhang
    assert_equal [900.0, 900.0, 820.0], CabinetLayout.envelope(params('corner', 900.0))
  end

  # ---- resizing in place ---------------------------------------------------

  def size_of(width) = CabinetLayout.envelope(params('base', width))

  def test_a_cabinet_may_grow_into_free_space
    first = insert('base', 600.0)
    insert('base', 600.0)
    entities = @entities
    # widen the LAST one: nothing after it
    last = entities.grep(FakeCabinet).last
    refute PlacementManager.crowds?(entities, last, last.transformation, size_of(900.0), size_of(600.0))
    assert first
  end

  def test_a_cabinet_may_not_grow_into_its_neighbour
    first = insert('base', 600.0)
    insert('base', 600.0)
    assert PlacementManager.crowds?(@entities, first, first.transformation, size_of(800.0), size_of(600.0))
  end

  def test_shrinking_is_always_allowed
    first = insert('base', 600.0)
    insert('base', 600.0)
    refute PlacementManager.crowds?(@entities, first, first.transformation, size_of(400.0), size_of(600.0))
  end

  def test_an_overlap_that_was_already_there_does_not_block_other_edits
    first = insert('base', 600.0)
    insert('base', 600.0)
    # the user dragged the second one back onto the first
    overlapping = size_of(800.0)
    assert PlacementManager.crowds?(@entities, first, first.transformation, overlapping, size_of(600.0))
    refute PlacementManager.crowds?(@entities, first, first.transformation, overlapping, overlapping),
           'when the old size already collided, the edit is not refused for it'
  end

  def test_the_first_wall_unit_starts_where_the_base_row_starts
    insert('base', 600.0)
    insert('base', 600.0)
    insert('base', 600.0)
    deselect
    wall = insert('wall', 600.0)
    assert_point [0, 0], wall.transformation.origin, 'above the first base unit, not after the last'
  end

  def test_the_next_wall_unit_follows_the_first_one
    insert('base', 600.0)
    insert('base', 600.0)
    deselect
    insert('wall', 600.0)
    deselect
    second = insert('wall', 600.0)
    assert_point [0, 600], second.transformation.origin, 'after the first wall unit'
  end

  def test_a_wall_unit_inserted_with_a_base_unit_selected_goes_directly_above_it
    insert('base', 600.0)
    middle = insert('base', 900.0)
    insert('base', 600.0)
    SelectionManager.selected = middle
    wall = insert('wall', 600.0)
    assert_point [0, 600], wall.transformation.origin, 'above the middle base unit'
    assert_in_delta 820.0 + 600.0, wall.transformation.origin.z.to_mm, 0.01
  end

  def test_a_base_unit_inserted_with_a_wall_unit_selected_goes_directly_below_it
    insert('base', 600.0)
    deselect
    wall = insert('wall', 600.0)
    second_wall = insert('wall', 800.0)
    SelectionManager.selected = second_wall
    base = insert('base', 800.0)
    assert_in_delta second_wall.transformation.origin.y, base.transformation.origin.y, 0.01, 'below the selected wall unit'
    assert_in_delta 0.0, base.transformation.origin.z, 0.01, 'on the floor'
    refute_equal wall.transformation.origin.y, base.transformation.origin.y
  end
  def loft_params(width = 800.0, height = 400.0)
    params('wall', width).merge('cabinet_type' => 'wall_loft_2door', 'height' => height)
  end

  def insert_loft(width = 800.0, height = 400.0)
    p = loft_params(width, height)
    fit = PlacementManager.loft_fit(@model)
    p = p.merge('width' => fit['width'], 'depth' => fit['depth']) if fit
    _entities, transformation = PlacementManager.target_for_new(@model, p)
    cabinet = FakeCabinet.new(transformation, p, @parent, @sequence += 1)
    cabinet.attrs['loft_over'] = fit['unit'] if fit
    @entities.add(cabinet)
    SelectionManager.selected = cabinet
    cabinet
  end

  def test_a_loft_goes_directly_over_the_selected_wall_unit_starting_at_its_top
    wall = insert('wall', 600.0)
    SelectionManager.selected = wall
    loft = insert_loft(600.0)
    assert_in_delta wall.transformation.origin.y, loft.transformation.origin.y, 0.01, 'over it, not beside it'
    top = wall.transformation.origin.z.to_mm + wall.get_attribute('kcm', 'top_z')
    assert_in_delta top, loft.transformation.origin.z.to_mm, 0.01, 'starting at the top of the wall unit'
  end

  def test_with_nothing_selected_the_first_loft_goes_over_the_first_wall_or_tall_unit_of_the_row
    insert('base', 600.0)
    first = insert('tall', 600.0)
    insert('tall', 600.0)
    deselect
    loft = insert_loft(600.0)
    assert_in_delta first.transformation.origin.y, loft.transformation.origin.y, 0.01, 'over the first one, not the last'
    assert_in_delta first.transformation.origin.z.to_mm + first.get_attribute('kcm', 'top_z'), loft.transformation.origin.z.to_mm, 0.01
  end

  def test_the_lofts_go_over_the_units_one_by_one_each_as_wide_and_as_deep_as_its_unit
    one = insert('tall', 600.0, depth: 560.0)
    two = insert('tall', 900.0, depth: 600.0)
    three = insert('tall', 400.0, depth: 560.0)
    deselect
    lofts = [insert_loft, insert_loft, insert_loft]
    [one, two, three].zip(lofts).each_with_index do |(unit, loft), i|
      assert_in_delta unit.transformation.origin.y, loft.transformation.origin.y, 0.01, "loft #{i + 1} is over unit #{i + 1}"
      assert_in_delta unit.get_attribute('kcm', 'width'), loft.get_attribute('kcm', 'width'), 0.01, 'as wide as its unit'
      assert_in_delta 600.0, loft.get_attribute('kcm', 'depth'), 0.01, 'every loft is as deep as the deepest unit, so all the fronts are flush'
      assert_in_delta unit.transformation.origin.z.to_mm + unit.get_attribute('kcm', 'top_z'), loft.transformation.origin.z.to_mm, 0.01, 'on top of it'
    end
    assert_equal 1, lofts.map { |loft| loft.transformation.origin.z.to_mm.round }.uniq.length, 'no stacking'
  end

  def test_with_a_loft_selected_the_next_one_goes_over_the_unit_after_the_one_it_is_over
    one = insert('wall', 600.0)
    two = insert('wall', 800.0)
    SelectionManager.selected = one
    first = insert_loft
    second = insert_loft # (the first loft is selected now)
    assert_in_delta two.transformation.origin.y, second.transformation.origin.y, 0.01
    assert_in_delta one.transformation.origin.y, first.transformation.origin.y, 0.01
  end

  def test_when_every_unit_has_a_loft_the_next_one_goes_after_the_last_loft
    unit = insert('wall', 600.0)
    SelectionManager.selected = unit
    first = insert_loft
    deselect
    extra = insert_loft(500.0)
    assert_in_delta first.transformation.origin.y + first.get_attribute('kcm', 'width'), extra.transformation.origin.y, 0.01
    assert_in_delta first.transformation.origin.z, extra.transformation.origin.z, 0.01, 'at the same height'
  end

  def test_the_ceiling_and_what_a_loft_is
    assert PlacementManager.loft?('cabinet_type' => 'wall_loft_liftup')
    refute PlacementManager.loft?('cabinet_type' => 'wall_2door')
    assert_equal 50.0, PlacementManager::LOFT_FILLER_MM
  end
  def test_every_loft_stands_at_one_level_whatever_is_under_it
    tall = insert('tall', 600.0)
    wall = insert('wall', 600.0)
    deselect
    over_tall = insert_loft
    over_wall = insert_loft
    top = [tall, wall].map { |unit| unit.transformation.origin.z.to_mm + unit.get_attribute('kcm', 'top_z') }.max
    assert_in_delta top, over_tall.transformation.origin.z.to_mm, 0.01, 'at the top of the highest unit'
    assert_in_delta over_tall.transformation.origin.z, over_wall.transformation.origin.z, 0.01, 'the loft over the lower wall unit is in line with the other'
    assert_in_delta wall.transformation.origin.y, over_wall.transformation.origin.y, 0.01, 'and still over its own unit'
  end
  def test_the_loft_level_is_the_top_of_the_highest_unit_and_does_not_depend_on_the_lofts
    assert_nil PlacementManager.loft_level(@model), 'no unit, no level'
    tall = insert('tall', 600.0)
    wall = insert('wall', 600.0)
    tops = [tall, wall].map { |unit| unit.transformation.origin.z.to_mm + unit.get_attribute('kcm', 'top_z') }
    assert_in_delta tops.max, PlacementManager.loft_level(@model), 0.01
    SelectionManager.selected = wall
    insert_loft
    assert_in_delta tops.max, PlacementManager.loft_level(@model), 0.01, 'a loft is not a unit it goes over'
  end
  def test_a_loft_over_a_shallow_wall_unit_is_as_deep_as_the_ones_over_the_tall_units
    tall = insert('tall', 600.0, depth: 560.0)
    wall = insert('wall', 600.0, depth: 320.0)
    deselect
    over_tall = insert_loft
    over_wall = insert_loft
    assert_in_delta 560.0, over_tall.get_attribute('kcm', 'depth'), 0.01
    assert_in_delta 560.0, over_wall.get_attribute('kcm', 'depth'), 0.01, 'flush with the others at the front'
    assert_in_delta 320.0, wall.get_attribute('kcm', 'depth'), 0.01, 'the wall unit itself is unchanged'
    assert_in_delta 560.0, PlacementManager.loft_depth(@model), 0.01
    refute_nil tall
  end
  def test_a_depth_typed_for_the_lofts_is_the_one_every_loft_has
    insert('tall', 600.0, depth: 560.0)
    assert_in_delta 560.0, PlacementManager.loft_depth(@model), 0.01
    @model.set_attribute('kcm', 'loft_depth', 450.0)
    assert_in_delta 450.0, PlacementManager.loft_depth(@model), 0.01
  end
  def test_the_ceiling_filler_over_a_loft_does_not_stop_the_loft_from_growing
    wall = insert('wall', 600.0)
    SelectionManager.selected = wall
    loft = insert_loft(600.0, 290.0)
    top = loft.transformation.origin.z.to_mm + loft.get_attribute('kcm', 'top_z')
    filler = FakeCabinet.new(Geom::Transformation.new(loft.transformation.to_a), params('wall', 600.0).merge('height' => 50.0), @parent, 0)
    filler.attrs['ceiling_filler'] = "#{loft.get_attribute('kcm', 'cabinet_id')}:0"
    filler.attrs['part_id'] = 'PART_1'
    filler.attrs.delete('cabinet_id')
    @entities.add(filler)
    refute AttributeManager.occupant?(filler), 'a ceiling filler is no occupant'
    taller = [loft.get_attribute('kcm', 'envelope_depth'), 600.0, top - loft.transformation.origin.z.to_mm + 200.0]
    refute PlacementManager.collides?(@entities, loft.transformation, taller, exclude: loft), 'the loft 200 mm taller does not run into its filler'
  end
  def test_a_clicked_spot_is_where_the_cabinet_goes_whatever_stands_in_the_model
    insert('base', 600.0)
    PlacementManager.place_at = { 'x' => 3000.0, 'y' => 1200.0, 'out_x' => 0.0, 'out_y' => -1.0 }
    cabinet = insert('base', 800.0)
    PlacementManager.place_at = nil
    origin = cabinet.transformation.origin
    assert_in_delta 3000.0, origin.x, 0.01
    assert_in_delta 1200.0, origin.y, 0.01
    assert_in_delta 0.0, origin.z, 0.01, 'a base unit stands on the floor'
    assert_in_delta(-1.0, cabinet.transformation.xaxis.y, 1e-9, 'its front faces the way that was asked')
  end

  def test_the_next_cabinet_carries_on_from_the_one_that_was_clicked
    PlacementManager.place_at = { 'x' => 3000.0, 'y' => 1200.0, 'out_x' => 1.0, 'out_y' => 0.0 }
    first = insert('base', 600.0)
    PlacementManager.place_at = nil
    second = insert('base', 600.0)
    assert_in_delta first.transformation.origin.x, second.transformation.origin.x, 0.01
    assert_in_delta 1800.0, second.transformation.origin.y, 0.01
  end
  def test_the_corner_of_insert_on_path_is_placed_like_a_corner_unit_inserted_after_a_row
    # a row along y whose last cabinet ends at 1000: the corner unit is turned a quarter at the far end (see turned), its front looking back along the row
    turned = PlacementManager.send(:turned, Geom::Transformation.new, PlacementManager::CORNER_TURN_DEGREES, 1000.0)
    out = [0.0, -1.0] # what PathKitchen.placements gives for a wall running along +y: the opposite of the way the wall runs
    along = [-out[1], out[0]]
    placed = Geom::Transformation.axes(Geom::Point3d.new(0.0, 1000.0, 0.0), Geom::Vector3d.new(out[0], out[1], 0), Geom::Vector3d.new(along[0], along[1], 0), Geom::Vector3d.new(0, 0, 1))
    assert_in_delta turned.origin.y, placed.origin.y, 0.01
    assert_in_delta turned.xaxis.x, placed.xaxis.x, 1e-9
    assert_in_delta turned.xaxis.y, placed.xaxis.y, 1e-9
    assert_in_delta turned.yaxis.x, placed.yaxis.x, 1e-9
    assert_in_delta turned.yaxis.y, placed.yaxis.y, 1e-9
  end
end
