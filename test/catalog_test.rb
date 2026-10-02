# frozen_string_literal: true

# Runs the plugin's REAL CatalogManager against the bundled catalog files.
# Run:  ruby test/catalog_test.rb

require 'json'
require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
require_relative '../kitchen_cabinet_master/response'
require_relative '../kitchen_cabinet_master/defaults'
require_relative '../kitchen_cabinet_master/catalog_manager'

class CatalogTest < Minitest::Test
  include KitchenCabinetMaster
  DATA_DIR_FOR_TEST = KitchenCabinetMaster::DATA_DIR

  def test_the_models_are_door_with_pull_handle_drawer_units_and_handleless_doors
    catalogs = CatalogManager.catalogs
    assert_equal ['Door with pull handle', 'Drawer base units', 'Handleless doors', 'Kitchen Cabinet - Pull Handle'], catalogs.map { |c| c['name'] }
    assert_empty CatalogManager.warnings
  end

  def test_the_handleless_model_has_no_handle_and_the_drawer_model_has_drawers
    plain = CatalogManager.catalogs.find { |c| c['id'] == 'handleless_doors' }
    refute_includes plain['features'], 'handle'
    assert_equal [], plain['handle_bundles']
    assert_equal [2, 3, 4, 3, 0], CatalogManager.cabinets('drawer_units', 'base').map { |c| c['drawers'].to_i }
    refute_empty CatalogManager.cabinets('handleless_doors', 'wall')
  end

  def test_the_catalog_switches_on_every_option
    features = CatalogManager.catalogs.first['features']
    assert_equal CatalogManager::FEATURES.sort, features.sort
  end

  def test_cabinets_from_an_older_version_still_find_their_catalog
    assert_equal 'door_with_pull_handle', CatalogManager.catalog('sample_catalog')['id']
    refute_empty CatalogManager.cabinets('sample_catalog', 'base')
  end

  def test_the_catalog_lists_its_handle_bundles
    bundles = CatalogManager.catalogs.first['handle_bundles']
    assert_equal %w[sample_bar_handles sample_knobs], bundles.sort
    assert_equal bundles.sort, CatalogManager.handle_bundles.map { |b| b['id'] }.sort
  end

  def test_a_catalog_without_a_features_list_offers_everything
    assert_equal CatalogManager::FEATURES, CatalogManager.features_of({})
    assert_equal %w[base filler], CatalogManager.features_of('features' => %w[base filler nonsense])
  end

  def test_a_leftover_sample_catalog_never_shows_as_a_second_catalog
    store = {
      'sample_catalog' => { 'id' => 'sample_catalog', 'name' => 'Sample Catalog' },
      'door_with_pull_handle' => { 'id' => 'door_with_pull_handle', 'aliases' => ['sample_catalog'] }
    }
    CatalogManager.send(:drop_superseded, store)
    assert_equal ['door_with_pull_handle'], store.keys
  end

  def test_the_sample_catalog_file_is_not_shipped
    refute File.exist?(File.join(DATA_DIR_FOR_TEST, 'catalogs', 'sample_catalog.json'))
    assert_includes CatalogManager::LEGACY_FILES, 'catalogs/sample_catalog.json'
  end
end
