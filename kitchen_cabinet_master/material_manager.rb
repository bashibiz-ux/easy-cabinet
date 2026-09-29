# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Central place for SketchUp materials. Rules:
  #  * A material is looked up by name and reused if it already exists.
  #  * A preset from data/materials.json is created only when first used.
  #  * Unknown names are never invented; ensure_material returns nil instead.
  module MaterialManager
    PRESETS_FILE = File.join(DATA_DIR, 'materials.json')
    FALLBACK_COLOR = [200, 200, 200].freeze

    # Options for the HTML dropdowns:
    #   { 'panel' => [...], 'toe_kick' => [...] }
    # Each entry: { 'id' => name, 'name' => label, 'color' => '#RRGGBB' or nil }
    def self.options(model)
      existing = model.materials.map { |m| entry(m.name, hex(m.color)) }

      panel = merge(existing, presets_for('panel'))
      toe_kick = merge(existing, presets_for('toe_kick'))
      toe_kick.unshift({ 'id' => Defaults::SAME_AS_CARCASS, 'name' => 'Same as carcass material', 'color' => nil })
      toe_kick.unshift({ 'id' => Defaults::SAME_AS_DOOR, 'name' => 'Same as door material', 'color' => nil })

      { 'panel' => panel, 'toe_kick' => toe_kick }
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
    def self.ensure_material(model, name, color = nil)
      name = name.to_s.strip
      return nil if name.empty? || follows_another_part?(name)

      existing = model.materials[name]
      return existing if existing

      preset = presets.find { |p| p['name'] == name }
      color ||= preset && preset['color']
      return nil unless color

      material = model.materials.add(name)
      material.color = hex_to_color(color)
      material
    end

    # Paints an entity with the named material. Returns true if a material was applied.
    def self.apply(entity, name, model = Sketchup.active_model, color = nil)
      material = ensure_material(model, name, color)
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
      return [] unless File.file?(PRESETS_FILE)

      data = JSON.parse(File.read(PRESETS_FILE, encoding: 'UTF-8'))
      list = data.is_a?(Hash) ? data['materials'] : nil
      list.is_a?(Array) ? list.select { |p| p.is_a?(Hash) && !p['name'].to_s.empty? } : []
    rescue JSON::ParserError, SystemCallError => e
      warn "[Kitchen Cabinet Master] Could not read materials.json: #{e.message}"
      []
    end
    private_class_method :load_presets

    def self.presets_for(kind)
      presets
        .select { |p| Array(p['kinds']).include?(kind) }
        .map { |p| entry(p['name'], p['color']) }
    end
    private_class_method :presets_for

    # Union by name; existing model materials win over presets with the same name.
    def self.merge(existing, presets)
      by_name = {}
      (presets + existing).each { |item| by_name[item['id']] = item }
      by_name.values.sort_by { |item| item['name'].downcase }
    end
    private_class_method :merge

    def self.entry(name, color)
      { 'id' => name, 'name' => name, 'color' => color }
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
