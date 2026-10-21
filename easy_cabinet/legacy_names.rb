# frozen_string_literal: true

require 'fileutils'

module EasyCabinet
  # The extension was called Kitchen Cabinet Master and kept its things under that name: the attributes it puts on the parts of a model, the preferences it keeps in
  # SketchUp, and the folder of your own catalogs. They are brought over to the new names, once, so that what you made with the old name keeps working.
  module LegacyNames
    OLD_DICTIONARY = 'KitchenCabinetMaster'
    OLD_DATA_DIR = 'KitchenCabinetMaster_Data'
    KEY_RENAMES = { 'kcm_dimension' => 'ec_dimension' }.freeze # (a mark that had the old short name in it)
    MARKER = 'legacy_names_done'

    # The attributes of a model, its definitions, layers, materials and the parts in them: the dictionary of the old name is copied to the new one and taken away.
    # Once for each model (it remembers). => how many parts had some.
    def self.migrate_model(model)
      return 0 unless model && model.respond_to?(:get_attribute)
      return 0 if model.get_attribute(AttributeManager::DICTIONARY, MARKER)

      moved = 0
      model.start_operation('Easy Cabinet: bring the cabinets over to the new name', true)
      begin
        parts = [model] + model.definitions.to_a + model.layers.to_a + model.materials.to_a + parts_in(model.entities)
        model.definitions.each { |definition| parts.concat(parts_in(definition.entities)) }
        parts.each { |part| moved += 1 if bring_over(part) }
        model.set_attribute(AttributeManager::DICTIONARY, MARKER, true)
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        warn "[Easy Cabinet] Could not bring the names over: #{e.message}"
        return 0
      end
      moved
    end

    def self.parts_in(entities)
      entities.select { |item| item.is_a?(Sketchup::ComponentInstance) || item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::Dimension) }
    end
    private_class_method :parts_in

    def self.bring_over(part)
      old = part.attribute_dictionary(OLD_DICTIONARY)
      return false unless old

      old.each_pair { |key, value| part.set_attribute(AttributeManager::DICTIONARY, KEY_RENAMES.fetch(key, key), value) }
      part.attribute_dictionaries.delete(OLD_DICTIONARY)
      true
    end
    private_class_method :bring_over

    # The snapping switch kept in SketchUp: read from the old section when the new one has nothing yet. (The panel's saved settings are not brought over: they were
    # kept as a JSON text that SketchUp cannot read back, and reading it makes SketchUp report an extension error.)
    def self.migrate_preferences
      [[SnapManager::PREFERENCE_SECTION, SnapManager::PREFERENCE_KEY]].each do |section, key|
        begin
          old = Sketchup.read_default(OLD_DICTIONARY, key, nil)
          next if old.nil? || !Sketchup.read_default(section, key, nil).nil?

          Sketchup.write_default(section, key, old)
        rescue StandardError, ScriptError => e # (SketchUp reads a text it kept with quotes in it by evaluating it: that can be a SyntaxError)
          warn "[Easy Cabinet] Could not bring the preference #{key} over: #{e.message[0, 80]}"
        end
      end
    end

    # Your own catalogs, handles, materials and models: the folders they had in the Plugins folder (under the old name and under this one) are moved to
    # `target`, your user folder (when that is not there yet).
    def self.move_user_dir(plugins, target)
      return if plugins.nil? || File.exist?(target)

      [OLD_DATA_DIR, CatalogManager::USER_DIR_NAME].each do |name|
        old = File.join(plugins, name)
        next unless File.directory?(old)

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.mv(old, target)
        break
      end
    rescue StandardError => e
      warn "[Easy Cabinet] Could not bring your own data over: #{e.message}"
    end

    if defined?(Sketchup::AppObserver)
      class Watcher < Sketchup::AppObserver
        def expectsStartupModelNotifications = true
        def onNewModel(model) = LegacyNames.migrate_model(model)
        def onOpenModel(model) = LegacyNames.migrate_model(model)
        def onActivateModel(model) = LegacyNames.migrate_model(model)
      end
    end

    # Call once when the extension loads: the preferences, and the model that is open.
    def self.install
      migrate_preferences
      migrate_model(Sketchup.active_model)
      Sketchup.add_observer(Watcher.new) if defined?(Watcher)
    end
  end
end
