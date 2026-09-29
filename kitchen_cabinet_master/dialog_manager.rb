# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Owns the control-panel window and the messaging layer.
  #
  #   HTML -> Ruby : sketchup.kcm_request(JSON.stringify({ id, action, data }))
  #   Ruby -> HTML : KCM.receive({ id, ok, message, data, errors })      (reply)
  #                  KCM.receive({ event, data })                        (push, no id)
  module DialogManager
    PREFERENCES_KEY = 'KitchenCabinetMaster.ControlPanel'
    CABINET_ACTIONS = %w[insert update duplicate delete toggle visibility].freeze
    PART_ACTIONS = %w[insert_filler insert_end_panel insert_toe_kick update_part delete_part].freeze

    class << self
      def show
        if @dialog
          @dialog.visible? ? @dialog.bring_to_front : @dialog.show
        else
          @dialog = build_dialog
          @dialog.show
        end
        @dialog
      end

      # Sends an unsolicited message to the panel (used for selection changes).
      def push(event, data = {})
        deliver('event' => event, 'data' => data)
      end

      private

      def build_dialog
        dialog = UI::HtmlDialog.new(
          dialog_title: EXTENSION_NAME,
          preferences_key: PREFERENCES_KEY,
          scrollable: false,
          resizable: true,
          width: 400,
          height: 820,
          min_width: 340,
          min_height: 520,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        dialog.set_file(File.join(HTML_DIR, 'index.html'))
        dialog.add_action_callback('kcm_request') { |_context, json| handle_request(json) }
        dialog.set_on_closed { @dialog = nil }
        dialog
      end

      def handle_request(json)
        message = JSON.parse(json.to_s)
        result = dispatch(message['action'].to_s, message['data'])
        deliver(result.merge('id' => message['id']))
      rescue JSON::ParserError => e
        warn "[Kitchen Cabinet Master] Unreadable message from panel: #{e.message}"
      end

      def dispatch(action, data)
        data = {} unless data.is_a?(Hash)

        case action
        when 'init'          then Response.ok('', init_payload)
        when 'get_cabinets'  then Response.ok('', { 'cabinets' => CatalogManager.cabinets(data['catalog_id'], data['cabinet_category']) })
        when 'get_materials' then Response.ok('', { 'materials' => MaterialManager.options(Sketchup.active_model) })
        when *CABINET_ACTIONS then CabinetManager.perform(action, data)
        when *PART_ACTIONS then PartManager.perform(action, data)
        else Response.fail("Unknown action \"#{action}\".")
        end
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] #{e.class}: #{e.message}\n#{Array(e.backtrace).first(8).join("\n")}"
        Response.fail("Something went wrong: #{e.message}")
      end

      def init_payload
        {
          'version'         => EXTENSION_VERSION,
          'categories'      => Defaults::CATEGORIES,
          'directions'      => Defaults::DIRECTIONS,
          'standard_widths' => Defaults::STANDARD_WIDTHS,
          'catalogs'        => CatalogManager.catalogs,
          'handle_bundles'  => CatalogManager.handle_bundles,
          'handle_positions' => Defaults::HANDLE_POSITIONS,
          'handle_orientations' => Defaults::HANDLE_ORIENTATIONS,
          'end_panel_sides' => Defaults::END_PANEL_SIDES.map { |s| { 'id' => s, 'name' => s.capitalize } },
          'materials'       => MaterialManager.options(Sketchup.active_model),
          'defaults'        => Defaults.params,
          'filler_defaults' => Defaults.filler_params,
          'end_panel_defaults' => Defaults.end_panel_params,
          'toe_kick_defaults' => Defaults.toe_kick_params,
          'warnings'        => CatalogManager.warnings
        }
      end

      def deliver(payload)
        return unless @dialog

        json = JSON.generate(payload, script_safe: true)
        @dialog.execute_script("KCM.receive(#{json});")
      end
    end
  end
end
