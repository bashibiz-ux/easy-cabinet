module KitchenCabinet
  class CabinetManager
    DICT = CabinetGenerator::DICT
    attr_accessor :ui

    def initialize
      @model = Sketchup.active_model
      @animation = {}
      install_selection_observer
    end

    def parametric?(entity)
      entity.is_a?(Sketchup::ComponentInstance) && entity.definition.get_attribute(DICT, 'is_parametric', false)
    end

    def selected_cabinet
      sel = @model.selection.to_a
      ent = sel.find { |e| parametric?(e) }
      return ent if ent
      # Allow a child component to resolve to its parametric root.
      child = sel.find { |e| e.is_a?(Sketchup::ComponentInstance) }
      return nil unless child
      parent = child.parent
      nil unless parent
    end

    def all_cabinets
      @model.entities.grep(Sketchup::ComponentInstance).select { |i| parametric?(i) }
    end

    def next_id
      nums = all_cabinets.map { |i| i.definition.get_attribute(DICT, 'cabinet_id', '').to_s[/\d+/].to_i }.compact
      n = nums.max.to_i + 1
      format('CABINET_%03d', n)
    end

    def params_for(instance)
      return nil unless parametric?(instance)
      JSON.parse(instance.definition.get_attribute(DICT, 'params_json', '{}'))
    rescue JSON::ParserError
      CabinetGenerator.defaults
    end

    def create(params)
      p = CabinetGenerator.normalize(params)
      id = next_id
      CabinetGenerator.validate!(p)
      @model.start_operation('Insert Kitchen Cabinet', true)
      begin
        defn = @model.definitions.add("KC_#{id}")
        CabinetGenerator.build(defn, p, id)
        instance = @model.entities.add_instance(defn, placement_transform(p))
        instance.set_attribute(DICT, 'cabinet_id', id)
        instance.set_attribute(DICT, 'is_parametric', true)
        @model.selection.clear
        @model.selection.add(instance)
        @model.commit_operation
        instance
      rescue => e
        @model.abort_operation
        raise e
      end
    end

    def update(instance, params)
      raise ArgumentError, 'Select a parametric cabinet first.' unless parametric?(instance)
      p = CabinetGenerator.normalize(params)
      id = instance.definition.get_attribute(DICT, 'cabinet_id', next_id)
      @model.start_operation('Update Kitchen Cabinet', true)
      begin
        CabinetGenerator.build(instance.definition, p, id)
        instance.set_attribute(DICT, 'cabinet_id', id)
        instance.set_attribute(DICT, 'is_parametric', true)
        @model.commit_operation
        instance
      rescue => e
        @model.abort_operation
        raise e
      end
    end

    def duplicate(instance)
      raise ArgumentError, 'Select a parametric cabinet first.' unless parametric?(instance)
      p = params_for(instance)
      p['placement_gap'] = p['placement_gap'].to_f
      create(p)
    end

    def delete(instance)
      raise ArgumentError, 'Select a parametric cabinet first.' unless parametric?(instance)
      @model.start_operation('Delete Kitchen Cabinet', true)
      instance.erase!
      @model.commit_operation
    end

    def placement_transform(p)
      selected = selected_cabinet
      if selected && !selected.deleted?
        bb = selected.bounds
        end_y = bb.max.y
        gap = p['placement_gap'].to_f.mm
        Geom::Transformation.translation([bb.min.x, end_y + gap, bb.min.z])
      else
        Geom::Transformation.translation([0,0,0])
      end
    end

    def select(instance)
      return unless instance && !instance.deleted?
      @model.selection.clear
      @model.selection.add(instance)
      @ui&.load_instance(instance)
    end

    def animate_doors(instance, open = true)
      raise ArgumentError, 'Select a parametric cabinet first.' unless parametric?(instance)
      angle = params_for(instance)['opening_angle'].to_f
      @model.start_operation(open ? 'Open Cabinet Door' : 'Close Cabinet Door', true)
      begin
        doors = instance.definition.entities.grep(Sketchup::ComponentInstance).select { |e| e.get_attribute(DICT, 'part_type') == 'door' }
        doors.each do |door|
          animate_door(instance, door, open, angle)
        end
        @model.commit_operation
      rescue => e
        @model.abort_operation
        raise e
      end
    end

    def animate_door(root, door, open, angle_deg)
      base = Geom::Transformation.new(door.get_attribute(DICT, 'base_transform')) rescue door.transformation
      hinge = door.get_attribute(DICT, 'hinge', 'left').to_sym
      sign = hinge == :left ? 1.0 : -1.0
      target = open ? sign * angle_deg.degrees : 0.0
      pivot = Geom::Point3d.new(0,0,0)
      rot = Geom::Transformation.rotation(pivot, Geom::Vector3d.new(0,0,1), target)
      door.transformation = base * rot
      door.set_attribute(DICT, 'open', open)
      door.set_attribute(DICT, 'opening_angle', angle_deg)
    end

    def visibility(instance, key, value)
      p = params_for(instance)
      p[key] = !!value
      update(instance, p)
    end

    def materials
      @model.materials.map(&:name).sort
    end

    def install_selection_observer
      @model.selection.add_observer(SelectionObserver.new(self))
    end

    class SelectionObserver < Sketchup::SelectionObserver
      def initialize(manager); @manager = manager; end
      def onSelectionBulkChange(selection)
        ent = selection.find { |e| @manager.parametric?(e) }
        @manager.ui&.load_instance(ent) if ent
      end
      def onSelectionCleared(selection); @manager.ui&.selection_cleared; end
      def onSelectionAdded(selection, entity); @manager.ui&.load_instance(entity) if @manager.parametric?(entity); end
    end
  end
end
