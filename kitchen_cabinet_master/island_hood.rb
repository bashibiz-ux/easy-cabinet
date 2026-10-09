# frozen_string_literal: true

module KitchenCabinetMaster
  # A cooker hood hung from the ceiling over an island's hob: a canopy over the hob and a square chimney up to the ceiling. Pure maths in
  # `boxes` (millimetres, in the frame of the island's first unit: Y along the island, X from its back to its front), `build` draws them.
  module IslandHood
    BOTTOM = 1650.0     # the underside of the canopy above the floor (the hob is at 900)
    CANOPY_HEIGHT = 150.0
    CANOPY_DEPTH = 600.0
    CHIMNEY = 300.0
    ISLAND_DEPTH = 580.0
    MATERIAL = 'Stainless Steel'

    # => [[name, [x, y, z], [dx, dy, dz]]]
    def self.boxes(hood)
      width = [hood[:width].to_f + 300.0, 900.0].max
      centre = hood[:start].to_f + (hood[:width].to_f / 2.0)
      cx = ISLAND_DEPTH / 2.0
      top = BOTTOM + CANOPY_HEIGHT
      out = [['Island Hood Canopy', [cx - (CANOPY_DEPTH / 2.0), centre - (width / 2.0), BOTTOM], [CANOPY_DEPTH, width, CANOPY_HEIGHT]]]
      ceiling = hood[:top].to_f
      out << ['Island Hood Chimney', [cx - (CHIMNEY / 2.0), centre - (CHIMNEY / 2.0), top], [CHIMNEY, CHIMNEY, ceiling - top]] if ceiling - top >= 50.0
      out
    end

    # One group "Island Hood" in the model, placed by `frame` (the transformation of the island's first unit).
    def self.build(model, entities, frame, hood)
      group = entities.add_group
      group.name = 'Island Hood'
      material = MaterialManager.ensure_material(model, hood[:material] || MATERIAL)
      boxes(hood).each do |name, (x, y, z), (dx, dy, dz)|
        part = group.entities.add_group
        part.name = name
        face = part.entities.add_face([x.mm, y.mm, z.mm], [(x + dx).mm, y.mm, z.mm], [(x + dx).mm, (y + dy).mm, z.mm], [x.mm, (y + dy).mm, z.mm])
        face.reverse! if face.normal.z.negative?
        face.pushpull(dz.mm)
        part.material = material if material
      end
      group.transformation = frame
      group
    end
  end
end
