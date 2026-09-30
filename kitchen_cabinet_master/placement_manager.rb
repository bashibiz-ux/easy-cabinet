# frozen_string_literal: true

module KitchenCabinetMaster
  # Decides where a new cabinet or filler is inserted.
  #
  #   Nothing selected      -> straight after the last cabinet or filler inserted
  #                            (at the model origin when there is none yet).
  #   An occupant selected  -> Selected End + Configured Gap = New Item Start,
  #                            measured along the selected item's own Y axis, so a
  #                            row keeps its direction, rotation and height. A
  #                            "selected occupant" is a cabinet or a filler (an end
  #                            panel is not part of a row, so it is never a chain anchor).
  #
  # A new item is NEVER placed on top of (overlapping) an existing cabinet, filler
  # or end panel. If the spot is taken, it slides along the row, past whatever is in
  # the way plus the configured gap, until it finds free space. Every occupant's
  # space is its stored envelope (envelope_depth / envelope_width / envelope_top,
  # written once when it is built), so this needs no per-kind knowledge and an open
  # door never blocks anything.
  module PlacementManager
    MAX_STEPS = 200

    # A corner unit that follows another item turns the row a quarter turn
    # clockwise (seen from above), so the row carries on along the next wall.
    CORNER_TURN_DEGREES = -90.0

    # Returns [entities, transformation] for a new CABINET.
    def self.target_for_new(model, params)
      corner = params['cabinet_category'].to_s == 'corner'
      target_row(model, params, CabinetLayout.envelope(params),
                 turn: corner ? CORNER_TURN_DEGREES : nil, own_width: params['width'].to_f)
    end

    # Returns [entities, transformation] for a new item of any kind, given its
    # own closed size [depth, width, top] in millimetres.
    #
    # `turn` (degrees about Z) rotates the new item as it joins the row: it takes
    # the slot after the selected item, then is turned about its own origin so
    # that its back lies along the far end of that slot and its own Y axis --
    # which the next item follows -- points along the new wall. That needs the
    # item's `own_width`, since a quarter turn swings it that far sideways.
    # Nothing selected: it follows the LAST cabinet or filler inserted (see
    # last_occupant); with none in the model yet, it goes at the origin unturned.
    def self.target_row(model, params, size, turn: nil, own_width: nil)
      selected = SelectionManager.selected_occupant(model) || last_occupant(model)
      entities = selected ? selected.parent.entities : model.active_entities
      gap = params['placement_gap'].to_f.mm

      transformation =
        if selected
          width = selected.get_attribute(AttributeManager::DICTIONARY, 'width').to_f
          slot = selected.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, width.mm + gap, 0))
          turn ? turned(slot, turn, own_width.to_f.mm) : slot
        else
          Geom::Transformation.new
        end

      [entities, clear_of_occupants(entities, transformation, size.map(&:mm), gap)]
    end

    # The cabinet or filler that was inserted most recently (highest 'sequence');
    # on a tie, the one added to the model last. Items from before sequence numbers
    # existed count as 0, so they come before anything inserted since. nil when the
    # model has none. An end panel or toe kick is not part of the row, so is skipped.
    def self.last_occupant(model)
      rows = model.active_entities.grep(Sketchup::ComponentInstance).select do |instance|
        AttributeManager.cabinet?(instance) || AttributeManager.part_kind(instance) == 'filler'
      end
      rows.each_with_index.max_by { |instance, index| [instance.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    # The cabinet or filler that was inserted FIRST (lowest 'sequence'), or nil: the
    # start of the row. What a toe kick starts at when nothing is selected.
    def self.first_occupant(model)
      rows = model.active_entities.grep(Sketchup::ComponentInstance).select do |instance|
        AttributeManager.cabinet?(instance) || AttributeManager.part_kind(instance) == 'filler'
      end
      rows.each_with_index.min_by { |instance, index| [instance.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    # The cabinet (not a filler) that was inserted most recently, or nil. What a
    # filler goes against when no cabinet is selected.
    def self.last_cabinet(model)
      cabinets = model.active_entities.grep(Sketchup::ComponentInstance).select { |i| AttributeManager.cabinet?(i) }
      cabinets.each_with_index.max_by { |i, index| [i.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    # `slot` moved to the far end of its own width, then turned by `degrees` about
    # the new origin. For -90 the item's back ends up on the far side of its slot.
    def self.turned(slot, degrees, width)
      far_end = slot * Geom::Transformation.translation(Geom::Vector3d.new(0, width, 0))
      far_end * Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1),
                                              degrees * Math::PI / 180.0)
    end
    private_class_method :turned

    # Slides `transformation` along its own Y axis until the candidate box no
    # longer overlaps any occupant in `entities`.
    def self.clear_of_occupants(entities, transformation, size, gap)
      others = existing_boxes(entities)
      return transformation if others.empty?

      MAX_STEPS.times do
        box = box_for(transformation, size)
        blocker = others.find { |other| overlap?(box, other) }
        return transformation unless blocker

        transformation = slide_past(transformation, blocker, gap)
      end
      raise 'There is no free space in the row for another item.'
    end
    private_class_method :clear_of_occupants

    # Would resizing `root` (an item already in the model) make it run into a
    # neighbour? True only when the NEW size collides and the size it has now does not,
    # so an edit is never blocked by an overlap that was already there (say, from a
    # cabinet the user moved by hand). Sizes are [depth, width, top] in mm.
    def self.crowds?(entities, root, transformation, new_size, old_size)
      collides?(entities, transformation, new_size, exclude: root) &&
        !collides?(entities, transformation, old_size, exclude: root)
    end

    # The axis-aligned box of every cabinet, filler and end panel in `entities`,
    # read straight from their stored envelope attributes (no recomputation).
    # `exclude`, when given, is left out (used when checking a part against
    # everything ELSE while updating that same part).
    def self.existing_boxes(entities, exclude: nil)
      occupants = entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.occupant?(instance) }
      occupants = occupants.reject { |instance| instance.equal?(exclude) } if exclude

      occupants.map do |instance|
        size = %w[envelope_depth envelope_width envelope_top].map do |key|
          instance.get_attribute(AttributeManager::DICTIONARY, key).to_f.mm
        end
        box_for(instance.transformation, size)
      end
    end

    # Does a candidate box (already positioned by `transformation`, own local size
    # in millimetres) overlap anything already in `entities`? Used for placements
    # that are NOT part of the row chain (an end panel goes exactly where it's
    # told, against its target's face, so it is checked rather than slid).
    def self.collides?(entities, transformation, size, exclude: nil)
      box = box_for(transformation, size.map(&:mm))
      existing_boxes(entities, exclude: exclude).any? { |other| overlap?(box, other) }
    end

    # The axis-aligned box (in the parent's coordinates) around an item's local
    # box [0..depth] x [0..width] x [0..top], top already including any lift (a
    # cabinet's toe-kick height, say).
    def self.box_for(transformation, size)
      corners = [0, size[0]].product([0, size[1]], [0, size[2]]).map do |x, y, z|
        transformation * Geom::Point3d.new(x, y, z)
      end
      xs = corners.map(&:x)
      ys = corners.map(&:y)
      zs = corners.map(&:z)
      { min: [xs.min, ys.min, zs.min], max: [xs.max, ys.max, zs.max], corners: corners }
    end

    # True when the boxes share volume. Touching faces (within 1 mm) do not count.
    def self.overlap?(first, second)
      tolerance = 1.0.mm
      (0..2).all? do |axis|
        first[:min][axis] < second[:max][axis] - tolerance && first[:max][axis] > second[:min][axis] + tolerance
      end
    end

    # Moves the candidate along its Y axis so it starts just after `blocker` (plus the gap).
    def self.slide_past(transformation, blocker, gap)
      axis = transformation.yaxis
      origin = transformation.origin
      start = (origin.x * axis.x) + (origin.y * axis.y) + (origin.z * axis.z)
      finish = blocker[:corners].map { |c| (c.x * axis.x) + (c.y * axis.y) + (c.z * axis.z) }.max
      distance = [finish - start + gap, 10.0.mm].max # always make progress

      move = Geom::Vector3d.new(axis.x * distance, axis.y * distance, axis.z * distance)
      Geom::Transformation.translation(move) * transformation
    end
    private_class_method :slide_past
  end
end
