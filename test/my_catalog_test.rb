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
%w[response defaults attribute_manager cabinet_layout validation_manager catalog_manager material_manager].each { |f| require File.join(plugin, f) }

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
    glass = list.find { |m| m['name'] == 'VR Clear Glass' }
    assert glass['alpha'] < 1.0, 'glass is see-through'
  end

  def test_the_options_group_by_category_with_the_models_own_materials_first
    model = FakeModel.new([FakeMaterial.new('My Special', FakeColor.new(1, 2, 3)), FakeMaterial.new('White', FakeColor.new(255, 255, 255))])
    panel = MaterialManager.options(model)['panel']
    assert_equal 'In this model', panel.first['group']
    assert_equal 'My Special', panel.first['id']
    white = panel.find { |m| m['id'] == 'White' }
    assert_equal 'Plain colours - Whites', white['group'], 'a preset that is also in the model keeps its category'
    assert_equal 1, panel.count { |m| m['id'] == 'White' }
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
end
