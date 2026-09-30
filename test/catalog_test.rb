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

  def test_there_is_one_catalog_named_door_with_pull_handle
    catalogs = CatalogManager.catalogs
    assert_equal ['Door with pull handle'], catalogs.map { |c| c['name'] }
    assert_empty CatalogManager.warnings
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
end