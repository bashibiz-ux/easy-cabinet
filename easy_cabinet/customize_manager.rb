# frozen_string_literal: true

require 'json'

module EasyCabinet
  # The Customize window: a second window for ONE cabinet, with a picture of it that can be orbited, a list of its
  # boards and fields to change the size of any board and to move it. Every change is applied to the cabinet in the
  # model straight away (one Undo step each) and stored on it as `custom_overrides` (see Customizer).
  #
  #   window -> Ruby : sketchup.ec_cust(JSON.stringify({ id, action, data }))   get, set, reset, reset_all
  #   Ruby -> window : EC.receive({ id, ok, message, data })
  module CustomizeManager
    PREFERENCES_KEY = 'EasyCabinet.Customize'
    PART_KINDS = %w[filler end_panel toe_kick worktop backsplash].freeze # what, besides a cabinet, can be customized

    class << self
      # Shows the window for `root` (a cabinet instance).
      def open(root)
        @root = root
        if @dialog
          @dialog.visible? ? @dialog.bring_to_front : @dialog.show
          push_snapshot
        else
          @dialog = build_dialog
          @dialog.show
        end
        @dialog
      end

      def close
        dialog = @dialog
        @dialog = nil
        dialog&.close
      end

      private

      def build_dialog
        dialog = UI::HtmlDialog.new(
          dialog_title: "#{EXTENSION_NAME} - Customize",
          preferences_key: PREFERENCES_KEY,
          scrollable: false,
          resizable: true,
          width: 980,
          height: 660,
          min_width: 640,
          min_height: 420,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        dialog.set_file(File.join(HTML_DIR, 'customize.html'))
        dialog.add_action_callback('ec_cust') { |_context, json| handle(json) }
        dialog.set_on_closed { @dialog = nil }
        dialog
      end

      def handle(json)
        message = JSON.parse(json.to_s)
        deliver(dispatch(message['action'].to_s, message['data']).merge('id' => message['id']))
      rescue JSON::ParserError => e
        warn "[Easy Cabinet] Unreadable message from the Customize window: #{e.message}"
      end

      def dispatch(action, data)
        data = {} unless data.is_a?(Hash)
        return Response.fail('That cabinet is no longer in the model.') unless cabinet_valid?

        stored = AttributeManager.read(@root)
        overrides = ValidationManager.clean_overrides(stored['custom_overrides'])
        case action
        when 'get' then Response.ok('', snapshot)
        when 'set' then apply(Customizer.with_change(overrides, data['key'], Array(data['extent']), Array(data['move'])), 'Part changed.')
        when 'reset' then apply(Customizer.without(overrides, data['key']), 'Part put back.')
        when 'reset_all' then apply({}, 'Every part put back.')
        else Response.fail("Unknown action \"#{action}\".")
        end
      rescue StandardError => e
        warn "[Easy Cabinet] #{e.class}: #{e.message}\n#{Array(e.backtrace).first(8).join("\n")}"
        Response.fail("Something went wrong: #{e.message}")
      end

      def cabinet_valid?
        @root && @root.valid? && (AttributeManager.cabinet?(@root) || PART_KINDS.include?(AttributeManager.part_kind(@root)))
      end

      def cabinet?
        AttributeManager.cabinet?(@root)
      end

      # What the window draws and lists.
      def snapshot
        params = AttributeManager.read(@root)
        parts = cabinet? ? Customizer.parts(params) : Customizer.part_parts(params)
        { 'name' => @root.name, 'width' => params['width'], 'depth' => params['depth'], 'height' => params['height'], 'parts' => parts || [] }
      end

      def push_snapshot
        deliver('event' => 'snapshot', 'data' => snapshot) if cabinet_valid?
      end

      # Puts `overrides` on the cabinet and rebuilds it, checked by the same rules as an Update (a handle that no
      # longer fits a changed door is refused). One Undo step.
      def apply(overrides, done)
        return apply_to_part(overrides, done) unless cabinet?

        model = Sketchup.active_model
        stored = AttributeManager.read(@root)
        params, errors = CabinetManager.send(:restyle_params, model, stored, 'custom_overrides' => overrides)
        return Response.fail(errors.first['message'], errors) unless errors.empty?

        params['custom_overrides'] = overrides
        params['cabinet_name'] = NamingManager.for_update(@root, params)
        SelectionManager.suspend do
          model.start_operation('Customize Cabinet', true)
          begin
            CabinetGenerator.update(model, @root, params)
            PartManager.follow_door(model, @root)
            model.commit_operation
          rescue StandardError
            model.abort_operation
            raise
          end
        end
        Response.ok(done, snapshot)
      end

      # A filler, side panel, toe kick or worktop piece: its board is rebuilt from what it stored, with the changes.
      def apply_to_part(overrides, done)
        model = Sketchup.active_model
        params = AttributeManager.read(@root).merge('custom_overrides' => overrides)
        layout = PartLayout.layout_for(params)
        return Response.fail('This part was made by an older version and cannot be customized. Apply the worktop again first.') unless layout

        SelectionManager.suspend do
          model.start_operation('Customize Part', true)
          begin
            PartGenerator.update(model, @root, params, layout)
            model.commit_operation
          rescue StandardError
            model.abort_operation
            raise
          end
        end
        Response.ok(done, snapshot)
      end

      def deliver(payload)
        return unless @dialog

        @dialog.execute_script("EC.receive(#{JSON.generate(payload, script_safe: true)});")
      end
    end
  end
end
