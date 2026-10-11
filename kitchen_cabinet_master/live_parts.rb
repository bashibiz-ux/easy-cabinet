# frozen_string_literal: true

module KitchenCabinetMaster
  # Parts that follow the cabinets by themselves while their tick in the Presets is on: the dimensions, and a side panel on every exposed side.
  # The ticks are kept in the model. After every change made through the panel (a cabinet inserted, changed, deleted, the kitchen designed ...) they
  # are drawn again, in a step that joins the change's own Undo step.
  module LiveParts
    DICTIONARY = 'KitchenCabinetMaster'
    KEY_DIMENSIONS = 'live_dimensions'
    KEY_SIDE_PANELS = 'live_side_panels'
    KEY_SIDE_VALUES = 'live_side_values'
    AUTO = 'auto_exposed' # marks a side panel this made (the ones you inserted yourself are never touched)

    def self.perform(action, raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      on = [true, 'true', 1, '1'].include?(raw['enabled'])
      case action
      when 'set_live_dimensions'
        model.set_attribute(DICTIONARY, KEY_DIMENSIONS, on)
        apply(model, "#{on ? 'Show' : 'Hide'} Dimensions") { sync_dimensions(model) }
        Response.ok(on ? 'Dimensions are on: they follow the cabinets.' : 'Dimensions are off.')
      when 'set_live_side_panels'
        model.set_attribute(DICTIONARY, KEY_SIDE_PANELS, on)
        model.set_attribute(DICTIONARY, KEY_SIDE_VALUES, JSON.generate(raw['values'])) if raw['values'].is_a?(Hash)
        apply(model, "#{on ? 'Place' : 'Remove'} Side Panels") { sync_side_panels(model) }
        Response.ok(on ? 'Side panels on every exposed side are on: they follow the cabinets.' : 'The side panels placed by the tick are taken away.')
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    def self.dimensions? = Sketchup.active_model.get_attribute(DICTIONARY, KEY_DIMENSIONS, false) == true
    # On to begin with: a cabinet is inserted with its side panels (the end of a row; against a wall, a filler instead). The tick turns it off.
    def self.side_panels? = Sketchup.active_model.get_attribute(DICTIONARY, KEY_SIDE_PANELS, true) == true

    # After an action of the panel: draw again what the ticks keep up. Quietly: nothing changes when no tick is on.
    def self.refresh
      model = Sketchup.active_model
      return unless model && (dimensions? || side_panels?)

      apply(model, 'Refresh Dimensions and Side Panels') do
        sync_side_panels(model) # (first: the dimensions are of the units)
        sync_dimensions(model)
      end
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not refresh the live parts: #{e.message}"
    end

    # One step of Undo that joins the one before it.
    def self.apply(model, name)
      model.start_operation(name, true, false, true)
      begin
        yield
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
    end
    private_class_method :apply

    def self.sync_dimensions(model)
      DimensionManager.remove_all(model)
      return unless dimensions?

      cabinets = model.entities.select { |entity| AttributeManager.cabinet?(entity) }
      DimensionManager.add(model, cabinets) unless cabinets.empty?
    end
    private_class_method :sync_dimensions

    def self.sync_side_panels(model)
      PartManager.send(:remove_auto_panels, model)
      return unless side_panels?

      values = begin
        JSON.parse(model.get_attribute(DICTIONARY, KEY_SIDE_VALUES, '{}'))
      rescue JSON::ParserError
        {}
      end
      PartManager.send(:place_auto_panels, model, values)
    end
    private_class_method :sync_side_panels
  end
end