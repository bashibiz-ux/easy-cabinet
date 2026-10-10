require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/island_back_panel'

class IslandBackPanelTest < Minitest::Test
  P = KitchenCabinetMaster::IslandBackPanel

  def test_the_board_stands_against_the_back_of_the_units_the_length_of_the_island
    origin, size = P.box({ length: 1800.0, height: 880.0 })
    assert_equal [-18.0, 0.0, 0.0], origin
    assert_equal [18.0, 1800.0, 880.0], size
  end

  def test_an_unknown_height_is_the_usual_one
    assert_equal 860.0, P.box({ length: 1800.0 })[1][2]
  end
end