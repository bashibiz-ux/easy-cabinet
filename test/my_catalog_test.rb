# frozen_string_literal: true

# Your own catalogs (cabinets kept from the model), the categorised materials and the drawer / sink fields.
# Run:  ruby test/my_catalog_test.rb

require 'json'
require 'tmpdir'
require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout front_design validation_manager catalog_manager material_manager part_layout handle_manager].each { |f| require File.join(plugin, f) }

class MyCatalogTest < Minitest::Test
  include KitchenCabinetMaster

  FakeColor = Struct.new(:red, :green, :blue)
  FakeMaterial = Struct.new(:name, :color)
  FakeModel = Struct.new(:materials)

  def setup
    @dir = Dir.mktmpdir('kcm')
    CatalogManager.user_root_override = @dir
    CatalogManager.reload!
  end

  def teardown
    CatalogManager.user_root_override = nil
    CatalogManager.reload!
    FileUtils.remove_entry(@dir)
  end

  def stored(overrides = {})
    { 'catalog_id' => 'kitchen_cabinets', 'cabinet_category' => 'base', 'cabinet_type' => 'base_2drawer', 'name_code' => 'BD',
      'width' => 750.0, 'depth' => 560.0, 'height' => 780.0, 'door_count' => 0, 'drawer_count' => 4, 'shelf_count' => 0 }.merge(overrides)
  end

  def base_of(data)
    CatalogManager.cabinet(data['catalog_id'], data['cabinet_category'], data['cabinet_type'])
  end

  def test_a_saved_cabinet_is_listed_in_a_catalog_of_your_own
    data = stored
    entry = CatalogManager.entry_from(data, base_of(data), 'Four drawers 750')
    ids = CatalogManager.save_custom('Kitchen 2', 'base', entry)
    assert_equal %w[custom_kitchen_2 four_drawers_750], ids
    catalog = CatalogManager.catalogs.find { |c| c['id'] == 'custom_kitchen_2' }
    assert catalog && catalog['custom'], 'listed as one of your own'
    assert_equal 'Kitchen 2', catalog['name']
    saved = CatalogManager.cabinet('custom_kitchen_2', 'base', 'four_drawers_750')
    assert_equal 4, saved['drawers']
    assert_equal 750.0, saved['defaults']['width']
    assert_equal 'BD', saved['code']
    assert_empty CatalogManager.warnings
    refute CatalogManager.catalogs.find { |c| c['id'] == 'kitchen_cabinets' }['custom']
  end

  def test_saving_under_the_same_name_replaces_and_a_second_name_adds
    data = stored
    CatalogManager.save_custom('Mine', 'base', CatalogManager.entry_from(data, base_of(data), 'A'))
    CatalogManager.save_custom('Mine', 'base', CatalogManager.entry_from(stored('width' => 800.0), base_of(data), 'A'))
    CatalogManager.save_custom('Mine', 'base', CatalogManager.entry_from(data, base_of(data), 'B'))
    list = CatalogManager.cabinets('custom_mine', 'base')
    assert_equal %w[a b], list.map { |c| c['id'] }.sort
    assert_equal 800.0, list.find { |c| c['id'] == 'a' }['defaults']['width']
  end

  def test_the_adjustable_heights_and_the_sink_come_along
    data = stored('cabinet_category' => 'tall', 'cabinet_type' => 'tall_2door', 'door_count' => 2, 'drawer_count' => 0, 'split_height' => 900.0, 'height' => 2160.0)
    base = CatalogManager.cabinet('kitchen_cabinets', 'tall', 'tall_2door')
    skip 'no such tall entry' unless base && base['split_label']
    assert_equal 900.0, CatalogManager.entry_from(data, base, 'Tall').fetch('split')
    sink = CatalogManager.cabinet('kitchen_cabinets', 'base', 'base_sink')
    entry = CatalogManager.entry_from(stored('cabinet_type' => 'base_sink', 'door_count' => 2, 'drawer_count' => 0, 'sink_bowls' => 2, 'sink_tray' => false), sink, 'Sink')
    assert_equal 2, entry['sink_bowls']
    assert_equal false, entry['sink_tray']
  end

  def test_removing_a_cabinet_removes_an_empty_catalog
    data = stored
    CatalogManager.save_custom('Mine', 'base', CatalogManager.entry_from(data, base_of(data), 'A'))
    CatalogManager.save_custom('Mine', 'base', CatalogManager.entry_from(data, base_of(data), 'B'))
    assert CatalogManager.remove_custom('custom_mine', 'base', 'a')
    assert_equal %w[b], CatalogManager.cabinets('custom_mine', 'base').map { |c| c['id'] }
    assert CatalogManager.remove_custom('custom_mine', 'base', 'b')
    assert_nil CatalogManager.catalog('custom_mine')
    refute CatalogManager.remove_custom('kitchen_cabinets', 'base', 'base_2drawer'), 'a bundled catalog is never changed'
  end

  # ---- materials ----

  def test_materials_come_in_categories_and_include_wood_plain_and_v_ray_ready_ones
    list = MaterialManager.presets
    assert list.length >= 100
    assert list.all? { |m| m['category'].to_s != '' && m['color'] =~ /\A#\h{6}\z/ }, 'every preset has a category and a colour'
    assert_equal list.map { |m| m['name'] }.uniq.length, list.length
    categories = list.map { |m| m['category'] }.uniq
    assert categories.count { |c| c.start_with?('Wood') } >= 3
    assert categories.count { |c| c.start_with?('Plain colours') } >= 3
    assert categories.count { |c| c.start_with?('V-Ray ready') } >= 2
    %w[Shutter\ -\ Light\ Beige Carcass\ -\ Light\ Gray White].each { |name| assert list.any? { |m| m['name'] == name }, name }
    assert list.select { |m| m['kinds'].include?('panel') }.none? { |m| m['name'] =~ /Glass|\A(Gold|Red|Yellow|Coral|Mustard|Mint)\z|VR Gloss Red/ }, 'no loud colours, no glass among the board materials, no gold'
  end

  def test_the_options_group_by_category_with_the_models_own_materials_first
    model = FakeModel.new([FakeMaterial.new('My Special', FakeColor.new(1, 2, 3)), FakeMaterial.new('White', FakeColor.new(255, 255, 255)), FakeMaterial.new('Appliance - Inox', FakeColor.new(200, 200, 200)), FakeMaterial.new('Cabinet Name Label', FakeColor.new(0, 0, 0))])
    panel = MaterialManager.options(model)['panel']
    assert_equal 'In this model', panel.first['group']
    assert_equal 'My Special', panel.first['id']
    white = panel.find { |m| m['id'] == 'White' }
    assert_equal 'Plain colours - Whites', white['group'], 'a preset that is also in the model keeps its category'
    assert_equal 1, panel.count { |m| m['id'] == 'White' }
    refute panel.any? { |m| m['id'] =~ /\AAppliance - |Cabinet Name Label/ }, 'the extension''s own materials are not offered'
    walnut = panel.find { |m| m['id'] == 'Walnut' }
    assert_match(/Wood/, walnut['group'])
    toe = MaterialManager.options(model)['toe_kick']
    assert_equal Defaults::SAME_AS_DOOR, toe.first['id']
  end

  # ---- drawers and sink ----

  def test_a_drawer_unit_can_have_any_number_of_drawers
    result = ValidationManager.validate({ 'catalog_id' => 'kitchen_cabinets', 'cabinet_category' => 'base', 'cabinet_type' => 'base_2drawer', 'width' => '600', 'depth' => '560', 'height' => '780',
                                          'toe_kick_height' => '100', 'door_opening_direction' => 'left' }, door_count: 0, drawer_count: 5)
    assert_empty result.errors.map { |e| e['message'] }
    params = result.params.merge('door_count' => 0, 'drawer_count' => 5)
    assert_equal 5, CabinetLayout.compute(params).drawers.length
  end

  def test_a_sink_is_mirrored_not_turned
    base = { 'sink' => true, 'catalog_id' => 'kitchen_cabinets', 'cabinet_category' => 'base', 'cabinet_type' => 'base_sink', 'width' => '900', 'depth' => '560', 'height' => '780',
             'toe_kick_height' => '100', 'door_opening_direction' => 'left' }
    plain = ValidationManager.validate(base, door_count: 2, drawer_count: 0)
    assert_equal false, plain.params['sink_mirror']
    mirrored = ValidationManager.validate(base.merge('sink_mirror' => true), door_count: 2, drawer_count: 0)
    assert_equal true, mirrored.params['sink_mirror']
    old = ValidationManager.validate(base.merge('sink_rotation' => '180'), door_count: 2, drawer_count: 0)
    assert_equal true, old.params['sink_mirror'], 'an older cabinet turned half a turn is mirrored'
    assert_equal false, ValidationManager.validate(base.merge('sink_rotation' => '90'), door_count: 2, drawer_count: 0).params['sink_mirror']
  end

  def test_the_one_door_sink_is_single_and_the_hood_comes_in_900
    one = CatalogManager.cabinet('kitchen_cabinets', 'base', 'base_sink_1door')
    assert one['sink_single']
    refute CatalogManager.cabinet('kitchen_cabinets', 'base', 'base_sink')['sink_single']
    assert_includes CatalogManager.cabinet('kitchen_cabinets', 'wall', 'wall_hood')['widths'], 900
  end
  def test_a_model_you_drew_is_kept_as_a_component_entry_and_its_file_goes_with_it
    FileUtils.mkdir_p(File.join(@dir, 'models'))
    file = File.join('models', 'custom_mine_shelf.skp')
    File.write(File.join(@dir, file), 'model')
    entry = CatalogManager.component_entry('Shelf unit', [800.0, 300.0, 1800.0], file)
    ids = CatalogManager.save_custom('Mine', 'tall', entry)
    saved = CatalogManager.cabinet(ids[0], 'tall', ids[1])
    assert_equal file, saved['component']
    assert_equal [800.0, 300.0, 1800.0], saved.dig('defaults', 'width').then { |w| [w, saved['defaults']['depth'], saved['defaults']['height']] }
    assert_equal File.join(@dir, file), CatalogManager.component_path(saved)
    assert_empty CatalogManager.warnings
    assert CatalogManager.remove_custom(ids[0], 'tall', ids[1])
    refute File.file?(File.join(@dir, file)), 'the model file is deleted with its entry'
  end

  def test_egger_decors_are_listed_in_their_own_categories
    names = MaterialManager.presets.select { |m| m['category'].to_s.start_with?('EGGER') }
    assert_operator names.length, :>=, 25
    assert names.any? { |m| m['name'] == 'EGGER H1145 Bardolino Oak' && m['texture'] }, 'a woodgrain decor has its picture'
    assert names.any? { |m| m['name'] == 'EGGER W1000 Premium White' && m['texture'].nil? }, 'a plain decor is a plain colour'
    assert_equal %w[EGGER\ -\ Plain\ decors EGGER\ -\ Woodgrain\ decors], names.map { |m| m['category'] }.uniq.sort
    assert MaterialManager.presets.all? { |m| m['texture'].nil? || File.file?(File.join(MaterialManager::TEXTURE_DIR, m['texture'])) }, 'every picture exists'
  end
  def test_your_own_materials_are_listed_by_category_and_can_be_removed
    assert_nil MaterialManager.save_custom('name' => 'Walnut Veneer 7', 'category' => 'Kitchen', 'color' => '#6b4a32', 'kinds' => %w[panel toe_kick])
    assert_nil MaterialManager.save_custom('name' => 'Teal Gloss', 'category' => '', 'color' => '#2f6f73')
    mine = MaterialManager.custom_summary
    assert_equal ['Teal Gloss', 'Walnut Veneer 7'], mine.map { |m| m['name'] }.sort
    assert_equal 'General', mine.find { |m| m['name'] == 'Teal Gloss' }['category'], 'a blank category is General'
    panel = MaterialManager.options(FakeModel.new([]))['panel']
    walnut = panel.find { |m| m['id'] == 'Walnut Veneer 7' }
    assert_equal 'My materials - Kitchen', walnut['group']
    assert_equal '#6B4A32', MaterialManager.presets.find { |m| m['name'] == 'Walnut Veneer 7' }['color']
    assert_match(/name/i, MaterialManager.save_custom('name' => '', 'color' => '#ffffff'))
    assert_match(/comes with/, MaterialManager.save_custom('name' => 'White', 'color' => '#ffffff'), 'a bundled name is not taken')
    assert_match(/colour/, MaterialManager.save_custom('name' => 'Bad', 'color' => 'red'))
    assert MaterialManager.remove_custom('Teal Gloss')
    refute MaterialManager.remove_custom('Teal Gloss')
    assert_equal ['Walnut Veneer 7'], MaterialManager.custom_summary.map { |m| m['name'] }
  end
  def test_front_designs_cut_shapes_into_a_front_and_leave_a_small_one_flat
    ids = FrontDesign::DESIGNS.map { |d| d['id'] }
    assert_equal %w[flat shaker slim_shaker stepped fluted grooved three_panel beaded flutes_h line_frame edge_pull], ids
    assert_empty FrontDesign.cuts('flat', 600, 700, 18)
    ids.reject { |id| id == 'flat' }.each do |id|
      cuts = FrontDesign.cuts(id, 596, 716, 18)
      assert_operator cuts.length, :>=, 1, id
      cuts.each do |y0, y1, z0, z1, from, to|
        assert y0 >= 0 && y1 <= 596 && z0 >= 0 && z1 <= 716, "#{id}: inside the front"
        assert_operator y1, :>, y0
        assert_operator z1, :>, z0
        assert_operator to, :>, from
        FrontDesign.glass?(id) ? assert_equal(18.0, to, "#{id}: a glass design cuts right through") : assert_operator(to, :<, 18, "#{id}: never through the board")
      end
    end
    shaker = FrontDesign.cuts('shaker', 596, 716, 18).first
    assert_equal [70.0, 526.0, 70.0, 646.0], shaker[0, 4], 'a recessed panel in a 70 mm frame'
    assert_equal 2, FrontDesign.cuts('stepped', 596, 716, 18).length, 'two steps'
    assert_operator FrontDesign.cuts('fluted', 596, 716, 18).length, :>=, 20, 'many grooves'
    assert_equal 1, FrontDesign.cuts('grooved', 596, 716, 18).length
    # a small front stays flat, a narrow one gets a slimmer frame
    assert_empty FrontDesign.cuts('shaker', 100, 100, 18), 'too small for a frame'
    assert_empty FrontDesign.cuts('fluted', 60, 700, 18)
    assert_empty FrontDesign.cuts('grooved', 400, 200, 18)
    narrow = FrontDesign.cuts('shaker', 146, 716, 18).first
    assert_in_delta 43.0, narrow[0], 0.01, 'the frame is narrower on a narrow front'
    assert_equal 'flat', FrontDesign.clean('nonsense')
    assert_equal 'shaker', FrontDesign.clean('shaker')
  end

  def test_a_cabinet_keeps_its_front_design
    base = { 'catalog_id' => 'kitchen_cabinets', 'cabinet_category' => 'base', 'cabinet_type' => 'base_2door', 'width' => '900', 'depth' => '560', 'height' => '780',
             'toe_kick_height' => '100', 'door_opening_direction' => 'left' }
    assert_equal 'flat', ValidationManager.validate(base, door_count: 2, drawer_count: 0).params['front_design']
    assert_equal 'shaker', ValidationManager.validate(base.merge('front_design' => 'shaker'), door_count: 2, drawer_count: 0).params['front_design']
    assert_equal 'flat', ValidationManager.validate(base.merge('front_design' => 'zigzag'), door_count: 2, drawer_count: 0).params['front_design']
    assert_equal 'flat', Defaults.params['front_design']
  end
  def test_every_front_design_cuts_inside_a_tall_door_a_base_door_and_a_wide_drawer_front
    [[596, 716], [446, 2060], [896, 196], [296, 356]].each do |w, h|
      FrontDesign::DESIGNS.map { |d| d['id'] }.reject { |id| id == 'flat' }.each do |id|
        cuts = FrontDesign.cuts(id, w, h, 18)
        assert_operator cuts.length, :<=, 60, "#{id} #{w}x#{h}: not an endless number of grooves"
        cuts.each do |y0, y1, z0, z1, from, to|
          assert y0 >= -1e-9 && y1 <= w + 1e-9 && z0 >= -1e-9 && z1 <= h + 1e-9, "#{id} #{w}x#{h}: inside the front"
          assert y1 > y0 && z1 > z0 && to > from && (to < 18 || FrontDesign.glass?(id)) # (a glass design cuts right through)
        end
      end
    end
    assert_empty FrontDesign.cuts('edge_pull', 400, 100, 18), 'no finger groove on a very low front'
    assert_equal 2, FrontDesign.cuts('three_panel', 596, 2060, 18).length
    assert_equal 4, FrontDesign.cuts('line_frame', 596, 716, 18).length, 'the four sides of the outline'
    pull = FrontDesign.cuts('edge_pull', 596, 716, 18).first
    assert_equal 716.0, pull[3], 'the groove reaches the top edge'
    assert_operator FrontDesign.cuts('beaded', 596, 716, 18).length, :>, FrontDesign.cuts('fluted', 596, 716, 18).length
  end

  def test_an_end_panel_is_flat_or_in_the_selected_front_design
    raw = { 'side' => 'right', 'depth' => '580', 'thickness' => '18', 'height' => '880', 'material' => Defaults::SAME_AS_DOOR }
    flat = ValidationManager.validate_end_panel(raw)
    assert_equal 'flat', flat.params['face']
    follow = ValidationManager.validate_end_panel(raw.merge('face' => 'design', 'front_design' => 'shaker'))
    assert_equal ['design', 'shaker'], follow.params.values_at('face', 'front_design')
    assert_empty follow.errors
    base = follow.params.merge('target_base_z' => 0.0)
    assert_nil PartLayout.end_panel(base.merge('face' => 'flat', 'front_radius' => 0.0)).board.shape, 'a flat side panel with square edges'
    assert_equal ['front_flat@right', 3.0], PartLayout.end_panel(base.merge('face' => 'flat')).board.to_h.values_at(:shape, :round), 'a flat side panel has rounded edges'
    assert_equal 'front_shaker@right', PartLayout.end_panel(base).board.shape, 'cut in the design, on its outer (right) face'
    assert_equal 'front_fluted@left', PartLayout.end_panel(base.merge('side' => 'left', 'front_design' => 'fluted')).board.shape
    assert_nil PartLayout.end_panel(base.merge('front_design' => 'flat', 'front_radius' => 0.0)).board.shape, 'the flat design is no cut'
    assert_equal 'flat', Defaults.end_panel_params['face']
  end

  def test_a_handle_you_drew_is_kept_as_a_handle_package_listed_with_the_others
    bundle = CatalogManager.handle_from_model('My Long Bar', [200.0, 30.0, 12.0], 'models/handle_my_long_bar.skp')
    assert_equal 'custom_my_long_bar', bundle['id']
    assert_equal 'model', bundle['profile']
    assert_equal [200.0], bundle['lengths']
    assert_equal 12.0, bundle['section']
    assert_equal 30.0, bundle['projection']
    assert_equal 'x', bundle['along']
    assert_equal 'z', CatalogManager.handle_from_model('Tall', [12.0, 30.0, 200.0], 'models/t.skp')['along'], 'a handle drawn up the blue axis'
    assert_equal 'As drawn', bundle['finishes'].first['name']
    assert HandleManager.keeps_look?(bundle, 'As drawn')
    refute HandleManager.keeps_look?(bundle, bundle['finishes'][1]['name'])
    assert_nil CatalogManager.send(:handle_problem, bundle)

    CatalogManager.save_custom_handle(bundle)
    assert File.file?(File.join(@dir, 'handles', 'custom_my_long_bar.json'))
    listed = CatalogManager.handle_bundles.find { |b| b['id'] == 'custom_my_long_bar' }
    assert listed && listed['custom'] == true && listed['group'] == 'My handles'
    refute CatalogManager.handle_bundles.find { |b| b['id'] == 'sample_bar_handles' }['custom']
    refute CatalogManager.remove_custom_handle('sample_bar_handles'), 'a bundled handle cannot be removed'

    FileUtils.mkdir_p(File.join(@dir, 'models'))
    File.write(File.join(@dir, 'models', 'handle_my_long_bar.skp'), 'x')
    assert CatalogManager.remove_custom_handle('custom_my_long_bar')
    assert_nil CatalogManager.handle_bundle('custom_my_long_bar')
    refute File.exist?(File.join(@dir, 'models', 'handle_my_long_bar.skp'))
  end

  def test_a_handle_you_drew_is_turned_into_the_handle_frame_with_its_back_on_the_door
    # the frame: X out of the door, Y across it, Z along the grip. As drawn (grip along X, back on the high-Y side, standing out towards low Y).
    apply = lambda do |axes, point|
      x, y, z, origin = axes
      [0, 1, 2].map { |i| (x[i] * point[0]) + (y[i] * point[1]) + (z[i] * point[2]) + origin[i] }
    end
    min = [10.0, 5.0, 2.0]
    max = [210.0, 35.0, 14.0]
    axes = HandleManager.model_axes('x', min, max)
    back = apply.call(axes, [110.0, 35.0, 8.0]) # the middle of the back
    assert_in_delta 0.0, back[0], 1e-9
    assert_in_delta 0.0, back[1], 1e-9
    assert_in_delta 0.0, back[2], 1e-9
    front = apply.call(axes, [110.0, 5.0, 8.0])
    assert_in_delta 30.0, front[0], 1e-9, 'it stands out 30 from the door'
    end_of_grip = apply.call(axes, [210.0, 35.0, 8.0])
    assert_in_delta 100.0, end_of_grip[2], 1e-9, 'its length runs along Z'
    det = lambda do |x, y, z|
      (x[0] * ((y[1] * z[2]) - (y[2] * z[1]))) - (x[1] * ((y[0] * z[2]) - (y[2] * z[0]))) + (x[2] * ((y[0] * z[1]) - (y[1] * z[0])))
    end
    assert_equal 1, det.call(*axes.first(3)), 'a turn, not a mirror image'
    tall = HandleManager.model_axes('z', [0.0, 0.0, 0.0], [12.0, 30.0, 200.0])
    assert_equal 1, det.call(*tall.first(3))
    top = apply.call(tall, [6.0, 30.0, 200.0])
    assert_in_delta 100.0, top[2], 1e-9
    assert_in_delta 0.0, top[0], 1e-9
  end
end
