# frozen_string_literal: true

module KitchenCabinetMaster
  # Draws SketchUp dimensions on cabinets (see Dimensioning for which): on the selected cabinets, or every cabinet when none is selected; one Undo
  # step. They sit on a tag of their own, "Kitchen Dimensions", and are marked so that Remove Dimensions takes away only these.
  module DimensionManager
    TAG = 'Kitchen Dimensions'
    MARK = 'kcm_dimension'

    def self.perform(action, _raw)
      case action
      when 'add_dimensions' then add_action
      when 'remove_dimensions' then remove_action
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    def self.add_action
      model = Sketchup.active_model
      chosen = model.selection.select { |entity| AttributeManager.cabinet?(entity) }
      targets = chosen.empty? ? model.entities.select { |entity| AttributeManager.cabinet?(entity) } : chosen
      return Response.fail('There are no cabinets to dimension: insert a cabinet first.') if targets.empty?

      count = 0
      model.start_operation('Add Dimensions', true)
      begin
        count = add(model, targets)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      Response.ok("#{count} dimension#{'s' unless count == 1} added on the tag \"#{TAG}\".", { 'count' => count })
    end
    private_class_method :add_action

    def self.remove_action
      model = Sketchup.active_model
      found = dimensions_in(model)
      return Response.ok('There are no dimensions of the extension to remove.') if found.empty?

      model.start_operation('Remove Dimensions', true)
      found.each { |dimension| dimension.erase! if dimension.valid? }
      model.commit_operation
      Response.ok("#{found.length} dimension#{'s' unless found.length == 1} removed.")
    end
    private_class_method :remove_action

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
          tall: category == 'tall' }
      end
    end
    private_class_method :items_for

    def self.point(values) = Geom::Point3d.new(values[0].mm, values[1].mm, values[2].mm)
    def self.vector(values) = Geom::Vector3d.new(values[0].mm, values[1].mm, values[2].mm)
    private_class_method :point, :vector
  end
end