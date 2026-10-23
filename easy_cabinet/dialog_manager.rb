# frozen_string_literal: true

require 'json'

module EasyCabinet
  # Owns the control-panel window and the messaging layer.
  #
  #   HTML -> Ruby : sketchup.ec_request(JSON.stringify({ id, action, data }))
  #   Ruby -> HTML : EC.receive({ id, ok, message, data, errors })      (reply)
  #                  EC.receive({ event, data })                        (push, no id)
  module DialogManager
    PREFERENCES_KEY = 'EasyCabinet.ControlPanel'
    CABINET_ACTIONS = %w[insert insert_at_point insert_on_path update duplicate delete toggle visibility rotate apply_all set_unit_sizes reset_unit_sizes add_appliance remove_appliance get_selection customize apply_front_design apply_glass_design save_to_catalog remove_from_catalog add_handle remove_handle].freeze
    PART_ACTIONS = %w[insert_filler insert_end_panel insert_panel insert_exposed_side_panels insert_toe_kick apply_toe_kicks apply_ceiling_fillers update_placed update_part delete_part].freeze
    LIVE_ACTIONS = %w[set_live_loft set_live_loft_follow set_live_loft_bottom set_live_ceiling_filler set_live_dimensions set_live_side_panels set_live_toe_kicks set_live_wall_bottom set_live_worktop].freeze
    WORKTOP_ACTIONS = %w[apply_worktop remove_worktop apply_wall_bottom remove_wall_bottom].freeze
    ROOM_ACTIONS = %w[build_room remove_room update_room create_layout_scenes].freeze
    CUT_LIST_ACTIONS = %w[get_cut_list export_cut_list].freeze
    PRESET_ACTIONS = %w[load_presets save_presets reset_presets].freeze
    KITCHEN_ACTIONS = %w[design_kitchen design_kitchen_options design_path_kitchen].freeze
    # After these the dimensions and side panels that are ticked in the Presets are drawn again (not after what only shows or hides things).
    # After these what was selected stays selected (with its new size or settings) until the user picks something else.
    KEEP_SELECTION = %w[toggle visibility update apply_all set_unit_sizes reset_unit_sizes apply_toe_kicks update_placed update_part apply_front_design apply_glass_design rotate customize
                        set_live_loft set_live_loft_follow set_live_loft_bottom set_live_ceiling_filler set_live_dimensions set_live_side_panels set_live_toe_kicks set_live_wall_bottom set_live_worktop apply_worktop apply_wall_bottom].freeze
    REFRESHING = (CABINET_ACTIONS + PART_ACTIONS + WORKTOP_ACTIONS + KITCHEN_ACTIONS - %w[toggle visibility get_selection]).freeze

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
        dialog.add_action_callback('ec_request') { |_context, json| handle_request(json) }
        dialog.set_on_closed { @dialog = nil }
        dialog
      end

      def handle_request(json)
        message = JSON.parse(json.to_s)
        result = dispatch(message['action'].to_s, message['data'])
        deliver(result.merge('id' => message['id']))
      rescue JSON::ParserError => e
        warn "[Easy Cabinet] Unreadable message from panel: #{e.message}"
      end

      def dispatch(action, data)
        data = {} unless data.is_a?(Hash)
        chosen = KEEP_SELECTION.include?(action) ? selection_keys(Sketchup.active_model) : nil

        result = case action
        when 'init'          then (organise_tags; unhide_base_units; CabinetManager.refresh_stale_gola; Response.ok('', init_payload))
        when 'undo'          then undo_last
        when 'set_snap'      then (SnapManager.enabled = data['enabled'] == true; Response.ok(SnapManager.enabled? ? 'Moved cabinets stick to their neighbours and the walls.' : 'Moved cabinets stay where you put them.'))
        when 'send_feedback' then FeedbackManager.perform(data)
        when 'open_donation' then FeedbackManager.donate
        when 'cancel_place'  then (PlaceTool.cancel; Response.ok('')) # (Esc in the panel: the cabinet that follows the cursor is dropped)
        when 'get_cabinets' then Response.ok('', { 'cabinets' => CatalogManager.cabinets(data['catalog_id'], data['cabinet_category']) })
        when 'get_cabinet_shapes' then Response.ok('', { 'shapes' => CabinetGallery.shapes(data['catalog_id'], data['cabinet_category']) }) # (the pictures of the gallery)
        when 'get_materials' then Response.ok('', { 'materials' => MaterialManager.options(Sketchup.active_model) })
        when 'add_material', 'remove_material' then MaterialManager.perform(action, data) # your own materials
        when *CABINET_ACTIONS then CabinetManager.perform(action, data)
        when *PART_ACTIONS then PartManager.perform(action, data)
        when *WORKTOP_ACTIONS then WorktopManager.perform(action, data)
        when *LIVE_ACTIONS then LiveParts.perform(action, data)
        when *KITCHEN_ACTIONS then KitchenManager.perform(action, data)
        when *ROOM_ACTIONS then RoomShell.perform(action, data)
        when *CUT_LIST_ACTIONS then CutListManager.perform(action, data)
        when *PRESET_ACTIONS then PresetManager.perform(action, data)
        else Response.fail("Unknown action \"#{action}\".")
        end
        LiveParts.absorb(action, data) if result.is_a?(Hash) && result['ok']
        LiveParts.refresh if result.is_a?(Hash) && result['ok'] && REFRESHING.include?(action)
        restore_selection(Sketchup.active_model, chosen) if chosen
        result
      rescue StandardError => e
        warn "[Easy Cabinet] #{e.class}: #{e.message}\n#{Array(e.backtrace).first(8).join("\n")}"
        Response.fail("Something went wrong: #{e.message}")
      end

      # What is selected, as the entity and the id it carries (an item drawn again is a new entity with the same id).
      def selection_keys(model)
        return [] unless model

        model.selection.to_a.map { |item| [item, identity_of(item) || identity_of(owner_of(model, item)), identity_of(owner_of(model, item))] }
      end

      def identity_of(item)
        return nil unless item.respond_to?(:get_attribute)

        AttributeManager.cabinet_id(item) || AttributeManager.part_id(item)
      end

      # The cabinet or part a selected piece (a door, a drawer, a panel inside it) belongs to.
      def owner_of(model, item)
        return nil unless item.respond_to?(:parent)

        definition = item.parent
        return nil unless definition.is_a?(Sketchup::ComponentDefinition)

        model.entities.grep(Sketchup::ComponentInstance).find { |other| other.definition == definition && identity_of(other) }
      end

      def restore_selection(model, chosen)
        return if chosen.empty? || model.nil?

        all = model.entities.grep(Sketchup::ComponentInstance)
        find = ->(id) { id && all.find { |other| identity_of(other) == id } }
        found = chosen.map do |item, id, owner_id|
          next item if item.valid?

          find.call(id) || find.call(owner_id) # (a piece inside a cabinet that was built again: the cabinet stays selected)
        end.compact.uniq
        return if found.empty?

        unless model.selection.to_a.sort_by(&:object_id) == found.sort_by(&:object_id)
          SelectionManager.suspend do
            model.selection.clear
            found.each { |item| model.selection.add(item) }
          end
        end
        SelectionManager.push_selection(model) # (the panel may have been told, while it was drawn again, that nothing is selected)
      rescue StandardError => e
        warn "[Easy Cabinet] Could not keep the selection: #{e.message}"
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
        warn "[Easy Cabinet] Could not show the base units: #{e.message}"
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
        warn "[Easy Cabinet] Could not organise tags: #{e.message}"
      end

      def init_payload
        {
          'version'         => EXTENSION_VERSION,
          'room_built'      => RoomShell.built?,
          'snap_enabled'    => SnapManager.enabled?,
          'live_dimensions' => LiveParts.dimensions?,
          'live_side_panels' => LiveParts.side_panels?,
          'live_toe_kicks' => LiveParts.toe_kicks?,
          'live_ceiling_filler' => LiveParts.ceiling_fillers?,
          'live_loft' => LiveParts.lofts?,
          'live_loft_follow' => LiveParts.loft_follow?,
          'live_loft_bottom' => LiveParts.loft_bottom?,
          'live_wall_bottom' => LiveParts.wall_bottom?,
          'live_worktop' => LiveParts.worktop?,
          'categories'      => Defaults::CATEGORIES,
          'directions'      => Defaults::DIRECTIONS,
          'standard_widths' => Defaults::STANDARD_WIDTHS,
          'catalogs'        => CatalogManager.catalogs,
          'front_designs'   => FrontDesign::DESIGNS,
          'kitchen_variations' => KitchenPlanner.variations,
          'my_appliances' => MyAppliances.list,
        'glass_designs'   => FrontDesign::GLASS_DESIGNS,
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
          'warnings'        => CatalogManager.warnings,
          'show_worktop'    => WorktopManager.shown?(Sketchup.active_model, 'worktop'),
          'show_backsplash' => WorktopManager.shown?(Sketchup.active_model, 'backsplash')
        }
      end

      def deliver(payload)
        return unless @dialog

        json = JSON.generate(payload, script_safe: true)
        @dialog.execute_script("EC.receive(#{json});")
      end
    end
  end
end
