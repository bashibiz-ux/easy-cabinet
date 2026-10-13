# frozen_string_literal: true

# A cabinet's component definition is named with the cabinet's own number. Run:  ruby test/definition_name_test.rb

require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
require_relative '../kitchen_cabinet_master/defaults'
require_relative '../kitchen_cabinet_master/naming_manager'

class DefinitionNameTest < Minitest::Test
  include KitchenCabinetMaster

  def test_the_definition_is_named_with_the_cabinet_number
    assert_equal 'BU600 - 113', NamingManager.definition_name('BU600', 'CABINET_0113')
    assert_equal 'WU800 - 1', NamingManager.definition_name('WU800', 'CABINET_0001')
  end

  def test_without_a_number_it_is_just_the_name
    assert_equal 'BU600', NamingManager.definition_name('BU600', nil)
    assert_equal 'BU600', NamingManager.definition_name('BU600', '')
  end
end
