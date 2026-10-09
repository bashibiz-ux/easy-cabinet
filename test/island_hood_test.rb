require 'minitest/autorun'
require_relative '../kitchen_cabinet_master/island_hood'

class IslandHoodTest < Minitest::Test
  def test_a_canopy_over_the_hob_and_a_chimney_up_to_the_ceiling
    canopy, chimney = KitchenCabinetMaster::IslandHood.boxes({ start: 600.0, width: 600.0, top: 2400.0 })
    assert_equal 900.0, canopy[2][1], 'the canopy is at least 900 wide'
    assert_in_delta 900.0, canopy[1][1] + (canopy[2][1] / 2.0), 0.01, 'centred over the hob'
    assert_equal 1650.0, canopy[1][2]
    assert_in_delta 2400.0, chimney[1][2] + chimney[2][2], 0.01, 'the chimney reaches the ceiling'
    assert_equal 1800.0, chimney[1][2]
  end

  def test_a_wide_hob_gets_a_wider_canopy_and_a_low_ceiling_no_chimney
    boxes = KitchenCabinetMaster::IslandHood.boxes({ start: 0.0, width: 900.0, top: 1700.0 })
    assert_equal 1200.0, boxes.first[2][1]
    assert_equal 1, boxes.length
  end
end