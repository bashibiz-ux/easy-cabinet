# frozen_string_literal: true

module KitchenCabinetMaster
  # Plans a whole kitchen from a few answers (the walls' lengths, which appliances it has, the windows, an island). Pure maths: no SketchUp
  # objects.
  #
  # A kitchen is one to three RUNS of units along walls. A straight kitchen has run A; an L kitchen has run A, a corner unit and run B; a U
  # kitchen has A, a corner, B, a corner and C (a corner turns the row a quarter turn, as when the units are inserted one after another by hand).
  # Every position is measured along its wall from the start of the run: run A from its free end, run B from wall A, run C from wall B.
  #
  # The plan lists the base units (floor level, in the order they are placed), the wall units (over them) and an island (units of its own).
  # Every unit is {category, type (a catalog id of the kitchen catalogs), width, kind}; the widths of a wall add up to its length.
  module KitchenPlanner
    Item = Struct.new(:category, :type, :width, :kind, :run, :start, :gap_before, :extra, keyword_init: true) # extra: values this unit has of its own (a glass door)
    Plan = Struct.new(:base, :wall, :wall_start, :notes, :error, :island, :style, :layout, :first_length, :open_ends, :run_ends, :turn, keyword_init: true) # first_length: how long the first wall is (what the next kitchen is put beyond)
    Island = Struct.new(:items, :x, :y, :length, :aisle, :hood, :seating, :back_panel, :side_panels, :wall, :frame, keyword_init: true) # x: from its wall to the island's back, y: along that wall to its high end; frame: [along, across, degrees] of that wall's own frame from wall A's
    class Short < StandardError; end
    ADJACENT = 'The sink and the hob are next to each other: there is no worktop between them.'

    CORNER_BASE = 1000.0 # a corner base unit (L shape) covers this much of each wall
    CORNER_WALL = 700.0  # and the corner wall unit this much
    IDEAL = 600.0        # the width the filling units like to be
    MIN_FILL = 300.0
    MAX_FILL = 900.0
    MIN_UNIT = 100.0
    FRONT_DEPTH = 580.0  # a base unit with its doors, front to back
    FRIDGE = { 'builtin' => ['tall_fridge_builtin_2door', 600.0], 'free' => ['tall_fridge_housing_free', 900.0] }.freeze
    OVEN = ['tall_oven', 600.0].freeze
    SINK_WIDTH = 900.0
    SINK_WIDTH_TWO = 1200.0 # a sink with two bowls (and a drainer)
    SINK_WIDTH_PLAIN = 600.0 # one bowl and no drainer
    SINK_WIDTH_TWO_PLAIN = 900.0 # two bowls and no drainer
    HOB_WIDTH = 600.0
    DISH_WIDTH = 600.0 # the space for a dishwasher, beside the sink
    # How the kitchen looks: doors everywhere; glass doors on the wall units; or wide lift-up wall units over drawers.
    STYLES = %w[classic glass lift].freeze
    MAX_SEATING = 450.0 # the most an island's worktop can reach beyond its back for stools
    ISLAND_FEATURES = %w[none hob sink].freeze # what an island has built in
    RUNS = { 'straight' => [:a], 'l' => %i[a b], 'u' => %i[a b c] }.freeze

    # The tall units a variation is made of: [catalog id, width, kind].
    TALL = {
      storage: ['tall_2door', 900.0, :storage], storage_narrow: ['tall_1door', 600.0, :storage], drawers: ['tall_4drawer', 600.0, :storage],
      pantry: ['tall_pullout', 300.0, :storage], glass: ['tall_glass_2door', 900.0, :storage],
      fridge_free: ['tall_fridge_housing_free', 900.0, :fridge], fridge: ['tall_fridge_builtin_2door', 600.0, :fridge],
      freezer: ['tall_fridge_builtin_1door', 600.0, :freezer], oven: ['tall_oven', 600.0, :oven]
    }.freeze

    # Ways to arrange the tall units of a kitchen: `start` stand at the start of wall A, `end` at the end of the last wall. `fill` is how the floor
    # units between them are made (classic: doors with a drawer unit now and then; drawers; doors; alternate: drawer, door, drawer ...; drawer_door:
    # a drawer over doors), `wall` how the wall units are: classic doors; open (every third one an open shelf); lift (normal lift-up doors); lift_fold
