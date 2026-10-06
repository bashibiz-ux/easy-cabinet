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

  def test_the_models_are_kitchen_cabinet_with_handle_and_with_gola_handle
    catalogs = CatalogManager.catalogs
    assert_equal ['Kitchen Cabinet - with handle', 'Kitchen Cabinet - Gola handle'], catalogs.map { |c| c['name'] }
    assert_empty CatalogManager.warnings
  end

  def test_the_gola_model_has_no_handle_and_the_other_has_the_handle_bundles
    gola = CatalogManager.catalogs.find { |c| c['name'] == 'Kitchen Cabinet - Gola handle' }
    refute_includes gola['features'], 'handle'
    assert_equal [], gola['handle_bundles']
    assert CatalogManager.catalog(gola['id'])['gola'], 'it makes the Gola profile'
    refute CatalogManager.catalog('kitchen_cabinets')['gola']
    %w[base wall tall].each { |category| assert_equal CatalogManager.cabinets('kitchen_cabinets', category).map { |c| c['id'] }, CatalogManager.cabinets(gola['id'], category).map { |c| c['id'] }, category }
  end

  def test_the_catalog_switches_on_every_option_but_corner
    features = CatalogManager.catalogs.first['features']
    assert_equal (CatalogManager::FEATURES - ['corner']).sort, features.sort
  end

  def test_cabinets_from_an_older_version_still_find_their_catalog
    %w[door_with_pull_handle drawer_units handleless_doors].each { |old| assert_equal 'kitchen_cabinets', CatalogManager.catalog(old)['id'], old }
    refute_empty CatalogManager.cabinets('door_with_pull_handle', 'base')
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
      'kitchen_cabinets' => { 'id' => 'kitchen_cabinets', 'aliases' => ['sample_catalog'] }
    }
    CatalogManager.send(:drop_superseded, store)
    assert_equal ['kitchen_cabinets'], store.keys
  end

  def test_the_sample_catalog_file_is_not_shipped
    refute File.exist?(File.join(DATA_DIR_FOR_TEST, 'catalogs', 'sample_catalog.json'))
    assert_includes CatalogManager::LEGACY_FILES, 'catalogs/sample_catalog.json'
  end

  def test_the_other_models_are_not_shipped_and_are_cleared_away_from_an_older_install
    %w[door_with_pull_handle drawer_units handleless_doors].each do |id|
      refute File.exist?(File.join(DATA_DIR_FOR_TEST, 'catalogs', "#{id}.json")), id
      assert_includes CatalogManager::LEGACY_FILES, "catalogs/#{id}.json"
    end
    assert_equal %w[kitchen_cabinets.json kitchen_cabinets_gola.json], Dir.children(File.join(DATA_DIR_FOR_TEST, 'catalogs')).sort
  end
end
