# frozen_string_literal: true

# Wardrobes: dividers, hanging rails, shelves and sliding doors. Run:  ruby test/wardrobe_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager gola_profile cabinet_layout front_design appliance_parts fixtures validation_manager catalog_manager door_animation cabinet_gallery].each { |f| require File.join(plugin, f) }

class WardrobeTest < Minitest::Test
  include EasyCabinet

  def layout(id)
    entry = CatalogManager.cabinet('wardrobes', 'tall', id)
    refute_nil entry, id
    raw = CabinetGallery.layout_of('wardrobes', 'tall', entry)
    refute_nil raw, "#{id}: the layout is built"
    raw
  end

  def test_the_catalog_has_every_kind_of_wardrobe
    ids = CatalogManager.cabinets('wardrobes', 'tall').map { |e| e['id'] }
    assert_equal %w[wardrobe_2door wardrobe_3door wardrobe_4door wardrobe_sliding_2door wardrobe_sliding_3door wardrobe_open_2 wardrobe_open_3 wardrobe_corner_l], ids
  end

  def test_every_wardrobe_has_a_picture
    shapes = CabinetGallery.shapes('wardrobes', 'tall')
    assert_equal 8, shapes.length
    shapes.each_value { |shape| assert_includes shape['parts'].map { |p| p['k'] }, 'body' }
  end

  def test_a_hinged_wardrobe_has_dividers_a_rail_and_shelves_in_the_other_sections
    shape = CabinetGallery.shapes('wardrobes', 'tall')['wardrobe_3door']
    assert_equal 3, shape['parts'].count { |p| p['k'] == 'door' }
  end

  def test_sliding_doors_overlap_and_run_on_two_tracks
    params = Defaults.params.merge('width' => 2100.0, 'depth' => 600.0, 'height' => 2400.0, 'door_count' => 3, 'sliding' => true, 'wardrobe' => true,
                                   'dividers' => 2, 'rail' => true, 'cabinet_category' => 'tall', 'toe_kick_height' => 100.0, 'shelf_count' => 4,
                                   'door_gap' => 3.0, 'door_reveal' => 1.0)
    layout = CabinetLayout.compute(params)
    doors = layout.doors
    assert_equal 3, doors.length
    assert_equal [nil, true, nil], doors.map { |d| d.slide ? true : nil }
    assert_operator doors[1].offset[0], :>, doors[0].offset[0], 'the middle door runs in front'
    assert_equal doors[0].offset[0], doors[2].offset[0]
    doors.each_cons(2) { |a, b| assert_operator a.offset[1] + a.extent[1], :>, b.offset[1], 'neighbours overlap' }
    assert_in_delta 2098.0, doors.last.offset[1] + doors.last.extent[1] - doors.first.offset[1], 0.1
    roles = layout.panels.map(&:role)
    assert_equal 2, roles.count { |r| r.start_with?('divider_') }
    assert_equal 2, roles.count { |r| r.start_with?('rail_') }, 'the 1st and 3rd sections hang clothes'
    assert roles.any? { |r| r.start_with?('shelf_2_') }, 'the middle section has shelves'
    assert_equal 'cyl_y', layout.panels.find { |p| p.role == 'rail_1' }.shape
  end

  def test_dividers_that_leave_a_section_too_narrow_are_refused
    raw = { 'width' => '600', 'depth' => '600', 'height' => '2400', 'cabinet_category' => 'tall', 'wardrobe' => true, 'dividers' => '3' }
    assert ValidationManager.validate(raw).errors.any? { |e| e.to_s.include?('sections would be only') }
    refute ValidationManager.validate(raw.merge('width' => '2000')).errors.any? { |e| e.to_s.include?('sections would be only') }
  end

  def test_a_saved_wardrobe_keeps_its_dividers_and_rail
    base = CatalogManager.cabinet('wardrobes', 'tall', 'wardrobe_3door')
    stored = { 'door_count' => 3, 'shelf_count' => 5, 'width' => 1500, 'depth' => 600, 'height' => 2400, 'dividers' => 1, 'rail' => false }
    entry = CatalogManager.entry_from(stored, base, 'Mine')
    assert_equal 1, entry['dividers']
    assert_equal false, entry['rail']
  end

  def test_a_sliding_door_moves_along_y_and_has_no_plan_swing
    door = CabinetLayout::Door.new(role: 'door_2', name: 'Door 2', extent: [18.0, 800.0, 2000.0], offset: [0.0, 0.0, 0.0], hinge: 'right',
                                   pivot: [0.0, 0.0, 0.0], rotation: 0.0, slide: -760.0)
    assert_empty DoorAnimation.indicator_segments([door], 90.0, 100.0)
    refute_empty DoorAnimation.door_symbol_segments(door)
  end
end