# (lift-up by fold, bi-fold); lift_glass (glass bi-fold lift-ups); lift_mix (bi-fold, glass bi-fold and normal lift-ups in turn); door_lift and
# glass_door_lift (a door, a lift-up by fold, a door ...; the second with glass doors).
    VARIATIONS = [
      { id: 'v01', name: '1 - Storage tall, freestanding fridge, oven tall', start: %i[storage fridge_free oven], end: [], fill: 'classic', wall: 'classic' },
      { id: 'v02', name: '2 - Built-in fridge, built-in freezer, oven tall', start: %i[fridge freezer oven], end: [], fill: 'classic', wall: 'classic' },
      { id: 'v03', name: '3 - Built-in fridge and freezer, oven tall at the far end', start: %i[fridge freezer], end: %i[oven], fill: 'classic', wall: 'door_lift' },
      { id: 'v04', name: '4 - Storage tall, built-in fridge | oven tall (drawers)', start: %i[storage fridge], end: %i[oven], fill: 'drawers', wall: 'lift' },
      { id: 'v05', name: '5 - Freestanding fridge | storage tall, oven tall', start: %i[fridge_free], end: %i[storage oven], fill: 'classic', wall: 'classic' },
      { id: 'v06', name: '6 - Oven tall, storage tall | built-in fridge (doors)', start: %i[oven storage], end: %i[fridge], fill: 'doors', wall: 'lift_glass' },
      { id: 'v07', name: '7 - Storage tall | freestanding fridge (drawers and doors)', start: %i[storage], end: %i[fridge_free], fill: 'alternate', wall: 'lift_mix' },
      { id: 'v08', name: '8 - Freezer, fridge | storage tall (open wall shelves)', start: %i[freezer fridge], end: %i[storage], fill: 'classic', wall: 'open' },
      { id: 'v09', name: '9 - Oven tall | built-in fridge and freezer (drawer over doors)', start: %i[oven], end: %i[fridge freezer], fill: 'drawer_door', wall: 'lift_fold' },
      { id: 'v10', name: '10 - Pantry pull-out, built-in fridge | oven tall', start: %i[pantry fridge], end: %i[oven], fill: 'classic', wall: 'classic' },
      { id: 'v11', name: '11 - Tall drawers, freestanding fridge | oven tall (drawers)', start: %i[drawers fridge_free], end: %i[oven], fill: 'drawers', wall: 'glass_door_lift' },
      { id: 'v12', name: '12 - Two storage talls | freestanding fridge', start: %i[storage storage_narrow], end: %i[fridge_free], fill: 'classic', wall: 'classic' },
      { id: 'v13', name: '13 - Built-in fridge | glass display tall, oven tall', start: %i[fridge], end: %i[glass oven], fill: 'alternate', wall: 'glass_door_lift' },
      { id: 'v14', name: '14 - Freestanding fridge, oven tall | storage tall (doors)', start: %i[fridge_free oven], end: %i[storage], fill: 'doors', wall: 'lift' },
      { id: 'v15', name: '15 - Narrow storage, built-in fridge | oven tall (open wall shelves)', start: %i[storage_narrow fridge], end: %i[oven], fill: 'alternate', wall: 'open' },
      { id: 'v16', name: '16 - Built-in fridge | oven tall (drawer over doors)', start: %i[fridge], end: %i[oven], fill: 'drawer_door', wall: 'lift_fold' },
      { id: 'v17', name: '17 - Freezer, built-in fridge (drawers, open wall shelves)', start: %i[freezer fridge], end: [], fill: 'drawers', wall: 'open' },
      { id: 'v18', name: '18 - Storage tall, oven tall', start: %i[storage oven], end: [], fill: 'classic', wall: 'door_lift' },
      { id: 'v19', name: '19 - Oven tall, built-in fridge (drawers and doors)', start: %i[oven fridge], end: [], fill: 'alternate', wall: 'lift_mix' },
      { id: 'v20', name: '20 - Freestanding fridge | oven tall (drawers, open wall shelves)', start: %i[fridge_free], end: %i[oven], fill: 'drawers', wall: 'open' },
      { id: 'v21', name: '21 - Glass display, storage tall | built-in fridge, oven tall', start: %i[glass storage], end: %i[fridge oven], fill: 'classic', wall: 'lift_glass' },
      { id: 'v22', name: '22 - Built-in fridge, freezer, storage tall (drawers and doors)', start: %i[fridge freezer storage], end: [], fill: 'alternate', wall: 'door_lift' },
      { id: 'v23', name: '23 - Oven tall | storage tall, freestanding fridge (doors)', start: %i[oven], end: %i[storage fridge_free], fill: 'doors', wall: 'lift' },
      { id: 'v24', name: '24 - Pantry, storage, oven tall | built-in fridge (drawer over doors, open wall shelves)', start: %i[pantry storage oven], end: %i[fridge], fill: 'drawer_door', wall: 'open' },
      { id: 'v25', name: '25 - Tall drawers, built-in fridge, freezer | oven tall (drawers and doors)', start: %i[drawers fridge freezer], end: %i[oven], fill: 'alternate', wall: 'lift_mix' }
    ].freeze

    def self.variations = VARIATIONS.map { |variation| { 'id' => variation[:id], 'name' => variation[:name] } }
    def self.variation(id) = VARIATIONS.find { |variation| variation[:id] == id.to_s }


    DEFAULTS = {
      'layout' => 'straight', 'wall_a' => 3600.0, 'wall_b' => 2400.0, 'wall_c' => 2400.0, 'fridge' => 'builtin', 'sink' => true, 'sink_bowls' => 1, 'sink_drain' => true, 'dishwasher' => true, 'dishwasher_handle' => true, 'hob' => true,
      'hood' => true, 'oven_tower' => false, 'wall_units' => true, 'style' => 'classic', 'mirror' => false, 'island_wall' => 'a', 'variation' => '', 'sink_wall' => '', 'hob_wall' => '', 'island' => false, 'island_feature' => 'none', 'island_length' => 1800.0, 'island_aisle' => 1100.0, 'island_seating' => 300.0, 'run_end_panels' => true, 'island_back_panel' => false, 'island_mirror' => false, 'panel_thickness' => 0.0, 'open_ends' => false, 'island_back_panel_material' => '', 'island_side_panels' => false, 'island_hood_colour' => 'Stainless Steel', 'ceiling' => 2400.0
    }.freeze

    # The options as the plan needs them: numbers as numbers, ticks as true / false, anything unknown as the default.
    def self.normalise(raw)
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      flag = ->(key) { raw.key?(key) ? [true, 'true', 1, '1', 'on'].include?(raw[key]) : DEFAULTS[key] }
      number = lambda do |key|
        value = raw[key].to_s.strip.tr(',', '.').to_f
        value.positive? ? value : DEFAULTS[key]
      end
      fridge = FRIDGE.key?(raw['fridge'].to_s) ? raw['fridge'].to_s : (raw.key?('fridge') ? 'none' : DEFAULTS['fridge'])
      layout = RUNS.key?(raw['layout'].to_s) ? raw['layout'].to_s : 'straight'
      { 'layout' => layout, 'wall_a' => number.call('wall_a'), 'wall_b' => number.call('wall_b'), 'wall_c' => number.call('wall_c'), 'fridge' => fridge,
        'sink' => flag.call('sink'), 'sink_bowls' => raw['sink_bowls'].to_s == '2' ? 2 : 1, 'sink_drain' => flag.call('sink_drain'), 'dishwasher' => flag.call('dishwasher'), 'dishwasher_handle' => flag.call('dishwasher_handle'), 'hob' => flag.call('hob'), 'hood' => flag.call('hood'), 'oven_tower' => flag.call('oven_tower'),
        'wall_units' => flag.call('wall_units'), 'style' => STYLES.include?(raw['style'].to_s) ? raw['style'].to_s : 'classic', 'mirror' => flag.call('mirror'), 'island_wall' => (%w[a b c].include?(raw['island_wall'].to_s.downcase) ? raw['island_wall'].to_s.downcase : 'a'), 'variation' => (variation(raw['variation']) ? raw['variation'].to_s : ''), 'sink_wall' => (%w[a b c].include?(raw['sink_wall'].to_s.downcase) ? raw['sink_wall'].to_s.downcase : ''), 'hob_wall' => (%w[a b c].include?(raw['hob_wall'].to_s.downcase) ? raw['hob_wall'].to_s.downcase : ''), 'island' => flag.call('island'), 'island_feature' => ISLAND_FEATURES.include?(raw['island_feature'].to_s) ? raw['island_feature'].to_s : 'none', 'island_length' => number.call('island_length'),
        'island_aisle' => [number.call('island_aisle'), 700.0].max, 'ceiling' => number.call('ceiling'), 'island_back_panel' => flag.call('island_back_panel'), 'island_mirror' => flag.call('island_mirror'), 'panel_thickness' => raw['panel_thickness'].to_s.tr(',', '.').to_f.clamp(0.0, 60.0), 'open_ends' => flag.call('open_ends'), 'island_back_panel_material' => raw['island_back_panel_material'].to_s.strip, 'island_side_panels' => flag.call('island_side_panels'), 'island_hood_colour' => IslandHood::COLOURS.include?(raw['island_hood_colour'].to_s) ? raw['island_hood_colour'].to_s : DEFAULTS['island_hood_colour'], 'island_seating' => raw.key?('island_seating') ? raw['island_seating'].to_s.tr(',', '.').to_f.clamp(0.0, MAX_SEATING) : DEFAULTS['island_seating'], 'run_end_panels' => flag.call('run_end_panels'), 'windows' => windows_of(raw['windows'], RUNS[layout]) }
    end

    # The windows the walls have: [{ run, from, to }], the distance from the start of the wall. Anything unusable is left out.
    def self.windows_of(list, runs)
      Array(list).filter_map do |entry|
        next unless entry.is_a?(Hash)

        entry = entry.transform_keys(&:to_s)
        run = entry['wall'].to_s.downcase.to_sym
        from = entry['from'].to_s.tr(',', '.').to_f
        width = entry['width'].to_s.tr(',', '.').to_f
        next unless runs.include?(run) && width >= 200.0 && from >= 0.0

        { run: run, from: from, to: from + width }
      end
    end
    private_class_method :windows_of

    def self.plan(raw)
      build_plan(normalise(raw))
    rescue Short => e
      failure(e.message)
    end

    def self.build_plan(o)
      runs = RUNS[o['layout']]
      lengths = { a: o['wall_a'], b: o['wall_b'], c: o['wall_c'] }
      notes = []
      chosen = variation(o['variation'])
      start_tall = chosen ? chosen[:start].map { |key| TALL[key] } : (FRIDGE.key?(o['fridge']) ? [[FRIDGE[o['fridge']][0], FRIDGE[o['fridge']][1], :fridge]] : [])
      end_tall = chosen ? chosen[:end].map { |key| TALL[key] } : (o['oven_tower'] ? [[OVEN[0], OVEN[1], :oven]] : [])
      fridge_w = start_tall.sum { |tall| tall[1] }
      oven_w = end_tall.sum { |tall| tall[1] }
      @fill_mode = chosen ? chosen[:fill] : 'classic'
      @wall_mode = chosen ? chosen[:wall] : 'classic'

      # A tall unit beside lower units gets a full side panel, and the units after it stand one panel thickness further along.
      panel = o['panel_thickness'].to_f
      fridge_end = fridge_w.positive? ? fridge_w + panel : 0.0
      oven_end = oven_w.positive? ? oven_w + panel : 0.0

      reserve = lambda do |run|
        index = runs.index(run)
        [index.zero? ? fridge_end : CORNER_BASE, index == runs.length - 1 ? oven_end : CORNER_BASE]
      end
      free = runs.to_h { |run| [run, lengths[run] - reserve.call(run).sum] }
      runs.each do |run|
        return failure("Wall #{run.to_s.upcase} is too short (#{fmt(lengths[run])} mm) for the units it needs. Make it longer or leave something out.") if free[run] < 300.0
      end

      # An island with the hob or the sink in it takes it off the wall (planned first: the room may not allow the island).
      island_lengths = o['mirror'] ? runs.to_h { |run| [run, lengths[runs.reverse[runs.index(run)]]] } : lengths
      island = o['island'] ? island_plan(o, runs, island_lengths, notes) : nil
      o = o.merge('hob' => false) if island && island.items.any? { |item| item.kind == :hob }
      o = o.merge('sink' => false) if island && island.items.any? { |item| item.kind == :sink }

      sink_run, hob_run = appliance_runs(o, runs, free, notes)
      window = o['windows'].find { |w| w[:run] == sink_run }
      sink_center = window ? (window[:from] + window[:to]) / 2.0 : nil

      base = []
      cursor = 0.0
      start_tall.each do |type, width, kind|
        base << Item.new(category: 'tall', type: type, width: width, kind: kind, run: :a, start: cursor)
        cursor += width
      end
      runs.each_with_index do |run, index|
        base.concat(safe_run(run, free[run], reserve.call(run)[0], sink_run == run, hob_run == run, notes, sink_center, style: o['style'], with_dish: o['dishwasher'], bowls: o['sink_bowls'], drain: o['sink_drain']))
        base << Item.new(category: 'base', type: 'base_corner_l', width: CORNER_BASE, kind: :corner, run: run, start: lengths[run] - CORNER_BASE) if index < runs.length - 1
      end
      cursor = lengths[runs.last] - oven_w
      end_tall.each do |type, width, kind|
        base << Item.new(category: 'tall', type: type, width: width, kind: kind, run: runs.last, start: cursor)
        cursor += width
      end

      wall = o['wall_units'] ? wall_items(o, base, runs, lengths, fridge_end, oven_end, notes, o['style']) : []
      wall_start = fridge_end
      turn = nil
      if o['mirror'] # the other hand: the whole row of units the other way round (see mirrored)
        turn = mirror_turn(runs, lengths)
        base, wall, lengths = mirrored(base, wall, runs, lengths, oven_end)
        wall_start = oven_end
      end
      spaced_for_panels(base, panel)
      Plan.new(base: base, wall: wall, wall_start: wall_start, notes: notes, error: nil, island: island, style: o['style'], layout: o['layout'], first_length: lengths[:a], open_ends: o['open_ends'], run_ends: o['run_end_panels'], turn: turn)
    end

    # The room for a side panel between a tall unit and the lower unit beside it (in the same row): that unit has `panel` mm before it.
    def self.spaced_for_panels(base, panel)
      base.each { |item| item.gap_before = 0.0 }
      return unless panel.positive?

      base.each_cons(2) do |before, item|
        item.gap_before = panel if before.run == item.run && (before.category == 'tall') != (item.category == 'tall') && before.kind != :corner && item.kind != :corner
      end
    end
    private_class_method :spaced_for_panels

    # ---- the other hand ------------------------------------------------------------

    # The kitchen as its mirror image. A row of units always turns the same way at a corner (clockwise, as when units are inserted one after
    # another), so the mirror image of an L is the same L built from the other wall: the units in the opposite order, each wall read from its
    # other end, the corner between the same two walls. So the fridge, which was at the start of wall A, ends the row, and the walls keep their own
    # names in the order they are now met (the first wall is the old last one). Returns [base, wall, lengths] (the lengths by the new names).
    def self.mirrored(base, wall, runs, lengths, oven_w)
      rename = runs.zip(runs.reverse).to_h # old name => new name
      new_lengths = runs.to_h { |run| [run, lengths[rename[run]]] }
      reflect = lambda do |list, corner_width|
        out = []
        list.reverse_each do |item|
          copy = item.dup
          copy.extra = (item.extra || {}).merge('flip_hand' => true) unless item.kind == :corner # hinges and the drainer flip like a real mirror
          if item.kind == :corner # between the two walls, so after the one just before it
            copy.run = out.last.run
            copy.start = new_lengths[copy.run] - corner_width
          else
            copy.run = rename[item.run]
            copy.start = (lengths[item.run] - (item.start + item.width)).round(2)
          end
          out << copy
        end
        out
      end
      new_base = reflect.call(base, CORNER_BASE)
      new_wall = reflect.call(wall, CORNER_WALL)
      current = nil
      cursor = 0.0
      new_wall.each do |item| # the room a window leaves empty before a unit, now counted from the other end
        if item.run != current
          current = item.run
          cursor = runs.index(current).zero? ? oven_w : CORNER_WALL
        end
        gap = item.start - cursor
        item.gap_before = gap > 0.5 ? gap.round(2) : 0.0
        cursor = item.start + item.width
      end
      [new_base, new_wall, new_lengths]
    end
