# frozen_string_literal: true

require 'fileutils'
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
    # Files of earlier versions (an install cannot delete them, so they are removed when the catalogs load). The other models were
    # taken out: Kitchen Cabinet - with handle and Kitchen Cabinet - Gola handle are the two models.
    LEGACY_FILES = %w[catalogs/sample_catalog.json catalogs/door_with_pull_handle.json catalogs/drawer_units.json catalogs/handleless_doors.json catalogs/kitchen_cabinets_gola.json].freeze
    DEFAULT_CUSTOM_NAME = 'My cabinets'
    # The measurements a catalog entry lets the panel adjust: entry key => [the key that switches it on, stored parameter].
    ADJUSTABLE = {
      'zone' => %w[zone_label front_zone], 'zone_bottom' => %w[bottom_label bottom_zone], 'top_front' => %w[top_front_label top_front],
      'fridge' => %w[fridge_label fridge_height], 'split' => %w[split_label split_height], 'blind' => %w[blind_label blind_width]
    }.freeze

    # What a catalog can switch on in the panel. A catalog lists the ones it offers
    # under `features`; anything not listed stays greyed out while it is selected.
    #   categories : base wall tall corner filler end_panel toe_kick
    #   options    : door_gap door_reveal door_distance front_radius top_panel panel_thickness back_thickness
    #   sections   : cabinet_extras (the Cabinet & Extras section) handle materials
    #                door_opening visibility rotate
    # A catalog with no `features` list offers all of them.
    FEATURES = %w[base wall tall corner filler end_panel toe_kick
                  door_gap door_reveal door_distance front_radius top_panel panel_thickness back_thickness
                  cabinet_extras worktop handle materials door_opening visibility rotate].freeze

    class << self
      # [{ 'id', 'name', 'aliases', 'features', 'handle_bundles' }]
      def catalogs
        data[:catalogs].values.map do |c|
          { 'id' => c['id'], 'name' => c['name'], 'aliases' => Array(c['aliases']), 'custom' => c['custom'] == true, 'finger_pull' => c['finger_pull'] == true,
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

      # Where your own catalogs are kept (tests point this at a temporary folder).
      attr_writer :user_root_override

      # The cabinets you save from the model go into catalogs of your own: a file in your KitchenCabinetMaster_Data
      # folder, listed beside the bundled catalogs. Saving a cabinet under a name the catalog already has replaces it.
      # `entry` is a catalog entry (see entry_from); returns [catalog id, cabinet id].
      def save_custom(catalog_name, category, entry)
        root = user_root
        raise 'There is no folder to keep your own catalogs in.' unless root

        name = catalog_name.to_s.strip
        name = DEFAULT_CUSTOM_NAME if name.empty?
        catalog_id = "custom_#{slug(name)}"
        path = File.join(root, 'catalogs', "#{catalog_id}.json")
        stored = File.file?(path) ? read_json(path) : nil
        stored = { 'id' => catalog_id, 'name' => name, 'custom' => true, 'categories' => {} } unless stored.is_a?(Hash) && stored['categories'].is_a?(Hash)
        list = (stored['categories'][category.to_s] ||= [])
        entry = entry.merge('id' => slug(entry['name']))
        list.reject! { |item| item['id'] == entry['id'] }
        list << entry
        write_custom(path, stored)
        [catalog_id, entry['id']]
      end

      # Takes a cabinet out of one of your own catalogs; the catalog file goes when it is empty. Returns true if found.
      def remove_custom(catalog_id, category, cabinet_id)
        found = catalog(catalog_id)
        root = user_root
        return false unless found && found['custom'] == true && root

        path = File.join(root, 'catalogs', "#{found['id']}.json")
        stored = File.file?(path) ? read_json(path) : nil
        list = stored.is_a?(Hash) ? stored.dig('categories', category.to_s) : nil
        return false unless list.is_a?(Array) && list.any? { |item| item['id'] == cabinet_id.to_s }

        gone = list.select { |item| item['id'] == cabinet_id.to_s }
        list.reject! { |item| item['id'] == cabinet_id.to_s }
        gone.each { |item| forget_model_file(item, stored) }
        if stored['categories'].values.all?(&:empty?)
          File.delete(path)
          reload!
        else
          write_custom(path, stored)
        end
        true
      end

      # A catalog entry for a cabinet in the model, from the parameters stored on it: the entry it was made from
      # (`base`, nil when its catalog is gone), with the cabinet's own size, doors, drawers, shelves and the
      # adjustable heights it has now as the starting values.
      def entry_from(stored, base, name)
        entry = (base || {}).dup
        entry['name'] = name.to_s.strip
        entry['code'] = (base && base['code']) || stored['name_code'].to_s
        unless base && base['lower'] # an oven housing's doors and drawers follow its lower part
          entry['doors'] = stored['door_count'].to_i
          entry['drawers'] = stored['drawer_count'].to_i
        end
        entry['shelves'] = stored['shelf_count'].to_i
        defaults = { 'width' => stored['width'], 'depth' => stored['depth'], 'height' => stored['height'] }
        %w[leg2_length leg2_depth].each { |key| defaults[key] = stored[key] if stored[key].is_a?(Numeric) }
        entry['defaults'] = defaults.transform_values { |v| v.to_f }
        entry['widths'] = (base['widths'] + [stored['width']]).compact.uniq.sort if base && base['widths'].is_a?(Array)
        ADJUSTABLE.each do |catalog_key, (label_key, stored_key)|
          value = stored[stored_key].to_f
          entry[catalog_key] = value if entry[label_key] && value.positive?
        end
        if entry['sink'] && !entry['sink_single']
          entry['sink_bowls'] = stored['sink_bowls'].to_i == 2 ? 2 : 1
          entry['sink_tray'] = stored['sink_tray'] == true
        end
        entry
      end

      # The folder of your own catalogs and models (nil when there is none).
      def user_dir
        user_root
      end

      # A catalog entry for a model you drew: size is its [width (X), depth (Y), height (Z)] in mm, ile the model file
      # (relative to your folder). It is inserted as a component, not rebuilt from parameters.
      def component_entry(name, size, file)
        { 'name' => name.to_s.strip, 'code' => 'CU', 'doors' => 0, 'shelves' => 0, 'widths' => [size[0]], 'component' => file,
          'defaults' => { 'width' => size[0], 'depth' => size[1], 'height' => size[2] } }
      end

      def component_path(entry)
        root = user_root
        entry['component'].to_s.empty? || root.nil? ? nil : File.join(root, entry['component'])
      end

      def slug(text)
        text.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')[0, 60].then { |s| s.empty? ? 'cabinet' : s }
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

      # A model file that no entry of this catalog uses any more is deleted.
      def forget_model_file(item, stored)
        return if item['component'].to_s.empty?
        return if stored['categories'].values.flatten.any? { |other| other['component'] == item['component'] }

        path = File.join(user_root.to_s, item['component'])
        File.delete(path) if File.file?(path)
      rescue SystemCallError => e
        warn "[Kitchen Cabinet Master] Could not delete #{item['component']}: #{e.message}"
      end

      def read_json(path)
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def write_custom(path, stored)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(stored)}\n", encoding: 'UTF-8')
        reload!
      end

      def user_root
        return @user_root_override if @user_root_override
        return nil unless defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)

        plugins = Sketchup.find_support_file('Plugins')
        plugins ? File.join(plugins, USER_DIR_NAME) : nil
      rescue StandardError
        nil
      end
    end
  end
end

# A hot reload of this file must also forget the catalogs it read before, so new catalog files show up.
KitchenCabinetMaster::CatalogManager.reload!
