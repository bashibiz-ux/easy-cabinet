# frozen_string_literal: true

# The plan of a whole kitchen from a few answers (KitchenPlanner): pure maths.
# Run:  ruby test/kitchen_planner_test.rb

require 'json'
require 'minitest/autorun'

plugin = File.expand_path('../kitchen_cabinet_master', __dir__)
require File.join(plugin, 'kitchen_planner')

class KitchenPlannerTest < Minitest::Test
  include KitchenCabinetMaster

  CATALOG = JSON.parse(File.read(File.expand_path('../kitchen_cabinet_master/data/catalogs/kitchen_cabinets.json', __dir__)))
  IDS = CATALOG['categories'].to_h { |category, list| [category, list.map { |entry| entry['id'] }] }

  def plan(options = {})
    KitchenPlanner.plan(options)
  end

  def run_sum(items, run)
    items.select { |item| item.run == run }.sum(&:width).round(1)
  end

  def test_the_units_of_a_straight_kitchen_fill_the_wall_exactly
    [2700, 3000, 3300, 3600, 4200, 5100, 6000].each do |length|
      result = plan('wall_a' => length)
      assert_nil result.error, "#{length}: #{result.error}"
      assert_in_delta length, run_sum(result.base, :a), 0.5, "the base units of a #{length} mm wall"
      assert_equal [0.0] + result.base.each_cons(2).map { |a, b| (b.start - (a.start + a.width)).round(1) }.map { 0.0 }.uniq.first(0), [0.0]
      result.base.each_cons(2) { |a, b| assert_in_delta a.start + a.width, b.start, 0.5, 'each unit starts where the one before it ends' }
    end
  end

  def test_the_fridge_stands_at_the_start_and_the_sink_hob_and_hood_are_where_they_belong
    result = plan
    assert_equal :fridge, result.base.first.kind
    assert_equal 'tall', result.base.first.category
    kinds = result.base.map(&:kind)
    assert_operator kinds.index(:sink), :<, kinds.index(:hob)
    sink_at = kinds.index(:sink)
    hob_at = kinds.index(:hob)
    assert_operator hob_at - sink_at, :>=, 2, 'worktop between the sink and the hob'
    hob = result.base[hob_at]
    hood = result.wall.find { |item| item.kind == :hood }
    assert hood, 'a hood over the hob'
    assert_in_delta hob.start, hood.start, 0.01
    assert_in_delta hob.width, hood.width, 0.01
    refute_includes result.base.map(&:kind), :oven
  end

  def test_the_wall_units_fill_the_wall_between_the_tall_units_and_are_contiguous
    result = plan('wall_a' => 3600, 'oven_tower' => true)
    first = result.wall.first
    last = result.wall.last
    assert_in_delta 600.0, first.start, 0.01, 'after the fridge'
    assert_in_delta 3600.0 - 600.0, last.start + last.width, 0.5, 'before the oven housing'
    result.wall.each_cons(2) { |a, b| assert_in_delta a.start + a.width, b.start, 0.5 }
    assert_equal :oven, result.base.last.kind
  end

  def test_an_l_kitchen_has_a_corner_between_the_two_runs_and_both_walls_are_filled
    [[3600, 2800], [3200, 2400], [4200, 3000], [3000, 2000]].each do |a, b|
      result = plan('layout' => 'l', 'wall_a' => a, 'wall_b' => b)
      assert_nil result.error, "#{a} x #{b}: #{result.error}"
      assert_in_delta a, run_sum(result.base, :a), 0.5, "wall A #{a} (with the corner)"
      assert_in_delta b - 1000.0, run_sum(result.base, :b), 0.5, "wall B #{b} (less the corner)"
      corners = result.base.select { |item| item.kind == :corner }
      assert_equal 1, corners.length
      assert_equal 'base_corner_l', corners.first.type
      order = result.base.map(&:run)
      assert_equal order, order.sort_by { |run| run == :a ? 0 : 1 }, 'the units of A come before those of B'
      assert_equal :corner, result.base.select { |item| item.run == :a }.last.kind, 'the corner ends run A'
      wall_corner = result.wall.find { |item| item.kind == :corner }
      assert_equal 'wall_corner_l', wall_corner.type
      assert_in_delta a - 700.0, run_sum(result.wall.select { |item| item.run == :a && item.kind != :corner }, :a) + 600.0, 0.5, 'the wall units of A end at the wall corner'
    end
  end

  def test_the_hob_goes_on_wall_b_of_an_l_kitchen_when_there_is_room_and_the_hood_is_over_it
    result = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800)
    hob = result.base.find { |item| item.kind == :hob }
    assert_equal :b, hob.run
    hood = result.wall.find { |item| item.kind == :hood }
    assert_equal :b, hood.run
    assert_in_delta hob.start, hood.start, 0.01
    assert_equal :a, result.base.find { |item| item.kind == :sink }.run
  end

  def test_what_is_ticked_off_is_left_out
    result = plan('sink' => false, 'hob' => false, 'hood' => false, 'fridge' => 'none', 'wall_units' => false)
    assert_equal %i[fill], result.base.map(&:kind).uniq
    assert_empty result.wall
    result = plan('hood' => false)
    refute_includes result.wall.map(&:kind), :hood
  end

  def test_every_unit_is_in_the_kitchen_catalogs_and_the_widths_are_sensible
    configs = [{}, { 'layout' => 'l' }, { 'oven_tower' => true, 'fridge' => 'free' }, { 'wall_a' => 2100 }, { 'layout' => 'l', 'wall_a' => 2600, 'wall_b' => 1800 }]
    configs.each do |options|
      result = plan(options)
      next if result.error

      (result.base + result.wall).each do |item|
        assert_includes IDS[item.category], item.type, "#{item.type} is in the catalog"
        assert_operator item.width, :>=, 100.0
        assert_operator item.width, :<=, 1300.0
      end
      result.base.select { |item| item.kind == :fill }.each { |item| assert_operator item.width, :>=, 250.0 }
    end
  end

  def test_a_wall_that_is_too_short_says_so_and_a_hob_that_does_not_fit_is_left_out_with_a_note
    assert plan('wall_a' => 900).error
    assert plan('layout' => 'l', 'wall_a' => 3000, 'wall_b' => 1200).error
    result = plan('wall_a' => 1800)
    assert_nil result.error
    refute_includes result.base.map(&:kind), :hob
    assert(result.notes.any? { |note| note.include?('hob') })
    assert_in_delta 1800.0, run_sum(result.base, :a), 0.5
  end

  def test_the_answers_are_read_from_text_as_the_panel_sends_them
    options = KitchenPlanner.normalise('layout' => 'l', 'wall_a' => '3 600'.delete(' '), 'wall_b' => '2400', 'sink' => 'false', 'hob' => true, 'fridge' => 'none')
    assert_equal 'l', options['layout']
    assert_in_delta 3600.0, options['wall_a'], 0.001
    refute options['sink']
    assert options['hob']
    assert_equal 'none', options['fridge']
    assert_equal 'straight', KitchenPlanner.normalise('layout' => 'weird')['layout']
    assert_equal 'builtin', KitchenPlanner.normalise({})['fridge']
  end

  def test_the_description_names_what_was_planned
    text = KitchenPlanner.describe(plan)
    assert_includes text, 'hob'
    assert_includes text, 'sink'
    assert_includes text, 'hood'
    assert_equal 'oops', KitchenPlanner.describe(KitchenPlanner::Plan.new(error: 'oops', base: [], wall: []))
  end

  def test_a_u_kitchen_has_two_corners_and_the_three_walls_are_filled
    [[3000, 4200, 3000], [3300, 4800, 2700], [2700, 3600, 2700]].each do |a, b, c|
      result = plan('layout' => 'u', 'wall_a' => a, 'wall_b' => b, 'wall_c' => c)
      assert_nil result.error, "#{a} x #{b} x #{c}: #{result.error}"
      assert_equal 2, result.base.count { |item| item.kind == :corner }
      assert_in_delta a, run_sum(result.base, :a), 0.5
      assert_in_delta b - 1000.0, run_sum(result.base, :b), 0.5, 'wall B between its two corners'
      assert_in_delta c - 1000.0, run_sum(result.base, :c), 0.5
      assert_equal %i[a b c], result.base.map(&:run).uniq
      assert_equal 2, result.wall.count { |item| item.kind == :corner }
      assert_equal %i[a b c], result.wall.map(&:run).uniq
    end
  end

  def test_the_sink_is_in_the_middle_wall_of_a_u_and_the_hob_on_the_last_wall
    result = plan('layout' => 'u', 'wall_a' => 3000, 'wall_b' => 4200, 'wall_c' => 3000)
    assert_equal :b, result.base.find { |item| item.kind == :sink }.run
    assert_equal :c, result.base.find { |item| item.kind == :hob }.run
    assert_equal :c, result.wall.find { |item| item.kind == :hood }.run
  end

  def test_an_island_stands_parallel_to_wall_a_with_the_aisle_between
    result = plan('wall_a' => 4200, 'island' => true)
    island = result.island
    assert island
    assert_in_delta 4200.0, island.items.sum(&:width) + (4200.0 - island.length), 0.5
    assert_in_delta island.length, island.items.sum(&:width), 0.5
    assert_in_delta 580.0 + 1100.0 + 580.0, island.x, 0.01, 'its back is two unit depths and the aisle from wall A'
    assert_in_delta 2100.0 + (island.length / 2.0), island.y, 0.5, 'centred along the wall'
    assert(island.items.all? { |item| item.kind == :island && IDS['base'].include?(item.type) })
    assert_nil plan('wall_a' => 4200).island
  end

  def test_an_island_keeps_clear_of_the_other_walls_of_an_l_or_u
    l_shape = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 3000, 'island' => true, 'island_length' => 3000)
    assert_operator l_shape.island.y, :<=, 3600.0 - 580.0 - 1100.0 + 0.01, 'clear of the units of wall B'
    assert(l_shape.notes.any? { |note| note.include?('island') })
    narrow = plan('layout' => 'u', 'wall_a' => 3000, 'wall_b' => 3000, 'wall_c' => 3000, 'island' => true)
    assert_nil narrow.island, 'no room between the legs of a narrow U'
    assert(narrow.notes.any? { |note| note.include?('too narrow') })
    wide = plan('layout' => 'u', 'wall_a' => 3600, 'wall_b' => 5200, 'wall_c' => 3000, 'island' => true)
    assert wide.island
    assert_operator wide.island.x, :<=, 5200.0 - 580.0 - wide.island.aisle + 0.01, 'clear of the units of wall C'
  end

  def test_the_sink_goes_under_the_first_window_and_the_wall_units_skip_the_windows
    window = { 'wall' => 'a', 'from' => 1800, 'width' => 1200 }
    result = plan('wall_a' => 4200, 'windows' => [window])
    sink = result.base.find { |item| item.kind == :sink }
    assert_in_delta 2400.0, sink.start + (sink.width / 2.0), 160.0, 'under the window (the units beside it are whole units, so within a little)'
    result.wall.each do |item|
      assert(item.start + item.width <= 1800.0 + 0.5 || item.start >= 3000.0 - 0.5, "#{item.kind} at #{item.start} is over the window")
    end
    gap = result.wall.find { |item| item.gap_before.positive? }
    assert gap, 'a unit starts after the window'
    assert_in_delta 1200.0, gap.gap_before, 0.5
    assert_in_delta 3000.0, gap.start, 0.5
    assert_in_delta 4200.0, run_sum(result.base, :a), 0.5, 'the base units still fill the wall'
  end

  def test_a_hob_under_a_window_has_no_hood_and_windows_on_other_walls_are_read
    result = plan('wall_a' => 4200, 'windows' => [{ 'wall' => 'a', 'from' => 2400, 'width' => 1800 }])
    refute_includes result.wall.map(&:kind), :hood
    assert(result.notes.any? { |note| note.include?('window') })
    on_b = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 3000, 'windows' => [{ 'wall' => 'b', 'from' => 1500, 'width' => 1500 }])
    assert_equal :b, on_b.base.find { |item| item.kind == :sink }.run, 'the sink goes to the wall with the window'
    assert_empty KitchenPlanner.normalise('windows' => [{ 'wall' => 'z', 'from' => 100, 'width' => 900 }, { 'wall' => 'a', 'from' => 100, 'width' => 50 }])['windows']
    assert_equal 1, KitchenPlanner.normalise('windows' => [{ 'wall' => 'A', 'from' => '300', 'width' => '900' }])['windows'].length
  end

  def test_the_wall_units_next_to_a_corner_after_a_window_know_their_gap
    result = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 3000, 'windows' => [{ 'wall' => 'a', 'from' => 1500, 'width' => 1000 }])
    corner = result.wall.find { |item| item.kind == :corner }
    before = result.wall.select { |item| item.run == :a && item.kind != :corner }
    last_end = before.map { |item| item.start + item.width }.max
    assert_in_delta corner.start - last_end, corner.gap_before, 0.5
    result.wall.select { |item| item.run == :b }.each_cons(2) { |a, b| assert_in_delta a.start + a.width + b.gap_before, b.start, 0.5 }
  end

  def test_the_three_styles_change_the_wall_units_and_the_fronts_of_the_base_units
    classic = plan('layout' => 'l', 'wall_a' => 4200, 'wall_b' => 3000, 'style' => 'classic')
    glass = plan('layout' => 'l', 'wall_a' => 4200, 'wall_b' => 3000, 'style' => 'glass')
    lift = plan('layout' => 'l', 'wall_a' => 4200, 'wall_b' => 3000, 'style' => 'lift')
    assert_equal classic.base.map(&:type), glass.base.map(&:type), 'glass changes the wall units only'
    assert_equal classic.wall.map(&:width), glass.wall.map(&:width)
    glass.wall.select { |item| item.kind == :fill }.each { |item| assert_equal 'glass_wide_grid', item.extra['glass_design'] }
    assert(glass.wall.select { |item| %i[hood corner].include?(item.kind) }.all? { |item| item.extra.nil? })
    assert(classic.wall.all? { |item| item.extra.nil? })
    fills = lift.wall.select { |item| item.kind == :fill }
    assert(fills.all? { |item| item.type == 'wall_liftup_bifold' && item.width >= 600.0 && item.width <= 1200.0 })
    assert_operator lift.wall.length, :<, classic.wall.length, 'fewer, wider wall units'
    assert(lift.base.select { |item| item.kind == :fill }.all? { |item| item.type == 'base_3drawer' }, 'drawers below')
    [classic, glass, lift].each do |result|
      (result.base + result.wall).each { |item| assert_includes IDS[item.category], item.type }
      assert_in_delta 4200.0, run_sum(result.base, :a), 0.5
    end
    assert_equal 'classic', KitchenPlanner.normalise('style' => 'weird')['style']
    assert_equal 'lift', KitchenPlanner.normalise('style' => 'lift')['style']
    assert_includes KitchenPlanner.describe(lift), 'lift-up'
    assert_includes KitchenPlanner.describe(glass), 'glass doors'
  end

  def test_the_end_panels_are_for_the_open_ends_only
    assert_empty KitchenPlanner.end_panel_targets(plan('wall_a' => 3600)), 'a straight kitchen stands between two walls'
    island_only = KitchenPlanner.end_panel_targets(plan('wall_a' => 4200, 'island' => true))
    assert_equal [{ part: :island, index: 0, side: 'left' }, { part: :island, index: 2, side: 'right' }], island_only
    u_shape = plan('layout' => 'u', 'wall_a' => 3000, 'wall_b' => 4200, 'wall_c' => 3000)
    targets = KitchenPlanner.end_panel_targets(u_shape)
    assert_includes targets, { part: :base, index: 0, side: 'left' }
    assert_includes targets, { part: :base, index: u_shape.base.length - 1, side: 'right' }
    assert_includes targets, { part: :wall, index: u_shape.wall.length - 1, side: 'right' }
    refute_includes targets, { part: :wall, index: 0, side: 'left' }, 'the wall unit beside the fridge needs none'
    no_fridge = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'fridge' => 'none')
    assert_includes KitchenPlanner.end_panel_targets(no_fridge), { part: :wall, index: 0, side: 'left' }
    oven = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'oven_tower' => true)
    refute(KitchenPlanner.end_panel_targets(oven).any? { |t| t[:part] == :wall && t[:side] == 'right' }, 'the oven housing is at that end')
  end

  def test_a_dishwasher_space_goes_beside_the_sink_and_counts_as_worktop
    result = plan('wall_a' => 3600)
    kinds = result.base.map(&:kind)
    assert_equal kinds.index(:sink) + 1, kinds.index(:dish), 'right beside the sink'
    dish = result.base.find { |item| item.kind == :dish }
    assert_equal 'base_dishwasher', dish.type
    assert_equal 600.0, dish.width
    assert_in_delta 3600.0, run_sum(result.base, :a), 0.5
    assert_includes IDS['base'], dish.type
    assert_includes KitchenPlanner.describe(result), 'dishwasher space'
    assert_equal 0, plan('dishwasher' => false).base.count { |item| item.kind == :dish }
    assert_equal 0, plan('sink' => false).base.count { |item| item.kind == :dish }, 'no sink, no dishwasher'
    short = plan('wall_a' => 2200)
    assert_equal 1, short.base.count { |item| item.kind == :dish }, 'still there when the hob has to go'
    tight = plan('wall_a' => 1800)
    assert_equal 0, tight.base.count { |item| item.kind == :dish }
    assert(tight.notes.any? { |note| note.include?('dishwasher') })
    assert_in_delta 1800.0, run_sum(tight.base, :a), 0.5
  end

  def test_a_mirror_image_is_the_same_kitchen_built_from_the_other_end
    [{ 'wall_a' => 3600 }, { 'layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'oven_tower' => true }, { 'layout' => 'u', 'wall_a' => 3000, 'wall_b' => 4200, 'wall_c' => 2700 }].each do |options|
      regular = plan(options)
      mirror = plan(options.merge('mirror' => true))
      assert_nil mirror.error
      assert_equal regular.base.map(&:type).reverse, mirror.base.map(&:type), 'the units in the opposite order'
      assert_equal regular.base.map(&:width).reverse, mirror.base.map(&:width)
      assert_equal regular.wall.map(&:type).reverse, mirror.wall.map(&:type)
      assert_equal mirror.base.length, mirror.base.map(&:run).length
      mirror.base.group_by(&:run).each_value do |items|
        items.each_cons(2) { |a, b| assert_in_delta a.start + a.width, b.start, 0.5, 'each unit starts where the one before it ends' }
      end
      assert_equal %i[a b c].first(KitchenPlanner::RUNS[options['layout'] || 'straight'].length), mirror.base.map(&:run).uniq, 'walls named in the order they are met'
      hob = mirror.base.find { |item| item.kind == :hob }
      hood = mirror.wall.find { |item| item.kind == :hood }
      assert_equal hob.run, hood.run
      assert_in_delta hob.start, hood.start, 0.01, 'the hood is still over the hob'
      mirror.wall.each_cons(2) { |a, b| assert_in_delta a.start + a.width + (a.run == b.run ? b.gap_before : 0.0), b.start, 0.5 if a.run == b.run }
    end
  end

  def test_in_a_mirrored_l_the_fridge_ends_the_row_the_oven_starts_it_and_the_first_wall_is_the_old_second
    mirror = plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800, 'oven_tower' => true, 'mirror' => true)
    assert_equal :oven, mirror.base.first.kind
    assert_equal :fridge, mirror.base.last.kind
    assert_in_delta 2800.0, mirror.base.select { |item| item.run == :a }.sum(&:width), 0.5, 'the first wall is the old wall B (with the corner)'
    assert_in_delta 3600.0 - 1000.0, mirror.base.select { |item| item.run == :b }.sum(&:width), 0.5
    assert_equal :corner, mirror.base.select { |item| item.run == :a }.last.kind
    assert_in_delta 600.0, mirror.wall_start, 0.01, 'the wall units start after the oven housing'
    assert_in_delta 2800.0, mirror.first_length, 0.01
    assert_in_delta 3600.0, plan('layout' => 'l', 'wall_a' => 3600, 'wall_b' => 2800).first_length, 0.01
    straight = plan('wall_a' => 3600, 'mirror' => true)
    assert_equal :fridge, straight.base.last.kind
  end

  def test_windows_keep_their_walls_in_a_mirror_image_and_the_gap_is_counted_from_the_other_end
    options = { 'layout' => 'l', 'wall_a' => 3600, 'wall_b' => 3000, 'windows' => [{ 'wall' => 'a', 'from' => 1500, 'width' => 1000 }] }
    regular = plan(options)
    mirror = plan(options.merge('mirror' => true))
    on_a = mirror.wall.select { |item| item.run == :b && item.kind != :corner } # wall A is the second wall now
    over_window = on_a.select { |item| item.start < 3600.0 - 1500.0 && item.start + item.width > 3600.0 - 2500.0 }
    assert_empty over_window, 'nothing over the window'
    assert_in_delta 1000.0, on_a.map(&:gap_before).max, 0.5
    sink_regular = regular.base.find { |item| item.kind == :sink }
    sink_mirror = mirror.base.find { |item| item.kind == :sink }
    assert_in_delta sink_regular.start + (sink_regular.width / 2.0), 3600.0 - (sink_mirror.start + (sink_mirror.width / 2.0)), 0.5, 'the sink is under the same window'
  end

  def test_an_island_in_a_mirrored_kitchen_is_planned_on_its_new_first_wall
    regular = plan('layout' => 'l', 'wall_a' => 4200, 'wall_b' => 3000, 'island' => true)
    mirror = plan('layout' => 'l', 'wall_a' => 4200, 'wall_b' => 3000, 'island' => true, 'mirror' => true)
    assert_operator regular.island.y, :<=, 4200.0 - 580.0 - 1100.0 + 0.01
    assert_operator mirror.island.y, :<=, 3000.0 - 580.0 - 1100.0 + 0.01, 'clear of the units of the other wall'
  end

  def test_an_island_can_have_a_seating_overhang
    island = plan('wall_a' => 4200, 'island' => true, 'island_seating' => 300).island
    assert_equal 300.0, island.seating
    assert_includes KitchenPlanner.describe(plan('wall_a' => 4200, 'island' => true, 'island_seating' => 300)), '300 mm seating overhang'
    assert_equal 0.0, plan('wall_a' => 4200, 'island' => true).island.seating
    assert_equal 450.0, plan('wall_a' => 4200, 'island' => true, 'island_seating' => 900).island.seating
    assert_equal 0.0, plan('wall_a' => 4200, 'island' => true, 'island_seating' => -5).island.seating
  end
  def test_an_island_hob_gets_a_hood_from_the_ceiling_unless_the_hood_is_off
    island = plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob').island
    hob = island.items.find { |item| item.kind == :hob }
    assert_equal({ start: hob.start, width: hob.width, top: 2400.0 }, island.hood)
    assert_includes KitchenPlanner.describe(plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob')), 'ceiling hood'
    assert_equal 2700.0, plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob', 'ceiling' => 2700).island.hood[:top]
    assert_nil plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob', 'hood' => false).island.hood
    assert_nil plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'sink').island.hood
    assert_nil plan('wall_a' => 4200, 'island' => true).island.hood
  end
  def test_an_island_can_have_the_hob_or_the_sink_which_then_leave_the_wall
    hob = plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'hob')
    assert_equal [:hob], hob.island.items.map(&:kind).select { |kind| kind == :hob }
    assert_equal 'base_hob', hob.island.items.find { |item| item.kind == :hob }.type
    refute_includes hob.base.map(&:kind), :hob, 'the wall has no hob any more'
    refute_includes hob.wall.map(&:kind), :hood, 'so no hood'
    assert_includes hob.base.map(&:kind), :sink
    assert_in_delta hob.island.length, hob.island.items.sum(&:width), 0.5
    assert(hob.island.items.reject { |item| item.kind == :hob }.all? { |item| item.type == 'base_3drawer' }, 'drawers beside it')
    assert_includes KitchenPlanner.describe(hob), 'on the island'
    sink = plan('wall_a' => 4200, 'island' => true, 'island_feature' => 'sink')
    assert_equal 'base_sink', sink.island.items.find { |item| item.kind == :sink }.type
    assert_includes sink.island.items.map(&:kind), :dish, 'with its dishwasher space'
    refute_includes sink.base.map(&:kind), :sink
    refute_includes sink.base.map(&:kind), :dish
    assert_includes sink.base.map(&:kind), :hob
    assert_operator sink.island.length, :>=, 2100.0, 'long enough for the sink, the dishwasher space and a unit beside them'
    assert_in_delta sink.island.length, sink.island.items.sum(&:width), 0.5
    assert(sink.island.items.all? { |item| IDS['base'].include?(item.type) })
    assert_equal 'none', KitchenPlanner.normalise('island_feature' => 'oven')['island_feature']
    assert_nil plan('wall_a' => 4200, 'island_feature' => 'hob').island, 'no island, no feature: the hob stays on the wall'
    assert_includes plan('wall_a' => 4200, 'island_feature' => 'hob').base.map(&:kind), :hob
  end

  def test_an_island_too_short_for_its_hob_or_sink_is_plain_and_the_wall_keeps_them
    cramped = plan('layout' => 'l', 'wall_a' => 3000, 'wall_b' => 3000, 'island' => true, 'island_feature' => 'sink')
    assert(cramped.notes.any? { |note| note.include?('too short for its sink') })
    assert_includes cramped.base.map(&:kind), :sink, 'the sink stays on the wall'
    assert(cramped.island.items.all? { |item| item.kind == :island })
    assert_in_delta 3000.0, cramped.base.select { |item| item.run == :a }.sum(&:width), 0.5
  end
end
