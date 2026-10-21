# frozen_string_literal: true

# What was made under the old name of the extension (Kitchen Cabinet Master) is brought over to the new one. Run:  ruby test/legacy_names_test.rb

require 'minitest/autorun'
require 'tmpdir'
require 'json'

module EasyCabinet
  DATA_DIR = File.expand_path('../easy_cabinet/data', __dir__)
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults catalog_manager legacy_names].each { |f| require File.join(plugin, f) }

class LegacyNamesTest < Minitest::Test
  include EasyCabinet

  def test_the_folder_of_your_own_data_is_renamed_to_the_new_name
    Dir.mktmpdir do |plugins|
      target = File.join(plugins, "user", "EasyCabinet")
      FileUtils.mkdir_p(File.join(plugins, LegacyNames::OLD_DATA_DIR, 'catalogs'))
      File.write(File.join(plugins, LegacyNames::OLD_DATA_DIR, 'catalogs', 'mine.json'), '{}')
      LegacyNames.move_user_dir(plugins, target)
      refute File.exist?(File.join(plugins, LegacyNames::OLD_DATA_DIR)), 'the old one is gone'
      assert File.exist?(File.join(target, 'catalogs', 'mine.json')), 'its files are in your user folder'
    end
  end

  def test_a_folder_that_is_already_there_under_the_new_name_is_left_alone
    Dir.mktmpdir do |plugins|
      target = File.join(plugins, "user", "EasyCabinet")
      FileUtils.mkdir_p(File.join(plugins, LegacyNames::OLD_DATA_DIR))
      FileUtils.mkdir_p(target)
      File.write(File.join(target, 'keep.txt'), 'x')
      LegacyNames.move_user_dir(plugins, target)
      assert File.exist?(File.join(plugins, LegacyNames::OLD_DATA_DIR)), 'nothing is overwritten'
      assert File.exist?(File.join(target, 'keep.txt'))
    end
  end

  def test_the_names_are_the_new_ones_everywhere
    assert_equal 'EasyCabinet', AttributeManager::DICTIONARY if defined?(AttributeManager::DICTIONARY)
    assert_equal 'EasyCabinet_Data', CatalogManager::USER_DIR_NAME
    assert_equal({ 'kcm_dimension' => 'ec_dimension' }, LegacyNames::KEY_RENAMES)
    sources = Dir[File.join(__dir__, '..', 'easy_cabinet', '**', '*.{rb,js,html,css}')].reject { |path| path.end_with?('legacy_names.rb') || path.include?('/lang/') }
    old = sources.select { |path| File.read(path, encoding: 'UTF-8').match?(/Kitchen Cabinet Master|KitchenCabinetMaster|kitchen_cabinet_master/) }
    assert_empty old, 'no file but the one that brings the old names over has an old name in it'
  end
end
