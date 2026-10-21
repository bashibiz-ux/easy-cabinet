# frozen_string_literal: true

# Which units get which side panels: the tall L corner unit has panels on the ends of its two arms. Run:  ruby test/arm_corner_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response defaults attribute_manager cabinet_layout toe_kick part_manager].each do |file|
  path = File.join(plugin, "#{file}.rb")
  begin
    require path
  rescue StandardError, LoadError => e
    warn "(#{file} not loaded: #{e.message})"
  end
end

class ArmCornerTest < Minitest::Test
  include EasyCabinet

  def params(category, style = 'l_shape')
    Defaults.params.merge('cabinet_category' => category, 'corner_style' => style, 'width' => 1000.0, 'depth' => 560.0, 'height' => 2160.0)
  end

  def test_only_a_tall_l_corner_has_arm_ends
    assert PartManager.send(:arm_corner?, params('tall'))
    refute PartManager.send(:arm_corner?, params('base')), 'the base L corner has no side panels of its own'
    refute PartManager.send(:arm_corner?, params('wall'))
    refute PartManager.send(:arm_corner?, params('tall', 'blind'))
    refute PartManager.send(:arm_corner?, params('tall', ''))
  end

  def test_the_sides_that_can_have_a_panel
    assert_equal %w[left right front], PartManager.send(:panel_sides, params('tall'))
    assert_equal %w[left right], PartManager.send(:panel_sides, params('base'))
    assert_equal %w[left right], PartManager.send(:panel_sides, params('tall', ''))
  end
end
