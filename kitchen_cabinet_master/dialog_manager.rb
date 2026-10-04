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
    CABINET_ACTIONS = %w[insert update duplicate delete toggle visibility rotate apply_all get_selection customize].freeze
    PART_ACTIONS = %w[insert_filler insert_end_panel insert_toe_kick apply_toe_kicks update_part delete_part].freeze
    WORKTOP_ACTIONS = %w[apply_worktop remove_worktop apply_wall_bottom remove_wall_bottom].freeze
    CUT_LIST_ACTIONS = %w[get_cut_list export_cut_list].freeze
    PRESET_ACTIONS = %w[load_presets save_presets reset_presets].freeze

    class << self
      def show
        if @dialog
          @dialog.visible? ? @dialog.bring_to_front : @dialog.show
          SelectionManager.push_selection # what is selected in the model opens in the panel
        else
          @dialog = build_dialog
          @dialog.show
        end
        @dialog
      end

      def open?
        !@dialog.nil? && @dialog.visible?
      end

      def close
        dialog = @dialog
        @dialog = nil
        dialog&.close
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
        when 'init'          then (organise_tags; unhide_base_units; Response.ok('', init_payload))
        when 'undo'          then undo_last
        when 'get_cabinets' then Response.ok('', { 'cabinets' => CatalogManager.cabinets(data['catalog_id'], data['cabinet_category']) })
        when 'get_materials' then Response.ok('', { 'materials' => MaterialManager.options(Sketchup.active_model) })
        when *CABINET_ACTIONS then CabinetManager.perform(action, data)
        when *PART_ACTIONS then PartManager.perform(action, data)
        when *WORKTOP_ACTIONS then WorktopManager.perform(action, data)
        when *CUT_LIST_ACTIONS then CutListManager.perform(action, data)
        when *PRESET_ACTIONS then PresetManager.perform(action, data)
        else Response.fail("Unknown action \"#{action}\".")
        end
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] #{e.class}: #{e.message}\n#{Array(e.backtrace).first(8).join("\n")}"
        Response.fail("Something went wrong: #{e.message}")
      end

      # Same as Edit > Undo: steps the model back one operation (an Insert, Update,
      # live edit or snap is each one step).
      def undo_last
        Sketchup.undo
        Response.ok('Undone.')
      end

      # Opening the panel makes sure the Base Unit, Worktop, Wall Unit, Tall Unit and
      # Toe Kick tags exist and that what is already in the model is on them. Nothing
      # happens (and nothing is added to Undo) when it is all in place.
      # Version 0.36.0 had a "Hide base units" tick that is gone. A model saved with it ticked would
      # keep its base units hidden with nothing to show them again, so they are shown once, here.
      def unhide_base_units
        model = Sketchup.active_model
        dictionary = AttributeManager::DICTIONARY
        return unless model && model.get_attribute(dictionary, 'hide_base_units', false) == true

        model.start_operation('Show Base Units', true)
        begin
          model.entities.grep(Sketchup::ComponentInstance).each do |item|
            next if item.visible?

            category = item.get_attribute(dictionary, 'cabinet_category') || item.get_attribute(dictionary, 'target_category')
            kind = AttributeManager.part_kind(item)
            base_unit = AttributeManager.cabinet?(item) || %w[filler end_panel].include?(kind)
            item.visible = true if base_unit && category == 'base'
          end
          model.delete_attribute(dictionary, 'hide_base_units')
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Could not show the base units: #{e.message}"
      end

      def organise_tags
        model = Sketchup.active_model
        return unless model && TagManager.needs_sync?(model)

        model.start_operation('Organise Tags', true)
        begin
          TagManager.sync_existing(model)
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
      rescue StandardError => e
        warn "[Kitchen Cabinet Master] Could not organise tags: #{e.message}"
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
          'handle_horizontal_places' => Defaults::HANDLE_HORIZONTAL_PLACES,
          'handle_orientations' => Defaults::HANDLE_ORIENTATIONS,
          'end_panel_sides' => Defaults::END_PANEL_SIDES.map { |s| { 'id' => s, 'name' => s.capitalize } },
          'materials'       => MaterialManager.options(Sketchup.active_model),
          'defaults'        => Defaults.params,
          'filler_defaults' => Defaults.filler_params,
          'end_panel_defaults' => Defaults.end_panel_params,
          'toe_kick_defaults' => Defaults.toe_kick_params,
          'worktop_defaults'  => Worktop::DEFAULTS,
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
