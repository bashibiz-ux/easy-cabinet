# frozen_string_literal: true

module KitchenCabinetMaster
  # Snaps a cabinet (or filler) that the user has moved with the Move tool, so a
  # hand-placed cabinet ends up exactly where it belongs instead of a few
  # millimetres off. Two things snap, both only on the floor plan (height never
  # changes), and both only when the item ends up within SNAP_DISTANCE:
  #
  #   1. SIDES  to the nearest cabinet's side, so the two touch. When it is also
  #             close, its back and front line up with that neighbour's.
  #   2. BACK   to a wall behind it: a tall vertical face in the model whose
  #             surface runs parallel to the cabinet's back.
  #
  #   before                            after
  #   wall ║ ┌────┐  ┌────┐             wall ║┌────┬────┐
  #        ║ │ A  │  │ B  │ B dragged        ║│ A  │ B  │   sides touch, backs on the wall
  #        ║ └────┘  └────┘ near A           ║└────┴────┘
  #
  # The maths (`delta`, `wall_delta`) knows nothing about SketchUp and is unit
  # tested; the observers below notice a move, work out the boxes and walls, and
  # apply the result as one transparent undo step, so Undo takes back the snap
  # together with the move. The snap never runs inside the Move tool's own
  # callback: it is always handed to a short timer, which is the safe moment to
  # start an operation. It can be switched off from the extension's menu.
  module SnapManager
    SNAP_DISTANCE_MM = 200.0
    MOVE_TOOL_ID = 21_048

    SETTLE_DELAY_S = 0.15 # after the Move tool lets go
    QUIET_DELAY_S = 1.5   # fallback: nothing has changed for this long

    # A wall is a vertical face at least this tall and this wide.
    WALL_MIN_HEIGHT_MM = 1000.0
    WALL_MIN_WIDTH_MM = 300.0
    WALL_FACING = 0.985 # how squarely the wall must face the cabinet's back (cosine)
    WALL_OVERLAP = 0.5  # how much of the cabinet's width must lie along the wall
    MAX_WALL_FACES = 4000
    MAX_WALL_DEPTH = 3

    PREFERENCE_SECTION = 'KitchenCabinetMaster'
    PREFERENCE_KEY = 'snap_enabled'

    # ---- the maths -----------------------------------------------------------

    # `moved` and each of `others`: { min: [x, y], max: [x, y] } (any one unit).
    # `threshold` is in that same unit. Returns [dx, dy] to add to `moved`, or nil
    # when nothing is close enough.
    def self.delta(moved, others, threshold)
      best = nil

      others.each do |other|
        [0, 1].each do |axis|
          across = 1 - axis
          next unless near_or_overlapping?(moved, other, across, threshold)

          gap = [other[:max][axis] - moved[:min][axis], other[:min][axis] - moved[:max][axis]].min_by(&:abs)
          next if gap.abs > threshold

          best = { axis: axis, gap: gap, other: other } if best.nil? || gap.abs < best[:gap].abs
        end
      end
      return nil unless best

      result = [0.0, 0.0]
      result[best[:axis]] = best[:gap]

      # Line up along the other direction too (back to back, front to front).
      across = 1 - best[:axis]
      other = best[:other]
      align = [other[:min][across] - moved[:min][across], other[:max][across] - moved[:max][across]].min_by(&:abs)
      result[across] = align if align.abs <= threshold
      result
    end

    # Do the two boxes overlap along `axis`, or come within `threshold` of it?
    # (Sides only snap together when the items actually sit next to each other,
    # not when one is merely in the same column of the room.)
    def self.near_or_overlapping?(first, second, axis, threshold)
      first[:min][axis] < second[:max][axis] + threshold && first[:max][axis] > second[:min][axis] - threshold
    end

    # How far to move a cabinet, along its own front direction, so its BACK lies
    # on the nearest wall behind it. Returns [dx, dy], or nil when no wall is close.
    #
    #   mover  { f: [fx, fy]        unit vector the cabinet's front faces (its X axis)
    #            origin: [x, y]     a point on its back (its origin)
    #            t: [min, max]      its extent across, along t = (-fy, fx)
    #            z: [min, max] }    its height range
    #   walls  [{ normal: [nx, ny], points: [[x, y], ...], z: [min, max] }, ...]
    #          a wall's `points` are its outline in plan; its surface is the line
    #          through them, and `normal` is perpendicular to that line.
    #
    # A wall counts when its surface is parallel to the cabinet's back (either
    # side of the face may be the visible one), it overlaps the cabinet in height,
    # and at least half the cabinet's width lies along it, so a cabinet that merely
    # passes a short stub of wall is left alone.
    def self.wall_delta(mover, walls, threshold)
      fx, fy = mover[:f]
      tx = -fy
      ty = fx
      width = mover[:t][1] - mover[:t][0]
      back = (mover[:origin][0] * fx) + (mover[:origin][1] * fy)
      best = nil

      walls.each do |wall|
        nx, ny = wall[:normal]
        next unless ((nx * fx) + (ny * fy)).abs > WALL_FACING
        next unless [mover[:z][1], wall[:z][1]].min - [mover[:z][0], wall[:z][0]].max > 0

        across = wall[:points].map { |x, y| (x * tx) + (y * ty) }
        along = [mover[:t][1], across.max].min - [mover[:t][0], across.min].max
        next unless along >= width * WALL_OVERLAP

        x, y = wall[:points].first
        gap = ((x * fx) + (y * fy)) - back
        next if gap.abs > threshold

        best = gap if best.nil? || gap.abs < best.abs
      end
      best && [fx * best, fy * best]
    end

    # ---- switching it on and off -----------------------------------------------

    def self.enabled?
      Sketchup.read_default(PREFERENCE_SECTION, PREFERENCE_KEY, true) ? true : false
    end

    def self.enabled=(value)
      Sketchup.write_default(PREFERENCE_SECTION, PREFERENCE_KEY, value ? true : false)
    end

    # ---- SketchUp glue -----------------------------------------------------------

    class EntitiesWatcher < Sketchup::EntitiesObserver
      def onElementAdded(_entities, entity)
        SnapManager.remember(entity)
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Snap watcher failed: #{e.message}"
      end

      def onElementModified(_entities, entity)
        SnapManager.modified(entity)
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Snap watcher failed: #{e.message}"
      end
    end

    # Snapping is asked for when the Move tool lets go (its state returns to 0) or
    # the user changes tool. It is never done here: the tool is still busy, so the
    # work goes to a timer (see request).
    class ToolWatcher < Sketchup::ToolsObserver
      def onToolStateChanged(_tools, _name, tool_id, tool_state)
        SnapManager.request(SETTLE_DELAY_S) if tool_id == MOVE_TOOL_ID && tool_state.zero?
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Snap watcher failed: #{e.message}"
      end

      def onActiveToolChanged(_tools, _name, _tool_id)
        SnapManager.request(SETTLE_DELAY_S)
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Snap watcher failed: #{e.message}"
      end
    end

    # Makes sure the watchers follow whichever model is active.
    class AppWatcher < Sketchup::AppObserver
      def expectsStartupModelNotifications
        true
      end

      def onNewModel(model)
        SnapManager.attach(model)
      end

      def onOpenModel(model)
        SnapManager.attach(model)
      end

      def onActivateModel(model)
        SnapManager.attach(model)
      end
    end

    # Call once when the extension loads.
    def self.install
      @attached = {}
      @known = {}
      @dirty = {}
      @entities_watcher = EntitiesWatcher.new
      @tool_watcher = ToolWatcher.new
      @app_watcher = AppWatcher.new
      Sketchup.add_observer(@app_watcher)
      attach(Sketchup.active_model)
    end

    def self.attach(model)
      return unless model

      key = model.guid
      return if @attached[key]

      model.entities.add_observer(@entities_watcher)
      model.tools.add_observer(@tool_watcher)
      @attached[key] = true
      model.entities.grep(Sketchup::ComponentInstance).each { |instance| remember(instance) }
    end

    # Notes where an occupant is, so a later change can be told apart from one
    # that did not move it (an attribute write, a visibility flip ...).
    def self.remember(entity)
      return unless snappable?(entity)

      @known[entity.persistent_id] = entity.transformation.to_a
    end

    def self.modified(entity)
      return unless snappable?(entity)
      return remember(entity) if @busy || SelectionManager.suspended? || !enabled?

      id = entity.persistent_id
      return remember(entity) if @known[id].nil? || same?(@known[id], entity.transformation.to_a)

      @dirty[id] = entity
      request(QUIET_DELAY_S)
    end

    # Asks for the snap to happen `delay` seconds from now (and pushes back any
    # earlier request), on a timer: safely outside whatever SketchUp is doing.
    def self.request(delay)
      return if @dirty.nil? || @dirty.empty?

      cancel_timer
      @timer = UI.start_timer(delay, false) do
        @timer = nil
        settle
      end
    end

    # A move has finished: snap whatever moved.
    def self.settle
      cancel_timer
      return if @dirty.empty?

      pending = @dirty.values
      @dirty = {}
      pending.each do |entity|
        next unless entity.valid?

        begin
          snap(entity)
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Could not snap #{entity.name}: #{e.class}: #{e.message}"
          notify("Could not snap #{entity.name}: #{e.message}")
        end
      end
    end

    def self.snappable?(entity)
      entity.is_a?(Sketchup::ComponentInstance) && entity.valid? && AttributeManager.occupant?(entity)
    end
    private_class_method :snappable?

    def self.same?(first, second)
      first.zip(second).all? { |a, b| (a - b).abs < 1e-9 }
    end
    private_class_method :same?

    def self.cancel_timer
      UI.stop_timer(@timer) if @timer
      @timer = nil
    end
    private_class_method :cancel_timer

    # Tells the control panel (if it is open) what the snap did.
    def self.notify(message)
      DialogManager.push('snap', { 'message' => message })
    end
    private_class_method :notify

    def self.snap(entity)
      return unless right_angled?(entity.transformation)

      threshold = SNAP_DISTANCE_MM.mm
      others = PlacementManager.existing_boxes(entity.parent.entities, exclude: entity).map { |box| plan(box) }
      box = own_box(entity)
      side = delta(plan(box), others, threshold)

      # The wall is measured from where the sides have already put the cabinet.
      shift = side || [0.0, 0.0]
      mover = mover_info(entity, box, shift)
      wall = wall_delta(mover, collect_walls(entity.model, entity), threshold)
      shift = [shift[0] + wall[0], shift[1] + wall[1]] if wall

      if shift.all? { |v| v.abs < 1e-6 }
        remember(entity)
        return
      end

      apply(entity, shift)
      # Only say what actually moved it: a back already on the wall did not "snap".
      to_wall = wall&.any? { |v| v.abs > 1e-6 }
      what = [('the next cabinet' if side), ('the wall' if to_wall)].compact.join(' and ')
      notify("#{entity.name} snapped to #{what}.")
    end
    private_class_method :snap

    # Moves `entity` by `shift` ([dx, dy], inches) as a transparent operation, so
    # it joins the Move that just finished: one Undo takes back both.
    def self.apply(entity, shift)
      model = entity.model
      @busy = true
      model.start_operation('Snap Cabinet', true, false, true)
      begin
        entity.transform!(Geom::Transformation.translation(Geom::Vector3d.new(shift[0], shift[1], 0)))
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        @busy = false
      end
      remember(entity)
    end
    private_class_method :apply

    def self.own_box(entity)
      size = %w[envelope_depth envelope_width envelope_top].map do |key|
        entity.get_attribute(AttributeManager::DICTIONARY, key).to_f.mm
      end
      PlacementManager.box_for(entity.transformation, size)
    end
    private_class_method :own_box

    def self.plan(box)
      { min: [box[:min][0], box[:min][1]], max: [box[:max][0], box[:max][1]] }
    end
    private_class_method :plan

    # What wall_delta needs to know about the cabinet, as it will be after `shift`.
    def self.mover_info(entity, box, shift)
      x = entity.transformation.xaxis
      f = [x.x, x.y]
      length = Math.hypot(*f)
      f = [f[0] / length, f[1] / length]
      t = [-f[1], f[0]]
      across = box[:corners].map { |c| (c.x * t[0]) + (c.y * t[1]) }
      moved_t = (shift[0] * t[0]) + (shift[1] * t[1])
      origin = entity.transformation.origin
      {
        f: f,
        origin: [origin.x + shift[0], origin.y + shift[1]],
        t: [across.min + moved_t, across.max + moved_t],
        z: [box[:min][2], box[:max][2]]
      }
    end
    private_class_method :mover_info

    # The walls in the model: tall vertical faces, as wall_delta expects them.
    # The extension's own cabinets and parts are never walls. Looks inside
    # groups and components a few levels down, and gives up after a few thousand
    # faces so a huge model cannot make a move sluggish.
    def self.collect_walls(model, skip)
      walls = []
      scanned = 0
      visit = lambda do |entities, transformation, depth|
        entities.each do |entity|
          break if scanned >= MAX_WALL_FACES

          if entity.is_a?(Sketchup::Face)
            scanned += 1
            wall = wall_from(entity, transformation)
            walls << wall if wall
          elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            next if entity.equal?(skip) || entity.hidden? || !entity.layer.visible?
            next if AttributeManager.cabinet?(entity) || AttributeManager.part?(entity) || depth >= MAX_WALL_DEPTH

            inside = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
            visit.call(inside, transformation * entity.transformation, depth + 1)
          end
        end
      end
      visit.call(model.entities, Geom::Transformation.new, 0)
      walls
    end
    private_class_method :collect_walls

    def self.wall_from(face, transformation)
      normal = face.normal.transform(transformation)
      return nil unless normal.z.abs < 0.02

      length = Math.hypot(normal.x, normal.y)
      return nil if length < 1e-9

      points = face.outer_loop.vertices.map { |vertex| transformation * vertex.position }
      heights = points.map(&:z)
      return nil if (heights.max - heights.min) < WALL_MIN_HEIGHT_MM.mm

      plan_points = points.map { |p| [p.x, p.y] }
      direction = [normal.x / length, normal.y / length]
      tangent = [-direction[1], direction[0]]
      across = plan_points.map { |x, y| (x * tangent[0]) + (y * tangent[1]) }
      return nil if (across.max - across.min) < WALL_MIN_WIDTH_MM.mm

      { normal: direction, points: plan_points, z: [heights.min, heights.max] }
    end
    private_class_method :wall_from

    # Turned by a whole number of quarter turns about Z (so its box in the plan is
    # exact), and standing upright.
    def self.right_angled?(transformation)
      x = transformation.xaxis
      y = transformation.yaxis
      aligned = ->(v) { v.x.abs < 1e-6 || v.y.abs < 1e-6 }
      aligned.call(x) && aligned.call(y) && x.z.abs < 1e-6 && y.z.abs < 1e-6
    end
    private_class_method :right_angled?
  end
end
