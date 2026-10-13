# frozen_string_literal: true

module KitchenCabinetMaster
  # Human-friendly cabinet names.
  #
  #   name = unit code + width in mm      BU600   base unit, 600 wide
  #                                       WU800   wall unit, 800 wide
  #                                       TU600   tall unit, 600 wide
  #
  # Cabinets of the same size and category share ONE name: two 600 mm base units
  # are both "BU600". (SketchUp itself may still number the component DEFINITION
  # behind each one, BU600#1, because definitions must have distinct names.)
  #
  # This is only the DISPLAY name (the instance name shown in the Outliner and in
  # the panel). The permanent unique ID (CABINET_0001 ...) is still stored in the
  # attribute dictionary and never changes.
  module NamingManager

    # "BU600": the unit code followed by the width.
    def self.base_name(params)
      code = params['name_code'].to_s
      code = Defaults::NAME_PREFIXES.fetch(params['cabinet_category'].to_s, 'CU') if code.empty?
      "#{code}#{format('%g', params['width'].to_f)}"
    end

    # The name of a cabinet's component DEFINITION: its name and its own number, "BU600 - 113" (SketchUp wants every definition to have a name of its
    # own, and would number the clashing ones itself, BU600#1, BU600#2 ...). The instance keeps the plain name, "BU600".
    def self.definition_name(label, cabinet_id)
      number = cabinet_id.to_s[/\d+/]
      number ? "#{label} - #{number.to_i}" : label.to_s
    end

    # "FIL100": a filler is named after its width, the same way a cabinet is.
    def self.filler_name(params)
      "#{Defaults::NAME_PREFIXES.fetch('filler', 'FIL')}#{format('%g', params['width'].to_f)}"
    end

    # "EP18": an side panel is named after its thickness, since its width and
    # height simply follow whatever it is attached to.
    def self.end_panel_name(params)
      "#{Defaults::NAME_PREFIXES.fetch('end_panel', 'EP')}#{format('%g', params['thickness'].to_f)}"
    end

    # "TK600x3": a toe kick is named after its piece length and how many pieces.
    def self.toe_kick_name(params)
      prefix = Defaults::NAME_PREFIXES.fetch('toe_kick', 'TK')
      "#{prefix}#{format('%g', params['toe_kick_piece_length'].to_f)}x#{params['toe_kick_pieces'].to_i}"
    end

    # Items of the same size deliberately share a name, so the name is just
    # `base`. (Kept as a method so every caller goes through one place.)
    def self.unique_name(_entities, base, _ignore = nil)
      base
    end

    # After an Update the name follows the size, so it is simply the new base name.
    def self.for_update(_root, params)
      base_name(params)
    end

    # Same rule as `for_update`, given an already-computed base name (a filler,
    # side panel or toe kick, whose base name comes from `filler_name` and friends).
    def self.for_update_base(_root, base)
      base
    end
  end
end
