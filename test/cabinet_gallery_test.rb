# frozen_string_literal: true

# The pictures of the cabinet gallery: every cabinet of every catalog has a shape made of boxes. Run:  ruby test/cabinet_gallery_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager gola_profile cabinet_layout front_design appliance_parts fixtures validation_manager catalog_manager handle_manager door_animation panel_generator cabinet_gallery].each { |f| require File.join(plugin, f) }

class CabinetGalleryTest < Minitest::Test
  include EasyCabinet

  def each_category
    CatalogManager.catalogs.each do |catalog|
      %w[base wall tall].each { |category| yield catalog['id'], category }
    end
  end

  def test_every_cabinet_of_every_category_has_a_shape_with_a_body_and_a_front
    seen = 0
    each_category do |catalog, category|
      entries = CatalogManager.cabinets(catalog, category)
      shapes = CabinetGallery.shapes(catalog, category)
      assert_equal entries.map { |e| e['id'] }, shapes.keys, "#{catalog} #{category}: a shape for each cabinet, in the order of the list"
      shapes.each do |id, shape|
        assert_operator shape['w'], :>, 0, "#{catalog} #{id}: width"
        assert_operator shape['h'], :>, 0, "#{catalog} #{id}: height"
        kinds = shape['parts'].map { |p| p['k'] }
        assert_includes kinds, 'body', "#{catalog} #{id}: a carcass"
        assert_includes kinds, 'door', "#{catalog} #{id}: a front" if kinds.none? { |k| k == 'drawer' } && !id.include?('open')
        shape['parts'].each do |part|
          assert_equal 3, part['o'].length
          assert_equal 3, part['e'].length
          assert part['o'].all? { |v| v.is_a?(Numeric) } && part['e'].all? { |v| v.is_a?(Numeric) }, "#{catalog} #{id}: numbers only"
        end
        seen += 1
      end
    end
    assert_operator seen, :>, 60
  end

  def test_a_base_unit_stands_on_a_plinth_and_a_wall_unit_does_not
    base = CabinetGallery.shapes('kitchen_cabinets', 'base')['base_2door']
    assert base['parts'].any? { |p| p['k'] == 'toe' }, 'a base unit shows its plinth'
    wall = CabinetGallery.shapes('kitchen_cabinets', 'wall')['wall_2door']
    assert wall['parts'].none? { |p| p['k'] == 'toe' }
  end

  def test_the_drawers_of_a_drawer_unit_are_fronts_of_their_own
    shape = CabinetGallery.shapes('kitchen_cabinets', 'base')['base_3drawer']
    skip 'no such unit' unless shape
    assert_operator shape['parts'].count { |p| p['k'] == 'drawer' }, :>=, 2
  end
end

# The ghost that follows the cursor when a cabinet is placed from the gallery: the cabinet's own boxes, with its doors and plinth.
require File.join(File.expand_path('../easy_cabinet', __dir__), 'place_tool')

class PlaceGhostTest < Minitest::Test
  include EasyCabinet

  def params_of(id, category = 'base')
    entry = CatalogManager.cabinet('kitchen_cabinets', category, id)
    _layout, params = CabinetGallery.send(:layout_of, 'kitchen_cabinets', category, entry)
    params
  end

  def test_the_ghost_has_edges_fronts_and_a_plinth
    tool = PlaceTool.allocate
    ghost = tool.send(:ghost_of, params_of('base_2door'))
    refute_nil ghost
    assert_operator ghost[:edges].length, :>, 60, 'the edges of every box'
    assert_equal 0, ghost[:edges].length % 2
    assert_operator ghost[:fronts].length, :>=, 8, 'two doors'
    assert_equal 0, ghost[:fronts].length % 4
    assert_equal 4, ghost[:toe].length, 'the plinth of a base unit'
  end

  def test_a_wall_unit_has_no_plinth
    ghost = PlaceTool.allocate.send(:ghost_of, params_of('wall_2door', 'wall'))
    assert_empty ghost[:toe]
  end

  def test_the_shape_says_where_a_door_is_hinged_and_which_kind_of_unit_it_is
    shape = CabinetGallery.shapes('kitchen_cabinets', 'base')['base_1door']
    assert_equal 'base', shape['cat']
    assert_includes %w[left right], shape['parts'].find { |p| p['k'] == 'door' }['g']
  end
end
