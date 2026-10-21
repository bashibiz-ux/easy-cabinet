# frozen_string_literal: true

# The outer face (the rounded edges, the front design) of the panel across the end of a tall L corner's arm. Run:  ruby test/arm_panel_face_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager gola_profile cabinet_layout front_design appliance_parts fixtures front_design toe_kick part_layout].each do |file|
  path = File.join(plugin, "#{file}.rb")
  require path if File.exist?(path)
end

class ArmPanelFaceTest < Minitest::Test
  include EasyCabinet

  def params(side)
    { 'depth' => 580.0, 'thickness' => 18.0, 'height' => 1400.0, 'target_base_z' => 880.0, 'side' => side, 'face' => 'flat', 'front_radius' => 3.0 }
  end

  def test_a_panel_across_an_arm_end_has_its_rounded_outer_edges_on_the_low_y_side_like_a_left_panel
    assert_equal PartLayout.end_panel(params('left')).board.shape, PartLayout.end_panel(params('front')).board.shape
    refute_equal PartLayout.end_panel(params('right')).board.shape, PartLayout.end_panel(params('front')).board.shape
    assert_equal 3.0, PartLayout.end_panel(params('front')).board.round
  end
end
