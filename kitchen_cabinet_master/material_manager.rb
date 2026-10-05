# frozen_string_literal: true

require 'fileutils'
require 'json'

module KitchenCabinetMaster
  # Central place for SketchUp materials. Rules:
  #  * A material is looked up by name and reused if it already exists.
  #  * A preset from data/materials.json is created only when first used.
  #  * Unknown names are never invented; ensure_material returns nil instead.
  module MaterialManager
    PRESETS_FILE = File.join(DATA_DIR, 'materials.json')
    FALLBACK_COLOR = [200, 200, 200].freeze
    IN_MODEL = 'In this model'
    MINE = 'My materials'
    TEXTURE_DIR = File.join(DATA_DIR, 'textures')
    DEFAULT_TEXTURE_SIZE = 600 # a picture is this many mm wide on the board

    # Options for the HTML dropdowns:
    #   { 'panel' => [...], 'toe_kick' => [...] }
    # Each entry: { 'id' => name, 'name' => label, 'color' => '#RRGGBB' or nil }
    def self.options(model)
      existing = model.materials.map { |m| entry(m.name, hex(m.color), IN_MODEL) }

      panel = merge(existing, presets_for('panel'))
      toe_kick = merge(existing, presets_for('toe_kick'))
      toe_kick.unshift({ 'id' => Defaults::SAME_AS_CARCASS, 'name' => 'Same as carcass material', 'color' => nil })
      toe_kick.unshift({ 'id' => Defaults::SAME_AS_DOOR, 'name' => 'Same as door material', 'color' => nil })

      { 'panel' => panel, 'toe_kick' => toe_kick, 'mine' => custom_summary }
    end

    # True if the name can be used: it exists in the model or is a known preset.
    def self.available?(model, name)
      name = name.to_s.strip
      return true if follows_another_part?(name)
      return false if name.empty?

      !model.materials[name].nil? || presets.any? { |preset| preset['name'] == name }
    end

    # The toe-kick choices that mean "use the door / carcass material" rather than naming one.
    def self.follows_another_part?(name)
      [Defaults::SAME_AS_DOOR, Defaults::SAME_AS_CARCASS, Defaults::SAME_AS_CABINET].include?(name)
    end

    # Finds a material by name, creating it from a preset if needed.
    # Call inside an operation because creation modifies the model.
    # `color` ("#RRGGBB") lets a caller that knows the colour (a handle finish)
    # create the material even though it is not one of the presets.
    def self.ensure_material(model, name, color = nil, props = nil)
      name = name.to_s.strip
      return nil if name.empty? || follows_another_part?(name)

      existing = model.materials[name]
      return upgrade(existing, name) if existing

      preset = presets.find { |p| p['name'] == name }
      color ||= preset && preset['color']
      props ||= preset
      return nil unless color

      material = model.materials.add(name)
      material.color = hex_to_color(color)
      style(material, props)
      material
    end

    # Paints an entity with the named material. Returns true if a material was applied.
    def self.apply(entity, name, model = Sketchup.active_model, color = nil, props = nil)
      material = ensure_material(model, name, color, props)
      return false unless material

      entity.material = material unless entity.material == material
      true
    end

    def self.presets
      @presets ||= load_presets
    end

    def self.reload!
      @presets = nil
    end

    # ---- internals -----------------------------------------------------------

    def self.load_presets
      read_materials(PRESETS_FILE) + read_materials(custom_file).map { |p| p.merge('custom' => true, 'category' => "#{MINE} - #{p['category'].to_s.empty? ? 'General' : p['category']}") }
    end

    def self.read_materials(path)
      return [] unless path && File.file?(path)

      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      list = data.is_a?(Hash) ? data['materials'] : nil
      list.is_a?(Array) ? list.select { |p| p.is_a?(Hash) && !p['name'].to_s.empty? } : []
    rescue JSON::ParserError, SystemCallError => e
      warn "[Kitchen Cabinet Master] Could not read #{File.basename(path.to_s)}: #{e.message}"
      []
    end
    private_class_method :read_materials
    private_class_method :load_presets

    # A plain material made earlier from a preset that now has a picture (a wood, a stone) gets the picture, as long as
    # it still has the preset's colour (a material you changed is left alone).
    def self.upgrade(material, name)
      preset = presets.find { |p| p['name'] == name }
      return material unless preset && !preset['texture'].to_s.empty? && material.texture.nil?
      return material unless hex(material.color) == preset['color'].to_s.upcase

      style(material, preset)
      material
    rescue StandardError
      material
    end
    private_class_method :upgrade

    # Gives a new material its look: see-through (`alpha`), a picture from data/textures laid out `size` mm wide
    # (`texture`), and the PBR settings `roughness` and `metalness` (0 to 1) wherever this SketchUp has them. The
    # settings are also kept on the material (KitchenCabinetMaster / pbr) for anything that reads them.
    def self.style(material, props)
      return unless props.is_a?(Hash)

      alpha = props['alpha']
      material.alpha = alpha.to_f if alpha.is_a?(Numeric)
      file = props['texture'].to_s
      path = file.empty? ? nil : texture_path(file, props['custom'])
      if path && File.file?(path)
        begin
          material.texture = path
          size = props['size'].is_a?(Numeric) ? props['size'] : DEFAULT_TEXTURE_SIZE
          material.texture.size = size.mm if material.texture
        rescue StandardError => e
          warn "[Kitchen Cabinet Master] Could not use the picture #{file}: #{e.message}"
        end
      end
      pbr = props.slice('roughness', 'metalness', 'emissive').select { |_, v| v.is_a?(Numeric) }
      pbr.each { |key, value| material.send("#{key}=", value.to_f) if material.respond_to?("#{key}=") }
      material.set_attribute('KitchenCabinetMaster', 'pbr', JSON.generate(pbr)) unless pbr.empty?
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not style a material: #{e.message}"
    end
    private_class_method :style

    # ---- your own materials ----------------------------------------------------------------------------
    # Kept in your KitchenCabinetMaster_Data folder (materials.json, pictures in textures/), in categories of your own;
    # they are listed under "My materials - <category>" with the bundled ones and can be used anywhere a material is chosen.

    def self.custom_file
      dir = CatalogManager.user_dir
      dir ? File.join(dir, 'materials.json') : nil
    end

    def self.custom_textures_dir
      dir = CatalogManager.user_dir
      dir ? File.join(dir, 'textures') : nil
    end

    # Where a picture is: yours in your folder, the bundled ones in data/textures.
    def self.texture_path(file, custom)
      custom ? File.join(custom_textures_dir.to_s, file) : File.join(TEXTURE_DIR, file)
    end

    # What the panel shows as the swatch: a bundled picture by file name, yours as a file address.
    def self.texture_swatch(preset)
      return preset['texture'] unless preset['custom'] && !preset['texture'].to_s.empty?

      path = texture_path(preset['texture'], true).tr('\\', '/')
      "file:///#{path.gsub(' ', '%20')}"
    end
    private_class_method :texture_swatch

    # [{ 'id', 'name', 'category' }] of your own materials.
    def self.custom_summary
      read_materials(custom_file).map { |p| { 'id' => p['name'], 'name' => p['name'], 'category' => p['category'].to_s.empty? ? 'General' : p['category'] } }
    end

    # Keeps (or replaces, by name) one material of your own. `entry` = { 'name', 'category', 'color', optional 'texture'
    # (a file in your textures folder), 'size', 'alpha', 'roughness', 'metalness' }. Returns nil, or an error message.
    def self.save_custom(entry)
      name = entry['name'].to_s.strip
      return 'Give the material a name.' if name.empty?
      return 'The name is at most 60 characters.' if name.length > 60
      return "\"#{name}\" is the name of a material that comes with the extension: choose another name." if read_materials(PRESETS_FILE).any? { |p| p['name'] == name }
      return 'The colour must be like #C8A46E.' unless entry['color'].to_s.match?(/\A#\h{6}\z/)
      return 'There is no folder to keep your materials in.' unless custom_file

      list = read_materials(custom_file).reject { |p| p['name'] == name }
      category = entry['category'].to_s.strip
      category = 'General' if category.empty?
      list << entry.merge('name' => name, 'category' => category[0, 40], 'color' => entry['color'].upcase)
      FileUtils.mkdir_p(File.dirname(custom_file))
      File.write(custom_file, "#{JSON.pretty_generate('materials' => list)}\n", encoding: 'UTF-8')
      reload!
      nil
    end

    def self.remove_custom(name)
      list = read_materials(custom_file)
      gone = list.select { |p| p['name'] == name.to_s }
      return false if gone.empty?

      kept = list - gone
      File.write(custom_file, "#{JSON.pretty_generate('materials' => kept)}\n", encoding: 'UTF-8')
      gone.each do |p|
        next if p['texture'].to_s.empty? || kept.any? { |q| q['texture'] == p['texture'] }

        path = texture_path(p['texture'], true)
        File.delete(path) if File.file?(path)
      end
      reload!
      true
    end

    # The panel's two actions: add_material { from (a material of the model, or blank for a new colour), name, category, color }
    # and remove_material { name }. The reply carries the whole material list again.
    def self.perform(action, data)
      data = {} unless data.is_a?(Hash)
      model = Sketchup.active_model
      case action
      when 'add_material'
        error = add_from_panel(model, data)
        return Response.fail(error) if error

        Response.ok("#{data['name'].to_s.strip} is in your materials, under \"#{data['category'].to_s.strip.empty? ? 'General' : data['category'].to_s.strip}\".", { 'materials' => options(model) })
      when 'remove_material'
        return Response.fail('Choose one of your materials to remove.') unless remove_custom(data['name'])

        Response.ok("#{data['name']} removed from your materials. It stays in cabinets and in the model.", { 'materials' => options(model) })
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # A material of the model (its colour and picture are copied) or a new colour becomes one of yours.
    def self.add_from_panel(model, data)
      entry = { 'name' => data['name'], 'category' => data['category'], 'color' => data['color'], 'kinds' => %w[panel toe_kick] }
      source = data['from'].to_s.strip
      unless source.empty?
        material = model.materials[source]
        return "The model has no material called \"#{source}\"." unless material

        entry['color'] = hex(material.color)
        entry['name'] = source if entry['name'].to_s.strip.empty?
        entry['alpha'] = material.alpha.round(2) if material.alpha < 1.0
        if material.texture && custom_textures_dir
          file = "#{CatalogManager.slug(entry['name'])}.png"
          FileUtils.mkdir_p(custom_textures_dir)
          material.texture.write(File.join(custom_textures_dir, file))
          entry['texture'] = file
          entry['size'] = material.texture.width.to_mm.round
        end
      end
      entry['roughness'] = 0.5
      entry['metalness'] = 0.0
      save_custom(entry)
    end
    private_class_method :add_from_panel

    def self.presets_for(kind)
      presets
        .select { |p| Array(p['kinds']).include?(kind) }
        .map { |p| entry(p['name'], p['color'], p['category'], texture_swatch(p)) }
    end
    private_class_method :presets_for

    # Union by name. A material that is in the model and also a preset keeps the preset's category; the ones only in
    # the model come first, under "In this model"; the presets follow in the order of the file, category by category.
    def self.merge(existing, presets)
      by_name = {}
      presets.each { |item| by_name[item['id']] = item }
      existing.each do |item|
        known = by_name[item['id']]
        by_name[item['id']] = known ? known.merge('color' => item['color'] || known['color']) : item
      end
      mine, listed = by_name.values.partition { |item| item['group'] == IN_MODEL }
      mine.sort_by { |item| item['name'].downcase } + listed
    end
    private_class_method :merge

    def self.entry(name, color, group = nil, texture = nil)
      item = { 'id' => name, 'name' => name, 'color' => color, 'group' => group }
      item['texture'] = texture unless texture.to_s.empty? # the picture, for the swatch in the panel
      item
    end
    private_class_method :entry

    def self.hex(color)
      return nil unless color

      format('#%<r>02X%<g>02X%<b>02X', r: color.red, g: color.green, b: color.blue)
    end
    private_class_method :hex

    def self.hex_to_color(text)
      match = /\A#?(\h{2})(\h{2})(\h{2})\z/.match(text.to_s)
      rgb = match ? match.captures.map { |part| part.to_i(16) } : FALLBACK_COLOR
      Sketchup::Color.new(*rgb)
    end
    private_class_method :hex_to_color
  end
end
