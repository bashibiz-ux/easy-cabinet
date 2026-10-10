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
  # or side panel. If the spot is taken, it slides along the row, past whatever is in
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
    class << self
      # After target_for_new: where the 50 mm gap beside a blind corner is, so a filler can fill it: :before the new
      # cabinet (blind part on the right) or :after it (on the left); nil when there is none.
      attr_reader :blind_gap
    end

    def self.target_for_new(model, params)
      @blind_gap = nil
      corner = CabinetLayout.corner?(params)
      target_row(model, params, CabinetLayout.envelope(params),
                 turn: corner ? CORNER_TURN_DEGREES : nil, own_width: corner ? CabinetLayout.envelope(params)[0] : params['width'].to_f,
                 z_mm: params['cabinet_category'].to_s == 'wall' ? wall_origin_z(model, params) : 0.0,
                 wall: params['cabinet_category'].to_s == 'wall', base: params['cabinet_category'].to_s == 'base')
    end

    # Only a wall unit hangs in the air: base, tall and corner units always start on
    # the floor, even when the item they follow is a wall unit up on the wall.
    #
    # A wall unit hangs in the air, and its TOP is what stays put when its height
    # changes (a taller one grows downwards, see CabinetManager.update). Where a new
    # one starts:
    #   * a tall unit in the model: its top lines up with the tall unit's top;
    #   * else a wall unit already in the row: tops line up with it;
    #   * else above the base unit it follows: its bottom is WALL_ABOVE_BASE_MM above
    #     that unit's top;
    #   * else (nothing in the model yet) where it would be over a standard base unit.
    # Returns the Z of its origin (its bottom), in millimetres.
    WALL_ABOVE_BASE_MM = 600.0
    DEFAULT_WALL_BOTTOM_MM = 1480.0 # 100 toe kick + 780 base unit + 600

    def self.wall_origin_z(model, params, selected = nil)
      selected ||= SelectionManager.selected_occupant(model) || last_occupant(model)
      height = params['height'].to_f

      tall = latest_cabinet(model) { |stored| stored['cabinet_category'] == 'tall' }
      return top_of_item(tall) - height if tall

      return top_of_item(selected) - height if selected && category_of(selected) == 'wall'

      base = (selected if selected && category_of(selected) != 'wall') || latest_cabinet(model) { |stored| stored['cabinet_category'] != 'wall' }
      return top_of_item(base) + WALL_ABOVE_BASE_MM if base

      DEFAULT_WALL_BOTTOM_MM
    end

    # The most recently inserted cabinet whose stored parameters satisfy the block.
    def self.latest_cabinet(model)
      dictionary = AttributeManager::DICTIONARY
      found = model.active_entities.grep(Sketchup::ComponentInstance).select do |instance|
        AttributeManager.cabinet?(instance) && yield(AttributeManager.read(instance) || {})
      end
      found.each_with_index.max_by { |instance, index| [instance.get_attribute(dictionary, 'sequence').to_i, index] }&.first
    end
    private_class_method :latest_cabinet

    def self.category_of(item)
      dictionary = AttributeManager::DICTIONARY
      item.get_attribute(dictionary, 'cabinet_category') || item.get_attribute(dictionary, 'target_category')
    end
    private_class_method :category_of

    # World height of an item's top, in millimetres: where it stands plus its own top.
    def self.top_of_item(item)
      item.transformation.origin.z.to_mm + item.get_attribute(AttributeManager::DICTIONARY, 'top_z').to_f
    end
    private_class_method :top_of_item

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
    def self.target_row(model, params, size, turn: nil, own_width: nil, z_mm: nil, wall: false, base: false)
      chosen = SelectionManager.selected_occupant(model)
      selected = chosen || last_occupant(model)
      # The first wall unit goes above the START of the row, not after its last unit; the
      # next ones then follow it.
      row_start = nil
      # A base unit (or filler, or corner) selected: the wall unit goes directly above it.
      # A wall unit selected: a new base unit goes directly below it, on the floor.
      if base && chosen && category_of(chosen).to_s == 'wall'
        row_start = chosen
      elsif wall && chosen && !%w[wall tall].include?(category_of(chosen).to_s)
        row_start = chosen
      elsif wall && !chosen
        last_wall = last_occupant(model) { |item| category_of(item) == 'wall' }
        if last_wall
          selected = last_wall
        elsif selected
          row_start = first_occupant(model)
        end
      end
      entities = selected ? selected.parent.entities : model.active_entities
      gap = params['placement_gap'].to_f.mm

      transformation =
        if row_start
          turn ? turned(row_start.transformation, turn, own_width.to_f.mm) : row_start.transformation
        elsif selected
          width = selected.get_attribute(AttributeManager::DICTIONARY, 'width').to_f
          slot = selected.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, width.mm + gap, 0))
          if turn
            turned(slot, turn, own_width.to_f.mm)
          else
            beside_blind(selected, params) || slot
          end
        else
          Geom::Transformation.new
        end

      # Every unit goes at its own height, not the row's: a wall unit up on the wall,
      # everything else on the floor.
      if z_mm
        lift = z_mm.mm - transformation.origin.z
        transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, lift)) * transformation
      end

      [entities, clear_of_occupants(entities, transformation, size.map(&:mm), gap)]
    end

    # The cabinet or filler that was inserted most recently (highest 'sequence');
    # on a tie, the one added to the model last. Items from before sequence numbers
    # existed count as 0, so they come before anything inserted since. nil when the
    # model has none. An side panel or toe kick is not part of the row, so is skipped.
    def self.last_occupant(model)
      rows = model.active_entities.grep(Sketchup::ComponentInstance).select do |instance|
        (AttributeManager.cabinet?(instance) || AttributeManager.part_kind(instance) == 'filler') && (!block_given? || yield(instance))
      end
      rows.each_with_index.max_by { |instance, index| [instance.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    # The cabinet or filler that was inserted FIRST (lowest 'sequence'), or nil: the
    # start of the row. What a toe kick starts at when nothing is selected.
    def self.first_occupant(model)
      rows = model.active_entities.grep(Sketchup::ComponentInstance).select do |instance|
        (AttributeManager.cabinet?(instance) || AttributeManager.part_kind(instance) == 'filler') && (!block_given? || yield(instance))
      end
      rows.each_with_index.min_by { |instance, index| [instance.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    # The cabinet (not a filler) that was inserted most recently, or nil. What a
    # filler goes against when no cabinet is selected.
    def self.last_cabinet(model)
      cabinets = model.active_entities.grep(Sketchup::ComponentInstance).select { |i| AttributeManager.cabinet?(i) }
      cabinets.each_with_index.max_by { |i, index| [i.get_attribute(AttributeManager::DICTIONARY, 'sequence').to_i, index] }&.first
    end

    BLIND_CLEARANCE_MM = 50.0 # a cabinet after a blind corner stands this far from the blind panel

    # What follows a blind corner is turned towards its blind side, so the row carries on along the wall there, and
    # starts 50 mm beyond the blind panel (measured from the front of the corner unit). nil when `selected` is not a
    # blind corner. The blind part is at the right end with Door Opening Direction "left", else at the left end.
    def self.beside_blind(selected, params)
      dictionary = AttributeManager::DICTIONARY
      return nil unless selected.get_attribute(dictionary, 'corner_style') == 'blind'

      right_end = selected.get_attribute(dictionary, 'door_opening_direction').to_s != 'right'
      @blind_gap = right_end ? :before : :after
      width = selected.get_attribute(dictionary, 'width').to_f
      shift = selected.get_attribute(dictionary, 'envelope_depth').to_f + BLIND_CLEARANCE_MM
      axis = Geom::Vector3d.new(0, 0, 1)
      if right_end
        # its back on the wall at the right end, running out along the next wall, clear of the blind panel
        selected.transformation * Geom::Transformation.translation(Geom::Vector3d.new(0, width.mm, 0)) *
          Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), axis, CORNER_TURN_DEGREES * Math::PI / 180.0) *
          Geom::Transformation.translation(Geom::Vector3d.new(0, shift.mm, 0))
      else
        # turned the other way at the left end: its own width then runs backwards, so it starts a width further out
        selected.transformation * Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), axis, -CORNER_TURN_DEGREES * Math::PI / 180.0) *
          Geom::Transformation.translation(Geom::Vector3d.new(0, -(shift + params['width'].to_f).mm, 0))
      end
    end
    private_class_method :beside_blind

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
    # `also` is a neighbour that is being made room for (shrunk), so it is not in the way.
    def self.crowds?(entities, root, transformation, new_size, old_size, also: nil)
      collides?(entities, transformation, new_size, exclude: [root, also]) &&
        !collides?(entities, transformation, old_size, exclude: [root, also])
    end

    # The axis-aligned box of every cabinet, filler and side panel in `entities`,
    # read straight from their stored envelope attributes (no recomputation).
    # `exclude`, when given, is left out (used when checking a part against
    # everything ELSE while updating that same part).
    def self.existing_boxes(entities, exclude: nil)
      occupants = entities.grep(Sketchup::ComponentInstance).select { |instance| AttributeManager.occupant?(instance) }
      left_out = [exclude].flatten.compact
      occupants = occupants.reject { |instance| left_out.any? { |other| other.equal?(instance) } } unless left_out.empty?

      occupants.map do |instance|
        size = %w[envelope_depth envelope_width envelope_top].map do |key|
          instance.get_attribute(AttributeManager::DICTIONARY, key).to_f.mm
        end
        box_for(instance.transformation, size)
      end
    end

    # Does a candidate box (already positioned by `transformation`, own local size
    # in millimetres) overlap anything already in `entities`? Used for placements
    # that are NOT part of the row chain (an side panel goes exactly where it's
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
