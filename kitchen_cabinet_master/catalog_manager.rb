# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Loads catalogs and handle bundles from JSON files. The cabinet engine never
  # refers to a specific catalog: it only receives whatever the JSON describes.
  #
  # Files are read from:
  #   1. <plugin>/data/catalogs/*.json and data/handles/*.json  (bundled)
  #   2. <SketchUp Plugins folder>/KitchenCabinetMaster_Data/catalogs|handles/*.json  (yours)
  # Files in (2) with the same "id" replace bundled ones.
  module CatalogManager
    USER_DIR_NAME = 'KitchenCabinetMaster_Data'
    REQUIRED_DEFAULTS = %w[width depth height].freeze
    LEGACY_FILES = ['catalogs/sample_catalog.json'].freeze

    # What a catalog can switch on in the panel. A catalog lists the ones it offers
    # under eatures; anything not listed stays greyed out while it is selected.
    #   categories : base wall tall corner filler end_panel toe_kick
    #   options    : door_gap door_reveal door_distance top_panel panel_thickness back_thickness
    #   sections   : cabinet_extras (the Cabinet & Extras section) handle materials
    #                door_opening visibility rotate
    # A catalog with no eatures list offers all of them.
    FEATURES = %w[base wall tall corner filler end_panel toe_kick
                  door_gap door_reveal door_distance top_panel panel_thickness back_thickness
                  cabinet_extras handle materials door_opening visibility rotate].freeze

    class << self
      # [{ 'id', 'name', 'aliases', 'features', 'handle_bundles' }]
      def catalogs
        data[:catalogs].values.map do |c|
          { 'id' => c['id'], 'name' => c['name'], 'aliases' => Array(c['aliases']),
            'features' => features_of(c), 'handle_bundles' => c['handle_bundles'].is_a?(Array) ? c['handle_bundles'] : nil }
        end
      end

      # By id, or by an old id the catalog used to have (cabinets drawn with an
      # earlier version keep working under the catalog's new name).
      def catalog(id)
        data[:catalogs][id.to_s] || data[:catalogs].values.find { |c| Array(c['aliases']).include?(id.to_s) }
      end

      def features_of(catalog)
        listed = catalog['features']
        listed.is_a?(Array) ? listed.map(&:to_s) & FEATURES : FEATURES.dup
      end

      # Cabinets of one category. Each entry carries id, name, doors, shelves, defaults.
      def cabinets(catalog_id, category)
        found = catalog(catalog_id)
        return [] unless found

        list = found.dig('categories', category.to_s)
        list.is_a?(Array) ? list : []
      end

      def cabinet(catalog_id, category, cabinet_id)
        cabinets(catalog_id, category).find { |c| c['id'] == cabinet_id.to_s }
      end

      # Everything the panel needs to offer a bundle's choices.
      def handle_bundles
        data[:handles].values.map { |bundle| bundle_summary(bundle) }
      end

      def handle_bundle(id)
        data[:handles][id.to_s]
      end

      # Human-readable problems found while loading (shown in the panel).
      def warnings
        data[:warnings]
      end

      def reload!
        @data = nil
      end

      private

      def data
        @data ||= load_all
      end

      def load_all
        remove_legacy_files
        result = { catalogs: {}, handles: {}, warnings: [] }
        [DATA_DIR, user_root].compact.each do |root|
          read_dir(File.join(root, 'catalogs'), :catalog, result[:catalogs], result[:warnings])
          read_dir(File.join(root, 'handles'), :handle, result[:handles], result[:warnings])
        end
        drop_superseded(result[:catalogs])
        result
      end

      # Installing a newer version over an older one leaves files the old version had
      # (the package cannot delete them). The sample catalog was replaced by
      # "Door with pull handle", so it is removed.
      def remove_legacy_files
        LEGACY_FILES.each do |relative|
          path = File.join(DATA_DIR, relative)
          File.delete(path) if File.file?(path)
        rescue SystemCallError => e
          warn "[Kitchen Cabinet Master] Could not remove #{path}: #{e.message}"
        end
      end

      # A catalog that took over an old id (see "aliases") replaces the catalog that
      # still has that id, so a leftover copy never shows up as a second catalog.
      def drop_superseded(store)
        store.values.flat_map { |c| Array(c['aliases']) }.each { |old| store.delete(old) }
      end

      def read_dir(dir, kind, store, warnings)
        return unless File.directory?(dir)

        Dir.glob(File.join(dir, '*.json')).sort.each do |path|
          parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
          problem = kind == :catalog ? catalog_problem(parsed) : handle_problem(parsed)
          if problem
            warnings << "#{File.basename(path)}: #{problem}"
          else
            store[parsed['id']] = parsed
          end
        rescue JSON::ParserError, SystemCallError => e
          warnings << "#{File.basename(path)}: #{e.message}"
        end
      end

      def catalog_problem(parsed)
        return 'the file must contain a JSON object' unless parsed.is_a?(Hash)
        return 'missing "id"' if parsed['id'].to_s.strip.empty?
        return 'missing "name"' if parsed['name'].to_s.strip.empty?
        return '"categories" must be an object' unless parsed['categories'].is_a?(Hash)
        return '"features" must be a list' if parsed.key?('features') && !parsed['features'].is_a?(Array)

        parsed['categories'].each do |category, list|
          return "category \"#{category}\" must be a list" unless list.is_a?(Array)

          list.each do |cabinet|
            problem = cabinet_problem(category, cabinet)
            return problem if problem
          end
        end
        nil
      end

      def cabinet_problem(category, cabinet)
        unless cabinet.is_a?(Hash) && !cabinet['id'].to_s.empty? && !cabinet['name'].to_s.empty?
          return "a cabinet in \"#{category}\" is missing \"id\" or \"name\""
        end

        defaults = cabinet['defaults']
        numeric = defaults.is_a?(Hash) && REQUIRED_DEFAULTS.all? { |key| defaults[key].is_a?(Numeric) }
        return nil if numeric

        "cabinet \"#{cabinet['id']}\" needs numeric width, depth and height in \"defaults\""
      end

      def handle_problem(parsed)
        return 'the file must contain a JSON object' unless parsed.is_a?(Hash)
        return 'missing "id"' if parsed['id'].to_s.strip.empty?
        return 'missing "name"' if parsed['name'].to_s.strip.empty?
        return "\"profile\" must be one of: #{Defaults::HANDLE_PROFILES.join(', ')}" unless Defaults::HANDLE_PROFILES.include?(parsed['profile'])

        lengths = parsed['lengths']
        return '"lengths" must be a list of positive numbers' unless lengths.is_a?(Array) && !lengths.empty? &&
                                                                    lengths.all? { |l| l.is_a?(Numeric) && l.positive? }

        finishes = parsed['finishes']
        unless finishes.is_a?(Array) && !finishes.empty? && finishes.all? { |f| f.is_a?(Hash) && !f['name'].to_s.empty? }
          return '"finishes" must be a list of objects, each with a "name" (and optionally "material" and "color")'
        end

        nil
      end

      def bundle_summary(bundle)
        lengths = bundle['lengths']
        {
          'id' => bundle['id'],
          'name' => bundle['name'],
          'profile' => bundle['profile'],
          'lengths' => lengths,
          'default_length' => lengths.include?(bundle['default_length']) ? bundle['default_length'] : lengths.first,
          'finishes' => bundle['finishes'].map { |f| { 'id' => f['name'], 'name' => f['name'], 'color' => f['color'] } },
          'defaults' => Defaults::HANDLE_DEFAULTS.merge(bundle['defaults'].is_a?(Hash) ? bundle['defaults'] : {})
        }
      end

      def user_root
        return nil unless defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)

        plugins = Sketchup.find_support_file('Plugins')
        plugins ? File.join(plugins, USER_DIR_NAME) : nil
      rescue StandardError
        nil
      end
    end
  end
end
