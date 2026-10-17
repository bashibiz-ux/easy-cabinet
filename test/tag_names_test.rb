# frozen_string_literal: true

# The tags of the cabinets and parts: numbered names, a tag for the lofts, the side panels and the ceiling fillers, and the old names renamed.
# Run:  ruby test/tag_names_test.rb

require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/tag_manager'

class TagNamesTest < Minitest::Test
  TM = KitchenCabinetMaster::TagManager

  def test_the_tags_are_numbered
    assert_equal ['01 - Base Unit', '02 - Wall Unit', '03 - Loft Unit', '04 - Tall Unit', '05 - Toe Kick', '05 - Side Panels', '06 - Ceiling Filler', 'Worktop'], TM::ALL
  end

  def test_a_cabinet_is_on_the_tag_of_its_kind_and_a_loft_has_its_own
    assert_equal '01 - Base Unit', TM.for_cabinet('cabinet_category' => 'base', 'cabinet_type' => 'base_2door')
    assert_equal '01 - Base Unit', TM.for_cabinet('cabinet_category' => 'base', 'cabinet_type' => 'base_corner_l')
    assert_equal '02 - Wall Unit', TM.for_cabinet('cabinet_category' => 'wall', 'cabinet_type' => 'wall_2door')
    assert_equal '03 - Loft Unit', TM.for_cabinet('cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_2door')
    assert_equal '04 - Tall Unit', TM.for_cabinet('cabinet_category' => 'tall', 'cabinet_type' => 'tall_fridge')
  end

  def test_parts_are_on_their_tags
    assert_equal '05 - Toe Kick', TM.for_stored('part_kind' => 'toe_kick')
    assert_equal '05 - Side Panels', TM.for_stored('part_kind' => 'end_panel')
    assert_equal '06 - Ceiling Filler', TM.for_stored('part_kind' => 'filler', 'ceiling_filler' => 'CABINET_0001:0')
    assert_nil TM.for_stored('part_kind' => 'filler'), 'a plain filler stays untagged'
    assert_equal 'Worktop', TM.for_stored('part_kind' => 'worktop')
    assert_equal 'Worktop', TM.for_stored('part_kind' => 'backsplash')
    assert_equal '02 - Wall Unit', TM.for_stored('part_kind' => 'wall_bottom')
    assert_equal '03 - Loft Unit', TM.for_stored('cabinet_id' => 'CABINET_0003', 'cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_1door')
  end

  # a stand-in for the tags of a model
  class Tag
    attr_accessor :name

    def initialize(name) = @name = name
  end

  class Tags
    def initialize(*names) = @list = names.map { |n| Tag.new(n) }
    def [](name) = @list.find { |t| t.name == name }
    def add(name) = Tag.new(name).tap { |t| @list << t }
    def names = @list.map(&:name)
  end

  Model = Struct.new(:layers)

  def test_a_model_with_the_old_names_gets_them_renamed_and_the_rest_added
    tags = Tags.new('Base Unit', 'Wall Unit', 'Tall Unit', 'Toe Kick', 'Worktop', 'My Own Tag')
    old_base = tags['Base Unit']
    TM.create_all(Model.new(tags))
    assert_equal '01 - Base Unit', old_base.name, 'the same tag: what is on it stays on it'
    assert_equal TM::ALL.sort, (tags.names - ['My Own Tag']).sort
    assert_nil tags['Base Unit']
    assert tags['My Own Tag'], 'a tag of your own is left alone'
  end

  def test_the_old_names_are_noticed_as_work_to_do
    assert_equal({ 'Base Unit' => '01 - Base Unit', 'Wall Unit' => '02 - Wall Unit', 'Tall Unit' => '04 - Tall Unit', 'Toe Kick' => '05 - Toe Kick' }, TM::OLD_NAMES)
  end
end
