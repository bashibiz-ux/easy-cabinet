# frozen_string_literal: true

module KitchenCabinetMaster
  # Parts that follow the cabinets by themselves while their tick in the Presets is on: the dimensions, and a side panel on every exposed side.
  # The ticks are kept in the model. After every change made through the panel (a cabinet inserted, changed, deleted, the kitchen designed ...) they
  # are drawn again, in a step that joins the change's own Undo step.
  module LiveParts
    DICTIONARY = 'KitchenCabinetMaster'
    KEY_DIMENSIONS = 'live_dimensions'
    KEY_SIDE_PANELS = 'live_side_panels'
    KEY_SIDE_VALUES = 'live_side_values'
    AUTO = 'auto_exposed' # marks a side panel this made (the ones you inserted yourself are never touched)
    AUTO_TOE = 'auto_toe' # and a toe kick this made
    KEY_TOE_KICKS = 'live_toe_kicks_on' # (the keys are new: a model that has an old Off written down starts On again)
    KEY_WALL_BOTTOM = 'live_wall_bottom_on'
    KEY_WORKTOP = 'live_worktop_on'
    KEY_LOFT = 'live_loft_on' # a loft over every wall and tall unit (see PartManager.sync_auto_lofts); off to begin with
    KEY_CEILING = 'live_ceiling_filler_on' # the ceiling filler over every loft (see PartManager.sync_ceiling_fillers)
    VALUES = { KEY_LOFT => 'live_loft_values', KEY_CEILING => 'live_ceiling_values', KEY_TOE_KICKS => 'live_toe_values', KEY_WALL_BOTTOM => 'live_bottom_values', KEY_WORKTOP => 'live_worktop_values' }.freeze
    MADE = { KEY_WALL_BOTTOM => 'live_bottom_made', KEY_WORKTOP => 'live_worktop_made' }.freeze # (made by the tick: taken away when it is turned off)

    def self.perform(action, raw)
      raw = {} unless raw.is_a?(Hash)
      model = Sketchup.active_model
      on = [true, 'true', 1, '1'].include?(raw['enabled'])
      case action
      when 'set_live_dimensions'
        model.set_attribute(DICTIONARY, KEY_DIMENSIONS, on)
        apply(model, "#{on ? 'Show' : 'Hide'} Dimensions") { sync_dimensions(model) }
        Response.ok(on ? 'Dimensions are on: they follow the cabinets.' : 'Dimensions are off.')
      when 'set_live_side_panels'
        model.set_attribute(DICTIONARY, KEY_SIDE_PANELS, on)
        forget(model, DISMISS_PREFIX.fetch(KEY_SIDE_PANELS)) unless on # (switched on again, the side panels that were deleted come back)
        model.set_attribute(DICTIONARY, KEY_SIDE_VALUES, JSON.generate(raw['values'])) if raw['values'].is_a?(Hash)
        apply(model, "#{on ? 'Place' : 'Remove'} Side Panels") { sync_side_panels(model) }
        cover_with_worktop(model) # (the worktop reaches over the side panels at its ends)
        Response.ok(on ? 'Side panels on every exposed side are on: they follow the cabinets.' : 'The side panels placed by the tick are taken away.')
      when 'set_live_toe_kicks'
        keep(model, KEY_TOE_KICKS, on, raw)
        apply(model, "#{on ? 'Place' : 'Remove'} Toe Kicks") { sync_toe_kicks(model) }
        Response.ok(on ? 'Toe kicks are on: they follow the cabinets.' : 'The toe kicks placed by the tick are taken away.')
      when 'set_live_loft'
        keep(model, KEY_LOFT, on, raw)
        refresh # (the lofts are placed, put in line with their units, and get their side panels and ceiling fillers, like after any change)
        Response.ok(on ? 'Lofts are on: every wall and tall unit has one.' : 'The lofts placed by the switch are taken away.')
      when 'set_live_ceiling_filler'
        keep(model, KEY_CEILING, on, raw)
        apply(model, "#{on ? 'Place' : 'Remove'} Ceiling Fillers") { sync_ceiling(model) }
        Response.ok(on ? 'Ceiling fillers are on: every loft has one.' : 'The ceiling fillers placed by the tick are taken away.')
      when 'set_live_wall_bottom'
        keep(model, KEY_WALL_BOTTOM, on, raw)
        sync_wall_bottom(model)
        Response.ok(on ? 'Wall unit bottom panels are on: they follow the cabinets.' : 'The bottom panels placed by the tick are taken away.')
      when 'set_live_worktop'
        keep(model, KEY_WORKTOP, on, raw)
        sync_worktop(model)
        Response.ok(on ? 'The worktop is on: it follows the cabinets.' : 'The worktop placed by the tick is taken away.')
      else Response.fail("Unknown action \"#{action}\".")
      end
    end

    # What the user took away with Delete stays away while the switch is on (the way it is told apart: a side panel by its cabinet and side, a toe
    # kick by the unit it starts at, the worktop and the bottom panels by their run of units). Turning the switch off and on again brings it back.
    KEY_DISMISSED = 'live_dismissed'
    DISMISS_PREFIX = { KEY_LOFT => 'loft', KEY_CEILING => 'ceiling', KEY_SIDE_PANELS => 'side', KEY_TOE_KICKS => 'toe', KEY_WORKTOP => 'worktop', KEY_WALL_BOTTOM => 'bottom' }.freeze

    def self.dismissed(model = Sketchup.active_model)
      JSON.parse(model.get_attribute(DICTIONARY, KEY_DISMISSED, '[]'))
    rescue JSON::ParserError
      []
    end

    def self.dismissed?(key) = dismissed.include?(key)

    # The ids dismissed under `prefix` ("worktop:123" => "123").
    def self.dismissed_ids(model, prefix)
      dismissed(model).filter_map { |key| key.split(':', 2)[1] if key.start_with?("#{prefix}:") }
    end

    def self.forget(model, prefix)
      model.set_attribute(DICTIONARY, KEY_DISMISSED, JSON.generate(dismissed(model).reject { |key| key.start_with?("#{prefix}:") }))
    end

    # Called before parts are deleted: those a switch made are remembered, so that the refresh does not put them back.
    def self.dismiss_parts(model, parts)
      keys = parts.filter_map { |part| key_for(part) }
      return if keys.empty?

      model.set_attribute(DICTIONARY, KEY_DISMISSED, JSON.generate((dismissed(model) + keys).uniq))
    end

    def self.key_for(part)
      dictionary = AttributeManager::DICTIONARY
      stored = AttributeManager.read(part) || {}
      return "loft:#{stored['loft_over']}" if part.get_attribute(dictionary, 'auto_loft') == true # (a loft the switch placed is told apart by its unit)

      ceiling = part.get_attribute(dictionary, 'ceiling_filler')
      return "ceiling:#{ceiling}" if ceiling # (a ceiling filler is told apart by its loft)

      case AttributeManager.part_kind(part)
      when 'end_panel', 'filler' then part.get_attribute(dictionary, AUTO) == true ? "side:#{stored['target_id']}:#{stored['side']}" : nil
      when 'toe_kick' then part.get_attribute(dictionary, AUTO_TOE) == true ? "toe:#{stored['toe_kick_from']}" : nil
      when 'worktop', 'backsplash' then worktop? && !stored['run_key'].to_s.empty? ? "worktop:#{stored['run_key']}" : nil
      when 'wall_bottom' then wall_bottom? && !stored['run_key'].to_s.empty? ? "bottom:#{stored['run_key']}" : nil
      end
    end

    # Writes down a tick and the settings that go with it (the panel's own fields, sent when the tick is changed).
    def self.keep(model, key, on, raw)
      model.set_attribute(DICTIONARY, key, on)
      forget(model, DISMISS_PREFIX.fetch(key)) unless on # (switched on again, everything comes back)
      model.set_attribute(DICTIONARY, VALUES[key], JSON.generate(raw['values'])) if raw['values'].is_a?(Hash)
    end
    private_class_method :keep

    def self.on?(key, default = true) = Sketchup.active_model.get_attribute(DICTIONARY, key, default) == true
    # Every switch is on to begin with, the dimensions apart.
    def self.toe_kicks? = on?(KEY_TOE_KICKS)
    def self.ceiling_fillers? = on?(KEY_CEILING)
    def self.lofts? = on?(KEY_LOFT, false)

    # The settings the ceiling fillers are drawn with (height, thickness, material), as sent by the panel.
    def self.ceiling_values(model = Sketchup.active_model) = values_of(model, KEY_CEILING)
    def self.wall_bottom? = on?(KEY_WALL_BOTTOM)
    def self.worktop? = on?(KEY_WORKTOP)

    def self.values_of(model, key)
      JSON.parse(model.get_attribute(DICTIONARY, VALUES[key], '{}'))
    rescue JSON::ParserError
      {}
    end
    private_class_method :values_of

    # An action of the panel that changes the settings of a part the ticks keep up: its values are the ones to draw it with from now on (the toe
    # kick fields send only what was changed; the worktop and the bottom panel send them all).
    def self.absorb(action, data)
      return unless data.is_a?(Hash)

      model = Sketchup.active_model
      case action
      when 'set_unit_sizes' then model.set_attribute(DICTIONARY, VALUES[KEY_LOFT], JSON.generate(values_of(model, KEY_LOFT).merge('height' => data['fields']['height']))) if data['category'] == 'loft' && data['fields'].is_a?(Hash) && !data['fields']['height'].to_s.strip.empty?
      when 'apply_ceiling_fillers' then model.set_attribute(DICTIONARY, VALUES[KEY_CEILING], JSON.generate(values_of(model, KEY_CEILING).merge(data.reject { |_, value| value.to_s.strip.empty? })))
      when 'apply_toe_kicks' then model.set_attribute(DICTIONARY, VALUES[KEY_TOE_KICKS], JSON.generate(values_of(model, KEY_TOE_KICKS).merge(data.reject { |_, value| value.to_s.strip.empty? })))
      when 'apply_worktop' then model.set_attribute(DICTIONARY, VALUES[KEY_WORKTOP], JSON.generate(data)) if worktop?
      when 'apply_wall_bottom' then model.set_attribute(DICTIONARY, VALUES[KEY_WALL_BOTTOM], JSON.generate(data)) if wall_bottom?
      end
    end

    def self.dimensions? = Sketchup.active_model.get_attribute(DICTIONARY, KEY_DIMENSIONS, false) == true
    # On to begin with: a cabinet is inserted with its side panels (the end of a row; against a wall, a filler instead). The tick turns it off.
    def self.side_panels? = Sketchup.active_model.get_attribute(DICTIONARY, KEY_SIDE_PANELS, true) == true

    # After an action of the panel: draw again what the ticks keep up. Quietly: nothing changes when no tick is on.
    def self.refresh
      model = Sketchup.active_model
      return unless model && (dimensions? || side_panels? || toe_kicks? || wall_bottom? || worktop? || ceiling_fillers? || lofts?)

      apply(model, 'Refresh Dimensions and Side Panels') do
        sync_lofts(model) # (the lofts the switch places first: they are units like the others for what follows)
        PartManager.send(:align_lofts, model) # (the lofts over their units first: a side panel goes up beside a loft)
        sync_side_panels(model) # (first: the dimensions are of the units)
        sync_toe_kicks(model)
        sync_dimensions(model)
        sync_ceiling(model) # (the lofts stand in line, and each has its ceiling filler)
      end
      kept = model.selection.to_a
      sync_worktop(model) # (the worktop and the bottom panels are steps of their own)
      sync_wall_bottom(model)
      keep_selection(model, kept)
      WorktopManager.report_splash(model) if defined?(WorktopManager)
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not refresh the live parts: #{e.message}"
      DialogManager.push('notice', { 'message' => "Some parts could not be drawn: #{e.message} at #{Array(e.backtrace).first.to_s[/\w+\.rb:\d+/]}" }) if defined?(DialogManager)
    end

    # One step of Undo that joins the one before it.
    def self.apply(model, name)
      kept = model.selection.to_a
      SelectionManager.suspend do
        model.start_operation(name, true, false, true)
        begin
          yield
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
      end
      keep_selection(model, kept)
    end
    private_class_method :apply

    # What was selected before stays selected (the parts that were drawn again may have cleared it).
    def self.keep_selection(model, kept)
      return if kept.empty?

      model.selection.clear
      kept.each { |item| model.selection.add(item) if item.valid? }
    end
    private_class_method :keep_selection

    def self.sync_dimensions(model)
      DimensionManager.remove_all(model)
      return unless dimensions?

      cabinets = model.entities.select { |entity| AttributeManager.cabinet?(entity) }
      DimensionManager.add(model, cabinets) unless cabinets.empty?
    end
    private_class_method :sync_dimensions

    # The worktop is drawn again after the side panels were placed or taken away, so that it covers them (or stops at the cabinets): with its switch on, as
    # the switch draws it; otherwise a worktop that is there (applied with the button) is rebuilt with its own settings.
    def self.cover_with_worktop(model)
      if worktop?
        sync_worktop(model)
      else
        kept = model.selection.to_a
        apply(model, 'Refresh Worktop') { WorktopManager.refresh(model) }
        keep_selection(model, kept)
      end
    end
    private_class_method :cover_with_worktop

    def self.sync_toe_kicks(model)
      PartManager.send(:remove_auto_toe_kicks, model)
      return unless toe_kicks?

      PartManager.send(:place_auto_toe_kicks, model, values_of(model, KEY_TOE_KICKS))
    end
    private_class_method :sync_toe_kicks

    # The worktop and the wall unit bottom panels are drawn by the Apply buttons' own code, again after every change. Turned off, what the tick
    # made is taken away (a worktop you applied yourself is left alone).
    def self.sync_worktop(model)
      if worktop?
        answer = WorktopManager.apply(values_of(model, KEY_WORKTOP).merge('only_if_exists' => false, 'skip_runs' => dismissed_ids(model, 'worktop')))
        model.set_attribute(DICTIONARY, MADE[KEY_WORKTOP], true) if answer['ok']
      elsif model.get_attribute(DICTIONARY, MADE[KEY_WORKTOP], false) == true
        WorktopManager.remove
        model.set_attribute(DICTIONARY, MADE[KEY_WORKTOP], false)
      end
    end
    private_class_method :sync_worktop

    def self.sync_wall_bottom(model)
      if wall_bottom?
        answer = WallBottomManager.apply(values_of(model, KEY_WALL_BOTTOM).merge('only_if_exists' => false, 'skip_runs' => dismissed_ids(model, 'bottom')))
        model.set_attribute(DICTIONARY, MADE[KEY_WALL_BOTTOM], true) if answer['ok']
      elsif model.get_attribute(DICTIONARY, MADE[KEY_WALL_BOTTOM], false) == true
        WallBottomManager.remove
        model.set_attribute(DICTIONARY, MADE[KEY_WALL_BOTTOM], false)
      end
    end
    private_class_method :sync_wall_bottom

    # The lofts are put in line (see PartManager.align_lofts); the ceiling fillers are drawn like the toe kicks: with the tick on, one over every loft but the
    # ones that were deleted, with the values of the Ceiling Filler section; with it off, none.
    def self.sync_ceiling(model)
      PartManager.send(:align_lofts, model)
      PartManager.send(:sync_ceiling_fillers, model, ceiling_fillers? ? values_of(model, KEY_CEILING) : nil, dismissed_ids(model, 'ceiling'))
    end
    private_class_method :sync_ceiling

    # The lofts of the Loft switch: with it on, every wall and tall unit that has no loft gets one (except where one was deleted: that stays so until the switch is
    # turned off and on); with it off, the lofts it placed are taken away.
    def self.sync_lofts(model)
      PartManager.send(:sync_auto_lofts, model, lofts? ? values_of(model, KEY_LOFT) : nil, dismissed_ids(model, 'loft'))
    end
    private_class_method :sync_lofts

    def self.sync_side_panels(model)
      PartManager.send(:remove_auto_panels, model)
      return unless side_panels?

      values = begin
        JSON.parse(model.get_attribute(DICTIONARY, KEY_SIDE_VALUES, '{}'))
      rescue JSON::ParserError
        {}
      end
      PartManager.send(:place_auto_panels, model, values)
    end
    private_class_method :sync_side_panels
  end
end