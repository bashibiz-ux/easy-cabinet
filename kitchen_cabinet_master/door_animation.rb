# frozen_string_literal: true

module KitchenCabinetMaster
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
    FRAMES = 18
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

    def self.swing(spec, angle, fraction)
      Geom::Transformation.rotation(
        Geom::Point3d.new(*spec.pivot.map(&:mm)),
        Geom::Vector3d.new(0, 0, 1),
        swing_radians(spec.hinge, spec.rotation, angle, fraction)
      )
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
        warn "[Kitchen Cabinet Master] Animation failed, applying instantly: #{e.message}"
        player.finish
      end
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
      end

      def start
        @model.start_operation(@operation_name, false)
        @started = true
        @model.active_view.animation = self
      end

      def nextFrame(view)
        return false if @done

        @frame += 1
        apply(ease(@frame.to_f / FRAMES))
        view.show_frame
        return true if @frame < FRAMES

        finish
        false
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Animation frame failed: #{e.message}"
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
        apply(1.0)
        @moves.each { |move| DoorAnimation.set_open(move.door, move.to.positive?) }
        @model.commit_operation if @started
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Could not finish door animation: #{e.message}"
        begin
          @model.abort_operation if @started
        rescue StandardError
          nil
        end
      ensure
        DoorAnimation.finished(self)
      end

      private

      def apply(progress)
        @moves.each do |move|
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
    # them showing the movement. Empty when `style` is 'elevation' (the symbol is
    # then drawn on each door instead, see door_symbol_segments).
    def self.indicator_segments(doors, angle, base_z, style = 'plan')
      return [] unless plan_symbol?(style)

      doors.flat_map { |door| plan_indicator(door, angle, base_z) }
    end

    # A short text that changes whenever the indicator would look different.
    # Base Z is left out on purpose: the indicator container moves with the toe
    # kick, so a change of toe-kick height must not rebuild the lines.
    def self.indicator_signature(doors, angle, base_z, style = 'plan')
      shapes = doors.map { |d| [d.hinge, d.pivot[0], d.pivot[1], d.extent, (d.offset[2] - base_z).round(2)] }
      shapes.push(angle.to_f, style.to_s).inspect
    end

    def self.plan_indicator(door, angle, base_z)
      px, py, = door.pivot
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
      hinge_y = door.hinge == 'left' ? 0.0 : width
      free_y = width - hinge_y
      apex = [x, hinge_y, height / 2.0]

      [[apex, [x, free_y, height]], [apex, [x, free_y, 0.0]]]
    end

    # Changes whenever the symbol would look different.
    def self.door_symbol_signature(door)
      [door.hinge, door.extent].inspect
    end

    # Does this style draw a symbol on the door itself?
    def self.door_symbol?(style)
      %w[elevation both].include?(style.to_s)
    end

    # Does this style draw the floor-level plan symbol?
    def self.plan_symbol?(style)
      style.to_s != 'elevation'
    end

    def self.rotate(vector, radians)
      cos = Math.cos(radians)
      sin = Math.sin(radians)
      [(vector[0] * cos) - (vector[1] * sin), (vector[0] * sin) + (vector[1] * cos)]
    end
    private_class_method :rotate
  end
end
