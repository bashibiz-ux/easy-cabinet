# frozen_string_literal: true

module EasyCabinet
  # Everything about how doors move.
  #
  # A door is only ever moved by a real Geom::Transformation:
  #
  #   door.transformation = Rotation(hinge axis, angle) * ClosedPlacement
  #
  # The hinge axis is the vertical line through `door.pivot`. Opening always
  # swings the free edge towards the front of the cabinet (+X):
  #   left hinge  -> rotate clockwise        (negative angle about +Z)
  #   right hinge -> rotate counter-clockwise (positive angle about +Z)
  module DoorAnimation
    OPEN_KEY = 'open'
    FRAMES = 36        # frames from closed to open (it was 18, then 30: slower again)
    GLASS_FRAMES = 60  # a glass door is slower still: there is glass to carry
    BIFOLD_EXTRA_FRAMES = 80 # both doors of a hydraulic bi-fold take this many frames longer (about 2.5 seconds in all, like the real mechanism)
    ARC_STEP_DEGREES = 10.0
    HINGE_MARK = 20.0 # mm above and below the hinge point

    # One door or drawer's change of state. `from` / `to` are opening fractions
    # (0 = closed, 1 = fully open). `kind` is :door (rotates about `spec.pivot`,
    # using `angle`) or :drawer (slides along X, using `depth` as the cabinet's
    # depth to size the pull-out); `angle`/`depth` are ignored for the other kind.
    # Every Move must be built with an explicit `kind:`.
    Move = Struct.new(:door, :spec, :angle, :depth, :from, :to, :kind, keyword_init: true)

    # ---- transformations -----------------------------------------------------

    # The door's transformation at a given opening fraction.
    def self.transformation(spec, angle, fraction)
      closed = closed_transformation(spec)
      return closed if fraction.zero?

      swing(spec, angle, fraction) * closed
    end

    # An ordinary door/drawer has `rotation` 0, so this is exactly the plain
    # translation it always was. A corner unit's diagonal door has a non-zero
    # `rotation`: it is rotated in place, about its own near (offset) corner,
    # to lie along the diagonal before any opening swing is applied.
    def self.closed_transformation(spec)
      translation = Geom::Transformation.new(spec.offset.map(&:mm))
      degrees = spec.rotation.to_f
      return translation if degrees.zero?

      pivot = Geom::Point3d.new(*spec.offset.map(&:mm))
      Geom::Transformation.rotation(pivot, Geom::Vector3d.new(0, 0, 1), degrees * Math::PI / 180.0) * translation
    end

    # A lift-up door ('top' hinge) turns about the horizontal line along its top edge, so its bottom edge
    # swings up and out; every other door about the vertical hinge line.
    def self.swing(spec, angle, fraction)
      return Geom::Transformation.translation(Geom::Vector3d.new(0, spec.slide.mm * fraction, 0)) if spec.respond_to?(:slide) && spec.slide # a sliding door runs along its track

      angle = angle_for(spec, angle)
      if spec.hinge == 'top'
        return Geom::Transformation.rotation(Geom::Point3d.new(*spec.pivot.map(&:mm)), Geom::Vector3d.new(0, 1, 0),
                                             -angle * fraction * Math::PI / 180.0)
      end
      return fold_swing(spec, angle, fraction) if spec.hinge == 'fold'

      Geom::Transformation.rotation(
        Geom::Point3d.new(*spec.pivot.map(&:mm)),
        Geom::Vector3d.new(0, 0, 1),
        swing_radians(spec.hinge, spec.rotation, angle, fraction)
      )
    end

    # The lower door of a hydraulic bi-fold goes with the door above it (it hangs from that door's outer edge) and is held by the mechanism so that it
    # hangs down from there, leaning with its top BIFOLD_LEAN degrees out: it turns the other way to the upper door, by the angle of the upper door plus the
    # lean (as in the video of the Titan bi-fold). (The pivot of the door is on the face of the one above, so the two do not run into each other.)
    # Measured from the frames of the Titan bi-fold video (a fixed camera, the camera fitted to the cabinet, the doors followed frame by frame): the upper door
    # turns BIFOLD_ANGLE degrees about its top edge (a rigid door, its lower edge ends about 100 mm above the top of the cabinet and 350 mm in front of it),
    # and the lower door, hanging from that edge, leans with its top out by 0.16 times the angle of the upper door (BIFOLD_LEAN at the end).
    BIFOLD_ANGLE = 107.0
    BIFOLD_LEAN = 17.0
    FOLD_ANGLE = -(BIFOLD_ANGLE + BIFOLD_LEAN) # (negative: against the way the upper door turns)

    def self.fold_swing(spec, angle, fraction)
      lifted = spec.parent ? swing(spec.parent, angle, fraction) : Geom::Transformation.new
      folded = Geom::Transformation.rotation(Geom::Point3d.new(*spec.pivot.map(&:mm)), Geom::Vector3d.new(0, 1, 0), -FOLD_ANGLE * fraction * Math::PI / 180.0)
      lifted * folded
    end
    private_class_method :fold_swing

    # How far open (0..1) a bi-fold is, by the seconds since it started, as the video shows it: it opens in 2.85 seconds, starting at once at about 40 degrees
    # a second, turning fastest in the middle and slowing down at the end; and it closes in 1.75 seconds, about twice as fast, slowly at first.
    BIFOLD_OPENING = [[0.0, 0.0], [0.15, 0.05], [0.25, 0.086], [0.35, 0.12], [0.45, 0.159], [0.55, 0.198], [0.65, 0.241], [0.75, 0.285], [0.85, 0.333],
                      [0.95, 0.38], [1.05, 0.428], [1.15, 0.47], [1.25, 0.515], [1.35, 0.569], [1.45, 0.616], [1.55, 0.656], [1.65, 0.697], [1.75, 0.746],
                      [1.85, 0.778], [1.95, 0.821], [2.05, 0.852], [2.15, 0.885], [2.25, 0.913], [2.35, 0.935], [2.45, 0.955], [2.55, 0.972], [2.65, 0.985],
                      [2.75, 0.996], [2.85, 1.0]].freeze
    BIFOLD_CLOSING = [[0.0, 1.0], [0.08, 0.988], [0.18, 0.965], [0.28, 0.932], [0.38, 0.885], [0.48, 0.836], [0.58, 0.771], [0.68, 0.706], [0.78, 0.632],
                      [0.88, 0.557], [0.98, 0.479], [1.08, 0.4], [1.18, 0.322], [1.28, 0.248], [1.38, 0.174], [1.48, 0.11], [1.58, 0.055], [1.68, 0.015],
                      [1.75, 0.0]].freeze

    # The openness (0 = closed, 1 = open) of a bi-fold `seconds` into its opening (or closing). Pure maths.
    def self.bifold_openness(seconds, opening)
      table = opening ? BIFOLD_OPENING : BIFOLD_CLOSING
      return table.last[1] if seconds >= table.last[0]
      return table.first[1] if seconds <= 0.0

      later = table.index { |(time, _)| time >= seconds }
      (t0, v0), (t1, v1) = table[later - 1], table[later]
      v0 + ((v1 - v0) * (seconds - t0) / (t1 - t0))
    end

    def self.bifold_seconds(opening)
      (opening ? BIFOLD_OPENING : BIFOLD_CLOSING).last[0]
    end

    LIFT_MAX_ANGLE = 100.0 # a lift-up door opens no further than this
    # A hydraulic bi-fold: the upper door turns up and out on its top edge until its outer edge stands a little above the top of the cabinet, and the lower door
    # hangs from that edge in front of the cabinet. That is what the mechanism does whatever the Opening Angle says.

    # How far a door really opens: the panel's Opening Angle, but never less than the door's own `swing`
    # (an L corner's doors open wide to show the inside) and, for a lift-up door, never more than it can.
    def self.angle_for(spec, angle)
      angle = angle.to_f
      angle = [angle, spec.swing.to_f].max if spec.respond_to?(:swing) && spec.swing
      angle = [angle, LIFT_MAX_ANGLE].min if %w[top fold].include?(spec.hinge)
      angle = BIFOLD_ANGLE if spec.respond_to?(:bifold) && spec.bifold && spec.hinge == 'top'
      angle
    end

    # Signed rotation in radians. Pure maths, no SketchUp objects.
    # The diagonal corner door is laid out in its own local frame exactly like an
    # ordinary door (hinge 'left' = low local Y, free edge at the high end), so
    # the same signs apply; `rotation` only turns that whole frame in place.
    def self.swing_radians(hinge, _rotation, angle_degrees, fraction)
      sign = hinge == 'left' ? -1.0 : 1.0
      sign * angle_degrees.to_f * fraction * Math::PI / 180.0
    end

    def self.open?(door)
      door.get_attribute(AttributeManager::DICTIONARY, OPEN_KEY) == true
    end

    def self.set_open(door, state)
      door.set_attribute(AttributeManager::DICTIONARY, OPEN_KEY, state ? true : false)
    end

    # ---- running an animation ------------------------------------------------

    # Animates `moves` (Array of Move) as ONE undoable step. Falls back to an
    # instant change if the animation cannot start.
    def self.run(model, moves, operation_name)
      stop_current(model)
      player = Player.new(model, moves, operation_name)
      @current = player
      begin
        player.start
      rescue StandardError => e
        warn "[Easy Cabinet] Animation failed, applying instantly: #{e.message}"
        player.finish
      end
    end

    # How many frames a move takes: a glass door (it has a pane in it) takes longer than any other.
    def self.frames_for(move)
      glass = move.kind != :drawer && move.door.respond_to?(:definition) &&
              move.door.definition.entities.any? { |entity| entity.respond_to?(:definition) && AttributeManager.role(entity) == 'door_glass' }
      # (a hydraulic bi-fold takes its time: the lower door has to fold over)
      frames = glass ? GLASS_FRAMES : FRAMES
      frames += BIFOLD_EXTRA_FRAMES if move.spec.respond_to?(:bifold) && move.spec.bifold
      frames
    rescue StandardError
      FRAMES
    end

    # The two doors of a bi-fold move as one: the lower one hangs from the upper one, so both take the same frames (a glass door takes longer than a
    # plain one, and the lower door would otherwise come away from the upper while it is still moving). Pure.
    def self.matched_frames(moves, frames)
      linked = moves.each_index.select { |i| moves[i].kind != :drawer && moves[i].spec.respond_to?(:bifold) && moves[i].spec.bifold }
      return frames if linked.empty?

      longest = linked.map { |i| frames[i] }.max
      frames.each_with_index.map { |count, i| linked.include?(i) ? longest : count }
    end

    def self.stop_current(model)
      return unless @current

      @current.finish
      model.active_view.animation = nil
      @current = nil
    rescue StandardError
      @current = nil
    end

    def self.finished(player)
      @current = nil if @current.equal?(player)
    end

    # Implements the Sketchup::Animation interface (SketchUp calls nextFrame
    # repeatedly until it returns false or stop is called).
    class Player
      def initialize(model, moves, operation_name)
        @model = model
        @moves = moves
        @operation_name = operation_name
        @frame = 0
        @done = false
        @frames = DoorAnimation.matched_frames(moves, moves.map { |move| DoorAnimation.frames_for(move) }) # each door takes the time its kind takes
        @frames = [FRAMES] if @frames.empty?
      end

      def start
        @model.start_operation(@operation_name, false)
        @started = true
        @model.active_view.animation = self
      end

      def nextFrame(view)
        return false if @done

        @frame += 1
        @started_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        apply(@frame)
        view.show_frame
        return true unless complete?

        finish
        false
      rescue StandardError => e
        warn "[Easy Cabinet] Animation frame failed: #{e.message}"
        finish
        false
      end

      # SketchUp calls this if the animation is interrupted (for example Esc).
      def stop
        finish
      end

      # Snaps every door to its final state, records it, and closes the undo step.
      def finish
        return if @done

        @done = true
        apply(@frames.max, true)
        @moves.each { |move| DoorAnimation.set_open(move.door, move.to.positive?) }
        @model.commit_operation if @started
      rescue StandardError => e
        warn "[Easy Cabinet] Could not finish door animation: #{e.message}"
        begin
          @model.abort_operation if @started
        rescue StandardError
          nil
        end
      ensure
        DoorAnimation.finished(self)
      end

      private

      # A bi-fold moves by the clock (as long as the real mechanism takes, whatever the frame rate), every other door by its frames.
      def bifold?(move)
        move.kind != :drawer && move.spec.respond_to?(:bifold) && move.spec.bifold ? true : false
      end

      def elapsed
        @started_at ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at : 0.0
      end

      def complete?
        frames_done = @moves.each_index.all? { |i| bifold?(@moves[i]) || @frame >= @frames[i] }
        clock_done = @moves.all? { |move| !bifold?(move) || elapsed >= DoorAnimation.bifold_seconds(move.to > move.from) }
        frames_done && clock_done
      end

      def apply(frame, final = false)
        @moves.each_with_index do |move, index|
          progress = if bifold?(move)
                       opening = move.to > move.from
                       openness = final ? (opening ? 1.0 : 0.0) : DoorAnimation.bifold_openness(elapsed, opening)
                       opening ? openness : 1.0 - openness
                     else
                       ease([frame.to_f / @frames[index], 1.0].min)
                     end
          fraction = move.from + ((move.to - move.from) * progress)
          move.door.transformation = if move.kind == :drawer
                                        DrawerAnimation.transformation(move.spec, move.depth, fraction)
                                      else
                                        DoorAnimation.transformation(move.spec, move.angle, fraction)
                                      end
        end
      end

      def ease(t)
        t * t * (3.0 - (2.0 * t)) # smoothstep: gentle start and stop
      end
    end

    # ---- opening-direction indicator ----------------------------------------

    ELEVATION_STANDOFF = 1.0 # mm in front of the door face, so the lines never z-fight

    # The FLOOR-level plan symbol's line segments [[x, y, z], [x, y, z]] in
    # millimetres, relative to the carcass base Z (the indicator container sits at
    # base Z). Per door: a short vertical mark at the hinge, a line from the hinge
    # to the free edge when closed, another when fully open, and the arc between
    # them showing the movement. (The other symbol, on the door itself, is
    # door_symbol_segments; the two are switched on and off independently.)
    def self.indicator_segments(doors, angle, base_z)
      shown = doors.reject { |door| %w[top fold].include?(door.hinge) || door.slide } # a lift-up door has no plan line, nor has a sliding door
      # one arrow per drawer column (stacked drawers share it)
      shown = shown.reject.with_index { |door, i| door.hinge == 'center' && shown.first(i).any? { |o| o.hinge == 'center' && o.offset[1] == door.offset[1] && o.extent[1] == door.extent[1] } }
      shown.flat_map { |door| plan_indicator(door, angle, base_z) }
    end

    # A short text that changes whenever the indicator would look different.
    # Base Z is left out on purpose: the indicator container moves with the toe
    # kick, so a change of toe-kick height must not rebuild the lines.
    def self.indicator_signature(doors, angle, base_z)
      shapes = doors.reject { |d| %w[top fold].include?(d.hinge) || d.slide }
                    .map { |d| [d.hinge, d.pivot[0], d.pivot[1], d.extent, (d.offset[2] - base_z).round(2)] }
      shapes.push(angle.to_f).inspect
    end

    # A drawer's plan symbol: an arrow from the middle of its front straight out, the way it slides.
    DRAWER_ARROW = 250.0
    def self.drawer_arrow(door, base_z)
      x = door.offset[0] + door.extent[0]
      y = door.offset[1] + (door.extent[1] / 2.0)
      z = -base_z
      tip = x + DRAWER_ARROW
      [[[x, y, z], [tip, y, z]], [[tip, y, z], [tip - 45.0, y - 30.0, z]], [[tip, y, z], [tip - 45.0, y + 30.0, z]]]
    end
    private_class_method :drawer_arrow

    def self.plan_indicator(door, angle, base_z)
      return drawer_arrow(door, base_z) if door.hinge == 'center'

      px, py, = door.pivot # (the leaves are drawn open at the angle asked, whatever the door itself opens to)
      thickness, width, = door.extent
      z = -base_z # the cabinet's floor (its Z = 0), relative to the container that sits at base Z
      direction = door.hinge == 'left' ? 1.0 : -1.0

      # Free-edge point relative to the hinge, halfway through the door thickness.
      # A corner door's local frame is turned by `rotation`, so turn the vector too.
      start = rotate([-thickness / 2.0, direction * width], door.rotation.to_f * Math::PI / 180.0)
      steps = [(angle.to_f / ARC_STEP_DEGREES).ceil, 3].max
      arc = (0..steps).map do |i|
        rotated = rotate(start, swing_radians(door.hinge, door.rotation, angle, i.to_f / steps))
        [px + rotated[0], py + rotated[1], z]
      end

      segments = [[[px, py, z], [px, py, z + (2 * HINGE_MARK)]]]
      segments << [[px, py, z], arc.first]
      segments << [[px, py, z], arc.last]
      arc.each_cons(2) { |a, b| segments << [a, b] }
      segments
    end
    private_class_method :plan_indicator

    # The dashed "door swing" symbol ON the door, in the door's OWN frame (origin
    # at the door's corner, X out of the face, Y across, Z up): two lines that
    # start at the hinge, halfway up, and run to the free edge's top and bottom
    # corners. It lives inside the door, so it swings with it, and because it is
    # in the door's own frame it is right for a corner unit's diagonal door too.
    # Returns [[[x, y, z], [x, y, z]], ...] in millimetres.
    def self.door_symbol_segments(door)
      thickness, width, height = door.extent
      x = thickness + ELEVATION_STANDOFF
      if door.respond_to?(:slide) && door.slide # a sliding door: an arrow along the way it runs
        tail = width * (door.slide.negative? ? 0.75 : 0.25)
        tip = width * (door.slide.negative? ? 0.25 : 0.75)
        mid = height / 2.0
        return [[[x, tail, mid], [x, tip, mid]], [[x, tip, mid], [x, tip + ((tail <=> tip) * 40.0), mid + 30.0]], [[x, tip, mid], [x, tip + ((tail <=> tip) * 40.0), mid - 30.0]]]
      end
      if %w[top fold].include?(door.hinge) # a lift-up door: from the middle of the top edge to the bottom corners
        apex = [x, width / 2.0, height]
        return [[apex, [x, 0.0, 0.0]], [apex, [x, width, 0.0]]]
      end

      if door.hinge == 'center' # a drawer front: a V pointing down from the top corners, the way a drawer is drawn on an elevation
        apex = [x, width / 2.0, 0.0]
        return [[apex, [x, 0.0, height]], [apex, [x, width, height]]]
      end

      hinge_y = door.hinge == 'left' ? 0.0 : width
      free_y = width - hinge_y
      apex = [x, hinge_y, height / 2.0]

      [[apex, [x, free_y, height]], [apex, [x, free_y, 0.0]]]
    end

    # Changes whenever the symbol would look different.
    def self.door_symbol_signature(door)
      [door.hinge, door.extent].inspect
    end

    def self.rotate(vector, radians)
      cos = Math.cos(radians)
      sin = Math.sin(radians)
      [(vector[0] * cos) - (vector[1] * sin), (vector[0] * sin) + (vector[1] * cos)]
    end
    private_class_method :rotate
  end
end
