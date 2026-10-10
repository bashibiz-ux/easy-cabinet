# frozen_string_literal: true

module KitchenCabinetMaster
  # Draws SketchUp dimensions on cabinets (see Dimensioning for which). They sit on a tag of their own, "Kitchen Dimensions", and are marked so that
  # only these are taken away again. The Dimensions tick of the Presets (see LiveParts) draws them for every cabinet and keeps them up to date.
  module DimensionManager
    TAG = 'Kitchen Dimensions'
    MARK = 'kcm_dimension'

    # The dimensions for these cabinets (inside an operation). => how many were drawn
    def self.add(model, cabinets)
      tag = model.layers[TAG] || model.layers.add(TAG)
      Dimensioning.lines(items_for(cabinets)).sum do |line|
        dimension = model.entities.add_dimension_linear(point(line[:from]), point(line[:to]), vector(line[:offset]))
        dimension.layer = tag
        dimension.set_attribute(AttributeManager::DICTIONARY, MARK, true)
        1
      end
    end

    # Takes away every dimension this extension drew (inside an operation).
    def self.remove_all(model)
      dimensions_in(model).each { |dimension| dimension.erase! if dimension.valid? }
    end

    def self.dimensions_in(model)
      model.entities.grep(Sketchup::DimensionLinear).select { |dimension| dimension.get_attribute(AttributeManager::DICTIONARY, MARK) == true }
    end
    private_class_method :dimensions_in

    def self.items_for(cabinets)
      cabinets.filter_map do |cabinet|
        stored = AttributeManager.read(cabinet)
        next unless stored

        category = stored['cabinet_category'].to_s
        transformation = cabinet.transformation
        origin = transformation.origin
        { x: origin.x.to_mm, y: origin.y.to_mm, z: origin.z.to_mm, hx: transformation.yaxis.x, hy: transformation.yaxis.y, fx: transformation.xaxis.x, fy: transformation.xaxis.y,
          width: stored['width'].to_f, depth: cabinet.get_attribute(AttributeManager::DICTIONARY, 'envelope_depth').to_f,
          base_z: category == 'wall' ? stored['base_z'].to_f : origin.z.to_mm, top: cabinet.get_attribute(AttributeManager::DICTIONARY, 'envelope_top').to_f + origin.z.to_mm,
          tall: category == 'tall', island: !cabinet.get_attribute(AttributeManager::DICTIONARY, 'island_seating').nil?,
          overhang: cabinet.get_attribute(AttributeManager::DICTIONARY, 'island_seating').to_f }
      end
    end
    private_class_method :items_for

    def self.point(values) = Geom::Point3d.new(values[0].mm, values[1].mm, values[2].mm)
    def self.vector(values) = Geom::Vector3d.new(values[0].mm, values[1].mm, values[2].mm)
    private_class_method :point, :vector
  end
end