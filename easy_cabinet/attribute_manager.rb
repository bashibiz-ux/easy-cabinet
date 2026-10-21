# frozen_string_literal: true

require 'json'

module EasyCabinet
  # Stores cabinet parameters in a SketchUp Attribute Dictionary on the cabinet
  # root instance. Hashes/arrays are stored as JSON strings because attribute
  # dictionaries only hold simple values.
  module AttributeManager
    DICTIONARY  = 'EasyCabinet'
    COUNTER_KEY = 'id_counter'
    ID_PREFIX   = 'CABINET_'
    JSON_KEYS   = %w[handle_settings shelf_settings visibility_settings toe_kick_turns custom_overrides board_extent board_points board_holes board_round_edge].freeze

    # Writes every key/value pair. Call inside model.start_operation / commit_operation.
    def self.write(entity, params)
      params.each do |key, value|
        entity.set_attribute(DICTIONARY, key.to_s, encode(value))
      end
      entity
    end

    # Returns a Hash of all stored parameters, or nil if the entity has none.
    def self.read(entity)
      return nil unless entity.respond_to?(:attribute_dictionary)

      dict = entity.attribute_dictionary(DICTIONARY, false)
      return nil unless dict

      result = {}
      dict.each_pair { |key, value| result[key] = decode(key, value) }
      result
    end

    def self.cabinet?(entity)
      return false unless entity.respond_to?(:attribute_dictionary)

      dict = entity.attribute_dictionary(DICTIONARY, false)
      !dict.nil? && !dict['cabinet_id'].to_s.empty?
    end

    # A model of your own from My Catalog (see CabinetManager.insert_component): it stands in a component of its own that carries a cabinet's
    # attributes (size, order, toe kick height ...), so the placement rules, the collision check, the snapping, the worktop, the toe kicks and
    # the side panels treat it as a cabinet. It has nothing to rebuild it from, so what rebuilds a cabinet leaves it alone.
    def self.custom_model?(entity)
      entity.respond_to?(:get_attribute) && (entity.get_attribute(DICTIONARY, 'custom_wrapper') == true || entity.get_attribute(DICTIONARY, 'custom_model') == true)
    end

    # A cabinet of the extension or a model of your own: something that stands in a row.
    def self.row_item?(entity)
      cabinet?(entity) || custom_model?(entity)
    end

    def self.cabinet_id(entity)
      return nil unless cabinet?(entity)

      entity.get_attribute(DICTIONARY, 'cabinet_id')
    end

    # A standalone part (filler or side panel): not a full cabinet, but it still
    # takes up its own footprint in the model, so Insert/Duplicate avoid placing
    # a new cabinet or filler on top of it (see PlacementManager).
    PART_COUNTER_KEY = 'part_id_counter'
    PART_ID_PREFIX   = 'PART_'

    def self.part?(entity)
      return false unless entity.respond_to?(:attribute_dictionary)

      dict = entity.attribute_dictionary(DICTIONARY, false)
      !dict.nil? && !dict['part_id'].to_s.empty?
    end

    def self.part_id(entity)
      return nil unless part?(entity)

      entity.get_attribute(DICTIONARY, 'part_id')
    end

    def self.part_kind(entity)
      value = entity.get_attribute(DICTIONARY, 'part_kind')
      value.to_s.empty? ? nil : value
    end

    def self.next_part_id(model)
      number = model.get_attribute(DICTIONARY, PART_COUNTER_KEY, 0).to_i + 1
      model.set_attribute(DICTIONARY, PART_COUNTER_KEY, number)
      format('%<prefix>s%<number>04d', prefix: PART_ID_PREFIX, number: number)
    end

    # The order things were inserted in: 1, 2, 3 ... across cabinets and fillers.
    # An insert with nothing selected goes after the one with the highest number
    # (see PlacementManager.last_occupant). Stored on the item as 'sequence'.
    SEQUENCE_KEY = 'sequence_counter'

    def self.next_sequence(model)
      number = model.get_attribute(DICTIONARY, SEQUENCE_KEY, 0).to_i + 1
      model.set_attribute(DICTIONARY, SEQUENCE_KEY, number)
      number
    end

    # A cabinet OR a part: anything with its own fixed footprint, for collision
    # avoidance (see PlacementManager). Every occupant carries 'envelope_depth',
    # 'envelope_width' and 'envelope_top' (mm, from its own local floor origin).
    # A toe kick is a part too, but it stands under the cabinets' fronts rather
    # than in the row, so it never blocks a cabinet and is not an occupant.
    def self.occupant?(entity)
      return false if entity.respond_to?(:get_attribute) && !entity.get_attribute(DICTIONARY, 'ceiling_filler').nil? # (the strip over a loft blocks nothing: the loft may grow into its place)

      row_item?(entity) || (part?(entity) && !%w[toe_kick worktop backsplash wall_bottom].include?(part_kind(entity)))
    end

    # Every child component of a cabinet (carcass, panels, later doors ...) is
    # tagged with a role so updates can find it without guessing from its name.
    ROLE_KEY = 'role'

    def self.set_role(entity, role)
      entity.set_attribute(DICTIONARY, ROLE_KEY, role)
    end

    def self.role(entity)
      value = entity.get_attribute(DICTIONARY, ROLE_KEY)
      value.to_s.empty? ? nil : value
    end

    # Door containers are marked so a door left over from an older version of the
    # extension (a bare panel) can be recognised and replaced safely.
    CONTAINER_KEY = 'container'

    def self.mark_container(entity)
      entity.set_attribute(DICTIONARY, CONTAINER_KEY, true)
    end

    def self.container?(entity)
      entity.get_attribute(DICTIONARY, CONTAINER_KEY) == true
    end

    # Definitions created by this extension carry a marker so they can be found and
    # cleaned up without relying on their name.
    MANAGED_KEY = 'managed'

    def self.mark_managed(definition)
      definition.set_attribute(DICTIONARY, MANAGED_KEY, true)
      definition
    end

    def self.managed?(definition)
      definition.get_attribute(DICTIONARY, MANAGED_KEY) == true ||
        definition.name.to_s.start_with?(Defaults::LEGACY_DEFINITION_PREFIX)
    end

    # Next unique ID such as CABINET_0001. The counter lives on the model, so no
    # model traversal is needed. Call inside an operation.
    def self.next_cabinet_id(model)
      number = model.get_attribute(DICTIONARY, COUNTER_KEY, 0).to_i + 1
      model.set_attribute(DICTIONARY, COUNTER_KEY, number)
      format('%<prefix>s%<number>04d', prefix: ID_PREFIX, number: number)
    end

    def self.encode(value)
      return '' if value.nil?
      return JSON.generate(value) if value.is_a?(Hash) || value.is_a?(Array)

      value
    end
    private_class_method :encode

    def self.decode(key, value)
      return value unless JSON_KEYS.include?(key.to_s) && value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end
    private_class_method :decode
  end
end
