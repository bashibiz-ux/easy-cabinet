# frozen_string_literal: true

# The tags of the cabinets and parts: numbered names, a tag for the lofts, the side panels and the ceiling fillers, and the old names renamed.
# Run:  ruby test/tag_names_test.rb

require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/tag_manager'

class TagNamesTest < Minitest::Test
  TM = KitchenCabinetMaster::TagManager

  def test_the_tags_are_numbered
    assert_equal ['01 Base Unit', '02 Wall Unit', '03 Loft Unit', '04 Tall Unit', '05 Toe Kick', '06 Side Panels', '07 Ceiling Filler', '08 Worktop'], TM::ALL
  end

  def test_a_cabinet_is_on_the_tag_of_its_kind_and_a_loft_has_its_own
    assert_equal '01 Base Unit', TM.for_cabinet('cabinet_category' => 'base', 'cabinet_type' => 'base_2door')
    assert_equal '01 Base Unit', TM.for_cabinet('cabinet_category' => 'base', 'cabinet_type' => 'base_corner_l')
    assert_equal '02 Wall Unit', TM.for_cabinet('cabinet_category' => 'wall', 'cabinet_type' => 'wall_2door')
    assert_equal '03 Loft Unit', TM.for_cabinet('cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_2door')
    assert_equal '04 Tall Unit', TM.for_cabinet('cabinet_category' => 'tall', 'cabinet_type' => 'tall_fridge')
  end

  def test_parts_are_on_their_tags
    assert_equal '05 Toe Kick', TM.for_stored('part_kind' => 'toe_kick')
    assert_equal '06 Side Panels', TM.for_stored('part_kind' => 'end_panel')
    assert_equal '07 Ceiling Filler', TM.for_stored('part_kind' => 'filler', 'ceiling_filler' => 'CABINET_0001:0')
    assert_nil TM.for_stored('part_kind' => 'filler'), 'a plain filler stays untagged'
    assert_equal '08 Worktop', TM.for_stored('part_kind' => 'worktop')
    assert_equal '08 Worktop', TM.for_stored('part_kind' => 'backsplash')
    assert_equal '02 Wall Unit', TM.for_stored('part_kind' => 'wall_bottom')
    assert_equal '03 Loft Unit', TM.for_stored('cabinet_id' => 'CABINET_0003', 'cabinet_category' => 'wall', 'cabinet_type' => 'wall_loft_1door')
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
    tags = Tags.new('Base Unit', 'Wall Unit', 'Tall Unit', '05 - Toe Kick', '05 - Side Panels', '06 - Ceiling Filler', 'Worktop', 'My Own Tag')
    old_base = tags['Base Unit']
    TM.create_all(Model.new(tags))
    assert_equal '01 Base Unit', old_base.name, 'the same tag: what is on it stays on it'
    assert_equal TM::ALL.sort, (tags.names - ['My Own Tag']).sort
    assert_nil tags['Base Unit']
    assert tags['My Own Tag'], 'a tag of your own is left alone'
  end

  def test_every_earlier_name_has_a_number_now_and_is_renamed
    assert_equal '01 Base Unit', TM::OLD_NAMES['Base Unit']
    assert_equal '08 Worktop', TM::OLD_NAMES['Worktop']
    assert_equal '01 Base Unit', TM::OLD_NAMES['01 - Base Unit']
    assert_equal '06 Side Panels', TM::OLD_NAMES['05 - Side Panels'], 'made by the first numbering'
    assert_equal '06 Side Panels', TM::OLD_NAMES['06 - Side Panels']
    assert_equal '07 Ceiling Filler', TM::OLD_NAMES['06 - Ceiling Filler']
    assert_equal '07 Ceiling Filler', TM::OLD_NAMES['07 - Ceiling Filler']
    assert(TM::OLD_NAMES.values.all? { |name| TM::ALL.include?(name) }, 'each one goes to a tag of the list')
    assert(TM::OLD_NAMES.keys.none? { |name| TM::ALL.include?(name) }, 'and none of the old names is a current one')
  end
end
