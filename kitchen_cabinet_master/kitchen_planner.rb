# frozen_string_literal: true

module KitchenCabinetMaster
  # Plans a whole kitchen from a few answers (the walls' lengths, which appliances it has). Pure maths: no SketchUp objects.
  #
  # A kitchen is one or two RUNS of units along walls. A straight kitchen has run A; an L kitchen has run A, a corner unit and run B
  # (the corner is at the far end of A; B carries on along the next wall, as when the units are inserted one after another by hand).
  #
  # The plan lists the base units (floor level, in the order they are placed) and the wall units (over them). Every unit is
  # {category, type (a catalog id of the kitchen catalogs), width, kind} with the widths summing to the length of the wall.
  module KitchenPlanner
    Item = Struct.new(:category, :type, :width, :kind, :run, :start, keyword_init: true)
    Plan = Struct.new(:base, :wall, :wall_start, :notes, :error, keyword_init: true)
    class Short < StandardError; end
    ADJACENT = 'The sink and the hob are next to each other: there is no worktop between them.'

    CORNER_BASE = 1000.0 # a corner base unit (L shape) covers this much of each wall
    CORNER_WALL = 700.0  # and the corner wall unit this much
    IDEAL = 600.0        # the width the filling units like to be
    MIN_FILL = 300.0
    MAX_FILL = 900.0
    MIN_UNIT = 100.0
    FRIDGE = { 'builtin' => ['tall_fridge_builtin_2door', 600.0], 'free' => ['tall_fridge_housing_free', 900.0] }.freeze
    OVEN = ['tall_oven', 600.0].freeze
    SINK_WIDTH = 900.0
    HOB_WIDTH = 600.0
    HOB_MAX = 900.0

    DEFAULTS = {
      'layout' => 'straight', 'wall_a' => 3600.0, 'wall_b' => 2400.0, 'fridge' => 'builtin', 'sink' => true, 'hob' => true,
      'hood' => true, 'oven_tower' => false, 'wall_units' => true
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
      { 'layout' => raw['layout'].to_s == 'l' ? 'l' : 'straight', 'wall_a' => number.call('wall_a'), 'wall_b' => number.call('wall_b'), 'fridge' => fridge,
        'sink' => flag.call('sink'), 'hob' => flag.call('hob'), 'hood' => flag.call('hood'), 'oven_tower' => flag.call('oven_tower'),
        'wall_units' => flag.call('wall_units') }
    end

    def self.plan(raw)
      build_plan(normalise(raw))
    rescue Short => e
      failure(e.message)
    end

    def self.build_plan(o)
      l_shape = o['layout'] == 'l'
      notes = []
      fridge_w = FRIDGE.key?(o['fridge']) ? FRIDGE[o['fridge']][1] : 0.0
      oven_w = o['oven_tower'] ? OVEN[1] : 0.0

      free_a = o['wall_a'] - fridge_w - (l_shape ? CORNER_BASE : oven_w)
      free_b = l_shape ? o['wall_b'] - CORNER_BASE - oven_w : 0.0
      return failure("Wall A is too short (#{fmt(o['wall_a'])} mm) for the units it needs. Make it longer or leave something out.") if free_a < 300.0
      return failure("Wall B is too short (#{fmt(o['wall_b'])} mm) for the corner and its units.") if l_shape && free_b < 300.0

      sink_run = o['sink'] ? :a : nil
      hob_run = nil
      hob_run = (l_shape && free_b >= 900.0 ? :b : :a) if o['hob']

      base = []
      base << Item.new(category: 'tall', type: FRIDGE[o['fridge']][0], width: fridge_w, kind: :fridge, run: :a, start: 0.0) if fridge_w.positive?
      run_a = safe_run(:a, free_a, fridge_w, sink_run == :a, hob_run == :a, notes)
      base.concat(run_a)
      base << Item.new(category: 'base', type: 'base_corner_l', width: CORNER_BASE, kind: :corner, run: :a, start: o['wall_a'] - CORNER_BASE) if l_shape
      run_b = []
      if l_shape
        run_b = safe_run(:b, free_b, CORNER_BASE, false, hob_run == :b, notes)
        base.concat(run_b)
      end
      oven_run = l_shape ? :b : :a
      if oven_w.positive?
        start = l_shape ? o['wall_b'] - oven_w : o['wall_a'] - oven_w
        base << Item.new(category: 'tall', type: OVEN[0], width: oven_w, kind: :oven, run: oven_run, start: start)
      end

      wall = o['wall_units'] ? wall_items(o, base, fridge_w, oven_w, l_shape, notes) : []
      Plan.new(base: base, wall: wall, wall_start: fridge_w, notes: notes, error: nil)
    end

    def self.failure(message)
      Plan.new(base: [], wall: [], wall_start: 0.0, notes: [], error: message)
    end
    private_class_method :failure

    def self.fmt(value)
      format('%g', value)
    end
    private_class_method :fmt

    # ---- one run of base units --------------------------------------------------

    # run_items, but when the run is too short for its sink and hob the hob is left out (and then the sink made a narrow one), with a note.
    def self.safe_run(run, free, start, with_sink, with_hob, notes)
      run_items(run, free, start, with_sink, with_hob, notes)
    rescue Short
      raise unless with_hob || with_sink

      notes.delete(ADJACENT)
      if with_hob
        notes << "There is no room for the hob in run #{run.to_s.upcase}: put it in by hand."
        safe_run(run, free, start, with_sink, false, notes)
      else
        notes << "The sink unit of run #{run.to_s.upcase} had to be a narrow one."
        run_items(run, free, start, true, false, notes, 600.0)
      end
    end
    private_class_method :safe_run

    # The units of a run `free` mm long that starts `start` mm along its wall: the sink and the hob where they go, the rest filled with
    # equal units. A unit next to the hob is a unit of drawers, the others are doors with a unit of drawers now and then.
    def self.run_items(run, free, start, with_sink, with_hob, notes, sink_width = SINK_WIDTH)
      sink = with_sink ? sink_width : nil
      hob = with_hob ? HOB_WIDTH : nil
      tokens = []
      tokens << [:seg, 0]
      tokens << [:sink, sink] if sink
      tokens << [:seg, sink && hob ? 1 : 0] if sink && hob
      tokens << [:hob, hob] if hob
      tokens << [:seg, 0] if hob
      tokens << [:seg, 0] if !hob && sink
      fixed = tokens.select { |kind, _| kind != :seg }
      segs = tokens.each_index.select { |i| tokens[i][0] == :seg }

      notes << ADJACENT if sink && hob && free - fixed.sum { |_, w| w } < MIN_FILL * 0.8
      remaining = free - fixed.sum { |_, w| w }
      raise Short, "Run #{run.to_s.upcase} is too short for its sink and hob units." if remaining < -1.0

      counts = counts_for(remaining, segs.length, segs.map { |i| tokens[i][1] })
      if counts.nil? # too little room for filling units: the sink and the hob take what is left
        extra = [remaining, 0.0].max
        fixed = fixed.map { |kind, w| [kind, w + (extra / fixed.length)] } unless fixed.empty? || extra > 300.0 * fixed.length
        counts = Array.new(segs.length, 0)
        remaining = free - fixed.sum { |_, w| w }
        remaining = 0.0 if remaining.abs < 1.0
      end
      widths = fill_widths(remaining, counts.sum)
      items = []
      position = start
      cursor = 0
      fixed_cursor = 0
      tokens.each_with_index do |(kind, _), i|
        if kind == :seg
          n = counts[segs.index(i)]
          units = widths.slice(cursor, n)
          cursor += n
          anchor = tokens[i - 1] && tokens[i - 1][0] == :hob ? :hob : (tokens[i + 1] && tokens[i + 1][0] == :hob ? :hob_after : nil)
          ordered = anchor == :hob_after ? units.reverse : units
          made = ordered.each_with_index.map { |w, index| fill_unit(w, anchor ? index : index + 1, anchor, run) }
          made = made.reverse if anchor == :hob_after
          made.each do |item|
            item.start = position
            position += item.width
            items << item
          end
        else
          width = fixed[fixed_cursor][1]
          fixed_cursor += 1
          type = kind == :sink ? (width < 800.0 ? 'base_sink_1door' : 'base_sink') : 'base_hob'
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

    # `count` widths adding up to `total`, equal and to the nearest 5 mm, the last one taking what is left.
    def self.fill_widths(total, count)
      return [] if count.zero?

      each = ((total / count) / 5.0).round * 5.0
      widths = Array.new(count, each)
      widths[-1] = (total - (each * (count - 1))).round(2)
      widths
    end
    private_class_method :fill_widths

    def self.fill_unit(width, index, anchor, run)
      drawers = anchor ? index.zero? : (index % 3).zero? && index.positive?
      drawers &&= width <= 900.0
      type = if drawers then 'base_3drawer'
             elsif width <= 600.0 then 'base_1door'
             else 'base_2door'
             end
      Item.new(category: 'base', type: type, width: width, kind: :fill, run: run)
    end
    private_class_method :fill_unit

    # ---- the wall units ---------------------------------------------------------

    def self.wall_items(o, base, fridge_w, oven_w, l_shape, notes)
      items = []
      hob = base.find { |item| item.kind == :hob }
      hood = o['hood'] && hob
      runs = l_shape ? %i[a b] : [:a]
      runs.each do |run|
        if run == :a
          from = fridge_w
          to = l_shape ? o['wall_a'] - CORNER_WALL : o['wall_a'] - oven_w
        else
          from = CORNER_WALL
          to = o['wall_b'] - oven_w
        end
        if hood && hob.run == run && hob.start >= from && hob.start + hob.width <= to
          items.concat(wall_fill(from, hob.start, run, notes))
          items << Item.new(category: 'wall', type: 'wall_hood', width: hob.width, kind: :hood, run: run, start: hob.start)
          items.concat(wall_fill(hob.start + hob.width, to, run, notes))
        else
          items.concat(wall_fill(from, to, run, notes))
        end
        items << Item.new(category: 'wall', type: 'wall_corner_l', width: CORNER_WALL, kind: :corner, run: :a, start: o['wall_a'] - CORNER_WALL) if l_shape && run == :a
      end
      items
    end
    private_class_method :wall_items

    def self.wall_fill(from, to, run, notes)
      length = to - from
      return [] if length < MIN_UNIT

      if length < MIN_FILL
        notes << "Only a #{fmt(length.round)} mm wall unit fits beside the others on wall #{run.to_s.upcase}." if length >= 150.0
        return length >= 150.0 ? [Item.new(category: 'wall', type: 'wall_1door', width: length.round(2), kind: :fill, run: run, start: from)] : []
      end
      n = (length / IDEAL).round
      n += 1 while n.positive? && length / n > MAX_FILL
      n -= 1 while n > 1 && length / n < MIN_FILL
      widths = fill_widths(length, [n, 1].max)
      position = from
      widths.map do |w|
        item = Item.new(category: 'wall', type: w <= 700.0 ? 'wall_1door' : 'wall_2door', width: w, kind: :fill, run: run, start: position)
        position += w
        item
      end
    end
    private_class_method :wall_fill

    # A line of text for the reply: what was planned.
    def self.describe(plan)
      return plan.error if plan.error

      count = ->(items, kind) { items.count { |item| item.kind == kind } }
      parts = ["#{plan.base.length} floor units"]
      parts << "#{plan.wall.length} wall units" unless plan.wall.empty?
      parts << 'a hob' if count.call(plan.base, :hob).positive?
      parts << 'a sink' if count.call(plan.base, :sink).positive?
      parts << 'a fridge housing' if count.call(plan.base, :fridge).positive?
      parts << 'an oven housing' if count.call(plan.base, :oven).positive?
      parts << 'a hood' if count.call(plan.wall, :hood).positive?
      parts.join(', ')
    end
  end
end
