# frozen_string_literal: true

module KitchenCabinetMaster
  # Snaps a cabinet (or filler) that the user has moved with the Move tool to the
  # sides of the nearest neighbour, so a hand-placed cabinet ends up exactly
  # against the next one instead of a few millimetres off.
  #
  # When a moved item finishes up within SNAP_DISTANCE of another cabinet's side,
  # it is nudged so the two sides touch, and (when it is also close) its back and
  # front line up with that neighbour's. Only the floor plan (X and Y) is touched;
  # height never changes.
  #
  #   before                     after
  #   ┌────┐  ┌────┐             ┌────┬────┐
  #   │ A  │  │ B  │  B dragged  │ A  │ B  │   sides touch, backs level
  #   └────┘  └────┘  close to A └────┴────┘
  #
  # The maths (`delta`) knows nothing about SketchUp; the observers below just
  # notice a move, work out the boxes and apply the result as one transparent
  # undo step, so Undo takes back the snap together with the move.
  module SnapManager
    SNAP_DISTANCE_MM = 150.0
    MOVE_TOOL_ID = 21_048

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

    # ---- SketchUp glue -------------------------------------------------------

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

    # Snapping runs when the Move tool lets go (its state returns to 0), or when
    # the user changes tool. A short timer covers anything else that moved a cabinet.
    class ToolWatcher < Sketchup::ToolsObserver
      def onToolStateChanged(_tools, _name, tool_id, tool_state)
        SnapManager.settle if tool_id == MOVE_TOOL_ID && tool_state.zero?
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Snap watcher failed: #{e.message}"
      end

      def onActiveToolChanged(_tools, _name, _tool_id)
        SnapManager.settle
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
      return remember(entity) if @busy || SelectionManager.suspended?

      id = entity.persistent_id
      return remember(entity) if @known[id].nil? || same?(@known[id], entity.transformation.to_a)

      @dirty[id] = entity
      schedule
    end

    # A move has finished: snap whatever moved.
    def self.settle
      cancel_timer
      return if @dirty.empty?

      pending = @dirty.values
      @dirty = {}
      pending.each { |entity| snap(entity) if entity.valid? }
    end

    def self.snappable?(entity)
      entity.is_a?(Sketchup::ComponentInstance) && entity.valid? && AttributeManager.occupant?(entity)
    end
    private_class_method :snappable?

    def self.same?(first, second)
      first.zip(second).all? { |a, b| (a - b).abs < 1e-9 }
    end
    private_class_method :same?

    def self.schedule
      cancel_timer
      @timer = UI.start_timer(1.2, false) do
        @timer = nil
        settle
      end
    end
    private_class_method :schedule

    def self.cancel_timer
      UI.stop_timer(@timer) if @timer
      @timer = nil
    end
    private_class_method :cancel_timer

    def self.snap(entity)
      return unless right_angled?(entity.transformation)

      others = PlacementManager.existing_boxes(entity.parent.entities, exclude: entity).map { |box| plan(box) }
      shift = delta(plan(own_box(entity)), others, SNAP_DISTANCE_MM.mm)

      if shift.nil? || shift.all? { |v| v.abs < 1e-6 }
        remember(entity)
        return
      end

      model = entity.model
      @busy = true
      # Transparent: joins the Move that just finished, so one Undo takes back both.
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
    private_class_method :snap

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
