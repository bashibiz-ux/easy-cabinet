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
    Plan = Struct.new(:base, :wall, :wall_start, :notes, :error, :island, :style, :layout, :first_length, keyword_init: true) # first_length: how long the first wall is (what the next kitchen is put beyond)
    Island = Struct.new(:items, :x, :y, :length, :aisle, :hood, :seating, :pendants, keyword_init: true) # x: from wall A to the island's back, y: along wall A to its high end
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
    HOB_WIDTH = 600.0
    DISH_WIDTH = 600.0 # the space for a dishwasher, beside the sink
    # How the kitchen looks: doors everywhere; glass doors on the wall units; or wide lift-up wall units over drawers.
    STYLES = %w[classic glass lift].freeze
    MAX_SEATING = 450.0 # the most an island's worktop can reach beyond its back for stools
    ISLAND_FEATURES = %w[none hob sink].freeze # what an island has built in
    RUNS = { 'straight' => [:a], 'l' => %i[a b], 'u' => %i[a b c] }.freeze

    DEFAULTS = {
      'layout' => 'straight', 'wall_a' => 3600.0, 'wall_b' => 2400.0, 'wall_c' => 2400.0, 'fridge' => 'builtin', 'sink' => true, 'dishwasher' => true, 'hob' => true,
      'hood' => true, 'oven_tower' => false, 'wall_units' => true, 'style' => 'classic', 'mirror' => false, 'island' => false, 'island_feature' => 'none', 'island_length' => 1800.0, 'island_aisle' => 1100.0, 'island_seating' => 0.0, 'island_pendants' => false, 'island_pendant_colour' => 'Stainless Steel', 'island_pendant_shape' => 'drum', 'island_pendant_size' => 'medium', 'island_pendant_spacing' => 800.0, 'island_pendant_height' => 'normal', 'island_pendant_thickness' => 'surface', 'island_hood_colour' => 'Stainless Steel', 'ceiling' => 2400.0
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
        'sink' => flag.call('sink'), 'dishwasher' => flag.call('dishwasher'), 'hob' => flag.call('hob'), 'hood' => flag.call('hood'), 'oven_tower' => flag.call('oven_tower'),
        'wall_units' => flag.call('wall_units'), 'style' => STYLES.include?(raw['style'].to_s) ? raw['style'].to_s : 'classic', 'mirror' => flag.call('mirror'), 'island' => flag.call('island'), 'island_feature' => ISLAND_FEATURES.include?(raw['island_feature'].to_s) ? raw['island_feature'].to_s : 'none', 'island_length' => number.call('island_length'),
        'island_aisle' => [number.call('island_aisle'), 700.0].max, 'ceiling' => number.call('ceiling'), 'island_pendants' => flag.call('island_pendants'), 'island_pendant_shape' => IslandPendants::SHAPES.include?(raw['island_pendant_shape'].to_s) ? raw['island_pendant_shape'].to_s : DEFAULTS['island_pendant_shape'], 'island_pendant_size' => IslandPendants::SIZES.key?(raw['island_pendant_size'].to_s) ? raw['island_pendant_size'].to_s : DEFAULTS['island_pendant_size'], 'island_pendant_spacing' => (IslandPendants::SPACINGS.find { |s| s == raw['island_pendant_spacing'].to_s.tr(',', '.').to_f } || DEFAULTS['island_pendant_spacing']), 'island_pendant_height' => IslandPendants::HEIGHTS.key?(raw['island_pendant_height'].to_s) ? raw['island_pendant_height'].to_s : DEFAULTS['island_pendant_height'], 'island_pendant_thickness' => IslandPendants::THICKNESSES.key?(raw['island_pendant_thickness'].to_s) ? raw['island_pendant_thickness'].to_s : DEFAULTS['island_pendant_thickness'], 'island_hood_colour' => IslandPendants::COLOURS.include?(raw['island_hood_colour'].to_s) ? raw['island_hood_colour'].to_s : DEFAULTS['island_hood_colour'], 'island_pendant_colour' => IslandPendants::COLOURS.include?(raw['island_pendant_colour'].to_s) ? raw['island_pendant_colour'].to_s : DEFAULTS['island_pendant_colour'], 'island_seating' => raw['island_seating'].to_s.tr(',', '.').to_f.clamp(0.0, MAX_SEATING), 'windows' => windows_of(raw['windows'], RUNS[layout]) }
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
      fridge_w = FRIDGE.key?(o['fridge']) ? FRIDGE[o['fridge']][1] : 0.0
      oven_w = o['oven_tower'] ? OVEN[1] : 0.0

      reserve = lambda do |run|
        index = runs.index(run)
        [index.zero? ? fridge_w : CORNER_BASE, index == runs.length - 1 ? oven_w : CORNER_BASE]
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
      base << Item.new(category: 'tall', type: FRIDGE[o['fridge']][0], width: fridge_w, kind: :fridge, run: :a, start: 0.0) if fridge_w.positive?
      runs.each_with_index do |run, index|
        base.concat(safe_run(run, free[run], reserve.call(run)[0], sink_run == run, hob_run == run, notes, sink_center, style: o['style'], with_dish: o['dishwasher']))
        base << Item.new(category: 'base', type: 'base_corner_l', width: CORNER_BASE, kind: :corner, run: run, start: lengths[run] - CORNER_BASE) if index < runs.length - 1
      end
      if oven_w.positive?
        base << Item.new(category: 'tall', type: OVEN[0], width: oven_w, kind: :oven, run: runs.last, start: lengths[runs.last] - oven_w)
      end

      wall = o['wall_units'] ? wall_items(o, base, runs, lengths, fridge_w, oven_w, notes, o['style']) : []
      wall_start = fridge_w
      if o['mirror'] # the other hand: the whole row of units the other way round (see mirrored)
        base, wall, lengths = mirrored(base, wall, runs, lengths, oven_w)
        wall_start = oven_w
      end
      Plan.new(base: base, wall: wall, wall_start: wall_start, notes: notes, error: nil, island: island, style: o['style'], layout: o['layout'], first_length: lengths[:a])
    end

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
    # Which run takes the sink and which the hob. The sink goes under a window when there is one on a run it fits, else in the middle wall of a U,
    # else on A. The hob goes on the last wall when there is room, else on A.
    def self.appliance_runs(o, runs, free, notes)
      sink_run = nil
      if o['sink']
        under_window = o['windows'].map { |w| w[:run] }.find { |run| free[run] >= SINK_WIDTH }
        sink_run = under_window || (runs.length == 3 && free[:b] >= SINK_WIDTH ? :b : :a)
      end
      hob_run = nil
      if o['hob']
        candidate = runs.reverse.find { |run| run != :a && free[run] >= 900.0 && run != sink_run }
        hob_run = candidate || :a
        hob_run = runs.reverse.find { |run| free[run] >= 900.0 && run != sink_run } || hob_run if hob_run == sink_run && runs.length > 1
      end
      [sink_run, hob_run]
    end
    private_class_method :appliance_runs

    def self.failure(message)
      Plan.new(base: [], wall: [], wall_start: 0.0, notes: [], error: message, island: nil)
    end
    private_class_method :failure

    def self.fmt(value)
      format('%g', value)
    end
    private_class_method :fmt
    # ---- one run of base units --------------------------------------------------

    # run_items, but when the run is too short for its sink and hob the hob is left out (and then the sink made a narrow one), with a note.
    def self.safe_run(run, free, start, with_sink, with_hob, notes, sink_center = nil, style: 'classic', with_dish: false)
      run_items(run, free, start, with_sink, with_hob, notes, sink_center, style: style, with_dish: with_dish)
    rescue Short
      raise unless with_hob || with_sink

      notes.delete(ADJACENT)
      if with_hob
        notes << "There is no room for the hob in run #{run.to_s.upcase}: put it in by hand."
        safe_run(run, free, start, with_sink, false, notes, sink_center, style: style, with_dish: with_dish)
      elsif with_dish
        notes << "There is no room for the dishwasher space in run #{run.to_s.upcase}: put it in by hand."
        safe_run(run, free, start, with_sink, false, notes, sink_center, style: style, with_dish: false)
      else
        notes << "The sink unit of run #{run.to_s.upcase} had to be a narrow one."
        run_items(run, free, start, true, false, notes, sink_center, 600.0, style: style)
      end
    end
    private_class_method :safe_run

    # The units of a run `free` mm long that starts `start` mm along its wall: the sink and the hob where they go, the rest filled with
    # equal units. A unit next to the hob is a unit of drawers, the others are doors with a unit of drawers now and then.
    def self.run_items(run, free, start, with_sink, with_hob, notes, sink_center = nil, sink_width = SINK_WIDTH, style: 'classic', with_dish: false)
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
          items << Item.new(category: 'base', type: type, width: width, kind: kind, run: run, start: position)
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
      drawers = true if style == 'lift' # a lift-up kitchen has drawers below
      drawers &&= width <= 900.0
      type = if drawers then 'base_3drawer'
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
      aisle = o['island_aisle']
      if runs.length == 3
        space = lengths[:b] - (2 * FRONT_DEPTH) # between the units of A and of C
        aisle = [aisle, (space - FRONT_DEPTH) / 2.0].min
        if aisle < 900.0
          notes << 'The room is too narrow for an island: it was left out.'
          return nil
        end
      end
      y_max = runs.length > 1 ? lengths[:a] - FRONT_DEPTH - aisle : lengths[:a]
      if y_max < 600.0
        notes << 'Wall A is too short for an island: it was left out.'
        return nil
      end
      feature = o['island_feature']
      with_dish = feature == 'sink' && o['dishwasher']
      needed = { 'hob' => HOB_WIDTH, 'sink' => SINK_WIDTH + (with_dish ? DISH_WIDTH : 0.0) }.fetch(feature, 0.0) + (2 * MIN_FILL)
      if feature != 'none' && needed > y_max
        notes << "The island is too short for its #{feature}: it is a plain island."
        feature = 'none'
      end
      wanted = feature == 'none' ? o['island_length'] : [o['island_length'], needed].max
      length = [wanted, y_max].min
      items = nil
      if feature != 'none'
        begin
          items = run_items(:island, length, 0.0, feature == 'sink', feature == 'hob', notes, nil, style: 'lift', with_dish: with_dish)
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
      hob = items.find { |item| item.kind == :hob }
      hood = hob && o['hood'] ? { start: hob.start, width: hob.width, top: o['ceiling'], material: o['island_hood_colour'] } : nil # a hood hung from the ceiling over the island's hob
      Island.new(items: items, x: FRONT_DEPTH + aisle + FRONT_DEPTH, y: ((y_max / 2.0) + (length / 2.0)).round(2), length: length, aisle: aisle, hood: hood, seating: o['island_seating'],
                 pendants: o['island_pendants'] && o['island_seating'].positive? ? { positions: IslandPendants.positions(length, o['island_pendant_spacing']), back: o['island_seating'], top: o['ceiling'], material: o['island_pendant_colour'], shape: o['island_pendant_shape'], size: o['island_pendant_size'], height: o['island_pendant_height'], thickness: o['island_pendant_thickness'] } : nil)
    end
    private_class_method :island_plan

    def self.wall_fill(from, to, run, notes, style = 'classic')
      length = to - from
      return [] if length < MIN_UNIT

      lift = style == 'lift' # wide lift-up units: about 900 mm each
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
      widths.map do |w|
        item = wall_unit(lift ? 'wall_liftup_bifold' : (w <= 700.0 ? 'wall_1door' : 'wall_2door'), w, run, position, style)
        position += w
        item
      end
    end

    def self.wall_unit(type, width, run, start, style)
      extra = style == 'glass' ? { 'glass_design' => 'glass_wide_grid' } : nil
      Item.new(category: 'wall', type: type, width: width, kind: :fill, run: run, start: start, extra: extra)
    end
    private_class_method :wall_unit
    private_class_method :wall_fill

    # Where the end panels go, for the sides that are open: both ends of an island, and the free ends of the runs of an L or a U (a straight
    # kitchen stands between two walls). [{ part: :base | :wall | :island, index: (in plan.base, plan.wall or plan.island.items), side: 'left' | 'right' }]
    # A wall unit that stands next to a tall unit at that end has no panel: the tall unit's side is in the way.
    def self.end_panel_targets(plan)
      targets = []
      if plan.island && !plan.island.items.empty?
        targets << { part: :island, index: 0, side: 'left' }
        targets << { part: :island, index: plan.island.items.length - 1, side: 'right' }
      end
      if %w[l u].include?(plan.layout) && !plan.base.empty?
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
      parts << 'an oven housing' if count.call(plan.base, :oven).positive?
      parts << { 'glass' => 'glass doors on the wall units', 'lift' => 'lift-up wall units over drawers' }[plan.style] if %w[glass lift].include?(plan.style)
      island_items = plan.island ? plan.island.items : []
      parts << (plan.island.hood ? 'a hob with a ceiling hood on the island' : 'a hob on the island') if island_items.any? { |item| item.kind == :hob }
      parts << 'a sink on the island' if island_items.any? { |item| item.kind == :sink }
      parts << 'a hood' if count.call(plan.wall, :hood).positive?
      parts << ('an island of ' + plan.island.items.length.to_s + ' units' + (plan.island.seating.to_f.positive? ? ' with a ' + fmt(plan.island.seating) + ' mm seating overhang' : '') + (plan.island.pendants ? ' and ' + plan.island.pendants[:positions].length.to_s + ' pendant light' + (plan.island.pendants[:positions].length == 1 ? '' : 's') : '')) if plan.island
      parts.join(', ')
    end
  end
end
