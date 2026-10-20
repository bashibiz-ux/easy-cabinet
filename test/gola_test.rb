# frozen_string_literal: true

# The Gola handle model: profiles (Häfele systems B Plus, C Plus, D, E) in the gaps between the fronts. Run:  ruby test/gola_test.rb

require 'json'
require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout front_design validation_manager catalog_manager handle_manager door_animation panel_generator].each { |f| require File.join(plugin, f) }

class GolaTest < Minitest::Test
  include KitchenCabinetMaster

  CATALOG = 'kitchen_cabinets_gola_profile'

  def layout_of(category, id, width, system, drawer_system = system, extra = {})
    entry = CatalogManager.cabinet(CATALOG, category, id)
    raw = { 'catalog_id' => CATALOG, 'cabinet_category' => category, 'cabinet_type' => id, 'width' => width.to_s, 'depth' => entry['defaults']['depth'].to_s,
            'height' => entry['defaults']['height'].to_s, 'toe_kick_height' => '100', 'door_opening_direction' => 'left', 'shelf_count' => entry['shelves'].to_s,
            'drawer_pattern' => entry['pattern'].to_s, 'gola_system' => system, 'gola_system_drawer' => drawer_system }.merge(extra)
    result = ValidationManager.validate(raw, door_count: entry['doors'].to_i, drawer_count: entry['drawers'].to_i)
    assert_empty result.errors
    params = result.params.merge('door_count' => entry['doors'].to_i, 'drawer_count' => entry['drawers'].to_i)
    [CabinetLayout.compute(params), params]
  end

  def top(item) = item.offset[2] + item.extent[2]

  # ---- the packages ------------------------------------------------------------------------

  def test_the_catalog_has_the_cabinets_of_the_model_with_handle_and_the_four_gola_packages
    assert_equal 'Kitchen Cabinet - Gola handle', CatalogManager.catalog(CATALOG)['name']
    %w[base wall tall].each do |category|
      assert_equal CatalogManager.cabinets('kitchen_cabinets', category).map { |c| c['id'] }, CatalogManager.cabinets(CATALOG, category).map { |c| c['id'] }, category
    end
    assert_equal %w[gola_b_plus gola_c_plus gola_d gola_e], CatalogManager.catalog(CATALOG)['handle_bundles']
    assert_empty CatalogManager.warnings
  end

  def test_the_packages_have_the_sizes_and_finishes_of_the_hafele_pages
    sizes = { 'gola_b_plus' => [56.5, 27, 4100], 'gola_c_plus' => [73, 26, 4100], 'gola_d' => [66.5, 12, 2670], 'gola_e' => [72, 20, 2400] }
    sizes.each do |id, (width, depth, length)|
      bundle = CatalogManager.handle_bundle(id)
      assert_equal 'gola', bundle['profile'], id
      assert_equal width, bundle['section'], id
      assert_equal depth, bundle['projection'], id
      assert_equal [length], bundle['lengths'], id
      assert_equal ['Silver anodised', 'Brushed brass anodised', 'Bronze anodised', 'Brushed copper anodised', 'Graphite powder coated'].sort, bundle['finishes'].map { |f| f['name'] }.sort, id
      assert(bundle['finishes'].all? { |f| f['article'] =~ /\A126\.\d\d\.\d{3}\z/ }, "#{id}: every finish has its article number")
    end
    assert_equal '126.36.940', CatalogManager.handle_bundle('gola_b_plus')['finishes'].find { |f| f['name'] == 'Silver anodised' }['article']
    assert_equal '126.36.972', CatalogManager.handle_bundle('gola_d')['finishes'].find { |f| f['name'] == 'Silver anodised' }['end_article'], 'the end profile'
    assert_equal 'd', CatalogManager.gola_system('gola_d')
    assert_equal '', CatalogManager.gola_system('d_handles')
    assert_equal '', CatalogManager.gola_system('')
  end

  # ---- the sections are closed solids ---------------------------------------------------------

  def closed?(faces)
    edges = Hash.new(0)
    faces.each { |c| c.each_with_index { |p, i| edges[[p.map { |v| v.round(3) }, c[(i + 1) % c.length].map { |v| v.round(3) }]] += 1 } }
    edges.keys.reject { |a, b| edges.key?([b, a]) }.empty?
  end

  def test_every_section_is_a_simple_closed_shape_drawn_as_a_closed_solid
    %w[b c d e].each do |system|
      kinds = GolaProfile::SYSTEMS[system][:horizontal] ? %w[top between] : %w[pair end_right end_left]
      kinds.each do |kind|
        spot = { 'system' => system, 'kind' => kind, 'back' => -21.0 }
        outline = GolaProfile.outline_for(spot)
        outline.each_with_index { |p, i| assert_operator Math.hypot(p[0] - outline[(i + 1) % outline.length][0], p[1] - outline[(i + 1) % outline.length][1]), :>, 0.5, "#{system} #{kind}" }
        faces = HandleManager.loft_faces([[-100.0, outline], [100.0, outline]])
        assert closed?(faces), "#{system} #{kind}"
      end
    end
  end

  # ---- B Plus: the top fronts of a base unit ----------------------------------------------------

  def test_b_plus_cuts_the_top_fronts_of_a_base_unit_back_and_puts_a_profile_in_the_gap
    plain, = layout_of('base', 'base_2door', 900, '')
    layout, params = layout_of('base', 'base_2door', 900, 'b')
    reveal = params['door_reveal'].to_f
    layout.doors.each_with_index do |door, i|
      assert_in_delta plain.doors[i].extent[2] - (56.5 - reveal), door.extent[2], 0.02, 'the door is cut back to make room for the profile'
      assert_in_delta top(plain.doors[i]) - 56.5 + reveal, top(door), 0.02
      assert_equal 'top', door.gola['kind']
      assert_equal door.extent[2], door.gola['v'], 'the profile stands on the top edge of the door'
    end
    assert_equal ['b'], layout.doors.map { |d| d.gola['system'] }.uniq
  end

  def test_b_plus_profiles_of_neighbouring_doors_join_and_reach_the_carcass_at_the_ends
    layout, params = layout_of('base', 'base_2door', 900, 'b')
    first, second = layout.doors
    reveal = params['door_reveal'].to_f
    gap = params['door_gap'].to_f
    from = first.offset[1] + first.gola['u'] - (first.gola['length'] / 2.0)
    to = second.offset[1] + second.gola['u'] + (second.gola['length'] / 2.0)
    assert_in_delta first.offset[1] - reveal, from, 0.05
    assert_in_delta second.offset[1] + second.extent[1] + reveal, to, 0.05
    meet = first.offset[1] + first.gola['u'] + (first.gola['length'] / 2.0)
    assert_in_delta second.offset[1] + second.gola['u'] - (second.gola['length'] / 2.0), meet, 0.05, "the two profiles meet in the gap of #{gap} mm"
  end

  def test_b_plus_is_only_for_the_top_fronts_of_base_units_and_wall_units_have_no_handle
    layout, = layout_of('wall', 'wall_2door', 800, 'b')
    assert(layout.doors.all? { |d| d.gola.nil? }, 'a wall unit has no worktop above it: no profile, no handle')
    layout, = layout_of('base', 'base_open', 600, 'b')
    assert_empty layout.doors
  end

  def test_the_drawers_of_a_base_unit_get_their_profile_in_the_system_of_the_drawers
    layout, = layout_of('base', 'base_3drawer', 600, 'd', 'b')
    top_drawer = layout.drawers.max_by { |d| top(d) }
    assert_equal 'b', top_drawer.gola['system']
    others = layout.drawers - [top_drawer]
    assert(others.all? { |d| d.gola.nil? }, 'B Plus is only between the worktop and the top front')
  end

  # ---- C Plus: between a front and the one above it ------------------------------------------------

  def test_c_plus_fills_the_gap_between_two_stacked_fronts
    plain, = layout_of('base', 'base_3drawer', 600, '')
    layout, = layout_of('base', 'base_3drawer', 600, 'c')
    ordered = layout.drawers.sort_by { |d| d.offset[2] }
    assert_nil ordered.last.gola, 'the top front has nothing above it'
    ordered[0..-2].each_with_index do |drawer, i|
      above = ordered[i + 1]
      gap = above.offset[2] - top(drawer)
      before = plain.drawers.sort_by { |d| d.offset[2] }
      assert_in_delta 73.0 - (before[i + 1].offset[2] - top(before[i])), before[i].extent[2] - drawer.extent[2], 0.05, 'the lower front gives up what the profile needs'
      assert_in_delta 73.0, gap, 0.05, 'and the profile (73 high) fills the space between them'
      assert_equal 'between', drawer.gola['kind']
    end
  end

  # ---- D and E: between doors --------------------------------------------------------------------

  def test_d_and_e_set_the_gap_between_two_doors_and_put_a_profile_in_it
    plain, = layout_of('base', 'base_2door', 900, '')
    %w[d e].each do |system|
      layout, = layout_of('base', 'base_2door', 900, system)
      left, right = layout.doors
      spec = GolaProfile::SYSTEMS[system]
      assert_in_delta spec[:gap], right.offset[1] - (left.offset[1] + left.extent[1]), 0.05, "the gap of system #{system}"
      assert_in_delta plain.doors[0].offset[1], left.offset[1], 0.05, 'the outer edges stay'
      assert_in_delta plain.doors[1].offset[1] + plain.doors[1].extent[1], right.offset[1] + right.extent[1], 0.05
      assert_equal 'pair', left.gola['kind']
      assert_nil right.gola, 'one profile serves both doors'
      assert_in_delta left.extent[1] + (spec[:gap] / 2.0), left.gola['u'], 0.05, 'in the middle of the gap'
      assert_in_delta left.extent[2], left.gola['length'], 0.05
      assert_equal false, left.gola['horizontal']
    end
  end

  def test_the_hinges_follow_the_edges_of_doors_that_were_cut_back
    layout, = layout_of('base', 'base_2door', 900, 'd')
    left, right = layout.doors
    plain, = layout_of('base', 'base_2door', 900, '')
    shift = plain.doors[0].extent[1] - left.extent[1]
    assert_operator shift, :>, 0
    assert_in_delta plain.doors[0].pivot[1] + (left.hinge == 'right' ? -shift : 0.0), left.pivot[1], 0.05
    assert_in_delta plain.doors[1].pivot[1] + (right.hinge == 'left' ? shift : 0.0), right.pivot[1], 0.05
  end

  def test_a_door_with_no_neighbour_has_an_end_profile_on_its_free_edge
    plain, = layout_of('base', 'base_1door', 600, '')
    layout, = layout_of('base', 'base_1door', 600, 'e')
    door = layout.doors.first
    assert_in_delta plain.doors.first.extent[1] - GolaProfile::END_REDUCE, door.extent[1], 0.05
    assert_equal 'end_right', door.gola['kind'], 'hinged on the left: the free edge is on the right'
    assert_in_delta door.extent[1], door.gola['u'], 0.05
    layout, = layout_of('base', 'base_1door', 600, 'e', 'e', 'door_opening_direction' => 'right')
    door = layout.doors.first
    assert_equal 'end_left', door.gola['kind']
    assert_in_delta 0.0, door.gola['u'], 0.05
    assert_in_delta plain.doors.first.offset[1] + GolaProfile::END_REDUCE, door.offset[1], 0.05
  end

  # ---- every cabinet, every width, every system -----------------------------------------------------

  def test_every_cabinet_in_every_width_lays_out_with_every_system_and_no_front_is_too_small
    count = 0
    %w[base wall tall].each do |category|
      CatalogManager.cabinets(CATALOG, category).each do |entry|
        (entry['widths'] || [entry['defaults']['width']]).each do |width|
          %w[b c d e].each do |system|
            layout, = layout_of(category, entry['id'], width, system)
            (layout.doors + layout.drawers).each do |item|
              assert_operator item.extent[1], :>=, 50.0, "#{entry['id']} #{width} #{system}: #{item.name} too narrow"
              assert_operator item.extent[2], :>=, 50.0, "#{entry['id']} #{width} #{system}: #{item.name} too low"
              next unless item.gola

              assert_operator item.gola['length'], :>, 0.0
              assert_includes %w[top between pair end_left end_right], item.gola['kind']
            end
            count += 1
          end
        end
      end
    end
    assert_operator count, :>, 300
  end

  def test_a_catalog_without_gola_profiles_is_not_touched
    plain, = layout_of('base', 'base_2door', 900, '')
    assert(plain.doors.all? { |d| d.gola.nil? })
    other, = layout_of('base', 'base_2door', 900, 'x')
    assert_equal plain.doors.map(&:extent), other.doors.map(&:extent), 'an unknown system is no system'
  end

  # ---- the handle: placement and drawing ------------------------------------------------------------

  def test_the_profile_is_placed_where_the_layout_put_it
    layout, params = layout_of('base', 'base_2door', 900, 'b')
    bundle = CatalogManager.handle_bundle('gola_b_plus')
    door = layout.doors.first
    spot = HandleManager.placement(door, HandleManager.settings(HandleManager.apply_defaults!(params.dup, bundle), bundle), bundle)
    assert_equal door.gola['length'], spot['length']
    assert_equal true, spot['horizontal']
    assert_equal door.extent[2], spot['v']
    refute_nil HandleManager.handle_faces(bundle, spot['length'], false, spot)
    assert_empty HandleManager.errors(HandleManager.apply_defaults!(params.dup, bundle), layout, bundle), 'it never "does not fit"'
  end

  def test_the_profile_is_drawn_as_a_solid_of_the_outline_of_its_system
    bundle = CatalogManager.handle_bundle('gola_c_plus')
    layout, = layout_of('base', 'base_3drawer', 600, 'c')
    drawer = layout.drawers.min_by { |d| d.offset[2] }
    faces = HandleManager.handle_faces(bundle, drawer.gola['length'], false, drawer.gola)
    xs = faces.flatten(1).map { |p| p[0] }
    assert_in_delta drawer.gola['back'], xs.min, 0.001, 'the back plate is on the front of the carcass'
    assert_in_delta 0.0, xs.max, 0.001, 'the lips are flush with the doors'
    ys = faces.flatten(1).map { |p| p[1] }
    assert_in_delta 73.0, ys.max - ys.min, 0.001
    assert closed?(faces)
  end
end
