# frozen_string_literal: true

module KitchenCabinetMaster
  # SketchUp "tags" (layers in older versions) for the parts of a kitchen, so each can be shown, hidden or coloured on its own from SketchUp's Tags panel:
  # 01 - Base Unit, 02 - Wall Unit, 03 - Loft Unit, 04 - Tall Unit, 05 - Toe Kick, 05 - Side Panels, 06 - Ceiling Filler, and Worktop.
  module TagManager
    BASE = '01 - Base Unit'
    WALL = '02 - Wall Unit'
    LOFT = '03 - Loft Unit'
    TALL = '04 - Tall Unit'
    TOE_KICK = '05 - Toe Kick'
    SIDE_PANELS = '05 - Side Panels'
    CEILING_FILLER = '06 - Ceiling Filler'
    WORKTOP = 'Worktop'
    ALL = [BASE, WALL, LOFT, TALL, TOE_KICK, SIDE_PANELS, CEILING_FILLER, WORKTOP].freeze
    # The names the tags had before they were numbered: a model that has them gets them renamed (what is on them stays on them).
    OLD_NAMES = { 'Base Unit' => BASE, 'Wall Unit' => WALL, 'Tall Unit' => TALL, 'Toe Kick' => TOE_KICK }.freeze

    # The tag a cabinet belongs on: corner units count as base units.
    def self.for_category(category)
      case category.to_s
      when 'wall' then WALL
      when 'tall' then TALL
      else BASE
      end
    end

    # The tag of a cabinet from its parameters: a loft is a wall unit of its own.
    def self.for_cabinet(params)
      return LOFT if params['cabinet_type'].to_s.start_with?('wall_loft')

      for_category(params['cabinet_category'])
    end

    # The tag for any cabinet or part, from its stored parameters; nil for what has none
    # (fillers stay untagged, they take their cabinet's look).
    def self.for_stored(stored)
      return nil unless stored.is_a?(Hash)
      return TOE_KICK if stored['part_kind'] == 'toe_kick'
      return SIDE_PANELS if stored['part_kind'] == 'end_panel'
      return CEILING_FILLER if stored['part_kind'] == 'filler' && stored['ceiling_filler']
      return WORKTOP if %w[worktop backsplash].include?(stored['part_kind'])
      return WALL if stored['part_kind'] == 'wall_bottom'
      return nil if stored['part_kind']

      for_cabinet(stored) if stored['cabinet_id']
    end

    # Makes sure the tags exist (the ones with the old names are renamed first).
    def self.create_all(model)
      OLD_NAMES.each do |old, current|
        old_tag = model.layers[old]
        old_tag.name = current if old_tag && model.layers[current].nil?
      end
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

    # Tags every cabinet, toe kick, side panel, ceiling filler and worktop already in the model. Returns how many
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
      return true if ALL.any? { |name| model.layers[name].nil? } || OLD_NAMES.keys.any? { |name| model.layers[name] }

      model.entities.grep(Sketchup::ComponentInstance).any? do |instance|
        name = for_stored(AttributeManager.read(instance))
        name && instance.layer != model.layers[name]
      end
    end
  end
end