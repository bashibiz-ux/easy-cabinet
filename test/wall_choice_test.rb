# frozen_string_literal: true

# Runs the plugin's REAL KitchenPlanner: the wall the sink and the hob go on.
# Run:  ruby test/wall_choice_test.rb

require 'minitest/autorun'

module KitchenCabinetMaster
  DATA_DIR = File.expand_path('../kitchen_cabinet_master/data', __dir__)
end
%w[response defaults catalog_manager island_hood kitchen_planner].each { |file| require_relative "../kitchen_cabinet_master/#{file}" }

class WallChoiceTest < Minitest::Test
  include KitchenCabinetMaster

  U = { 'layout' => 'u', 'wall_a' => 4200.0, 'wall_b' => 5200.0, 'wall_c' => 5200.0, 'wall_units' => true }.freeze

  def run_of(plan, kind)
    plan.base.find { |item| item.kind == kind }&.run
  end

  def test_the_sink_and_the_hob_go_where_they_are_asked
    %i[a b c].each do |sink|
      %i[a b c].each do |hob|
        plan = KitchenPlanner.plan(U.merge('sink_wall' => sink.to_s, 'hob_wall' => hob.to_s))
        assert_nil plan.error
        assert_equal sink, run_of(plan, :sink), "sink asked for #{sink}"
        assert_equal hob, run_of(plan, :hob), "hob asked for #{hob}"
      end
    end
  end

  def test_automatic_is_what_it_was
    plan = KitchenPlanner.plan(U)
    assert_equal run_of(KitchenPlanner.plan(U.merge('sink_wall' => '', 'hob_wall' => '')), :sink), run_of(plan, :sink)
  end

  def test_a_wall_the_layout_does_not_have_is_told_and_the_unit_goes_where_it_fits
    plan = KitchenPlanner.plan('layout' => 'straight', 'wall_a' => 4200.0, 'sink_wall' => 'c')
    assert_equal :a, run_of(plan, :sink)
    assert plan.notes.any? { |note| note.include?('no wall C') }
  end

  def test_a_wall_too_short_is_told
    plan = KitchenPlanner.plan(U.merge('wall_b' => 2500.0, 'sink_wall' => 'b'))
    assert plan.notes.any? { |note| note.include?('too short for the sink') }, plan.notes.inspect
  end
end
