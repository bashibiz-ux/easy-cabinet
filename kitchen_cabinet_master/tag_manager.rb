# frozen_string_literal: true

module KitchenCabinetMaster
  # SketchUp "tags" (layers in older versions) for the parts of a kitchen, so each
  # can be shown, hidden or coloured on its own from SketchUp's Tags panel:
  # Base Unit, Worktop, Wall Unit, Tall Unit and Toe Kick.
  module TagManager
    BASE = 'Base Unit'
    WORKTOP = 'Worktop'
    WALL = 'Wall Unit'
    TALL = 'Tall Unit'
    TOE_KICK = 'Toe Kick'
    ALL = [BASE, WORKTOP, WALL, TALL, TOE_KICK].freeze

    # The tag a cabinet belongs on: corner units count as base units.
    def self.for_category(category)
      case category.to_s
      when 'wall' then WALL
      when 'tall' then TALL
      else BASE
      end
    end

    # The tag for any cabinet or part, from its stored parameters; nil for what has none
    # (fillers and side panels stay untagged, they take their cabinet's look).
    def self.for_stored(stored)
      return nil unless stored.is_a?(Hash)
      return TOE_KICK if stored['part_kind'] == 'toe_kick'
      return WORKTOP if %w[worktop backsplash].include?(stored['part_kind'])
      return WALL if stored['part_kind'] == 'wall_bottom'
      return nil if stored['part_kind']

      for_category(stored['cabinet_category']) if stored['cabinet_id']
    end

    # Makes sure the five tags exist.
    def self.create_all(model)
      ALL.each { |name| layer(model, name) }
    end

    def self.layer(model, name)
      model.layers[name] || model.layers.add(name)
    end

    # Puts `entity` on the tag called `name` (creating the tag if needed).
    def self.assign(model, entity, name)
      return unless name

      tag = layer(model, name)
      entity.layer = tag unless entity.layer == tag
    end

    # Tags every cabinet, toe kick and worktop already in the model. Returns how many
    # were moved. Call inside an operation.
    def self.sync_existing(model)
      create_all(model)
      moved = 0
      model.entities.grep(Sketchup::ComponentInstance).each do |instance|
        name = for_stored(AttributeManager.read(instance))
        next unless name

        tag = layer(model, name)
        next if instance.layer == tag

        instance.layer = tag
        moved += 1
      end
      moved
    end

    # Is there anything to do? (Checked first, so opening the panel in a model that is
    # already tagged adds nothing to the Undo list.)
    def self.needs_sync?(model)
      return true if ALL.any? { |name| model.layers[name].nil? }

      model.entities.grep(Sketchup::ComponentInstance).any? do |instance|
        name = for_stored(AttributeManager.read(instance))
        name && instance.layer != model.layers[name]
      end
    end
  end
end