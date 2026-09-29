# frozen_string_literal: true

module KitchenCabinetMaster
  # Human-friendly cabinet names.
  #
  #   name = unit code + width in mm      BU600   base unit, 600 wide
  #                                       WU800   wall unit, 800 wide
  #                                       TU600   tall unit, 600 wide
  #
  # Cabinets of the same size are copies of each other and are numbered the way
  # SketchUp numbers component copies:  BU600, BU600#1, BU600#2 ...
  #
  # This is only the DISPLAY name (the instance name shown in the Outliner and in
  # the panel). The permanent unique ID (CABINET_0001 ...) is still stored in the
  # attribute dictionary and never changes.
  module NamingManager
    COPY_SEPARATOR = '#'

    # "BU600": the unit code followed by the width.
    def self.base_name(params)
      code = params['name_code'].to_s
      code = Defaults::NAME_PREFIXES.fetch(params['cabinet_category'].to_s, 'CU') if code.empty?
      "#{code}#{format('%g', params['width'].to_f)}"
    end

    # "FIL100": a filler is named after its width, the same way a cabinet is.
    def self.filler_name(params)
      "#{Defaults::NAME_PREFIXES.fetch('filler', 'FIL')}#{format('%g', params['width'].to_f)}"
    end

    # "EP18": an end panel is named after its thickness, since its width and
    # height simply follow whatever it is attached to.
    def self.end_panel_name(params)
      "#{Defaults::NAME_PREFIXES.fetch('end_panel', 'EP')}#{format('%g', params['thickness'].to_f)}"
    end

    # "TK600x3": a toe kick is named after its piece length and how many pieces.
    def self.toe_kick_name(params)
      prefix = Defaults::NAME_PREFIXES.fetch('toe_kick', 'TK')
      "#{prefix}#{format('%g', params['toe_kick_piece_length'].to_f)}x#{params['toe_kick_pieces'].to_i}"
    end

    # `base` if no cabinet in `entities` has it yet, otherwise the first free
    # "base#1", "base#2" ... `ignore` is a cabinet that is allowed to keep its own name.
    def self.unique_name(entities, base, ignore = nil)
      taken = entities.grep(Sketchup::ComponentInstance).reject { |instance| instance.equal?(ignore) }.map(&:name)
      return base unless taken.include?(base)

      number = 1
      number += 1 while taken.include?("#{base}#{COPY_SEPARATOR}#{number}")
      "#{base}#{COPY_SEPARATOR}#{number}"
    end

    # After an Update the name follows the size: a cabinet that is still the same
    # size keeps its name (including its copy number); a resized one is renamed.
    def self.for_update(root, params)
      base = base_name(params)
      for_update_base(root, base)
    end

    # Same rule as `for_update`, given an already-computed base name (a filler or
    # an end panel, whose base name comes from `filler_name` / `end_panel_name`).
    def self.for_update_base(root, base)
      current = root.name.to_s
      return current if current == base || current.start_with?("#{base}#{COPY_SEPARATOR}")

      unique_name(root.parent.entities, base, root)
    end
  end
end
