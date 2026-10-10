# frozen_string_literal: true

module KitchenCabinetMaster
  # A back panel for an island: a board in the door material closing the room side of the island units, from the floor up to the underside
  # of the worktop. Pure maths in `box` (millimetres, in the frame of the island's first unit: Y along the island, X from its back to its front),
  # `build` draws it.
  module IslandBackPanel
    THICKNESS = 18.0
    DEFAULT_HEIGHT = 860.0 # when the height of the units is not known

    # => [[x, y, z], [dx, dy, dz]] of the board, standing against the back of the units.
    def self.box(spec)
      height = spec[:height].to_f.positive? ? spec[:height].to_f : DEFAULT_HEIGHT
      [[-THICKNESS, 0.0, 0.0], [THICKNESS, spec[:length].to_f, height]]
    end

    # One group "Island Back Panel" in the model, placed by `frame` (the transformation of the island's first unit).
    def self.build(model, entities, frame, spec)
      group = entities.add_group
      group.name = 'Island Back Panel'
      (x, y, z), (dx, dy, dz) = box(spec)
      face = group.entities.add_face([x.mm, y.mm, z.mm], [(x + dx).mm, y.mm, z.mm], [(x + dx).mm, (y + dy).mm, z.mm], [x.mm, (y + dy).mm, z.mm])
      face.reverse! if face.normal.z.negative?
      face.pushpull(dz.mm)
      material = MaterialManager.ensure_material(model, spec[:material].to_s)
      group.material = material if material
      group.transformation = frame
      group
    rescue StandardError
      group.erase! if group&.valid? # (a half-made group is not left behind)
      raise
    end
  end
end