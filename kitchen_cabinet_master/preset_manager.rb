# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # The panel's own settings (units, door gap, thickness, materials, handle, toe kick,
  # worktop ...) kept between sessions in SketchUp's saved defaults, so a new session starts
  # with what was used last. The panel sends them whenever one changes and asks for them
  # when it opens.
  module PresetManager
    SECTION = 'KitchenCabinetMaster'
    KEY = 'panel_presets'
    MAX_FIELDS = 120

    def self.perform(action, raw)
      case action
      when 'load_presets' then load_presets
      when 'save_presets' then save_presets(raw)
      when 'reset_presets' then reset_presets
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    def self.load_presets
      text = Sketchup.read_default(SECTION, KEY, '').to_s
      values = text.empty? ? {} : JSON.parse(text)
      Response.ok('', { 'values' => values.is_a?(Hash) ? clean(values) : {} })
    rescue JSON::ParserError
      Response.ok('', { 'values' => {} })
    end

    def self.save_presets(raw)
      values = raw.is_a?(Hash) ? (raw['values'] || raw[:values]) : nil
      return Response.fail('There are no settings to save.') unless values.is_a?(Hash)

      Sketchup.write_default(SECTION, KEY, JSON.generate(clean(values)))
      Response.ok('')
    end

    def self.reset_presets
      Sketchup.write_default(SECTION, KEY, '')
      Response.ok('The saved settings were cleared. The panel starts from the standard values.')
    end

    # Only plain text, numbers and ticks under simple names; nothing else is kept.
    def self.clean(values)
      values.each_with_object({}) do |(key, value), out|
        key = key.to_s
        next unless key.match?(/\A[A-Za-z][A-Za-z0-9_]{0,63}\z/)
        next unless [String, Integer, Float, TrueClass, FalseClass].any? { |type| value.is_a?(type) }
        next if value.is_a?(String) && value.length > 200

        out[key] = value
        break out if out.length >= MAX_FIELDS
      end
    end
  end
end