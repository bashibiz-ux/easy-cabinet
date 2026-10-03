# frozen_string_literal: true

# The starting colours: light grey carcass, light beige doors (as in the L-corner builder script). Run:  ruby test/default_colours_test.rb

require 'minitest/autorun'
require 'json'

module KitchenCabinetMaster
  DATA_DIR = 'unused'
end
require File.expand_path('../kitchen_cabinet_master/defaults', __dir__)

class DefaultColoursTest < Minitest::Test
  include KitchenCabinetMaster

  PRESETS = JSON.parse(File.read(File.expand_path('../kitchen_cabinet_master/data/materials.json', __dir__), encoding: 'UTF-8'))['materials']

  def colour(name) = PRESETS.find { |m| m['name'] == name }&.fetch('color')

  def test_the_doors_start_light_beige_and_the_carcass_light_grey
    params = Defaults.params
    assert_equal ['Shutter - Light Beige'] * 3, params.values_at('base_material', 'wall_material', 'tall_material')
    assert_equal 'Carcass - Light Gray', params['carcass_material']
  end

  def test_the_colours_are_the_script_s_rgb_values
    assert_equal [230, 220, 200], colour('Shutter - Light Beige').delete('#').scan(/../).map(&:hex)
    assert_equal [211, 211, 211], colour('Carcass - Light Gray').delete('#').scan(/../).map(&:hex)
  end

  def test_both_can_be_chosen_for_panels_and_toe_kicks
    %w[Shutter\ -\ Light\ Beige Carcass\ -\ Light\ Gray].each do |name|
      assert_equal %w[panel toe_kick], PRESETS.find { |m| m['name'] == name }['kinds'].sort
    end
  end
end