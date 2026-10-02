# frozen_string_literal: true

# The Show Cabinet Names tick travels with the cabinet's settings. Run:  ruby test/names_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
%w[response defaults attribute_manager cabinet_layout validation_manager].each { |f| require File.join(plugin, f) }

class NamesTest < Minitest::Test
  include KitchenCabinetMaster

  def raw(extra = {})
    { 'catalog_id' => 'c', 'cabinet_category' => 'base', 'cabinet_type' => 'b', 'width' => '600', 'depth' => '560', 'height' => '780',
      'toe_kick_height' => '100' }.merge(extra)
  end

  def test_the_names_start_hidden
    assert_equal false, Defaults.params['show_cabinet_names']
  end

  def test_the_tick_is_kept
    assert_equal true, ValidationManager.validate(raw('show_cabinet_names' => true), door_count: 1).params['show_cabinet_names']
    assert_equal false, ValidationManager.validate(raw('show_cabinet_names' => false), door_count: 1).params['show_cabinet_names']
  end
end