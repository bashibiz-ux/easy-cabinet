# frozen_string_literal: true

# Your own appliances: how a model is turned and scaled into the space of the drawn appliance, and what is kept. Run:  ruby test/my_appliances_test.rb

require 'json'
require 'tmpdir'
require 'minitest/autorun'

module EasyCabinet
  DATA_DIR = 'unused'
  # (only what MyAppliances asks of the catalog manager)
  module CatalogManager
    class << self
      attr_accessor :folder
      def user_dir = folder
    end
  end
  module Response
    def self.ok(message = '', data = {}) = { 'ok' => true, 'message' => message, 'data' => data }
    def self.fail(message, errors = []) = { 'ok' => false, 'message' => message, 'errors' => errors }
  end
end
require_relative '../easy_cabinet/my_appliances'

class MyAppliancesTest < Minitest::Test
  include EasyCabinet
  Part = Struct.new(:role, :offset, :extent)

  # Where a point of the model (mm, as drawn) ends up: the same steps as the transformation CabinetGenerator builds.
  def place(point, low, fit)
    x = point[0] - low[0]
    y = point[1] - low[1]
    z = point[2] - low[2]
    radians = fit[:turn] * Math::PI / 180.0
    x, y = [(x * Math.cos(radians)) - (y * Math.sin(radians)), (x * Math.sin(radians)) + (y * Math.cos(radians))]
    x += fit[:shift][0]
    y += fit[:shift][1]
    [(x * fit[:scale][0]) + fit[:origin][0], (y * fit[:scale][1]) + fit[:origin][1], (z * fit[:scale][2]) + fit[:origin][2]]
  end

  def corners(size) = [0.0, size[0]].product([0.0, size[1]], [0.0, size[2]])

  def test_a_model_drawn_with_its_front_to_the_front_view_fills_the_box_with_its_front_out_of_the_cabinet
    size = [600.0, 800.0, 900.0] # (x, y, z as drawn: 800 wide across the front view's -Y side)
    box_low = [20.0, 100.0, 50.0]
    box_size = [560.0, 760.0, 880.0] # (depth, width, height of the drawn appliance)
    fit = MyAppliances.fit(size, '-y', box_low, box_size)
    placed = corners(size).map { |c| place(c, [0.0, 0.0, 0.0], fit) }
    3.times do |i|
      assert_in_delta box_low[i], placed.map { |p| p[i] }.min, 0.01, "low #{i}"
      assert_in_delta box_low[i] + box_size[i], placed.map { |p| p[i] }.max, 0.01, "high #{i}"
    end
    # the model's front (its y = 0 face) is the one that now looks out: the highest X
    front = [0.0, 600.0].product([0.0], [0.0, 900.0]).map { |c| place(c, [0.0, 0.0, 0.0], fit)[0] }
    assert_in_delta box_low[0] + box_size[0], front.min, 0.01
  end

  def test_every_front_fills_the_box
    size = [500.0, 700.0, 300.0]
    MyAppliances::FRONT_TURNS.each_key do |front|
      fit = MyAppliances.fit(size, front, [0.0, 0.0, 0.0], [400.0, 600.0, 250.0])
      placed = corners(size).map { |c| place(c, [0.0, 0.0, 0.0], fit) }
      assert_equal [0.0, 0.0, 0.0], [0, 1, 2].map { |i| placed.map { |p| p[i] }.min.round(6).abs }, front
      assert_in_delta 400.0, placed.map { |p| p[0] }.max, 0.01, front
      assert_in_delta 600.0, placed.map { |p| p[1] }.max, 0.01, front
      assert_in_delta 250.0, placed.map { |p| p[2] }.max, 0.01, front
    end
  end

  def test_the_parts_of_an_appliance_are_found_by_their_roles
    assert_equal 'oven', MyAppliances.kind_of('appliance_oven_1_door')
    assert_equal 'micro', MyAppliances.kind_of('appliance_micro_1_body')
    assert_equal 'fridge', MyAppliances.kind_of('appliance_fridge_1_free_body')
    assert_nil MyAppliances.kind_of('carcass')
    assert_nil MyAppliances.kind_of('appliance_toaster_1_body')
    assert_equal 'appliance_oven_2', MyAppliances.group_of('appliance_oven_2_knob_1')
    assert_nil MyAppliances.group_of('door_1')
  end

  def test_the_box_of_a_group_of_parts
    parts = [Part.new('a', [10.0, 20.0, 30.0], [100.0, 50.0, 10.0]), Part.new('b', [0.0, 40.0, 25.0], [20.0, 100.0, 40.0])]
    low, size = MyAppliances.box_of(parts)
    assert_equal [0.0, 20.0, 25.0], low
    assert_equal [110.0, 120.0, 40.0], size
  end

  def test_what_is_kept_is_listed_and_read_again
    Dir.mktmpdir do |dir|
      CatalogManager.folder = dir
      assert_equal({}, MyAppliances.meta)
      MyAppliances.save_meta('oven' => { 'file' => 'models/appliance_oven.skp', 'front' => '+x', 'name' => 'My oven' }, 'toaster' => { 'file' => 'x' })
      assert_equal %w[oven], MyAppliances.meta.keys
      listed = MyAppliances.list
      assert_equal MyAppliances::KINDS.keys, listed.map { |entry| entry['id'] }
      assert_equal [true] + [false] * 5, listed.map { |entry| entry['custom'] }
      assert_equal '+x', listed.first['front']
    end
  ensure
    CatalogManager.folder = nil
  end

  def test_nothing_is_kept_without_a_folder
    CatalogManager.folder = nil
    assert_equal({}, MyAppliances.meta)
    assert_equal 'There is no folder of your own to keep the model in.', MyAppliances.add('kind' => 'oven')['message']
  end
end
