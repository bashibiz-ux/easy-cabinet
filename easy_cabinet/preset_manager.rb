# frozen_string_literal: true

require 'json'

module EasyCabinet
  # The panel's own settings (units, door gap, thickness, materials, handle, toe kick,
  # worktop ...) kept between sessions in SketchUp's saved defaults, so a new session starts
  # with what was used last. The panel sends them whenever one changes and asks for them
  # when it opens.
  module PresetManager
    SECTION = 'EasyCabinet'
    KEY = 'panel_presets_text' # (not 'panel_presets': what older versions kept under that name is a JSON text that SketchUp cannot read back; it is never read)
    MAX_FIELDS = 120

    def self.perform(action, raw)
      case action
      when 'load_presets' then load_presets
      when 'save_presets' then save_presets(raw)
      when 'reset_presets' then reset_presets
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # SketchUp keeps a text with double quotes in it without escaping them, and reads it back by evaluating it as Ruby: a JSON text cannot be read
    # back (a SyntaxError, which SketchUp also reports as an extension error). So the settings are kept as base64 text (letters and digits only).
    def self.load_presets
      text = Sketchup.read_default(SECTION, KEY, '').to_s
      text = text.unpack1('m').force_encoding('UTF-8') unless text.empty?
      values = text.empty? ? {} : JSON.parse(text)
      values = {} unless values.is_a?(Hash)
      values = migrate(values) unless text.empty?
      Response.ok('', { 'values' => clean(values) })
    rescue JSON::ParserError, ArgumentError, ScriptError
      Response.ok('', { 'values' => {} })
    end

    def self.save_presets(raw)
      values = raw.is_a?(Hash) ? (raw['values'] || raw[:values]) : nil
      return Response.fail('There are no settings to save.') unless values.is_a?(Hash)

      Sketchup.write_default(SECTION, KEY, [JSON.generate(clean(values).merge('presetRev' => REVISION))].pack('m0'))
      Response.ok('')
    end

    def self.reset_presets
      Sketchup.write_default(SECTION, KEY, '')
      Response.ok('The saved settings were cleared. The panel starts from the standard values.')
    end

    # Settings saved by an earlier version have the Front Edge Radius it started with (3 mm): that is not a choice, so the radius starts from 0 now (the
    # standard value) and is kept from then on as the user sets it. => the values, with the new revision.
    REVISION = 2
    def self.migrate(values)
      return values if values['presetRev'].to_i >= REVISION

      values.reject { |key, _| key == 'frontRadius' }.merge('presetRev' => REVISION)
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