private_class_method :mirrored

# The mirrored kitchen is built the usual way round (clockwise from its first wall), so it is turned to lie where the native mirror of the
# kitchen would: wall A where it was, the corner at its other end. An L turns a quarter and moves along by its first wall (wall B); a U
# turns half a turn and moves by the middle wall and the old last wall. [degrees, along, across] in the first unit's own frame (x: depth).
def self.mirror_turn(runs, lengths)
  case runs.length
  when 2 then [90.0, lengths[:b], 0.0]
  when 3 then [180.0, lengths[:b], lengths[:c]]
  end
end
private_class_method :mirror_turn
    # Which run takes the sink and which the hob. The sink goes under a window when there is one on a run it fits, else in the middle wall of a U,
    # else on A. The hob goes on the last wall when there is room, else on A.
    def self.appliance_runs(o, runs, free, notes)
      sink_run = nil
      if o['sink']
        under_window = o['windows'].map { |w| w[:run] }.find { |run| free[run] >= sink_width_for(o) }
        sink_run = under_window || (runs.length == 3 && free[:b] >= sink_width_for(o) ? :b : :a)
      end
      sink_run = chosen_run(o['sink_wall'], 'sink', runs, free, sink_width_for(o), sink_run, notes) if o['sink']
      hob_run = nil
      if o['hob']
        candidate = runs.reverse.find { |run| run != :a && free[run] >= 900.0 && run != sink_run }
        hob_run = candidate || :a
        hob_run = runs.reverse.find { |run| free[run] >= 900.0 && run != sink_run } || hob_run if hob_run == sink_run && runs.length > 1
        hob_run = chosen_run(o['hob_wall'], 'hob', runs, free, HOB_WIDTH, hob_run, notes)
      end
      [sink_run, hob_run]
    end

    # The wall the user asked for (A, B or C), when it is one of the walls of the layout and has room for the unit; else `automatic`, with a note.
    def self.chosen_run(wanted, what, runs, free, needed, automatic, notes)
      return automatic if wanted.to_s.empty?

      run = wanted.to_sym
      unless runs.include?(run)
        notes << "There is no wall #{wanted.upcase} in this layout, so the #{what} went where it fits best."
        return automatic
      end
      if free[run] < needed
        notes << "Wall #{wanted.upcase} is too short for the #{what}, so it went where it fits best."
        return automatic
      end
      run
    end
    private_class_method :chosen_run
    private_class_method :appliance_runs

    def self.failure(message)
      Plan.new(base: [], wall: [], wall_start: 0.0, notes: [], error: message, island: nil)
    end
    private_class_method :failure

    def self.fmt(value)
      format('%g', value)
    end
    private_class_method :fmt

    # How wide the sink unit is: the usual 900 mm, or 1200 mm for two bowls.
    def self.sink_width_for(options)
      two = options['sink_bowls'] == 2
      drain = options['sink_drain'] != false
      if two then drain ? SINK_WIDTH_TWO : SINK_WIDTH_TWO_PLAIN else drain ? SINK_WIDTH : SINK_WIDTH_PLAIN end
    end
    private_class_method :sink_width_for
    # ---- one run of base units --------------------------------------------------

    # run_items, but when the run is too short for its sink and hob the hob is left out (and then the sink made a narrow one), with a note.
    def self.safe_run(run, free, start, with_sink, with_hob, notes, sink_center = nil, style: 'classic', with_dish: false, bowls: 1, drain: true)
      run_items(run, free, start, with_sink, with_hob, notes, sink_center, sink_width_for({ 'sink_bowls' => bowls, 'sink_drain' => drain }), style: style, with_dish: with_dish, bowls: bowls, drain: drain)
    rescue Short
      raise unless with_hob || with_sink

      notes.delete(ADJACENT)
      if with_hob
        notes << "There is no room for the hob in run #{run.to_s.upcase}: put it in by hand."
        safe_run(run, free, start, with_sink, false, notes, sink_center, style: style, with_dish: with_dish, bowls: bowls, drain: drain)
      elsif with_dish
        notes << "There is no room for the dishwasher space in run #{run.to_s.upcase}: put it in by hand."
        safe_run(run, free, start, with_sink, false, notes, sink_center, style: style, with_dish: false, bowls: bowls, drain: drain)
      else
        notes << "The sink unit of run #{run.to_s.upcase} had to be a narrow one."
        run_items(run, free, start, true, false, notes, sink_center, 600.0, style: style)
      end
    end
    private_class_method :safe_run

    # The units of a run `free` mm long that starts `start` mm along its wall: the sink and the hob where they go, the rest filled with
    # equal units. A unit next to the hob is a unit of drawers, the others are doors with a unit of drawers now and then.
    def self.run_items(run, free, start, with_sink, with_hob, notes, sink_center = nil, sink_width = SINK_WIDTH, style: 'classic', with_dish: false, bowls: 1, drain: true)
      sink = with_sink ? sink_width : nil
      hob = with_hob ? HOB_WIDTH : nil
      tokens = []
      tokens << [:seg, 0]
      tokens << [:sink, sink] if sink
      tokens << [:dish, DISH_WIDTH] if sink && with_dish
      tokens << [:seg, sink && hob && !with_dish ? 1 : 0] if sink && hob # (the dishwasher space is worktop too: it is the landing space)
      tokens << [:hob, hob] if hob
      tokens << [:seg, 0] if hob
      tokens << [:seg, 0] if !hob && sink
      fixed = tokens.select { |kind, _| kind != :seg }
      segs = tokens.each_index.select { |i| tokens[i][0] == :seg }

      notes << ADJACENT if sink && hob && !with_dish && free - fixed.sum { |_, w| w } < MIN_FILL * 0.8
      remaining = free - fixed.sum { |_, w| w }
      raise Short, "Run #{run.to_s.upcase} is too short for its sink and hob units." if remaining < -1.0

      counts = counts_for(remaining, segs.length, segs.map { |i| tokens[i][1] })
      if counts.nil? # too little room for filling units: the sink and the hob take what is left
        extra = [remaining, 0.0].max
        stretch = fixed.count { |kind, _| %i[sink hob].include?(kind) }
        fixed = fixed.map { |kind, w| %i[sink hob].include?(kind) ? [kind, w + (extra / stretch)] : [kind, w] } unless stretch.zero? || extra > 300.0 * stretch
        counts = Array.new(segs.length, 0)
        remaining = free - fixed.sum { |_, w| w }
        remaining = 0.0 if remaining.abs < 1.0
      end
      seg_widths = nil
      if sink && sink_center && counts.sum.positive? && remaining.positive? # the sink under its window
        seg_widths = centered_segments(remaining, segs.map { |i| tokens[i][1] }, sink_center - (sink / 2.0) - start)
        counts = seg_widths.map(&:length) if seg_widths
      end
      if seg_widths.nil?
        widths = fill_widths(remaining, counts.sum)
        cursor = 0
        seg_widths = counts.map { |n| widths.slice(cursor, n).tap { cursor += n } }
      end
      items = []
      position = start
      fixed_cursor = 0
      tokens.each_with_index do |(kind, _), i|
        if kind == :seg
          units = seg_widths[segs.index(i)]
          anchor = tokens[i - 1] && tokens[i - 1][0] == :hob ? :hob : (tokens[i + 1] && tokens[i + 1][0] == :hob ? :hob_after : nil)
          ordered = anchor == :hob_after ? units.reverse : units
          made = ordered.each_with_index.map { |w, index| fill_unit(w, anchor ? index : index + 1, anchor, run, style) }
          made = made.reverse if anchor == :hob_after
          made.each do |item|
            item.start = position
            position += item.width
            items << item
          end
        else
          width = fixed[fixed_cursor][1]
          fixed_cursor += 1
          type = { sink: width < 800.0 ? 'base_sink_1door' : 'base_sink', dish: 'base_dishwasher', hob: 'base_hob' }[kind]
          special = {}
          if kind == :sink
            special['sink_bowls'] = 2 if bowls == 2 && width >= 850.0 # (two bowls need a wide sink unit)
            special['sink_tray'] = false if !drain && width >= 800.0 # (the narrow sink unit has no drainer anyway)
          end
          items << Item.new(category: 'base', type: type, width: width, kind: kind, run: run, start: position, extra: special.empty? ? nil : special)
          position += width
        end
      end
      leftover = (start + free) - position
      notes << "A gap of #{fmt(leftover.round(1))} mm is left at the end of run #{run.to_s.upcase}." if leftover.abs > 2.0
      items
    end
    private_class_method :run_items

    # How many filling units go in each segment: about one for every 600 mm, none narrower than 300 or wider than 900, and at least the segment's
    # minimum (the landing space between the sink and the hob). nil when even that does not fit.
    def self.counts_for(remaining, seg_count, minimums)
      return Array.new(seg_count, 0) if seg_count.zero?
      return nil if remaining < MIN_FILL * 0.8

      n = (remaining / IDEAL).round
      n = 1 if n < 1
      n += 1 while remaining / n > MAX_FILL
      n -= 1 while n > 1 && remaining / n < MIN_FILL
      wanted = minimums.dup
      index = wanted.length - 1
      while wanted.sum > n && index >= 0 # fewer units than the minimums ask for: drop them from the last segment backwards
        wanted[index] = 0
        index -= 1
      end
      counts = wanted.dup
      (n - counts.sum).times do
        pick = counts.each_index.min_by { |i| [counts[i], i.zero? || i == counts.length - 1 ? 0 : 1, i] } # the ends fill first
        counts[pick] += 1
      end
      counts
    end
    private_class_method :counts_for

    # The widths of the filling units of each segment of a run with its sink `before` mm from the start (the sink is between the first segment and
    # the others), so that the sink is where it was asked to be. The first segment is `before` long (none when that is under 150 mm, else at
    # least one 300 mm unit); the others share what is left, the one between the sink and the hob keeping at least its minimum. nil when it
    # cannot be done.
    def self.centered_segments(remaining, minimums, before)
      return nil if minimums.length < 2

      later_min = minimums.drop(1).sum
      room_after = remaining - (later_min * MIN_FILL)
      return nil if room_after < 0

      first = before.clamp(0.0, room_after)
      first = 0.0 if first < 150.0
      first = MIN_FILL if first.positive? && first < MIN_FILL
      first = [first, room_after].min
      first = 0.0 if first < MIN_FILL - 0.5
      later_length = remaining - first
      if later_min.zero? && later_length < MIN_FILL - 0.5 # too little left after the sink for a unit: the units before it take it
        first += later_length
        later_length = 0.0
      end
      n_later = [(later_length / IDEAL).round, later_min].max
      n_later += 1 while n_later.positive? && later_length / n_later > MAX_FILL
      n_later -= 1 while n_later > later_min && later_length / n_later < MIN_FILL
      counts = minimums.drop(1).dup
      counts[-1] += n_later - counts.sum
      n_first = first.zero? ? 0 : [(first / IDEAL).round, 1].max
      n_first += 1 while n_first.positive? && first / n_first > MAX_FILL
      n_first -= 1 while n_first > 1 && first / n_first < MIN_FILL
      lengths = counts.map { |n| n_later.zero? ? 0.0 : later_length * n / n_later }
      [fill_widths(first, n_first)] + counts.each_with_index.map { |n, i| fill_widths(lengths[i], n) }
    end
    private_class_method :centered_segments

    # `count` widths adding up to `total`, equal and to the nearest 5 mm, the last one taking what is left.
    def self.fill_widths(total, count)
      return [] if count.zero?

      each = ((total / count) / 5.0).round * 5.0
      widths = Array.new(count, each)
      widths[-1] = (total - (each * (count - 1))).round(2)
      widths
    end
    private_class_method :fill_widths

    def self.fill_unit(width, index, anchor, run, style = 'classic')
      drawers = anchor ? index.zero? : (index % 3).zero? && index.positive?
      case @fill_mode # (see VARIATIONS)
      when 'drawers' then drawers = true
      when 'doors' then drawers = anchor ? index.zero? : false
      when 'alternate' then drawers = anchor ? index.zero? : index.odd?
      end
      drawers = true if style == 'lift' # a lift-up kitchen has drawers below
      drawers &&= width <= 900.0
      over_doors = @fill_mode == 'drawer_door' && !anchor && style != 'lift'
      type = if over_doors then width <= 600.0 ? 'base_drawer_door' : 'base_drawer_2door'
             elsif drawers then 'base_3drawer'
             elsif width <= 600.0 then 'base_1door'
             else 'base_2door'
             end
      Item.new(category: 'base', type: type, width: width, kind: :fill, run: run)
    end
    private_class_method :fill_unit

    # ---- the wall units ---------------------------------------------------------

    def self.wall_items(o, base, runs, lengths, fridge_w, oven_w, notes, style = 'classic')
      items = []
      hob = base.find { |item| item.kind == :hob }
      hood = o['hood'] && hob
      runs.each_with_index do |run, index|
        last = index == runs.length - 1
        from = index.zero? ? fridge_w : CORNER_WALL
        to = last ? lengths[run] - oven_w : lengths[run] - CORNER_WALL
        blocked = o['windows'].select { |w| w[:run] == run }.map { |w| [[w[:from], from].max, [w[:to], to].min] }.select { |a, b| b > a }.sort
        hood_here = hood && hob.run == run && hob.start >= from && hob.start + hob.width <= to
        if hood_here && blocked.any? { |a, b| a < hob.start + hob.width && b > hob.start }
          notes << 'The hob is under a window, so it has no hood.'
          hood_here = false
        end
        mine = []
        spans(from, to, blocked).each do |s0, s1|
          if hood_here && hob.start >= s0 && hob.start + hob.width <= s1
            mine.concat(wall_fill(s0, hob.start, run, notes, style))
            mine << Item.new(category: 'wall', type: 'wall_hood', width: hob.width, kind: :hood, run: run, start: hob.start)
            mine.concat(wall_fill(hob.start + hob.width, s1, run, notes, style))
          else
            mine.concat(wall_fill(s0, s1, run, notes, style))
          end
        end
        mine << Item.new(category: 'wall', type: 'wall_corner_l', width: CORNER_WALL, kind: :corner, run: run, start: to) unless last
        cursor = from
        mine.each do |item| # the room a window leaves empty before a unit
          gap = item.start - cursor
          item.gap_before = gap > 0.5 ? gap.round(2) : 0.0
          cursor = item.start + item.width
        end
        items.concat(mine)
      end
      items
    end
    private_class_method :wall_items

    # What is left of [from, to] when the (sorted) intervals are taken out.
    def self.spans(from, to, blocked)
      list = []
      cursor = from
      blocked.each do |a, b|
        list << [cursor, a] if a - cursor > 0.5
        cursor = [cursor, b].max
      end
      list << [cursor, to] if to - cursor > 0.5
      list
    end
    private_class_method :spans

    # ---- an island ---------------------------------------------------------------

    # A row of units standing free in the room, parallel to wall A, its fronts towards wall A (the working side), `aisle` mm from the units there.
    # nil, with a note, when the room is too narrow or too short for it.
    def self.island_plan(o, runs, lengths, notes)
      wall = o['island_wall'].to_s.empty? ? :a : o['island_wall'].to_sym
      unless runs.include?(wall)
        notes << "There is no wall #{wall.upcase} in this layout, so the island is parallel to wall A."
        wall = :a
      end
      index = runs.index(wall)
      aisle = o['island_aisle']
      if runs.length == 3 && wall != :b # wall A and wall C face each other, wall B between them
        space = lengths[:b] - (2 * FRONT_DEPTH) # between the units of A and of C
        aisle = [aisle, (space - FRONT_DEPTH) / 2.0].min
        if aisle < 900.0
          notes << 'The room is too narrow for an island: it was left out.'
          return nil
        end
      end
      reach = FRONT_DEPTH + aisle # what a wall that meets this one at an end takes
      first = index.positive? ? reach : 0.0
      y_max = lengths[wall] - first - (index < runs.length - 1 ? reach : 0.0)
      if y_max < 600.0
        notes << "Wall #{wall.upcase} is too short for an island: it was left out."
        return nil
      end
      feature = o['island_feature']
      with_dish = feature == 'sink' && o['dishwasher']
      needed = { 'hob' => HOB_WIDTH, 'sink' => sink_width_for(o) + (with_dish ? DISH_WIDTH : 0.0) }.fetch(feature, 0.0) + (2 * MIN_FILL)
      if feature != 'none' && needed > y_max
        notes << "The island is too short for its #{feature}: it is a plain island."
        feature = 'none'
      end
      wanted = feature == 'none' ? o['island_length'] : [o['island_length'], needed].max
      length = [wanted, y_max].min
      items = nil
      if feature != 'none'
        begin
          items = run_items(:island, length, 0.0, feature == 'sink', feature == 'hob', notes, nil, sink_width_for(o), style: 'lift', with_dish: with_dish, bowls: o['sink_bowls'], drain: o['sink_drain'])
        rescue Short
          notes << "The island has no room for its #{feature}: it is a plain island."
        end
      end
      if items.nil?
        count = [(length / IDEAL).round, 1].max
        count -= 1 while count > 1 && length / count < MIN_FILL
        position = 0.0
        items = fill_widths(length, count).map do |w|
          item = Item.new(category: 'base', type: w <= 900.0 ? 'base_3drawer' : 'base_2door', width: w, kind: :island, run: :island, start: position)
          position += w
          item
        end
      end
      notes << "The island is #{fmt(length.round)} mm long (the room allows no more)." if length < wanted - 1.0
      if o['island_mirror'] # the other hand: the units in the opposite order along the island
        position = 0.0
        items = items.reverse.map do |item|
          copy = item.dup
          copy.start = position
          copy.extra = (item.extra || {}).merge('flip_hand' => true)
          position += copy.width
          copy
        end
      end
      hob = items.find { |item| item.kind == :hob }
      hood = hob && o['hood'] ? { start: hob.start, width: hob.width, top: o['ceiling'], material: o['island_hood_colour'] } : nil # a hood hung from the ceiling over the island's hob
      frame = { a: [0.0, 0.0, 0.0], b: [0.0, lengths[:a], -90.0], c: [lengths[:b], lengths[:a], 180.0] }[wall] # (where wall B and wall C start, turned to run along them)
      Island.new(wall: wall, frame: frame, items: items, x: FRONT_DEPTH + aisle + FRONT_DEPTH, y: (first + (y_max / 2.0) + (length / 2.0)).round(2), length: length, aisle: aisle, hood: hood, seating: o['island_seating'], back_panel: o['island_back_panel'] ? { length: length, material: o['island_back_panel_material'] } : nil, side_panels: o['island_side_panels'])
    end
    private_class_method :island_plan

    def self.wall_fill(from, to, run, notes, style = 'classic')
      length = to - from
      return [] if length < MIN_UNIT

      lift = style == 'lift' || LIFT_WALLS.include?(@wall_mode) # wide lift-up units: about 900 mm each
      ideal = lift ? 900.0 : IDEAL
      max = lift ? 1200.0 : MAX_FILL
      min = lift ? 600.0 : MIN_FILL
      if length < min
        notes << "Only a #{fmt(length.round)} mm wall unit fits beside the others on wall #{run.to_s.upcase}." if length >= 150.0
        return length >= 150.0 ? [wall_unit('wall_1door', length.round(2), run, from, style)] : []
      end
      n = (length / ideal).round
      n += 1 while n.positive? && length / n > max
      n -= 1 while n > 1 && length / n < min
      widths = fill_widths(length, [n, 1].max)
      position = from
      widths.each_with_index.map do |w, index|
        type = wall_type(w, index, lift)
        item = wall_unit(type, w, run, position, style)
        position += w
        item
      end
    end

    LIFT_WALLS = %w[lift lift_fold lift_glass lift_mix door_lift glass_door_lift].freeze

    # The unit of a wall run at `index`, as the variation's wall pattern (see VARIATIONS) says.
    def self.wall_type(width, index, lift)
      door = width <= 700.0 ? 'wall_1door' : 'wall_2door'
      glass_door = width <= 600.0 ? 'wall_glass_1door' : 'wall_glass_2door'
      case @wall_mode
      when 'lift_fold' then 'wall_liftup_bifold'
      when 'lift' then 'wall_liftup'
      when 'lift_glass' then 'wall_glass_liftup_bifold'
      when 'lift_mix' then %w[wall_liftup_bifold wall_glass_liftup_bifold wall_liftup][index % 3]
      when 'door_lift' then index.even? ? door : 'wall_liftup_bifold'
      when 'glass_door_lift' then index.even? ? glass_door : 'wall_glass_liftup_bifold'
      when 'open' then index % 3 == 2 && !lift ? 'wall_open' : (lift ? 'wall_liftup_bifold' : door)
      else lift ? 'wall_liftup_bifold' : door
      end
    end
    private_class_method :wall_type

    def self.wall_unit(type, width, run, start, style)
      extra = style == 'glass' ? { 'glass_design' => 'glass_wide_grid' } : nil
      Item.new(category: 'wall', type: type, width: width, kind: :fill, run: run, start: start, extra: extra)
    end
    private_class_method :wall_unit
    private_class_method :wall_fill

    # Where the side panels go, for the sides that are open: both ends of an island, and the free ends of the runs of an L or a U (a straight
    # kitchen stands between two walls). [{ part: :base | :wall | :island, index: (in plan.base, plan.wall or plan.island.items), side: 'left' | 'right' }]
    # A wall unit that stands next to a tall unit at that end has no panel: the tall unit's side is in the way.
    def self.end_panel_targets(plan)
      targets = []
      if plan.island && plan.island.side_panels && !plan.island.items.empty?
        targets << { part: :island, index: 0, side: 'left' }
        targets << { part: :island, index: plan.island.items.length - 1, side: 'right' }
      end
      if plan.run_ends && (%w[l u].include?(plan.layout) || plan.open_ends) && !plan.base.empty?
        targets << { part: :base, index: 0, side: 'left' }
        targets << { part: :base, index: plan.base.length - 1, side: 'right' }
        unless plan.wall.empty?
          targets << { part: :wall, index: 0, side: 'left' } unless plan.base.first.category == 'tall'
          targets << { part: :wall, index: plan.wall.length - 1, side: 'right' } unless plan.base.last.category == 'tall'
        end
      end
      targets
    end

    # A line of text for the reply: what was planned.
    def self.describe(plan)
      return plan.error if plan.error

      count = ->(items, kind) { items.count { |item| item.kind == kind } }
      parts = ["#{plan.base.length} floor units"]
      parts << "#{plan.wall.length} wall units" unless plan.wall.empty?
      parts << 'a hob' if count.call(plan.base, :hob).positive?
      parts << 'a sink' if count.call(plan.base, :sink).positive?
      parts << 'a dishwasher space' if count.call(plan.base, :dish).positive?
      parts << 'a fridge housing' if count.call(plan.base, :fridge).positive?
      parts << 'a freezer housing' if count.call(plan.base, :freezer).positive?
      parts << "#{count.call(plan.base, :storage)} storage tall unit#{'s' unless count.call(plan.base, :storage) == 1}" if count.call(plan.base, :storage).positive?
      parts << 'an oven housing' if count.call(plan.base, :oven).positive?
      parts << { 'glass' => 'glass doors on the wall units', 'lift' => 'lift-up wall units over drawers' }[plan.style] if %w[glass lift].include?(plan.style)
      island_items = plan.island ? plan.island.items : []
      parts << (plan.island.hood ? 'a hob with a ceiling hood on the island' : 'a hob on the island') if island_items.any? { |item| item.kind == :hob }
      parts << 'a sink on the island' if island_items.any? { |item| item.kind == :sink }
      parts << 'a hood' if count.call(plan.wall, :hood).positive?
      parts << ('an island of ' + plan.island.items.length.to_s + ' units' + (plan.island.seating.to_f.positive? ? ' with a ' + fmt(plan.island.seating) + ' mm seating overhang' : '') + (plan.island.back_panel ? ' and a back panel' : '')) if plan.island
      parts.join(', ')
    end
  end
end
