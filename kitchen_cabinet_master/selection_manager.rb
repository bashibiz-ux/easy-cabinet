# frozen_string_literal: true

module KitchenCabinetMaster
  # Knows which cabinet is "the selected cabinet" and keeps the HTML panel in
  # step with the SketchUp selection:
  #   1. identify the cabinet's unique ID
  #   2. read its Attribute Dictionary
  #   3. push the parameters to the panel, which loads them into the form
  module SelectionManager
    # Fires on every selection change in the model.
    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(_selection)
        SelectionManager.selection_changed
      end

      def onSelectionCleared(_selection)
        SelectionManager.selection_changed
      end

      def onSelectionAdded(_selection, _element)
        SelectionManager.selection_changed
      end

      def onSelectionRemoved(_selection, _element)
        SelectionManager.selection_changed
      end
    end

    # Makes sure the observer follows whichever model is active.
    class AppWatcher < Sketchup::AppObserver
      def expectsStartupModelNotifications
        true
      end

      def onNewModel(model)
        SelectionManager.attach(model)
      end

      def onOpenModel(model)
        SelectionManager.attach(model)
      end

      def onActivateModel(model)
        SelectionManager.attach(model)
      end
    end

    # Call once when the extension loads.
    def self.install
      @attached = {}
      @selection_watcher = SelectionWatcher.new
      @app_watcher = AppWatcher.new
      Sketchup.add_observer(@app_watcher)
      attach(Sketchup.active_model)
    end

    def self.attach(model)
      return unless model

      key = model.guid
      return if @attached[key]

      model.selection.add_observer(@selection_watcher)
      @attached[key] = true    end

    # The single cabinet the user has selected, or nil.
    # Also works while the user is editing inside a cabinet (double-clicked into it).
    def self.selected_cabinet(model)
      cabinets = model.selection.select { |entity| AttributeManager.cabinet?(entity) }
      return cabinets.first if cabinets.length == 1

      path = model.active_path
      path&.reverse_each { |entity| return entity if AttributeManager.cabinet?(entity) }
      nil
    end

    # A cabinet or a FILLER (an "occupant" that can anchor the next item in a
    # row). An side panel is never a chain anchor, since it isn't part of the row.
    def self.selected_occupant(model)
      found = model.selection.select { |e| AttributeManager.cabinet?(e) || AttributeManager.part_kind(e) == 'filler' }
      return found.first if found.length == 1

      path = model.active_path
      path&.reverse_each { |e| return e if AttributeManager.cabinet?(e) || AttributeManager.part_kind(e) == 'filler' }
      nil
    end

    # The single filler or side panel the user has selected, or nil.
    def self.selected_part(model)
      found = model.selection.select { |e| AttributeManager.part?(e) }
      found.length == 1 ? found.first : nil
    end

    # What Open / Close / Toggle should act on:
    #   * one or more selected doors (each door is independently selectable), or
    #   * every door of the selected cabinet.
    # Returns { cabinet:, doors:, explicit: } or nil when no cabinet is involved.
    # What Open / Close / Toggle should act on: the doors AND drawers selected
    # directly, or every door and drawer of the selected cabinet if none are.
    def self.selected_doors(model)
      cabinet = selected_cabinet(model)
      return nil unless cabinet

      picked = model.selection.select { |entity| openable?(entity) }
      explicit = !picked.empty?
      { cabinet: cabinet, doors: explicit ? picked : CabinetGenerator.openables_of(cabinet), explicit: explicit }
    end

    def self.openable?(entity)
      return false unless entity.respond_to?(:get_attribute)

      role = AttributeManager.role(entity).to_s
      role.start_with?(CabinetGenerator::DOOR_PREFIX) || role.start_with?(CabinetGenerator::DRAWER_PREFIX)
    end

    # Selects a cabinet and tells the panel, without triggering intermediate updates.
    def self.select(cabinet)
      model = Sketchup.active_model
      suspend do
        model.selection.clear
        model.selection.add(cabinet)
      end
      push_selection(model)
    end

    # Tells the panel about the current selection (used after Update and Delete):
    # a cabinet, a part (filler / side panel), or nothing.
    def self.push_selection(model = Sketchup.active_model)
      cabinet = selected_cabinet(model)
      if cabinet
        DialogManager.push('cabinet_selected', AttributeManager.read(cabinet))
        return
      end

      part = selected_part(model)
      if part
        DialogManager.push('part_selected', AttributeManager.read(part))
      else
        DialogManager.push('cabinet_cleared')
      end
    end

    # Runs a block with selection notifications muted (our own edits must not
    # flood the panel with half-finished states).
    def self.suspend
      previous = @suspended
      @suspended = true
      yield
    ensure
      @suspended = previous
    end

    # True while one of our own edits is running (see `suspend`).
    def self.suspended?
      @suspended ? true : false
    end

    def self.selection_changed
      return if @suspended

      push_selection
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Selection update failed: #{e.message}"
    end
  end
end
